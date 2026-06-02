#import "AppDetailViewController.h"
#import "InstallManager.h"
#import "IconLoader.h"
#import "VersionsViewController.h"
#import "IOS6Theme.h"
#import "Localization.h"
#import "LocalCatalog.h"
#import "DeviceInfo.h"

@interface AppDetailViewController () <UIAlertViewDelegate>
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *installButton;
@property (nonatomic, strong) UITextView *infoView;
// v1.3.1: richer download progress block under the Install button.
// progressContainer wraps the progress view + bytes/speed label so we can
// toggle visibility as a unit when the job leaves the downloading state.
@property (nonatomic, strong) UIView *progressContainer;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UILabel *progressLabel;
// v1.7: YES if we auto-switched to an older version because the latest needs a newer iOS.
@property (nonatomic, assign) BOOL pickedCompatibleVersion;
// v1.6 "Works today" update detection: version ipainstaller reports installed (nil if not
// installed) + whether the curated revival.json build is newer.
@property (nonatomic, copy) NSString *installedVersion;
@property (nonatomic, assign) BOOL hasUpdate;
@end

// Numeric version compare: -1 (a<b), 0 (a==b), 1 (a>b). e.g. "0.8.7" < "0.8.8".
static int ADVerCmp(NSString *a, NSString *b) {
    NSArray *ca = [(a ?: @"") componentsSeparatedByString:@"."];
    NSArray *cb = [(b ?: @"") componentsSeparatedByString:@"."];
    NSUInteger n = MAX(ca.count, cb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger x = (i < ca.count) ? [ca[i] integerValue] : 0;
        NSInteger y = (i < cb.count) ? [cb[i] integerValue] : 0;
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}

@implementation AppDetailViewController

- (instancetype)initWithApp:(NSDictionary *)app {
    return [self initWithApp:app allowVersionSwitch:YES];
}

- (instancetype)initWithApp:(NSDictionary *)app allowVersionSwitch:(BOOL)allow {
    if ((self = [super init])) {
        // If the version we were handed can't run on THIS device (its min iOS is newer),
        // switch to the latest version that CAN — so the whole screen + the Install
        // button use a compatible build, not a too-recent one. Skipped when the user
        // explicitly picked a version in the Versions menu (allow=NO).
        if (allow) {
            LocalCatalog *cat = [LocalCatalog shared];
            NSString *bid = app[@"bundleId"];
            if (bid.length && ![cat deviceCanRunMinIOS:app[@"minOS"]]) {
                NSDictionary *compat = [cat latestCompatibleVersionForBundleId:bid];
                if (compat) { app = compat; self.pickedCompatibleVersion = YES; }
            }
        }
        self.app = app;
    }
    return self;
}

- (NSString *)humanSize:(long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld %@", bytes, T(@"unit.b")];
    if (bytes < 1024*1024) return [NSString stringWithFormat:@"%.0f %@", bytes/1024.0, T(@"unit.kb")];
    if (bytes < 1024LL*1024*1024) return [NSString stringWithFormat:@"%.1f %@", bytes/(1024.0*1024), T(@"unit.mb")];
    return [NSString stringWithFormat:@"%.2f %@", bytes/(1024.0*1024*1024), T(@"unit.gb")];
}

// Decode the `plat` bitmask. Catalog upstream (stuffed18) stores it as 1 << UIDeviceFamily,
// not as raw UIDeviceFamily values:
//   bit 1 (value 2)  = iPhone / iPod touch  (UIDeviceFamily=1 → 1<<1 = 2)
//   bit 2 (value 4)  = iPad                 (UIDeviceFamily=2 → 1<<2 = 4)
//   bit 3 (value 8)  = AppleTV              (UIDeviceFamily=3 → 1<<3 = 8)
//   bit 4 (value 16) = Watch                (UIDeviceFamily=4 → 1<<4 = 16)
// Common combinations observed in the 157k catalog: 2 (iPhone-only), 4 (iPad-only),
// 6 (universal = 2|4), 8 (TV-only), 14 (iPhone+iPad+TV), 18 (iPhone+Watch).
- (NSString *)platformDescription:(NSInteger)mask {
    NSMutableArray *p = [NSMutableArray array];
    if (mask & 2)  [p addObject:@"iPhone"];
    if (mask & 4)  [p addObject:@"iPad"];
    if (mask & 8)  [p addObject:@"AppleTV"];
    if (mask & 16) [p addObject:@"Watch"];
    if (p.count == 0) return @"?";
    return [p componentsJoinedByString:@", "];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];  // App Store white
    self.title = self.app[@"title"] ?: T(@"app.fallback_title");

    // Right bar: "Versions" if bundleId available
    NSString *bid = self.app[@"bundleId"];
    if (bid.length) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:T(@"app.versions")
                                              style:UIBarButtonItemStyleBordered
                                             target:self
                                             action:@selector(versionsTapped)];
    }

    [self buildLayout];
    [self loadIcon];
    [self checkRevivalUpdate];
}

