#import "VersionsViewController.h"
#import "InstallManager.h"
#import "AppDetailViewController.h"
#import "IOS6Theme.h"
#import "LocalCatalog.h"
#import "Localization.h"
#import "MachOInspector.h"

@interface VersionsViewController ()
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *appTitle;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSArray *versions;
@property (nonatomic, strong) NSMutableDictionary *encByURL;   // url -> @(MachOInspectionResult)
@property (nonatomic, strong) NSMutableSet *encInflight;       // urls currently being probed
@property (nonatomic, assign) BOOL pendingReload;             // a probe resolved mid-scroll → reload when it settles (#151)
@end

@implementation VersionsViewController

- (instancetype)initWithBundleId:(NSString *)bundleId title:(NSString *)title {
    if ((self = [super init])) {
        _bundleId = [bundleId copy];
        _appTitle = [title copy];
    }
    return self;
}

// Live theme re-apply. Uses linenColor (cream linen on default, themed wash on custom).
- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme linenColor];
    self.tableView.backgroundColor = [IOS6Theme linenColor];
    if ([IOS6Theme isDark]) self.tableView.backgroundView = nil;
    self.tableView.separatorColor = [IOS6Theme separatorColor];
    self.statusLabel.textColor = [IOS6Theme labelGray];        // footer count: refresh on live switch
    self.statusLabel.backgroundColor = [UIColor clearColor];
    [self.tableView reloadData];
}

// Section header AND footer: clear the (else black/textured) backdrop + recolour the label.
- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:view];
}
- (void)tableView:(UITableView *)tv willDisplayFooterView:(UIView *)view forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:view];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.appTitle ?: T(@"app.versions");
    self.view.backgroundColor = [IOS6Theme linenColor];
    self.encByURL = [NSMutableDictionary dictionary];
    self.encInflight = [NSMutableSet set];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                   style:UITableViewStyleGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.rowHeight = 80;
    self.tableView.backgroundColor = [IOS6Theme linenColor];
    if ([IOS6Theme isDark]) self.tableView.backgroundView = nil;   // kill the light iOS-6 grouped backdrop
    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 30)];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [IOS6Theme labelGray];
    self.statusLabel.backgroundColor = [UIColor clearColor];   // else a UILabel footer renders white on iOS 6
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.tableView.tableFooterView = self.statusLabel;

    [self loadVersions];
}

- (void)loadVersions {
    [self.spinner startAnimating];
    self.statusLabel.text = T(@"catalog.loading_more");

    if ([[InstallManager shared] autonomousMode]) {
        if (![[LocalCatalog shared] isReady]) {
            [[LocalCatalog shared] loadWithProgress:^(NSString *s){ self.statusLabel.text = s; }
                                          completion:^(BOOL ok, NSError *e) {
                if (!ok) {
                    [self.spinner stopAnimating];
                    self.statusLabel.text = [NSString stringWithFormat:T(@"versions.load_failed"), e.localizedDescription ?: @""];
                    return;
                }
                [self queryLocalVersions];
            }];
        } else {
            [self queryLocalVersions];
        }
        return;
    }

    NSString *backend = [[InstallManager shared] backendURL];
    NSString *bid = [self.bundleId stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"";
    NSString *url = [NSString stringWithFormat:@"%@/catalog/versions?bundle_id=%@", backend, bid];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:20];
    [NSURLConnection sendAsynchronousRequest:req
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
        [self.spinner stopAnimating];
        if (e || !d) {
            self.statusLabel.text = [NSString stringWithFormat:T(@"versions.load_failed"),
                                       e.localizedDescription ?: @""];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (!json) { self.statusLabel.text = T(@"versions.invalid_response"); return; }
        self.versions = json[@"results"] ?: @[];
        self.statusLabel.text = [NSString stringWithFormat:@"%lu version%@",
                                  (unsigned long)self.versions.count,
                                  self.versions.count > 1 ? @"s" : @""];
        [self.tableView reloadData];
    }];
}

- (void)queryLocalVersions {
    NSArray *vs = [[LocalCatalog shared] versionsForBundleId:self.bundleId];
    [self.spinner stopAnimating];
    self.versions = vs;
    self.statusLabel.text = [NSString stringWithFormat:T(@"versions.count"), (unsigned long)vs.count];
    [self.tableView reloadData];
    [self probeVisibleRows];   // lazily badge the FIRST screenful's encrypted mirrors (#151)
}

- (NSString *)humanSize:(long long)b {
    if (b < 1024) return [NSString stringWithFormat:@"%lld B", b];
    if (b < 1024*1024) return [NSString stringWithFormat:@"%.0f KB", b/1024.0];
    if (b < 1024LL*1024*1024) return [NSString stringWithFormat:@"%.1f MB", b/(1024.0*1024)];
    return [NSString stringWithFormat:@"%.2f GB", b/(1024.0*1024*1024)];
}

#pragma mark - FairPlay-encryption badge (lazy probe + cache)

// Returns the cached MachOInspectionResult for this URL, or -1 if unknown. When unknown, kicks
// off a background HTTP-Range probe (reads only ~tens of KB) and reloads the row when it lands.
- (NSInteger)encStateForURL:(NSString *)url {
    if (url.length == 0) return -1;
    NSNumber *n = [self.encByURL objectForKey:url];
    if (n) return [n integerValue];
    NSInteger cached = [MachOInspector cachedResultForURL:url];
    if (cached >= 0) { [self.encByURL setObject:[NSNumber numberWithInteger:cached] forKey:url]; return cached; }
    // Unknown — do NOT probe here. cellForRow runs during fast scroll; probing per cell queued
    // dozens of blocking HTTP probes and froze the list (#151). Probing is driven by
    // -probeVisibleRows (bounded, visible rows only, when the scroll settles).
    return -1;
}

