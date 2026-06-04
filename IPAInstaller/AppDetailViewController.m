#import "AppDetailViewController.h"
#import "InstallManager.h"
#import "IconLoader.h"
#import "VersionsViewController.h"
#import "IOS6Theme.h"
#import "Localization.h"
#import "LocalCatalog.h"
#import "DeviceInfo.h"
#import "CollectionStore.h"
#import "MachOInspector.h"

@interface AppDetailViewController () <UIAlertViewDelegate>
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *installButton;
@property (nonatomic, strong) UIButton *laterButton;   // ⏱ add to "Télécharger plus tard"
@property (nonatomic, strong) UIButton *cancelButton;  // ✕ cancel a download/install in progress
@property (nonatomic, strong) UIButton *pauseButton;   // ⏸/▶ pause or resume a download in progress
@property (nonatomic, strong) UITextView *infoView;
// v1.3.1: richer download progress block under the Install button.
// progressContainer wraps the progress view + bytes/speed label so we can
// toggle visibility as a unit when the job leaves the downloading state.
@property (nonatomic, strong) UIView *progressContainer;
@property (nonatomic, strong) UIView *progressBar;     // custom track (no iOS-6 white UIProgressView groove)
@property (nonatomic, strong) UIView *progressFill;    // themed fill inside the track
@property (nonatomic, assign) CGFloat progressFrac;    // 0..1, re-applied on layout (rotation)
@property (nonatomic, strong) UILabel *progressLabel;
// Compatibility banner refs so a LIVE theme switch can recolour it (its colours are theme-dependent
// but were baked in at build time → stale white/black text after a dark↔light switch otherwise).
@property (nonatomic, strong) UIView *banner;
@property (nonatomic, strong) UILabel *bannerLabel;
@property (nonatomic, assign) NSInteger bannerLevel;   // 0 = compatible, 2 = won't run
// v1.7: YES if we auto-switched to an older version because the latest needs a newer iOS.
@property (nonatomic, assign) BOOL pickedCompatibleVersion;
// v1.6 "Works today" update detection: version ipainstaller reports installed (nil if not
// installed) + whether the curated revival.json build is newer.
@property (nonatomic, copy) NSString *installedVersion;
@property (nonatomic, assign) BOOL hasUpdate;
@property (nonatomic, strong) UIBarButtonItem *favBtn;   // ★ / ☆ favourite toggle
// FairPlay-encryption probe (over HTTP Range, no full download). If this exact version is
// encrypted (won't run), the banner says so; recommendedVersion is a decrypted build of the
// same app (if one exists) that tapping the banner opens.
@property (nonatomic, strong) UITapGestureRecognizer *bannerTap;
@property (nonatomic, copy) NSDictionary *recommendedVersion;
@property (nonatomic, assign) CGFloat contentTopY;       // Y where the banner/info content begins
@property (nonatomic, assign) BOOL encryptionProbed;     // probe at most once per screen
// YES when this screen auto-picks a compatible version (catalog tap); NO when the user explicitly
// chose a build in the Versions list. Drives encryption handling: auto path REDIRECTS to a
// decrypted build, explicit path just shows the tappable 🔒 banner.
@property (nonatomic, assign) BOOL allowVersionSwitch;
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

// A UITextView that NEVER scrolls horizontally — it clamps the x content-offset to its
// resting (left-inset) position. The description scrolls vertically only; a long URL or
// filename can't drag it sideways (feedback: detail screen scrolled left-right on iPhone +
// iPad even once the text wrapped). Works on every iOS (UITextView doesn't forward scroll
// delegate calls, so overriding setContentOffset: is the reliable hook).
@interface ADVerticalTextView : UITextView
@end
@implementation ADVerticalTextView
- (void)setContentOffset:(CGPoint)offset {
    [super setContentOffset:CGPointMake(-self.contentInset.left, offset.y)];
}
@end