- (void)versionsTapped {
    NSString *bid = self.app[@"bundleId"];
    if (!bid.length) return;
    VersionsViewController *vc = [[VersionsViewController alloc] initWithBundleId:bid
                                                                              title:self.app[@"title"] ?: T(@"app.versions")];
    [self.navigationController pushViewController:vc animated:YES];
}

// v2.0.9: the per-row filename mismatch detection (normalizeForMatch: + checkFilenameMismatch
// + persistent red banner + install confirmation alert) is gone. The catalog-quality reminder
// shown by AppDelegate at every launch covers the same ground without bothering the user on
// every tap. The .ipa filename is still printed in the cell list and the detail info text so
// the user can spot mismatches manually.

- (void)buildLayout {
    CGRect b = self.view.bounds;
    CGFloat w = b.size.width;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 120)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    header.backgroundColor = [UIColor whiteColor];

    self.iconView = [[UIImageView alloc] initWithFrame:CGRectMake(15, 15, 90, 90)];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    // v1.3.2.1: clear (not gray) — pre-rounded icon corners are transparent;
    // the gray placeholder bg showed as a square contour around the rounding.
    self.iconView.backgroundColor = [UIColor clearColor];
    // No layer.cornerRadius / borderWidth (offscreen render = slow on iPad A4/A6X)
    [header addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(120, 18, w - 135, 28)];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    self.titleLabel.text = self.app[@"title"] ?: @"?";  // ? is not a translatable string
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(120, 50, w - 135, 16)];
    self.subtitleLabel.font = [UIFont systemFontOfSize:13];
    self.subtitleLabel.textColor = [UIColor darkGrayColor];
    long long size = [self.app[@"size"] longLongValue];
    NSString *sizeStr = size > 0 ? [self humanSize:size] : T(@"app.size_unknown");
    self.subtitleLabel.text = [NSString stringWithFormat:T(@"app.subtitle_with_size"),
                                 self.app[@"version"] ?: @"?", sizeStr];
    self.subtitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:self.subtitleLabel];

    // v2.0.27: removed the small InstallProgressButton beside this one — redundant
    // with the title text feedback. The big button now reclaims the full width.
    self.installButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.installButton.frame = CGRectMake(120, 72, w - 135, 34);
    [self.installButton setTitle:T(@"app.install") forState:UIControlStateNormal];
    [IOS6Theme styleButton:self.installButton];
    self.installButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.installButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.installButton addTarget:self action:@selector(installTapped)
                  forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.installButton];

    // v1.3.1: live download progress under the Install button. Hidden until
    // the job enters the downloading state, then animates the bar from 0→100
    // and prints "%.1f / %.1f MB · %.0f KB/s" on a second line. Reddit users
    // asked for this in the detail screen — the button title alone was too
    // terse for the long iPad-Pro-sized download bytes count.
    CGFloat headerH = 156;
    UIView *header2 = header; // alias keeps the edits below local
    self.progressContainer = [[UIView alloc] initWithFrame:CGRectMake(15, 116, w - 30, 36)];
    self.progressContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.progressContainer.backgroundColor = [UIColor clearColor];
    self.progressContainer.hidden = YES;

    self.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressBar.frame = CGRectMake(0, 4, self.progressContainer.bounds.size.width, 9);
    self.progressBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.progressBar.progressTintColor = [IOS6Theme primaryBlue];
    [self.progressContainer addSubview:self.progressBar];

    self.progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, self.progressContainer.bounds.size.width, 18)];
    self.progressLabel.font = [UIFont systemFontOfSize:12];
    self.progressLabel.textColor = [UIColor darkGrayColor];
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.progressContainer addSubview:self.progressLabel];

    [header2 addSubview:self.progressContainer];
    header2.frame = CGRectMake(0, 0, w, headerH);

    // Watch job state so the big button's TITLE reflects the live state (Téléchargement
    // 42 %, Installation…, Installé, etc.). The ring widget on catalog cells does its
    // own subscription independently.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(refreshInstallButtonTitle)
            name:InstallManagerJobsChangedNotification
          object:nil];
    [self refreshInstallButtonTitle];

    [self.view addSubview:header];

    // v1.7: STRICT compatibility verdict, computed locally from REAL per-version data
    // (this EXACT IPA's real minimum iOS + platform bitmask). Shown on EVERY version —
    // even the obscure long tail with no AI description. nil = no real signal -> no banner.
    CGFloat contentY = headerH;

    NSDictionary *verdict =
        [DeviceInfo compatibilityVerdictForAppMinIOS:self.app[@"minOS"]
                                            platform:[self.app[@"platform"] integerValue]];
    if (verdict) {
        NSInteger level = [verdict[@"level"] integerValue];   // 0 = compatible, 2 = won't run
        UIColor *bg = (level == 0) ? [UIColor colorWithRed:0.84 green:0.93 blue:0.81 alpha:1.0]
                                   : [UIColor colorWithRed:0.98 green:0.84 blue:0.82 alpha:1.0];
        UIColor *fg = (level == 0) ? [UIColor colorWithRed:0.11 green:0.42 blue:0.13 alpha:1.0]
                                   : [UIColor colorWithRed:0.62 green:0.11 blue:0.10 alpha:1.0];
        NSString *prefix = (level == 0) ? @"✓  " : @"✗  ";

        NSString *msg = [prefix stringByAppendingString:(verdict[@"message"] ?: @"")];
        if (self.pickedCompatibleVersion) {
            // We auto-selected an older build because the newest needs a higher iOS.
            msg = [msg stringByAppendingFormat:@"\n%@", T(@"app.picked_compatible")];
        }
        CGFloat bh = self.pickedCompatibleVersion ? 58 : 40;
        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(0, contentY, w, bh)];
        banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        banner.backgroundColor = bg;
        UILabel *bl = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w - 24, bh)];
        bl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        bl.numberOfLines = self.pickedCompatibleVersion ? 3 : 2;
        bl.backgroundColor = [UIColor clearColor];
        bl.font = [UIFont boldSystemFontOfSize:13];
        bl.textColor = fg;
        bl.text = msg;
        [banner addSubview:bl];
        [self.view addSubview:banner];
        contentY += bh;
    }

    // AI description text — resolved by BUNDLE ID so it appears on every version.
    // The old AI "known issues" note is intentionally NOT shown anymore: it was
    // unreliable, templated boilerplate that just duplicated the verdict above.
    NSString *descText = nil;
    NSDictionary *desc = [[LocalCatalog shared] descriptionForBundleId:self.app[@"bundleId"]];
    if (!desc) {
        NSInteger pk = [self.app[@"id"] integerValue];
        if (pk > 0) desc = [[LocalCatalog shared] descriptionForPK:pk];
    }
    if (desc) descText = [self cleanMarkdown:desc[@"text"]];

    // Info text below (offset by verdict banner if shown)
    self.infoView = [[UITextView alloc] initWithFrame:CGRectMake(0, contentY, w, b.size.height - contentY)];
    self.infoView.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.infoView.font = [UIFont systemFontOfSize:13];
    self.infoView.editable = NO;
    self.infoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // textContainerInset is iOS 7+; on iOS 5/6 use contentInset for padding
    self.infoView.contentInset = UIEdgeInsetsMake(8, 8, 8, 8);

    NSString *fname = self.app[@"fileName"] ?: @"?";
    NSURL *u = [NSURL URLWithString:self.app[@"url"] ?: @""];
    NSString *host = u.host ?: @"?";

    NSString *tech = [NSString stringWithFormat:
        @"%@ : %@\n%@ : %@\n%@ : %@\n%@ : %@\n%@ : %@\n\n%@ : %@\n%@ : %@\n\n%@ :\n%@",
        T(@"app.info_bundle_id"), self.app[@"bundleId"] ?: @"?",
        T(@"app.info_version"), self.app[@"version"] ?: @"?",
        T(@"app.info_min_ios"), self.app[@"minOS"] ?: @"?",
        T(@"app.info_platform"), [self platformDescription:[self.app[@"platform"] integerValue]],
        T(@"app.info_size"), sizeStr,
        T(@"app.info_file"), fname,
        T(@"app.info_mirror"), host,
        T(@"app.info_url"), self.app[@"url"] ?: @"?"];

    if (descText.length) {
        // AI description on top, then a divider, then the technical details.
        self.infoView.text = [NSString stringWithFormat:@"%@\n\n———————————\n\n%@", descText, tech];
    } else {
        self.infoView.text = tech;
    }
    [self.view addSubview:self.infoView];
}

