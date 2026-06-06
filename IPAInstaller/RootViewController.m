#import "RootViewController.h"
#import "InstallManager.h"
#import "JobCell.h"
#import "IOS6Theme.h"
#import "Localization.h"
#import "CollectionViewController.h"
#import "CollectionStore.h"

// Sort rank for the jobs list: active downloads on top, then waiting, then finished/failed.
static int JobSortRank(InstallJob *j) {
    NSString *s = j.state;
    if ([s isEqualToString:@"downloading"] || [s isEqualToString:@"installing"]) return 0;
    if ([s isEqualToString:@"queued"]) return 1;
    return 2;   // completed / failed / cancelled
}

// v3.0: "Download later" nav glyph — a down arrow dropping into an open tray (replaces the 📥 emoji).
// Drawn as a solid alpha mask so the iOS 5/6 nav bar tints + embosses it like a stock bar glyph,
// which keeps it correct under every theme (it adopts the bar's button tint automatically).
static UIImage *ADDownloadLaterNavGlyph(void) {
    CGSize s = CGSizeMake(23, 23);
    UIGraphicsBeginImageContextWithOptions(s, NO, 0.0);   // device scale → crisp on Retina
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor blackColor] set];                            // colour is irrelevant; only the alpha shape matters
    CGContextSetLineWidth(ctx, 2.0);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    // Down arrow (shaft + head).
    CGContextMoveToPoint(ctx, 11.5, 2.5);
    CGContextAddLineToPoint(ctx, 11.5, 13.5);
    CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, 6.5, 9.0);
    CGContextAddLineToPoint(ctx, 11.5, 14.0);
    CGContextAddLineToPoint(ctx, 16.5, 9.0);
    CGContextStrokePath(ctx);
    // Open tray catching it.
    CGContextMoveToPoint(ctx, 4.0, 15.5);
    CGContextAddLineToPoint(ctx, 4.0, 19.5);
    CGContextAddLineToPoint(ctx, 19.0, 19.5);
    CGContextAddLineToPoint(ctx, 19.0, 15.5);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

@interface RootViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UIButton *installButton;
@property (nonatomic, strong) UITableView *jobsTable;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) NSArray *jobs;
@property (nonatomic, copy) NSString *jobsSignature;  // jobId|state per row — detects structural vs progress-only change
@end

@implementation RootViewController

// Live theme re-apply (AppDelegate calls this on a theme switch — no restart).
- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme linenColor];
    self.jobsTable.backgroundColor = [IOS6Theme linenColor];
    self.jobsTable.separatorColor = [IOS6Theme separatorColor];
    if (self.installButton) [IOS6Theme styleButton:self.installButton];
    [IOS6Theme styleTextField:self.urlField];
    [self.jobsTable reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"install.title");
    // Linen background still fits this "downloads" screen (slightly different from white Catalogue).
    self.view.backgroundColor = [IOS6Theme linenColor];

    // Right bar button: Vider (clear completed/failed/cancelled jobs).
    UIBarButtonItem *clearBtn = [[UIBarButtonItem alloc] initWithTitle:T(@"install.clear")
                                                                  style:UIBarButtonItemStyleBordered
                                                                 target:self
                                                                 action:@selector(clearDoneTapped)];
    // v3.0: "Download later" shortcut lives in the top-right nav bar (download glyph, rightmost), next to Vider.
    UIBarButtonItem *laterBtn = [[UIBarButtonItem alloc] initWithImage:ADDownloadLaterNavGlyph()
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(openLaterTapped)];
    self.navigationItem.rightBarButtonItems = @[laterBtn, clearBtn];

    [self buildHeader];
    [self buildTable];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(jobsChanged)
                                                 name:InstallManagerJobsChangedNotification
                                               object:nil];
    [self refreshJobs];
}