// White clock glyph for the "Plus tard" button — sits on the glossy accent button (white = legible
// on every theme's accent).
static UIImage *ADLaterClockGlyph(void) {
    static UIImage *img = nil;
    if (img) return img;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(26, 26), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(4, 4, 18, 18));
    CGContextMoveToPoint(ctx, 13, 13); CGContextAddLineToPoint(ctx, 13, 7.5);  CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, 13, 13); CGContextAddLineToPoint(ctx, 17.5, 15); CGContextStrokePath(ctx);
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// White "install" glyph (down arrow into a tray) — sits on the accent-coloured Install button.
static UIImage *ADInstallGlyph(void) {
    static UIImage *img = nil;
    if (img) return img;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(26, 26), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 2.2);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, 13, 4);  CGContextAddLineToPoint(ctx, 13, 15);  CGContextStrokePath(ctx); // shaft
    CGContextMoveToPoint(ctx, 8, 10);  CGContextAddLineToPoint(ctx, 13, 15);  CGContextAddLineToPoint(ctx, 18, 10); CGContextStrokePath(ctx); // arrowhead
    CGContextMoveToPoint(ctx, 6, 20);  CGContextAddLineToPoint(ctx, 20, 20);  CGContextStrokePath(ctx); // tray
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// White pause "❚❚" glyph.
static UIImage *ADPauseGlyph(void) {
    static UIImage *img = nil;
    if (img) return img;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(26, 26), NO, [UIScreen mainScreen].scale);
    [[UIColor whiteColor] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(8, 7, 3.4, 12) cornerRadius:1.5] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(15, 7, 3.4, 12) cornerRadius:1.5] fill];
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// White resume "▶" (play) glyph.
static UIImage *ADResumeGlyph(void) {
    static UIImage *img = nil;
    if (img) return img;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(26, 26), NO, [UIScreen mainScreen].scale);
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(9, 6)];
    [p addLineToPoint:CGPointMake(20, 13)];
    [p addLineToPoint:CGPointMake(9, 20)];
    [p closePath];
    [[UIColor whiteColor] setFill];
    [p fill];
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// White cancel "✕" glyph — sits on the glossy accent button.
static UIImage *ADCancelGlyph(void) {
    static UIImage *img = nil;
    if (img) return img;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(26, 26), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 2.4);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextMoveToPoint(ctx, 8, 8);   CGContextAddLineToPoint(ctx, 18, 18); CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, 18, 8);  CGContextAddLineToPoint(ctx, 8, 18);  CGContextStrokePath(ctx);
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

@implementation AppDetailViewController

- (instancetype)initWithApp:(NSDictionary *)app {
    return [self initWithApp:app allowVersionSwitch:YES];
}

