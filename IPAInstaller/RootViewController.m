#import "RootViewController.h"
#import "InstallManager.h"
#import "JobCell.h"
#import "IOS6Theme.h"
#import "Localization.h"

// Sort rank for the jobs list: active downloads on top, then waiting, then finished/failed.
static int JobSortRank(InstallJob *j) {
    NSString *s = j.state;
    if ([s isEqualToString:@"downloading"] || [s isEqualToString:@"installing"]) return 0;
    if ([s isEqualToString:@"queued"]) return 1;
    return 2;   // completed / failed / cancelled
}

@interface RootViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UIButton *installButton;
@property (nonatomic, strong) UITableView *jobsTable;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) NSArray *jobs;
@end

@implementation RootViewController

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
    self.navigationItem.rightBarButtonItem = clearBtn;

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
    if ([[InstallManager shared] hasActiveJobs]) {
        if (!self.navigationItem.leftBarButtonItem) {
            UIBarButtonItem *cancelAll = [[UIBarButtonItem alloc] initWithTitle:T(@"install.cancel_all")
                                                                          style:UIBarButtonItemStyleBordered
                                                                         target:self
                                                                         action:@selector(cancelAllTapped)];
            // Red tint to flag it as a destructive-ish action.
            cancelAll.tintColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:1.0];
            self.navigationItem.leftBarButtonItem = cancelAll;
        }
    } else {
        self.navigationItem.leftBarButtonItem = nil;
    }
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
    label.textColor = [UIColor colorWithRed:0.22 green:0.27 blue:0.40 alpha:1.0];
    label.backgroundColor = [UIColor clearColor];
    label.shadowColor = [UIColor colorWithWhite:1.0 alpha:0.6];
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
    [self.jobsTable reloadData];
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

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.jobs.count == 0) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"empty"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"empty"];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.textColor = [UIColor grayColor];
            cell.textLabel.font = [UIFont systemFontOfSize:13];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
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