// Show/hide the "Tout annuler" left button depending on whether any job is active.
// Called every time the jobs list changes.
- (void)refreshLeftBarButton {
    BOOL active = [[InstallManager shared] hasActiveJobs];   // includes paused (non-terminal)
    BOOL paused = [[InstallManager shared] hasPausedJobs];
    if (!active && !paused) { self.navigationItem.leftBarButtonItems = nil; return; }
    UIBarButtonItem *cancelAll = [[UIBarButtonItem alloc] initWithTitle:T(@"install.cancel_all")
        style:UIBarButtonItemStyleBordered target:self action:@selector(cancelAllTapped)];
    cancelAll.tintColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:1.0];   // destructive-ish
    NSMutableArray *items = [NSMutableArray arrayWithObject:cancelAll];
    // Resume-all if anything is paused; otherwise Pause-all when downloads are active.
    if (paused) {
        [items addObject:[[UIBarButtonItem alloc] initWithTitle:T(@"install.resume_all")
            style:UIBarButtonItemStyleBordered target:self action:@selector(resumeAllTapped)]];
    } else {
        [items addObject:[[UIBarButtonItem alloc] initWithTitle:T(@"install.pause_all")
            style:UIBarButtonItemStyleBordered target:self action:@selector(pauseAllTapped)]];
    }
    self.navigationItem.leftBarButtonItems = items;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)buildHeader {
    CGFloat w = self.view.bounds.size.width;
    self.headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 120)];
    self.headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.headerView.backgroundColor = [UIColor clearColor];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(15, 10, w - 30, 18)];
    label.text = T(@"install.url_label");
    label.font = [UIFont boldSystemFontOfSize:13];
    label.textColor = [IOS6Theme titleColor];
    label.backgroundColor = [UIColor clearColor];
    label.shadowColor = [IOS6Theme embossShadowColor];
    label.shadowOffset = CGSizeMake(0, 1);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.headerView addSubview:label];

    self.urlField = [[UITextField alloc] initWithFrame:CGRectMake(15, 32, w - 30, 36)];
    self.urlField.borderStyle = UITextBorderStyleRoundedRect;
    self.urlField.placeholder = T(@"install.url_placeholder");
    self.urlField.font = [UIFont systemFontOfSize:14];
    self.urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.urlField.keyboardType = UIKeyboardTypeURL;
    self.urlField.returnKeyType = UIReturnKeyGo;
    self.urlField.delegate = self;
    self.urlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.urlField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [IOS6Theme styleTextField:self.urlField];   // stock rounded (default) / dark field (dark themes)
    [self.headerView addSubview:self.urlField];

    self.installButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.installButton.frame = CGRectMake(15, 76, w - 30, 36);
    self.installButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.installButton setTitle:T(@"install.button") forState:UIControlStateNormal];
    [IOS6Theme styleButton:self.installButton];
    [self.installButton addTarget:self
                           action:@selector(installTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.installButton];
}

// v3.0: open the built-in "Download later" collection (apps the user saved to grab later).
- (void)openLaterTapped {
    CollectionViewController *vc = [[CollectionViewController alloc] initWithCollectionId:CollectionLaterId];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)buildTable {
    CGRect b = self.view.bounds;
    self.jobsTable = [[UITableView alloc] initWithFrame:b style:UITableViewStyleGrouped];
    self.jobsTable.dataSource = self;
    self.jobsTable.delegate = self;
    self.jobsTable.autoresizingMask = UIViewAutoresizingFlexibleWidth
                                    | UIViewAutoresizingFlexibleHeight;
    self.jobsTable.tableHeaderView = self.headerView;
    self.jobsTable.backgroundView = nil;
    self.jobsTable.backgroundColor = [IOS6Theme linenColor];
    [self.view addSubview:self.jobsTable];
}

- (void)refreshJobs {
    // Active downloads first, then waiting, then finished/failed — so it's clear at a glance
    // what's downloading now vs what's lined up.
    self.jobs = [[[InstallManager shared] jobs] sortedArrayUsingComparator:^NSComparisonResult(InstallJob *a, InstallJob *b) {
        int ra = JobSortRank(a), rb = JobSortRank(b);
        if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
        NSDate *da = a.startedAt ?: [NSDate distantPast], *db = b.startedAt ?: [NSDate distantPast];
        return [da compare:db];
    }];

    // A download posts a "changed" notification on every received chunk (many/sec). If we
    // reloadData on each one, a reload landing mid-touch tears the cell out from under the
    // user's finger and the row tap (pause/resume) never fires. So: only reloadData when the
    // job set/order/state actually changed (structural); for progress-only ticks, update the
    // visible cells in place — which leaves touch tracking intact so the tap registers.
    NSMutableString *sig = [NSMutableString string];
    for (InstallJob *j in self.jobs) [sig appendFormat:@"%@|%@;", j.jobId ?: @"", j.state ?: @""];
    BOOL structural = ![sig isEqualToString:self.jobsSignature ?: @""];
    self.jobsSignature = sig;

    if (structural) {
        [self.jobsTable reloadData];
    } else {
        for (NSIndexPath *ip in [self.jobsTable indexPathsForVisibleRows]) {
            if (ip.row >= (NSInteger)self.jobs.count) continue;
            UITableViewCell *cell = [self.jobsTable cellForRowAtIndexPath:ip];
            if ([cell isKindOfClass:[JobCell class]])
                [(JobCell *)cell configureWithJob:self.jobs[ip.row]];
        }
    }
    [self refreshLeftBarButton];
}