- (instancetype)initWithApp:(NSDictionary *)app allowVersionSwitch:(BOOL)allow {
    if ((self = [super init])) {
        self.allowVersionSwitch = allow;
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

// Live theme re-apply. Re-themes the header (built once in -buildLayout) too, so a live theme
// switch while this screen is open doesn't leave the white header + title behind.
- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
    if (self.titleLabel) {
        self.titleLabel.superview.backgroundColor = [IOS6Theme contentBackgroundColor];  // the header view
        self.titleLabel.backgroundColor = [UIColor clearColor];
        self.titleLabel.textColor = [IOS6Theme labelDark];
    }
    if (self.subtitleLabel) {
        self.subtitleLabel.backgroundColor = [UIColor clearColor];
        self.subtitleLabel.textColor = [IOS6Theme labelGray];
    }
    if (self.infoView) {
        self.infoView.backgroundColor = [IOS6Theme contentBackgroundColor];
        self.infoView.textColor = [IOS6Theme labelDark];   // <-- the live-switch fix: text was stale
    }
    if (self.progressLabel) self.progressLabel.textColor = [IOS6Theme labelGray];
    if (self.progressBar) {
        self.progressBar.backgroundColor = [IOS6Theme isDark] ? [UIColor colorWithWhite:0.30 alpha:1.0]
                                                              : [UIColor colorWithWhite:0.80 alpha:1.0];
        self.progressFill.backgroundColor = [IOS6Theme primaryBlue];
    }
    [self styleActionButtons];
    [self applyBannerColors];
}

// Colour + icon the grouped action buttons for the current theme. Install = vivid accent fill
// (primaryBlue is BRIGHT on dark themes → fixes the "too pale" install button) + white glyph;
// Later/Cancel = a theme-aware grey + theme-aware glyph. Re-run on a live theme switch.
- (void)styleActionButtons {
    // iOS 5/6 SKEUOMORPHIC glossy buttons — all three share the SAME style + colour (the themed
    // glossy accent via styleButton), distinguished only by their white glyph. styleButton sets the
    // glossy background image (Normal + pressed) so the buttons get the classic beveled look.
    NSMutableArray *btns = [NSMutableArray arrayWithObjects:self.installButton, self.laterButton, self.cancelButton, nil];
    if (self.pauseButton) [btns addObject:self.pauseButton];
    for (UIButton *b in btns) {
        b.backgroundColor = [UIColor clearColor];
        [IOS6Theme styleButton:b];
    }
    [self.installButton setImage:ADInstallGlyph() forState:UIControlStateNormal];
    [self.laterButton setImage:ADLaterClockGlyph() forState:UIControlStateNormal];
    [self.cancelButton setImage:ADCancelGlyph() forState:UIControlStateNormal];
    [self.pauseButton setImage:ADPauseGlyph() forState:UIControlStateNormal];
}

// ✕ Cancel the in-flight download/install for THIS app (no need to open the Install tab).
- (void)cancelTapped {
    NSString *appURL = self.app[@"url"];
    for (InstallJob *j in [[InstallManager shared] jobs]) {
        if ([j.url isEqualToString:appURL]) { [[InstallManager shared] cancelJob:j.jobId]; break; }
    }
    [self refreshInstallButtonTitle];
}

// ⏸/▶ : pause a running download, or resume a paused one (for THIS app's job).
- (void)pauseToggleTapped {
    NSString *appURL = self.app[@"url"];
    InstallJob *job = nil;
    for (InstallJob *j in [[InstallManager shared] jobs]) {
        if ([j.url isEqualToString:appURL]) { job = j; break; }
    }
    if (!job) return;
    if ([job.state isEqualToString:@"paused"]) [[InstallManager shared] resumeJob:job.jobId];
    else                                        [[InstallManager shared] pauseJob:job.jobId];
    [self refreshInstallButtonTitle];
}

// Set the custom progress fill to a 0..1 fraction (stored so it survives a rotation re-layout).
- (void)setProgressFraction:(CGFloat)f animated:(BOOL)animated {
    self.progressFrac = MAX(0.0f, MIN(1.0f, f));
    CGFloat h = self.progressBar.bounds.size.height;
    CGFloat fw = self.progressBar.bounds.size.width * self.progressFrac;
    void (^apply)(void) = ^{ self.progressFill.frame = CGRectMake(0, 0, fw, h); };
    if (animated) [UIView animateWithDuration:0.25 animations:apply];
    else apply();
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Keep the custom progress fill width correct when the bar's width changes (rotation).
    if (self.progressBar && self.progressContainer && !self.progressContainer.hidden) {
        self.progressFill.frame = CGRectMake(0, 0,
            self.progressBar.bounds.size.width * self.progressFrac, self.progressBar.bounds.size.height);
    }
}

// Banner background + text depend on the theme (dark vs light) AND the compatibility level. Kept in
// one place so buildLayout and a live applyTheme produce identical colours.
- (void)applyBannerColors {
    if (!self.banner) return;
    BOOL dk = [IOS6Theme isDark];
    UIColor *bg = (self.bannerLevel == 0)
        ? (dk ? [UIColor colorWithRed:0.10 green:0.22 blue:0.12 alpha:1.0] : [UIColor colorWithRed:0.84 green:0.93 blue:0.81 alpha:1.0])
        : (dk ? [UIColor colorWithRed:0.28 green:0.11 blue:0.10 alpha:1.0] : [UIColor colorWithRed:0.98 green:0.84 blue:0.82 alpha:1.0]);
    UIColor *fg = (self.bannerLevel == 0)
        ? (dk ? [UIColor colorWithRed:0.56 green:0.85 blue:0.56 alpha:1.0] : [UIColor colorWithRed:0.11 green:0.42 blue:0.13 alpha:1.0])
        : (dk ? [UIColor colorWithRed:0.98 green:0.60 blue:0.58 alpha:1.0] : [UIColor colorWithRed:0.62 green:0.11 blue:0.10 alpha:1.0]);
    self.banner.backgroundColor = bg;
    self.bannerLabel.textColor = fg;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];  // App Store white
    self.title = self.app[@"title"] ?: T(@"app.fallback_title");

    // Right bar: ★ favourite toggle (always), + "Versions" if a bundleId is available.
    self.favBtn = [[UIBarButtonItem alloc] initWithTitle:@"☆"
                                                   style:UIBarButtonItemStylePlain
                                                  target:self
                                                  action:@selector(toggleFavoriteTapped)];
    [self updateFavoriteButton];
    NSMutableArray *rightItems = [NSMutableArray arrayWithObject:self.favBtn];   // ★ rightmost
    NSString *bid = self.app[@"bundleId"];
    if (bid.length) {
        [rightItems addObject:[[UIBarButtonItem alloc] initWithTitle:T(@"app.versions")
                                                               style:UIBarButtonItemStyleBordered
                                                              target:self
                                                              action:@selector(versionsTapped)]];
    }
    self.navigationItem.rightBarButtonItems = rightItems;

    [self buildLayout];
    // Re-apply the theme right after building: buildLayout sets the header/labels with their
    // theme colours but NOT their backgrounds, so on a fresh push in a dark theme the title +
    // subtitle labels render on a white default backdrop (white-on-white = invisible). applyTheme
    // forces their backgrounds clear so the dark header shows through — fresh push == live switch.
    [self applyTheme];
    [self loadIcon];
    [self checkRevivalUpdate];
    [self probeEncryptionForCurrentVersion];
}