// Strip the light Markdown the AI emits (**bold**, *italic*, ## headings) so it
// reads cleanly in a plain UITextView on iOS 5/6. Keeps "- " bullets + line breaks.
- (NSString *)cleanMarkdown:(NSString *)s {
    if (![s isKindOfClass:[NSString class]] || !s.length) return @"";
    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"**" withString:@"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"## " withString:@"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"# "  withString:@"" options:0 range:NSMakeRange(0, m.length)];
    return [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)loadIcon {
    NSString *iconUrl = self.app[@"icon"];
    if (!iconUrl.length) return;
    CGSize sz = CGSizeMake(90, 90);
    UIImage *cached = [[IconLoader shared] cachedImageForURL:iconUrl targetSize:sz];
    if (cached) { self.iconView.image = cached; return; }
    [[IconLoader shared] loadImageForURL:iconUrl
                               targetSize:sz
                                      via:nil
                               completion:^(UIImage *img) {
        if (img) self.iconView.image = img;
    }];
}

// Revival apps support in-place updates: look up the version ipainstaller has on disk for
// this bundle id (off the main thread) and, if the curated revival.json build is newer, turn
// the big button into "Update to vX". Tapping it re-installs the .ipa over the old copy.
// No-op for catalogue apps (they never carry isRevival).
- (void)checkRevivalUpdate {
    if (![self.app[@"isRevival"] boolValue]) return;
    NSString *bid = self.app[@"bundleId"];
    NSString *curated = self.app[@"version"];
    if (!bid.length || !curated.length) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *inst = [[InstallManager shared] installedVersionForBundleId:bid];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.installedVersion = inst;
            self.hasUpdate = (inst.length > 0 && ADVerCmp(inst, curated) < 0);
            [self refreshInstallButtonTitle];
        });
    });
}