// Max FairPlay probes in flight at once. Each probe is a blocking HTTP-Range read, so a fast
// scroll must NOT spawn dozens (that froze the list — #151). Visible rows are probed a few at a
// time; as each lands, the next visible one is picked up.
static const NSUInteger kMaxConcurrentEncProbes = 3;

- (void)scheduleEncProbeForURL:(NSString *)url {
    if (url.length == 0 || [self.encInflight containsObject:url]) return;
    [self.encInflight addObject:url];
    __weak VersionsViewController *weakSelf = self;
    [MachOInspector inspectURL:url completion:^(MachOInspectionResult r) {
        VersionsViewController *s = weakSelf;
        if (!s) return;
        [s.encInflight removeObject:url];
        if (r != MachOInspectionResultUnknown) {
            [s.encByURL setObject:[NSNumber numberWithInteger:(NSInteger)r] forKey:url];
            // Defer the refresh while the user is flinging (mirrors CatalogViewController) — an
            // immediate reload mid-scroll churns layout and freezes on iOS 6/7 (#151).
            if (s.tableView.dragging || s.tableView.decelerating) s.pendingReload = YES;
            else [s.tableView reloadData];
        }
        [s probeVisibleRows];   // fill the freed slot with the next visible, unprobed row
    }];
}

// Probe only the rows currently on screen, a few at a time. Called after load and whenever the
// scroll settles — never from cellForRow (that per-cell probing is what froze the list, #151).
- (void)probeVisibleRows {
    for (NSIndexPath *ip in [self.tableView indexPathsForVisibleRows]) {
        if (self.encInflight.count >= kMaxConcurrentEncProbes) break;
        if (ip.row < 0 || ip.row >= (NSInteger)self.versions.count) continue;
        NSString *url = [[self.versions objectAtIndex:ip.row] objectForKey:@"url"] ?: @"";
        if (url.length == 0) continue;
        if ([self.encByURL objectForKey:url]) continue;              // already known
        if ([MachOInspector cachedResultForURL:url] >= 0) continue;  // known in the MachO cache
        if ([self.encInflight containsObject:url]) continue;         // in flight
        [self scheduleEncProbeForURL:url];
    }
}

- (void)flushAfterScroll {
    if (self.pendingReload) { self.pendingReload = NO; [self.tableView reloadData]; }
    [self probeVisibleRows];
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv { [self flushAfterScroll]; }
- (void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)decel {
    if (!decel) [self flushAfterScroll];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.versions.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return [NSString stringWithFormat:T(@"versions.available_header"), (unsigned long)self.versions.count];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return T(@"versions.footer");
}

// iOS 5/6 grouped tables drop a cell.backgroundColor set in cellForRow:, so dark-mode cells
// stayed white with unreadable (light) text. Re-apply the themed colour here (where it sticks).
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    cell.backgroundColor = [IOS6Theme cellColor];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"verCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cid];
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    NSDictionary *v = self.versions[ip.row];
    long long size = [v[@"size"] longLongValue];
    NSString *sizeStr = size > 0 ? [self humanSize:size] : T(@"versions.unknown_size");
    // Mark versions this device can't run (min iOS higher than the device's iOS).
    BOOL compatible = [[LocalCatalog shared] deviceCanRunMinIOS:v[@"minOS"]];
    NSString *url = v[@"url"] ?: @"";
    // FairPlay status — from the per-URL cache; probed lazily on first display (see encStateForURL:).
    BOOL encrypted = ([self encStateForURL:url] == MachOInspectionResultEncrypted);

    cell.backgroundColor = [IOS6Theme cellColor];
    cell.textLabel.text = [NSString stringWithFormat:@"%@v%@ — %@",
                            encrypted ? @"🔒 " : @"", v[@"version"] ?: @"?", sizeStr];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
    cell.textLabel.textColor = (compatible && !encrypted) ? [IOS6Theme labelDark] : [IOS6Theme labelGray];

    NSURL *u = [NSURL URLWithString:url];
    NSString *host = u.host ?: @"?";
    NSString *fileName = v[@"fileName"] ?: @"";
    // Encryption is decisive (won't run regardless of iOS), so its tag wins over "incompatible".
    NSString *tag = @"";
    if (encrypted)        tag = [T(@"versions.encrypted") stringByAppendingString:@"  "];
    else if (!compatible) tag = [T(@"versions.incompatible") stringByAppendingString:@"  "];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@min iOS %@ • %@\n%@",
                                  tag, v[@"minOS"] ?: @"?", host, fileName];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
    BOOL warn = encrypted || !compatible;
    cell.detailTextLabel.textColor = !warn
        ? [IOS6Theme labelGray]
        : ([IOS6Theme isDark] ? [UIColor colorWithRed:0.96 green:0.46 blue:0.46 alpha:1.0]
                              : [UIColor colorWithRed:0.62 green:0.11 blue:0.10 alpha:1.0]);   // red = won't run
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *v = self.versions[ip.row];
    // Keep the EXACT version the user picked here (don't auto-switch to a compatible one).
    AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:v allowVersionSwitch:NO];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