// ★ filled when this app is in Favoris, ☆ outline otherwise. Bigger glyph so it reads in the bar.
- (void)updateFavoriteButton {
    BOOL fav = [[CollectionStore shared] isFavorite:[CollectionStore keyForApp:self.app]];
    self.favBtn.title = fav ? @"★" : @"☆";
    if ([self.favBtn respondsToSelector:@selector(setTitleTextAttributes:forState:)]) {
        NSDictionary *attrs = @{ UITextAttributeFont: [UIFont systemFontOfSize:22] };
        [self.favBtn setTitleTextAttributes:attrs forState:UIControlStateNormal];
        [self.favBtn setTitleTextAttributes:attrs forState:UIControlStateHighlighted];
    }
}

- (void)toggleFavoriteTapped {
    [[CollectionStore shared] toggleFavorite:self.app];
    [self updateFavoriteButton];
}

- (void)laterTapped {
    BOOL was = [[CollectionStore shared] isInLater:[CollectionStore keyForApp:self.app]];
    [[CollectionStore shared] toggleLater:self.app];
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"collections.later")
        message:(was ? T(@"later.removed") : T(@"later.added"))
        delegate:nil cancelButtonTitle:T(@"common.ok") otherButtonTitles:nil];
    [a show];
}

- (void)versionsTapped {
    NSString *bid = self.app[@"bundleId"];
    if (!bid.length) return;
    VersionsViewController *vc = [[VersionsViewController alloc] initWithBundleId:bid
                                                                              title:self.app[@"title"] ?: T(@"app.versions")];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - FairPlay-encryption probe (pre-download, over HTTP Range)

// Probe THIS version's binary (reads only ~tens of KB via Range — no full download). If it's
// FairPlay-encrypted it won't run on any jailbreak (it's tied to the original buyer's Apple ID),
// so we warn and then look for a decrypted build of the same app to recommend instead.
- (void)probeEncryptionForCurrentVersion {
    if (self.encryptionProbed) return;
    self.encryptionProbed = YES;
    NSString *url = self.app[@"url"];
    if (url.length == 0) return;
    AD_WEAK AppDetailViewController *weakSelf = self;
    [MachOInspector inspectURL:url completion:^(MachOInspectionResult r) {
        AppDetailViewController *s = weakSelf;
        if (!s) return;
        if (r != MachOInspectionResultEncrypted) return;   // decrypted/unknown → nothing to do
        AD_WEAK AppDetailViewController *ws = s;
        if (s.allowVersionSwitch) {
            // Auto path (catalog/search): resolve SILENTLY — no transient 🔒 banner. Switch to a
            // clean build in place if one exists; otherwise say there's none.
            [s findDecryptedAlternativeThen:^(NSDictionary *alt) {
                AppDetailViewController *s2 = ws; if (!s2) return;
                if (alt) [s2 switchToVersionInPlace:alt];
                else     [s2 showEncryptedBannerNoAlternative];
            }];
        } else {
            // Explicit path (user picked this exact build in Versions): warn now + offer the clean one.
            [s showEncryptedBannerWithRecommendation:nil];
            [s findDecryptedAlternativeThen:^(NSDictionary *alt) {
                AppDetailViewController *s2 = ws; if (!s2) return;
                if (alt) { s2.recommendedVersion = alt; [s2 showEncryptedBannerWithRecommendation:alt]; }
                else     [s2 showEncryptedBannerNoAlternative];
            }];
        }
    }];
}

// Scan the other versions of this bundle id for a build that is BOTH device-compatible AND
// decrypted, newest first; calls `done` with that version (or nil if none). Bounded.
- (void)findDecryptedAlternativeThen:(void (^)(NSDictionary *decryptedOrNil))done {
    NSString *bid = self.app[@"bundleId"];
    NSString *currentURL = self.app[@"url"] ?: @"";
    NSMutableArray *candidates = [NSMutableArray array];
    if (bid.length) {
        for (NSDictionary *v in [[LocalCatalog shared] versionsForBundleId:bid]) {
            NSString *u = v[@"url"];
            if (u.length == 0 || [u isEqualToString:currentURL]) continue;
            // Skip versions this device can't run anyway (no point recommending them).
            NSDictionary *vd = [DeviceInfo compatibilityVerdictForAppMinIOS:v[@"minOS"]
                                                                   platform:[v[@"platform"] integerValue]];
            if (vd && [vd[@"level"] integerValue] != 0) continue;
            [candidates addObject:v];
            if (candidates.count >= 6) break;
        }
    }
    [self probeCandidates:candidates index:0 then:done];
}

- (void)probeCandidates:(NSArray *)candidates index:(NSUInteger)i then:(void (^)(NSDictionary *))done {
    if (i >= candidates.count) { if (done) done(nil); return; }
    NSDictionary *v = [candidates objectAtIndex:i];
    AD_WEAK AppDetailViewController *weakSelf = self;
    [MachOInspector inspectURL:v[@"url"] completion:^(MachOInspectionResult r) {
        AppDetailViewController *s = weakSelf;
        if (!s) return;
        if (r == MachOInspectionResultDecrypted) { if (done) done(v); }
        else [s probeCandidates:candidates index:i + 1 then:done];
    }];
}

// Silently switch THIS screen to the (decrypted) version IN PLACE — same VC, content rebuilt.
// We avoid swapping the VC in the nav stack (setViewControllers left the nav bar + banner stale
// until the next appearance — the "encrypted, no Versions button until you leave and come back"
// bug), and we show NO note: the user just lands on the working version.
- (void)switchToVersionInPlace:(NSDictionary *)v {
    if (!v) return;
    // buildLayout re-registers this observer; drop it first so we don't stack duplicates.
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:InstallManagerJobsChangedNotification object:nil];
    self.app = v;
    self.title = v[@"title"] ?: T(@"app.fallback_title");
    self.banner = nil; self.bannerLabel = nil; self.bannerTap = nil;
    self.recommendedVersion = nil;
    self.pickedCompatibleVersion = NO;
    self.encryptionProbed = YES;   // v is confirmed decrypted — don't re-probe/redirect
    for (UIView *sub in [self.view.subviews copy]) [sub removeFromSuperview];
    [self buildLayout];
    [self applyTheme];
    [self loadIcon];
    [self checkRevivalUpdate];
    [self updateFavoriteButton];
}