- (void)installTapped {
    NSString *url = self.app[@"url"];
    if (!url.length) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"app.no_url")
                                                    message:T(@"app.no_url_msg")
                                                   delegate:nil
                                          cancelButtonTitle:T(@"common.ok")
                                          otherButtonTitles:nil];
        [a show];
        return;
    }
    // v1.5-10: ipainstaller is now a hard Depends in the .deb (Cydia enforces
    // it at install time), so the in-app "do you have ipainstaller?" alert
    // is redundant. Go straight to install.
    [self doInstall];
}

- (void)doInstall {
    NSString *url = self.app[@"url"];
    // Dedup: if a job for this URL is already in flight, don't kick off another.
    // Otherwise tapping the button twice stacks two parallel downloads and
    // ipainstaller installs the .ipa twice.
    if ([[InstallManager shared] hasActiveJobForURL:url]) {
        // Title already reflects active state via refreshInstallButtonTitle.
        return;
    }
    self.installButton.enabled = NO;
    [self.installButton setTitle:T(@"app.starting") forState:UIControlStateNormal];
    [[InstallManager shared] startInstallWithURL:url
                                       completion:^(NSString *jobId, NSError *err) {
        self.installButton.enabled = YES;
        if (err) {
            [self.installButton setTitle:T(@"app.install") forState:UIControlStateNormal];
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"common.error")
                                                        message:err.localizedDescription
                                                       delegate:nil
                                              cancelButtonTitle:T(@"common.ok")
                                              otherButtonTitles:nil];
            [a show];
            return;
        }
        // Stay on the detail screen — title reflects progress via the notification
        // handler. The Jobs tab still works for a list view.
        [self refreshInstallButtonTitle];
    }];
}