- (void)jobsChanged {
    [self refreshJobs];
}

- (void)cancelAllTapped {
    NSInteger n = [[InstallManager shared] cancelAllActiveJobs];
    if (n == 0) return;
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"install.cancelled_title")
                                                 message:[NSString stringWithFormat:T(@"install.cancelled_msg"), (long)n]
                                                delegate:nil
                                       cancelButtonTitle:T(@"common.ok")
                                       otherButtonTitles:nil];
    [a show];
}

- (void)pauseAllTapped { [[InstallManager shared] pauseAllActiveJobs]; }
- (void)resumeAllTapped { [[InstallManager shared] resumeAllPausedJobs]; }

// Tap a job row to pause (if downloading/queued) or resume (if paused). Per-job control —
// iOS 6's single swipe button is already used for cancel/delete, so the tap toggles pause.
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)self.jobs.count) return;
    InstallJob *job = self.jobs[ip.row];
    NSString *s = job.state ?: @"";
    if ([s isEqualToString:@"downloading"] || [s isEqualToString:@"queued"]) [[InstallManager shared] pauseJob:job.jobId];
    else if ([s isEqualToString:@"paused"]) [[InstallManager shared] resumeJob:job.jobId];
}

- (void)installTapped {
    NSString *url = [self.urlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (url.length == 0) {
        [self showAlert:T(@"common.empty_url") message:T(@"common.empty_url_msg")];
        return;
    }
    NSString *extracted = [self extractIpaURL:url];
    if (!extracted) {
        [self showAlert:T(@"common.invalid_url")
                message:T(@"common.invalid_url_msg")];
        return;
    }
    [self.urlField resignFirstResponder];
    self.installButton.enabled = NO;
    [[InstallManager shared] startInstallWithURL:extracted
                                       completion:^(NSString *jobId, NSError *err) {
        self.installButton.enabled = YES;
        if (err) {
            [self showAlert:T(@"common.error") message:[err localizedDescription]];
            return;
        }
        self.urlField.text = @"";
    }];
}

- (NSString *)extractIpaURL:(NSString *)input {
    if ([input hasPrefix:@"http://"] || [input hasPrefix:@"https://"]) {
        // strip query for .ipa check
        NSString *pathOnly = [[input componentsSeparatedByString:@"?"] objectAtIndex:0];
        if ([[pathOnly lowercaseString] hasSuffix:@".ipa"]) return input;
        return nil;
    }
    if ([input hasPrefix:@"itms-services://"]) {
        NSRange r = [input rangeOfString:@"url="];
        if (r.location == NSNotFound) return nil;
        NSString *enc = [input substringFromIndex:r.location + r.length];
        NSString *manifest = [enc stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: enc;
        NSRange d = [manifest rangeOfString:@"d="];
        if (d.location == NSNotFound) return nil;
        NSString *b64 = [manifest substringFromIndex:d.location + d.length];
        NSRange amp = [b64 rangeOfString:@"&"];
        if (amp.location != NSNotFound) b64 = [b64 substringToIndex:amp.location];
        NSData *bytes = [self base64Decode:b64];
        if (!bytes) return nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
        return json[@"u"];
    }
    return nil;
}

// Manual base64 decode (iOS 5/6 compatible — initWithBase64EncodedString:options: is iOS 7+)
- (NSData *)base64Decode:(NSString *)s {
    static const char tbl[256] = {
        ['A']=0,['B']=1,['C']=2,['D']=3,['E']=4,['F']=5,['G']=6,['H']=7,['I']=8,['J']=9,
        ['K']=10,['L']=11,['M']=12,['N']=13,['O']=14,['P']=15,['Q']=16,['R']=17,['S']=18,['T']=19,
        ['U']=20,['V']=21,['W']=22,['X']=23,['Y']=24,['Z']=25,
        ['a']=26,['b']=27,['c']=28,['d']=29,['e']=30,['f']=31,['g']=32,['h']=33,['i']=34,['j']=35,
        ['k']=36,['l']=37,['m']=38,['n']=39,['o']=40,['p']=41,['q']=42,['r']=43,['s']=44,['t']=45,
        ['u']=46,['v']=47,['w']=48,['x']=49,['y']=50,['z']=51,
        ['0']=52,['1']=53,['2']=54,['3']=55,['4']=56,['5']=57,['6']=58,['7']=59,['8']=60,['9']=61,
        ['+']=62,['/']=63,
    };
    const char *src = [s UTF8String];
    NSUInteger len = strlen(src);
    if (len == 0) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:(len * 3) / 4 + 4];
    int bits = 0, buf = 0;
    for (NSUInteger i = 0; i < len; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '=' || c == ' ' || c == '\n' || c == '\r' || c == '\t') continue;
        if (c < 43 || c > 122) continue;
        char v = tbl[c];
        if (v == 0 && c != 'A') {
            // unrecognized char, skip
            continue;
        }
        buf = (buf << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            unsigned char byte = (buf >> bits) & 0xFF;
            [out appendBytes:&byte length:1];
        }
    }
    return out;
}