// 🔒 warning + (rec non-nil) a tappable line suggesting that decrypted version.
- (void)showEncryptedBannerWithRecommendation:(NSDictionary *)rec {
    NSString *msg = [@"🔒  " stringByAppendingString:T(@"app.encrypted_warning")];
    if (rec) {
        NSString *rv = rec[@"version"];
        msg = [msg stringByAppendingFormat:@"\n→ %@",
                 [NSString stringWithFormat:T(@"app.encrypted_use_version"), (rv.length ? rv : @"?")]];
    }
    [self renderBannerText:msg height:(rec ? 64 : 46) tappable:(rec != nil)];
}

// 🔒 warning when NO non-encrypted version of this app exists.
- (void)showEncryptedBannerNoAlternative {
    self.recommendedVersion = nil;
    [self renderBannerText:[@"🔒  " stringByAppendingString:T(@"app.encrypted_none")] height:46 tappable:NO];
}

// Create or update-in-place the red "encrypted / won't run" banner, pushing the info text down.
- (void)renderBannerText:(NSString *)msg height:(CGFloat)bh tappable:(BOOL)tappable {
    CGFloat w = self.view.bounds.size.width;
    CGFloat top = self.banner ? self.banner.frame.origin.y : self.contentTopY;
    if (top <= 0) top = 120;
    if (!self.banner) {
        self.banner = [[UIView alloc] initWithFrame:CGRectMake(0, top, w, bh)];
        self.banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.bannerLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w - 24, bh)];
        self.bannerLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.bannerLabel.backgroundColor = [UIColor clearColor];
        self.bannerLabel.font = [UIFont boldSystemFontOfSize:13];
        [self.banner addSubview:self.bannerLabel];
        [self.view addSubview:self.banner];
    } else {
        self.banner.frame = CGRectMake(0, top, w, bh);
        self.bannerLabel.frame = CGRectMake(12, 0, w - 24, bh);
    }
    self.bannerLabel.numberOfLines = 3;
    self.bannerLevel = 2;            // → red "won't run" styling via applyBannerColors
    self.bannerLabel.text = msg;
    [self applyBannerColors];
    self.banner.userInteractionEnabled = tappable;
    if (tappable && !self.bannerTap) {
        self.bannerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bannerTapped)];
        [self.banner addGestureRecognizer:self.bannerTap];
    }
    if (self.infoView) {
        CGFloat y = top + bh;
        CGRect f = self.infoView.frame;
        f.origin.y = y;
        f.size.height = MAX(0.0, self.view.bounds.size.height - y);
        self.infoView.frame = f;
    }
}