// Update the big-button title to reflect the live state of the install job for THIS
// app. Called on every InstallManagerJobsChangedNotification, and once at view-load.
// Idle / completed states keep the standard "Installer" label so the user can re-tap
// to install again (useful if they want to redo a botched install).
- (void)refreshInstallButtonTitle {
    NSString *appURL = self.app[@"url"];
    if (!appURL.length) return;
    InstallJob *job = nil;
    for (InstallJob *j in [[InstallManager shared] jobs]) {
        if ([j.url isEqualToString:appURL]) { job = j; break; }
    }
    NSString *state = job.state ?: @"";
    NSString *title;
    if ([state isEqualToString:@"downloading"]) {
        title = [NSString stringWithFormat:T(@"app.btn.downloading"), (long)job.progress];
    } else if ([state isEqualToString:@"installing"]) {
        title = T(@"app.btn.installing");
    } else if ([state isEqualToString:@"queued"]) {
        title = T(@"app.btn.queued");
    } else if ([state isEqualToString:@"completed"]) {
        title = T(@"app.btn.installed");
    } else if ([state isEqualToString:@"failed"]) {
        title = T(@"app.btn.retry");
    } else if ([state isEqualToString:@"cancelled"]) {
        title = T(@"app.btn.retry");
    } else {
        title = T(@"app.install");
    }
    // v1.6 "Works today": when the curated build is newer than the installed one, the idle
    // button reads "Update to vX". A completed install means we're current again.
    if ([state isEqualToString:@"completed"]) self.hasUpdate = NO;
    BOOL liveJob = [state isEqualToString:@"downloading"]
                || [state isEqualToString:@"installing"]
                || [state isEqualToString:@"queued"];
    if (self.hasUpdate && !liveJob) {
        title = [NSString stringWithFormat:T(@"revival.update"), self.app[@"version"] ?: @"?"];
    }
    [self.installButton setTitle:title forState:UIControlStateNormal];

    // v1.3.1: drive the progress widget. Visible during downloading/installing.
    // Hidden for idle/queued/completed/failed/cancelled to keep the screen clean.
    BOOL showProgress = [state isEqualToString:@"downloading"]
                     || [state isEqualToString:@"installing"];
    self.progressContainer.hidden = !showProgress;
    if (!showProgress) return;

    if ([state isEqualToString:@"installing"]) {
        // ipainstaller is opaque about progress — just show a full bar +
        // generic "Installing…" label. Faster reassuring feedback than a
        // half-filled bar that doesn't move.
        [self.progressBar setProgress:1.0 animated:NO];
        self.progressLabel.text = T(@"app.btn.installing");
        return;
    }

    // Downloading state. Animate the bar; build a "12.3 / 45.6 MB · 320 KB/s"
    // label from the byte counters InstallManager fills in for ETA tracking.
    float frac = MAX(0.0f, MIN(1.0f, (float)job.progress / 100.0f));
    [self.progressBar setProgress:frac animated:YES];

    NSString *bytesPart;
    if (job.totalBytes > 0) {
        bytesPart = [NSString stringWithFormat:@"%@ / %@",
                       [self humanSize:job.currentBytes],
                       [self humanSize:job.totalBytes]];
    } else if (job.currentBytes > 0) {
        bytesPart = [self humanSize:job.currentBytes];
    } else {
        bytesPart = nil;
    }

    NSString *speedPart = nil;
    if (job.bytesPerSec > 1024.0) {
        // Speed in KB/s for readability — most archive.org mirrors land
        // between 50 KB/s and 2 MB/s on a typical home connection.
        if (job.bytesPerSec >= 1024.0 * 1024.0) {
            speedPart = [NSString stringWithFormat:@"%.1f %@/s",
                           job.bytesPerSec / (1024.0 * 1024.0), T(@"unit.mb")];
        } else {
            speedPart = [NSString stringWithFormat:@"%.0f %@/s",
                           job.bytesPerSec / 1024.0, T(@"unit.kb")];
        }
    }

    if (bytesPart && speedPart) {
        self.progressLabel.text = [NSString stringWithFormat:@"%@ · %@", bytesPart, speedPart];
    } else if (bytesPart) {
        self.progressLabel.text = bytesPart;
    } else {
        self.progressLabel.text = [NSString stringWithFormat:@"%ld%%", (long)job.progress];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