- (void)clearDoneTapped {
    [[InstallManager shared] clearCompletedJobs];
}

- (void)showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:title
                                                message:msg
                                               delegate:nil
                                      cancelButtonTitle:T(@"common.ok")
                                      otherButtonTitles:nil];
    [a show];
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return MAX((NSInteger)self.jobs.count, 1);
}

// "Installations (N)" header + any footer: clear the backdrop + recolour the label (iOS 6's default
// dark blue-grey is unreadable on dark; the backdrop can render black after the texture is removed).
- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:view];
}
- (void)tableView:(UITableView *)tv willDisplayFooterView:(UIView *)view forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:view];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    // Live counter: "N downloading · M waiting" (only the non-zero parts). Falls back to the
    // total count when nothing is active/waiting (all finished, or empty).
    NSInteger active = 0, waiting = 0;
    for (InstallJob *j in self.jobs) {
        NSString *st = j.state;
        if ([st isEqualToString:@"downloading"] || [st isEqualToString:@"installing"]) active++;
        else if ([st isEqualToString:@"queued"]) waiting++;
    }
    NSMutableArray *parts = [NSMutableArray array];
    if (active > 0)  [parts addObject:[NSString stringWithFormat:T(@"install.count_active"),  (long)active]];
    if (waiting > 0) [parts addObject:[NSString stringWithFormat:T(@"install.count_waiting"), (long)waiting]];
    if (parts.count) return [parts componentsJoinedByString:@"  ·  "];
    return [NSString stringWithFormat:T(@"install.installations"), (unsigned long)self.jobs.count];
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return self.jobs.count == 0 ? 44 : 72;
}

// iOS 5/6 grouped tables drop a cell.backgroundColor set in cellForRow:, so the dark-mode
// "no downloads" placeholder cell stayed white with unreadable (light) text. Re-apply the themed
// colour here (JobCell already self-themes in layoutSubviews, so this just matches it).
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    cell.backgroundColor = [IOS6Theme cellColor];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.jobs.count == 0) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"empty"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"empty"];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.font = [UIFont systemFontOfSize:13];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        cell.backgroundColor = [IOS6Theme cellColor];
        cell.textLabel.textColor = [IOS6Theme labelGray];
        cell.textLabel.text = T(@"install.empty");
        return cell;
    }

    static NSString *cellId = @"jobCell";
    JobCell *cell = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[JobCell alloc] initWithStyle:UITableViewCellStyleDefault
                              reuseIdentifier:cellId];
    }
    InstallJob *job = self.jobs[ip.row];
    [cell configureWithJob:job];
    return cell;
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    // Every row is now swipeable: active jobs swipe to cancel, terminal jobs swipe to remove.
    return self.jobs.count > 0;
}

// Override the red action button label per-row: "Annuler" for active jobs, "Supprimer"
// for completed/failed/cancelled ones. iOS 3.0+ delegate method.
- (NSString *)tableView:(UITableView *)tv
titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    InstallJob *job = self.jobs[ip.row];
    BOOL terminal = [job.state isEqualToString:@"completed"]
                 || [job.state isEqualToString:@"failed"]
                 || [job.state isEqualToString:@"cancelled"];
    return terminal ? T(@"install.swipe_delete") : T(@"install.swipe_cancel");
}

- (void)tableView:(UITableView *)tv
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)ip {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    InstallJob *job = self.jobs[ip.row];
    BOOL terminal = [job.state isEqualToString:@"completed"]
                 || [job.state isEqualToString:@"failed"]
                 || [job.state isEqualToString:@"cancelled"];
    if (terminal) {
        [[InstallManager shared] removeJob:job.jobId];
    } else {
        [[InstallManager shared] cancelJob:job.jobId];
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [self installTapped];
    return YES;
}

#pragma mark - Rotation

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