- (void)bannerTapped {
    if (!self.recommendedVersion) return;
    AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:self.recommendedVersion
                                                          allowVersionSwitch:NO];
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
    header.backgroundColor = [IOS6Theme contentBackgroundColor];

    self.iconView = [[UIImageView alloc] initWithFrame:CGRectMake(15, 15, 90, 90)];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    // v1.3.2.1: clear (not gray) — pre-rounded icon corners are transparent;
    // the gray placeholder bg showed as a square contour around the rounding.
    self.iconView.backgroundColor = [UIColor clearColor];
    // No layer.cornerRadius / borderWidth (offscreen render = slow on iPad A4/A6X)
    [header addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(120, 18, w - 135, 28)];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    self.titleLabel.textColor = [IOS6Theme labelDark];
    self.titleLabel.text = self.app[@"title"] ?: @"?";  // ? is not a translatable string
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(120, 50, w - 135, 16)];
    self.subtitleLabel.font = [UIFont systemFontOfSize:13];
    self.subtitleLabel.textColor = [IOS6Theme labelGray];
    long long size = [self.app[@"size"] longLongValue];
    NSString *sizeStr = size > 0 ? [self humanSize:size] : T(@"app.size_unknown");  // also used by the tech info below
    if ([self isExternalRevival]) {
        // External entries (Cydia tweak / project page) have no meaningful download size —
        // show just the version (if known) + the min iOS, never a useless "size unknown".
        NSString *ver = self.app[@"version"];
        NSString *minOS = self.app[@"minOS"];
        NSMutableArray *parts = [NSMutableArray array];
        if ([ver isKindOfClass:[NSString class]] && ver.length)
            [parts addObject:[NSString stringWithFormat:@"v%@", ver]];
        if ([minOS isKindOfClass:[NSString class]] && minOS.length)
            [parts addObject:[NSString stringWithFormat:@"iOS %@+", minOS]];
        self.subtitleLabel.text = [parts componentsJoinedByString:@"  ·  "];
    } else {
        self.subtitleLabel.text = [NSString stringWithFormat:T(@"app.subtitle_with_size"),
                                     self.app[@"version"] ?: @"?", sizeStr];
    }
    self.subtitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:self.subtitleLabel];

    // Grouped action buttons — equal-size rounded ICON buttons, same style. Install (accent fill,
    // vivid on dark) + ⏱ Later (grey), grouped at the right. A ✕ Cancel (grey, hidden) takes the
    // slot during a live download/install. Colours/glyphs are (re)applied by -styleActionButtons.
    const CGFloat bs = 40, bh = 36, gap = 8, by = 70;
    BOOL ext = [self isExternalRevival];

    self.laterButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.laterButton.frame = CGRectMake(w - 15 - bs, by, bs, bh);
    self.laterButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.laterButton addTarget:self action:@selector(laterTapped) forControlEvents:UIControlEventTouchUpInside];
    self.laterButton.hidden = ext;   // external revival can't be queued
    [header addSubview:self.laterButton];

    self.installButton = [UIButton buttonWithType:UIButtonTypeCustom];
    // Install sits just left of Later (or at the far right when Later is hidden).
    self.installButton.frame = CGRectMake(ext ? (w - 15 - bs) : (w - 15 - bs - gap - bs), by, bs, bh);
    self.installButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.installButton addTarget:self action:@selector(installTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.installButton];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.cancelButton.frame = CGRectMake(w - 15 - bs, by, bs, bh);
    self.cancelButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    self.cancelButton.hidden = YES;
    [header addSubview:self.cancelButton];

    // Pause/Resume — left of Cancel (same slot the Install button uses when idle), shown only
    // during a download (⏸) or when paused (▶). Hidden while installing (ipainstaller can't pause).
    self.pauseButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.pauseButton.frame = CGRectMake(w - 15 - bs - gap - bs, by, bs, bh);
    self.pauseButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.pauseButton addTarget:self action:@selector(pauseToggleTapped) forControlEvents:UIControlEventTouchUpInside];
    self.pauseButton.hidden = YES;
    [header addSubview:self.pauseButton];

    [self styleActionButtons];

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

    // Custom 2-view progress bar (track + fill). The system UIProgressView renders a white/glossy
    // groove on iOS 6 that themeing can't fully control (the "completely white bar" bug); this is
    // fully theme-driven and identical on every OS.
    self.progressBar = [[UIView alloc] initWithFrame:CGRectMake(0, 4, self.progressContainer.bounds.size.width, 9)];
    self.progressBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.progressBar.backgroundColor = [IOS6Theme isDark] ? [UIColor colorWithWhite:0.30 alpha:1.0]
                                                          : [UIColor colorWithWhite:0.80 alpha:1.0];
    self.progressBar.layer.cornerRadius = 4.5;
    self.progressBar.clipsToBounds = YES;
    self.progressFill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 9)];
    self.progressFill.backgroundColor = [IOS6Theme primaryBlue];
    [self.progressBar addSubview:self.progressFill];
    [self.progressContainer addSubview:self.progressBar];

    self.progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, self.progressContainer.bounds.size.width, 18)];
    self.progressLabel.font = [UIFont systemFontOfSize:12];
    self.progressLabel.textColor = [IOS6Theme labelGray];
    self.progressLabel.backgroundColor = [UIColor clearColor];   // was defaulting to WHITE → the white strip in dark mode
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
    self.contentTopY = contentY;   // remembered so the async encryption banner can position itself

    NSDictionary *verdict =
        [DeviceInfo compatibilityVerdictForAppMinIOS:self.app[@"minOS"]
                                            platform:[self.app[@"platform"] integerValue]];
    if (verdict) {
        self.bannerLevel = [verdict[@"level"] integerValue];   // 0 = compatible, 2 = won't run
        NSString *prefix = (self.bannerLevel == 0) ? @"✓  " : @"✗  ";

        NSString *msg = [prefix stringByAppendingString:(verdict[@"message"] ?: @"")];
        if (self.pickedCompatibleVersion) {
            // We auto-selected an older build because the newest needs a higher iOS.
            msg = [msg stringByAppendingFormat:@"\n%@", T(@"app.picked_compatible")];
        }
        CGFloat bh = self.pickedCompatibleVersion ? 58 : 40;
        self.banner = [[UIView alloc] initWithFrame:CGRectMake(0, contentY, w, bh)];
        self.banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.bannerLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w - 24, bh)];
        self.bannerLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.bannerLabel.numberOfLines = self.pickedCompatibleVersion ? 3 : 2;
        self.bannerLabel.backgroundColor = [UIColor clearColor];
        self.bannerLabel.font = [UIFont boldSystemFontOfSize:13];
        self.bannerLabel.text = msg;
        [self applyBannerColors];                  // theme-aware bg + text (live-switch safe)
        [self.banner addSubview:self.bannerLabel];
        [self.view addSubview:self.banner];
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
    self.infoView = [[ADVerticalTextView alloc] initWithFrame:CGRectMake(0, contentY, w, b.size.height - contentY)];
    self.infoView.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.infoView.textColor = [IOS6Theme labelDark];
    self.infoView.font = [UIFont systemFontOfSize:13];
    self.infoView.editable = NO;
    self.infoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // textContainerInset is iOS 7+; on iOS 5/6 use contentInset for padding
    self.infoView.contentInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.infoView.showsHorizontalScrollIndicator = NO;   // vertical scrolling only

    NSString *fname = self.app[@"fileName"] ?: @"?";

    // (The "Mirror" info row was removed — its value (URL host) was empty/"?" for every app, so it
    // added nothing. The mirror CONCEPT still lives in the Versions list, retry status & FairPlay note.)
    NSString *tech = [NSString stringWithFormat:
        @"%@ : %@\n%@ : %@\n%@ : %@\n%@ : %@\n%@ : %@\n\n%@ : %@\n\n%@ :\n%@",
        T(@"app.info_bundle_id"), self.app[@"bundleId"] ?: @"?",
        T(@"app.info_version"), self.app[@"version"] ?: @"?",
        T(@"app.info_min_ios"), self.app[@"minOS"] ?: @"?",
        T(@"app.info_platform"), [self platformDescription:[self.app[@"platform"] integerValue]],
        T(@"app.info_size"), sizeStr,
        T(@"app.info_file"), [self softWrap:fname],
        T(@"app.info_url"), [self softWrap:(self.app[@"url"] ?: @"?")]];

    // Revival apps carry curator notes that credit the creator + say what the build is.
    // Show them at the very top of the description so the credit is always visible.
    NSString *revNotes = self.app[@"revivalNotes"];
    BOOL hasRevNotes = [self.app[@"isRevival"] boolValue]
                    && [revNotes isKindOfClass:[NSString class]] && revNotes.length > 0;

    if ([self isExternalRevival]) {
        // External entry: there's no .ipa / file / mirror / url to show. Display the notes
        // (with creator credit), the basics, and the project link the button opens.
        NSMutableString *body = [NSMutableString string];
        if (hasRevNotes) [body appendFormat:@"%@\n\n", revNotes];
        [body appendFormat:@"%@ : %@", T(@"app.info_min_ios"), self.app[@"minOS"] ?: @"?"];
        NSString *link = self.app[@"revivalLink"];
        if ([link isKindOfClass:[NSString class]] && link.length)
            [body appendFormat:@"\n%@ : %@", T(@"app.info_project"), [self softWrap:link]];
        self.infoView.text = body;
    } else {
        NSString *head = hasRevNotes
            ? [NSString stringWithFormat:@"%@\n\n———————————\n\n", revNotes] : @"";
        if (descText.length) {
            // (revival notes →) AI description → divider → technical details.
            self.infoView.text = [NSString stringWithFormat:@"%@%@\n\n———————————\n\n%@", head, descText, tech];
        } else {
            self.infoView.text = [NSString stringWithFormat:@"%@%@", head, tech];
        }
    }
    [self.view addSubview:self.infoView];
}

// Insert zero-width break opportunities into long, space-less strings (download URLs,
// filenames, host) so they WRAP instead of forcing the description's UITextView to scroll
// left-right (feedback: the app-detail screen scrolled horizontally on iPhone AND iPad).
// The inserted U+200B is invisible and works on both the WebKit UITextView (iOS 5/6) and TextKit (7-10).
- (NSString *)softWrap:(NSString *)s {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return s ?: @"";
    NSCharacterSet *brk = [NSCharacterSet characterSetWithCharactersInString:@"/._-+=&?:%~"];
    NSMutableString *m = [NSMutableString stringWithCapacity:s.length + 16];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        [m appendFormat:@"%C", c];
        if ([brk characterIsMember:c]) [m appendFormat:@"%C", (unichar)0x200B];
    }
    return m;
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
    if ([self isExternalRevival]) return;   // external entries have no in-app install/update
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

// YES if this is an "external" revival entry (no direct .ipa — a Cydia tweak, a companion-
// server app, etc.). For these the Install button becomes "Open project page".
- (BOOL)isExternalRevival {
    return [self.app[@"revivalExternal"] boolValue];
}

// Open the revival project's page (Cydia repo / GitHub / website) in the system browser.
- (void)openProjectPage {
    NSString *link = self.app[@"revivalLink"];
    NSURL *u = link.length ? [NSURL URLWithString:link] : nil;
    if (u && [[UIApplication sharedApplication] canOpenURL:u]) {
        [[UIApplication sharedApplication] openURL:u];
        return;
    }
    // Couldn't open (no handler / malformed) — copy the link so the user can paste it.
    if (link.length) [UIPasteboard generalPasteboard].string = link;
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"revival.open_page")
                                                message:(link.length ? link : T(@"app.no_url_msg"))
                                               delegate:nil
                                      cancelButtonTitle:T(@"common.ok")
                                      otherButtonTitles:nil];
    [a show];
}

- (void)installTapped {
    // External revival entry: no .ipa to install — open the project page instead.
    if ([self isExternalRevival]) { [self openProjectPage]; return; }
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
    // Show the ✕ Cancel button immediately (the job will appear as queued/downloading shortly).
    self.installButton.hidden = YES;
    self.laterButton.hidden = YES;
    self.cancelButton.hidden = NO;
    [[InstallManager shared] startInstallWithURL:url
                                       completion:^(NSString *jobId, NSError *err) {
        if (err) {
            [self refreshInstallButtonTitle];   // restores the install/later group
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
    if ([state isEqualToString:@"completed"]) self.hasUpdate = NO;
    BOOL downloading = [state isEqualToString:@"downloading"] || [state isEqualToString:@"queued"];
    BOOL paused      = [state isEqualToString:@"paused"];
    BOOL installing  = [state isEqualToString:@"installing"];
    BOOL live        = downloading || paused || installing;   // a job exists for THIS app

    // Idle → [Install][⏱]. Live → [⏸/▶ Pause][✕ Cancel] (Pause hidden while installing).
    self.installButton.hidden = live;
    self.laterButton.hidden   = live || [self isExternalRevival];
    self.cancelButton.hidden  = !live;
    self.pauseButton.hidden   = !(downloading || paused);
    [self.pauseButton setImage:(paused ? ADResumeGlyph() : ADPauseGlyph()) forState:UIControlStateNormal];

    // Progress widget: visible while downloading / installing / paused (frozen). Hidden otherwise.
    BOOL showProgress = [state isEqualToString:@"downloading"] || installing || paused;
    self.progressContainer.hidden = !showProgress;
    if (!showProgress) return;

    if (installing) {
        // ipainstaller is opaque about progress — just show a full bar + "Installing…".
        [self setProgressFraction:1.0 animated:NO];
        self.progressLabel.text = T(@"app.btn.installing");
        return;
    }
    if (paused) {
        // Freeze the bar at the last fraction; label shows "En pause".
        [self setProgressFraction:MAX(0.0f, MIN(1.0f, (float)job.progress / 100.0f)) animated:NO];
        self.progressLabel.text = T(@"install.state.paused");
        return;
    }

    // Downloading state. Animate the bar; build a "12.3 / 45.6 MB · 320 KB/s"
    // label from the byte counters InstallManager fills in for ETA tracking.
    float frac = MAX(0.0f, MIN(1.0f, (float)job.progress / 100.0f));
    [self setProgressFraction:frac animated:YES];

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

    // Always lead with the live % (the user asked for it right next to the bar), then bytes + speed.
    NSMutableArray *parts = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%ld %%", (long)job.progress]];
    if (bytesPart) [parts addObject:bytesPart];
    if (speedPart) [parts addObject:speedPart];
    self.progressLabel.text = [parts componentsJoinedByString:@"  ·  "];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
