#import "CatalogViewController.h"
#import "Localization.h"
#import "InstallManager.h"
#import "CollectionStore.h"
#import "FolderPicker.h"
#import "CatalogFilter.h"
#import "FilterViewController.h"
#import "AppDetailViewController.h"
#import "IconLoader.h"
#import "AppRowCell.h"
#import "AppTileView.h"
#import "IOS6Theme.h"
#import "LocalCatalog.h"
#import "CatalogAppCell.h"

static const CGFloat kIconSize = 44;
static const CGFloat kSelectionToolbarHeight = 44;
// Onboarding key shared with AppDetailViewController so the "ipainstaller required"
// alert only ever shows once, not twice (once per surface).
static NSString *const kOnboardingKey = @"IPAInstall.onboarding.ipainstaller.shown";

// v3.0: list vs grid is no longer an idiom check — it's driven by the density setting via
// -[self useGrid] / +[AppRowCell tilesPerRowForWidth:]. (The old kIsIPad() helper is gone.)

@interface CatalogViewController () <FilterViewControllerDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITapGestureRecognizer *catalogRetryRecognizer;
@property (nonatomic, strong) CatalogFilter *filter;
@property (nonatomic, strong) NSMutableArray *results;
@property (nonatomic, assign) NSInteger totalCount;
@property (nonatomic, assign) NSInteger pageOffset;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL eof;
@property (nonatomic, assign) BOOL pendingReload;   // page arrived mid-scroll; reload on stop
@property (nonatomic, copy) NSString *currentQuery;

// === Selection mode (multi-select install) ==========================
// Selected apps live in a dict keyed by pk (NSNumber). We store the FULL dict
// (not just the id) so that installs still work even if the user changes
// search/filter and the now-selected entries are no longer in self.results.
// This is what makes selection robust across far scrolling: the cells are
// recycled but our backing store is independent.
@property (nonatomic, assign) BOOL selectionMode;
@property (nonatomic, copy)   NSString *savedTitle;   // restored when leaving selection mode
@property (nonatomic, strong) NSMutableDictionary *selectedAppsByPk;
@property (nonatomic, strong) UIToolbar *selectionToolbar;
@property (nonatomic, strong) UIBarButtonItem *installSelectionItem;
@property (nonatomic, strong) UIBarButtonItem *favSelectionItem;
@property (nonatomic, strong) UIBarButtonItem *laterSelectionItem;
@property (nonatomic, strong) UIBarButtonItem *dossierSelectionItem;

// Pending batch when waiting for onboarding alert dismissal (so the user only
// sees the alert once, not once per app, when bulk-installing).
@property (nonatomic, strong) NSArray *pendingBatchInstall;
// iPad grid: rotation-reload guard (last tiles-per-row) + active-scroll flag (rasterize off while scrolling).
@property (nonatomic, assign) NSInteger lastTPR;
@property (nonatomic, assign) BOOL gridScrolling;
@end

@implementation CatalogViewController

#pragma mark - Lifecycle

// Live theme re-apply (called by AppDelegate when the user switches theme — no restart).
- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.tableView.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.tableView.separatorColor = [IOS6Theme separatorColor];
    self.statusLabel.textColor = [IOS6Theme labelGray];        // loading / empty-state: refresh on live switch
    self.statusLabel.backgroundColor = [UIColor clearColor];
    [self themeSelectionToolbar];
    [self.tableView reloadData];
}

// The bottom multi-select toolbar must follow the theme (it stayed light in dark mode). Same rule as
// the themed nav bar: stock for default, dark/colour bar + light button tint otherwise.
- (void)themeSelectionToolbar {
    UIToolbar *tb = self.selectionToolbar;
    if (!tb) return;
    BOOL canBg = [tb respondsToSelector:@selector(setBackgroundImage:forToolbarPosition:barMetrics:)];
    if ([IOS6Theme isDefaultTheme]) {
        tb.barStyle = UIBarStyleDefault;
        tb.tintColor = nil;
        if (canBg) [tb setBackgroundImage:nil forToolbarPosition:UIToolbarPositionAny barMetrics:UIBarMetricsDefault];
    } else {
        tb.barStyle = UIBarStyleBlack;
        tb.tintColor = [IOS6Theme navBarButtonTint];
        UIImage *bg = [IOS6Theme navBarBackground];
        if (bg && canBg) [tb setBackgroundImage:bg forToolbarPosition:UIToolbarPositionAny barMetrics:UIBarMetricsDefault];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Keep a caller-set title (the category home pushes us as "All apps"); else default.
    if (!self.title.length) self.title = T(@"catalog.title");
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];  // App Store white

    // v1.4: re-lay-out the tile grid when the Settings density slider changes.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(gridDensityDidChange)
            name:@"AppDropGridDensityChanged" object:nil];

    self.filter = [CatalogFilter load_];
    self.results = [NSMutableArray array];
    self.selectedAppsByPk = [NSMutableDictionary dictionary];
    self.currentQuery = @"";

    [self buildUI];
    [self refreshNavBar];
    [self performSearch];
}

- (void)buildUI {
    CGFloat w = self.view.bounds.size.width;

    // v1.1: the catalog search bar moved to its own dedicated Search tab in the
    // tab bar. This screen is now just the catalog grid + filter / select / refresh.
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                   style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Row height + separators follow the density setting (list = 76 pt with separators, grid = none).
    self.tableView.rowHeight = [AppRowCell gridRowHeightForWidth:self.tableView.bounds.size.width];
    self.tableView.separatorStyle = [self useGrid] ? UITableViewCellSeparatorStyleNone
                                                   : UITableViewCellSeparatorStyleSingleLine;
    self.tableView.backgroundColor = [IOS6Theme contentBackgroundColor];
    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc]
                     initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 36)];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [IOS6Theme labelGray];
    self.statusLabel.backgroundColor = [UIColor clearColor];   // iOS 6 table footers default to white
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.tableView.tableFooterView = self.statusLabel;

    // Selection toolbar — bottom of view, hidden by default. Shown in selection
    // mode so the user can tap "Installer (N)" without losing scroll position.
    self.selectionToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(
        0, self.view.bounds.size.height - kSelectionToolbarHeight,
        w, kSelectionToolbarHeight)];
    self.selectionToolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth
                                           | UIViewAutoresizingFlexibleTopMargin;
    self.selectionToolbar.hidden = YES;
    self.favSelectionItem = [[UIBarButtonItem alloc] initWithTitle:T(@"collections.favorites")
        style:UIBarButtonItemStyleBordered target:self action:@selector(addSelectedToFavorites)];
    self.laterSelectionItem = [[UIBarButtonItem alloc] initWithTitle:T(@"later.short")
        style:UIBarButtonItemStyleBordered target:self action:@selector(addSelectedToLater)];
    self.dossierSelectionItem = [[UIBarButtonItem alloc] initWithTitle:T(@"folder.short")
        style:UIBarButtonItemStyleBordered target:self action:@selector(addSelectedToFolder)];
    self.installSelectionItem = [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:T(@"catalog.install_n"), 0UL]
                style:UIBarButtonItemStyleDone
               target:self action:@selector(installSelectedTapped)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    // [Favoris] [Plus tard] [Dossier]  ⎵  [Installer (N)]
    self.selectionToolbar.items = @[self.favSelectionItem, self.laterSelectionItem,
                                    self.dossierSelectionItem, flex, self.installSelectionItem];
    [self themeSelectionToolbar];
    [self.view addSubview:self.selectionToolbar];
}

- (void)refreshNavBar {
    if (self.selectionMode) {
        // In selection mode: Cancel (left) + Done (right). No Filters/Refresh —
        // would be confusing because changing filters discards the selection.
        UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc]
            initWithTitle:T(@"common.done") style:UIBarButtonItemStyleDone
                                 target:self action:@selector(exitSelectionMode)];
        self.navigationItem.rightBarButtonItems = @[doneBtn];
    } else {
        UIBarButtonItem *filtersBtn = [[UIBarButtonItem alloc]
            initWithTitle:T(@"catalog.filters")
                    style:UIBarButtonItemStyleBordered
                   target:self action:@selector(filtersTapped)];
        UIBarButtonItem *selectBtn = [[UIBarButtonItem alloc]
            initWithTitle:T(@"catalog.select")
                    style:UIBarButtonItemStyleBordered
                   target:self action:@selector(enterSelectionMode)];
        UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                 target:self action:@selector(performSearch)];
        // Order is rightmost first: [filters, select, refresh].
        self.navigationItem.rightBarButtonItems = @[filtersBtn, selectBtn, refreshBtn];
    }
}

#pragma mark - Filters

- (void)filtersTapped {
    FilterViewController *fvc = [[FilterViewController alloc] init];
    fvc.filter = [self.filter copy];
    fvc.delegate = self;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fvc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)filterViewController:(FilterViewController *)vc didSaveFilter:(CatalogFilter *)filter {
    self.filter = filter;
    [self dismissViewControllerAnimated:YES completion:nil];
    [self performSearch];
}

- (void)filterViewControllerDidCancel:(FilterViewController *)vc {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Search

- (void)performSearch {
    self.pageOffset = 0;
    self.eof = NO;
    [self.results removeAllObjects];
    [self.tableView reloadData];
    [self loadMore];
}

- (void)loadMore {
    if (self.loading || self.eof) return;
    self.loading = YES;
    self.statusLabel.text = self.results.count == 0 ? T(@"catalog.loading") : T(@"catalog.loading_more");
    [self.spinner startAnimating];

    if ([[InstallManager shared] autonomousMode]) {
        [self loadMoreAutonomous];
        return;
    }

    NSString *backend = [[InstallManager shared] backendURL];
    NSString *qs = [self.filter queryStringWithSearch:self.currentQuery
                                                 offset:self.pageOffset
                                                  limit:30];
    NSString *url = [NSString stringWithFormat:@"%@/catalog?%@", backend, qs];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:20];
    [NSURLConnection sendAsynchronousRequest:req
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
        self.loading = NO;
        [self.spinner stopAnimating];
        if (e || !d) {
            self.statusLabel.text = [NSString stringWithFormat:T(@"catalog.network_error"),
                                       e.localizedDescription ?: @""];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (!json) {
            self.statusLabel.text = T(@"catalog.server_invalid");
            return;
        }
        NSArray *results = json[@"results"];
        NSInteger total = [json[@"total"] integerValue];
        self.totalCount = total;
        if ([results count] == 0) {
            self.eof = YES;
        } else {
            [self.results addObjectsFromArray:results];
            self.pageOffset += [results count];
            if (self.pageOffset >= total) self.eof = YES;
        }
        self.statusLabel.text = [NSString stringWithFormat:T(@"catalog.apps_count"),
                                  (unsigned long)self.results.count, (long)total,
                                  self.eof ? T(@"catalog.end") : @""];
        [self.tableView reloadData];
    }];
}

- (void)loadMoreAutonomous {
    void (^doQuery)(void) = ^{
        [[LocalCatalog shared] searchAsyncWithQuery:self.currentQuery
                                              minIOS:self.filter.minIOS
                                              maxIOS:self.filter.maxIOS
                                              unique:self.filter.uniqueOnly
                                                sort:self.filter.sort
                                          descending:self.filter.sortDescending
                                         deviceClass:self.filter.deviceClass
                                         category:nil
                                         subgenre:nil
                                              offset:self.pageOffset
                                               limit:30
                                          completion:^(NSDictionary *res) {
            self.loading = NO;
            [self.spinner stopAnimating];
            if (res[@"error"]) {
                self.statusLabel.text = [@"Local: " stringByAppendingString:res[@"error"]];
                return;
            }
            NSArray *page = res[@"results"];
            NSInteger total = [res[@"total"] integerValue];
            self.totalCount = total;
            if (!page.count) {
                self.eof = YES;
                [self.tableView reloadData];
            } else {
                [self.results addObjectsFromArray:page];
                self.pageOffset += page.count;
                if (self.pageOffset >= total) self.eof = YES;
                // Defer the reload while the user is flinging — reloading mid-scroll
                // re-lays-out every visible tile and stutters the dense grid.
                if (self.tableView.dragging || self.tableView.decelerating) {
                    self.pendingReload = YES;
                } else {
                    [UIView setAnimationsEnabled:NO];
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    [self.tableView reloadData];
                    [CATransaction commit];
                    [UIView setAnimationsEnabled:YES];
                }
            }
            self.statusLabel.text = [NSString stringWithFormat:T(@"catalog.apps_count"),
                                      (unsigned long)self.results.count, (long)total,
                                      self.eof ? T(@"catalog.end") : @""];
        }];
    };

    if ([[LocalCatalog shared] isReady]) { doQuery(); return; }
    self.statusLabel.text = T(@"catalog.loading");
    [[LocalCatalog shared] loadWithProgress:^(NSString *status) {
        self.statusLabel.text = status;
    } completion:^(BOOL ok, NSError *err) {
        if (!ok) {
            self.loading = NO;
            [self.spinner stopAnimating];
            // Catalog download failed/stalled (e.g. iPad 1 network) → let the user retry
            // in place instead of being stuck. (#146)
            self.statusLabel.text = T(@"catalog.retry");
            [self enableCatalogRetryTap];
            return;
        }
        doQuery();
    }];
}

// Make the footer status label tap-to-retry after a failed catalog load.
- (void)enableCatalogRetryTap {
    self.statusLabel.userInteractionEnabled = YES;
    if (!self.catalogRetryRecognizer) {
        self.catalogRetryRecognizer = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(catalogRetryTapped)];
        [self.statusLabel addGestureRecognizer:self.catalogRetryRecognizer];
    }
    self.catalogRetryRecognizer.enabled = YES;
}

- (void)catalogRetryTapped {
    self.catalogRetryRecognizer.enabled = NO;          // guard against double-tap
    self.statusLabel.userInteractionEnabled = NO;
    self.loading = NO;                                 // allow re-entry
    self.statusLabel.text = T(@"catalog.loading");
    [self.spinner startAnimating];
    [self loadMoreAutonomous];                         // re-run resolve → load → query
}

// v1.1: UISearchBarDelegate methods removed — search now lives in its own
// SearchViewController tab. CatalogVC's currentQuery is always @"" (the
// LocalCatalog query path still accepts it and returns the unfiltered list).

#pragma mark - Selection mode

- (void)enterSelectionMode {
    self.selectionMode = YES;
    self.savedTitle = self.navigationItem.title;   // restore it on exit
    [self refreshNavBar];
    [self updateSelectionToolbar];
    [self.tableView reloadData];
}

- (void)exitSelectionMode {
    self.selectionMode = NO;
    [self.selectedAppsByPk removeAllObjects];
    self.navigationItem.title = self.savedTitle;
    [self refreshNavBar];
    [self updateSelectionToolbar];
    [self.tableView reloadData];
}

- (void)toggleSelectionForApp:(NSDictionary *)app {
    NSNumber *pk = app[@"id"];
    if (!pk) return;
    if ([self.selectedAppsByPk objectForKey:pk]) {
        [self.selectedAppsByPk removeObjectForKey:pk];
    } else {
        // Copy because the dict in self.results may go away when the user
        // changes filter/search; we want our backing store independent.
        [self.selectedAppsByPk setObject:[app copy] forKey:pk];
    }
    [self updateSelectionToolbar];
}

- (void)updateSelectionToolbar {
    NSUInteger n = self.selectedAppsByPk.count;
    // Persistent count, always visible at the top while selecting.
    if (self.selectionMode)
        self.navigationItem.title = [NSString stringWithFormat:T(@"select.count"), (unsigned long)n];
    self.installSelectionItem.title = [NSString stringWithFormat:T(@"catalog.install_n"),
                                         (unsigned long)n];
    self.installSelectionItem.enabled = (n > 0);
    self.favSelectionItem.enabled = (n > 0);
    self.laterSelectionItem.enabled = (n > 0);
    self.dossierSelectionItem.enabled = (n > 0);
    BOOL shouldShow = self.selectionMode;
    if (shouldShow == !self.selectionToolbar.hidden) {
        // Already in correct state — just refresh content insets if needed.
    } else {
        self.selectionToolbar.hidden = !shouldShow;
        UIEdgeInsets ci = self.tableView.contentInset;
        ci.bottom = shouldShow ? kSelectionToolbarHeight : 0;
        self.tableView.contentInset = ci;
        UIEdgeInsets si = self.tableView.scrollIndicatorInsets;
        si.bottom = shouldShow ? kSelectionToolbarHeight : 0;
        self.tableView.scrollIndicatorInsets = si;
    }
}

- (void)installSelectedTapped {
    if (self.selectedAppsByPk.count == 0) return;
    NSArray *batch = [self.selectedAppsByPk.allValues copy];

    // v1.5-10: ipainstaller is now a hard Depends in the .deb — Cydia enforces
    // it at install time. Skip the in-app onboarding alert and go straight in.
    [self fireBatchInstall:batch];
}

- (void)fireBatchInstall:(NSArray *)batch {
    NSUInteger started = 0;
    for (NSDictionary *app in batch) {
        NSString *url = app[@"url"];
        if (!url.length) continue;
        // Dedup: skip if there's already a job in flight for this URL. Otherwise
        // double-tapping the install button stacks two parallel downloads of the
        // same .ipa and ipainstaller installs the app twice.
        if ([[InstallManager shared] hasActiveJobForURL:url]) continue;
        [[InstallManager shared] startInstallWithURL:url
                                          completion:^(NSString *jobId, NSError *err) {
            // Errors surface via the Jobs tab; nothing to do per-app here.
        }];
        started++;
    }
    // Toast-style status feedback.
    self.statusLabel.text = [NSString stringWithFormat:T(@"catalog.install_started_n"),
                               (unsigned long)started];
    // Only exit selection mode if we WERE in it. Quick-install button calls this
    // path too and we don't want to disturb the catalog scroll when it does.
    if (self.selectionMode) [self exitSelectionMode];
}

- (void)addSelectedToFavorites {
    NSArray *batch = [self.selectedAppsByPk.allValues copy];
    if (!batch.count) return;
    for (NSDictionary *app in batch) [[CollectionStore shared] addApp:app toCollection:CollectionFavoritesId];
    self.statusLabel.text = [NSString stringWithFormat:T(@"select.added_fav"), (unsigned long)batch.count];
    [self exitSelectionMode];
}

- (void)addSelectedToLater {
    NSArray *batch = [self.selectedAppsByPk.allValues copy];
    if (!batch.count) return;
    for (NSDictionary *app in batch) [[CollectionStore shared] addApp:app toCollection:CollectionLaterId];
    self.statusLabel.text = [NSString stringWithFormat:T(@"select.added_later"), (unsigned long)batch.count];
    [self exitSelectionMode];
}

- (void)addSelectedToFolder {
    NSArray *batch = [self.selectedAppsByPk.allValues copy];
    if (!batch.count) return;
    __weak typeof(self) ws = self;
    [FolderPicker presentAddToFolderFrom:self completion:^(NSString *cid) {
        if (!cid) return;
        for (NSDictionary *app in batch) [[CollectionStore shared] addApp:app toCollection:cid];
        ws.statusLabel.text = [NSString stringWithFormat:T(@"select.added_folder"), (unsigned long)batch.count];
        [ws exitSelectionMode];
    }];
}

#pragma mark - Quick install (single tap from list)

// quickInstallApp:/quickInstallFromButton: were removed in v2.0.30 along with
// the per-cell install shortcut. Single installs go through the detail VC;
// batch installs go through the multi-select toolbar.

#pragma mark - UIAlertViewDelegate (onboarding)

- (void)alertView:(UIAlertView *)av clickedButtonAtIndex:(NSInteger)idx {
    if (av.tag != 43) return;
    if (idx == av.cancelButtonIndex) {
        self.pendingBatchInstall = nil;
        return;
    }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kOnboardingKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSArray *batch = self.pendingBatchInstall;
    self.pendingBatchInstall = nil;
    if (batch.count) [self fireBatchInstall:batch];
}

#pragma mark - Table

- (NSInteger)tilesPerRowForWidth:(CGFloat)w {
    return [AppRowCell tilesPerRowForWidth:w];   // shared, density-driven (Settings slider)
}

// v3.0: list vs grid is decided by the density setting on BOTH idioms (iPhone defaults to a
// single-column list, iPad to a grid). n==1 → list (CatalogAppCell); n≥2 → packed tile grid.
- (BOOL)useGrid {
    CGFloat w = self.tableView.bounds.size.width;
    if (w < 1) w = [UIScreen mainScreen].bounds.size.width;
    return [AppRowCell tilesPerRowForWidth:w] > 1;
}

- (void)gridDensityDidChange {
    CGFloat w = self.tableView.bounds.size.width;
    self.tableView.rowHeight = [AppRowCell gridRowHeightForWidth:w];
    self.tableView.separatorStyle = [self useGrid] ? UITableViewCellSeparatorStyleNone
                                                   : UITableViewCellSeparatorStyleSingleLine;
    self.lastTPR = [AppRowCell tilesPerRowForWidth:w];   // keep the rotation guard in sync
    [self.tableView reloadData];   // new column count + row height from the density pref
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    NSInteger n = [self tilesPerRowForWidth:tv.bounds.size.width];
    if (n <= 1) return self.results.count;   // list: one app per row
    NSInteger rows = (NSInteger)(self.results.count + n - 1) / n;
    return rows;
}

- (NSString *)humanSize:(long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld %@", bytes, T(@"unit.b")];
    if (bytes < 1024*1024) return [NSString stringWithFormat:@"%.0f %@", bytes/1024.0, T(@"unit.kb")];
    if (bytes < 1024LL*1024*1024) return [NSString stringWithFormat:@"%.1f %@", bytes/(1024.0*1024), T(@"unit.mb")];
    return [NSString stringWithFormat:@"%.2f %@", bytes/(1024.0*1024*1024), T(@"unit.gb")];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // ============ Grid: multi-tile row (iPad always; iPhone when density > list) ============
    if ([AppRowCell tilesPerRowForWidth:tv.bounds.size.width] > 1) {
        static NSString *rowId = @"catRow";
        AppRowCell *row = [tv dequeueReusableCellWithIdentifier:rowId];
        if (!row) {
            row = [[AppRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:rowId];
        }
        NSInteger n = [self tilesPerRowForWidth:tv.bounds.size.width];
        row.tilesPerRow = n;
        [row setContentRasterized:!self.gridScrolling];   // rasterize at rest, plain while scrolling
        __weak typeof(self) ws = self;
        row.selectionMode = self.selectionMode;
        // Selection lookup callback — runs for each tile during layout so the
        // check overlay reflects the source-of-truth dict, not stale visuals.
        row.isAppSelectedBlock = ^BOOL(NSDictionary *app) {
            NSNumber *pk = app[@"id"];
            return pk && ws.selectedAppsByPk[pk] != nil;
        };
        row.onTileTap = ^(NSDictionary *app) {
            if (ws.selectionMode) {
                [ws toggleSelectionForApp:app];   // tile already flipped its own check instantly (no reload)
            } else {
                AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:app];
                [ws.navigationController pushViewController:vc animated:YES];
            }
        };
        NSInteger start = ip.row * n;
        NSInteger end = MIN(start + n, (NSInteger)self.results.count);
        NSArray *slice = (start < (NSInteger)self.results.count)
            ? [self.results subarrayWithRange:NSMakeRange(start, end - start)]
            : @[];
        [row setApps:slice];

        if (end >= (NSInteger)self.results.count - n * 2) [self loadMore];
        return row;
    }

    // ============ List: single app per row, custom cell (iPhone default) ============
    // v2.0.29: switched to CatalogAppCell (custom UITableViewCell subclass) so
    // the install button lives in contentView, not accessoryView. Resolves the
    // iOS 6 bug where UIControl-in-accessoryView taps were stolen by the cell's
    // tap recognizer and turned into didSelectRow.
    static NSString *cellId = @"catCell";
    CatalogAppCell *cell = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[CatalogAppCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:cellId];
    }
    NSDictionary *app = self.results[ip.row];
    cell.appTitleLabel.text = app[@"title"] ?: @"?";
    long long size = [app[@"size"] longLongValue];
    NSString *sizeStr = size > 0 ? [self humanSize:size] : @"?";
    NSString *fname = app[@"fileName"] ?: @"";
    NSString *metaLine = [NSString stringWithFormat:@"v%@ — min iOS %@ — %@",
                          app[@"version"] ?: @"?", ADDisplayIOS(app[@"minOS"]), sizeStr];
    cell.appSubtitleLabel.text = fname.length
        ? [NSString stringWithFormat:@"%@\n%@", metaLine, fname]
        : metaLine;

    // === Right slot: checkmark in selection mode, nothing in default ===
    if (self.selectionMode) {
        NSNumber *pk = app[@"id"];
        BOOL isSel = pk && [self.selectedAppsByPk objectForKey:pk] != nil;
        cell.accessoryType = isSel ? UITableViewCellAccessoryCheckmark
                                   : UITableViewCellAccessoryNone;
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;

    // Icon — async via IconLoader
    NSString *iconUrl = app[@"icon"];
    CGSize sz = CGSizeMake(kIconSize, kIconSize);
    UIImage *cached = [[IconLoader shared] cachedImageForURL:iconUrl targetSize:sz];
    if (cached) {
        cell.appIconView.image = cached;
    } else {
        cell.appIconView.image = nil;
        NSString *expectedTitle = app[@"title"];
        [[IconLoader shared] loadImageForURL:iconUrl
                                   targetSize:sz
                                          via:nil
                                   completion:^(UIImage *img) {
            if (!img) return;
            CatalogAppCell *visible = (CatalogAppCell *)[self.tableView cellForRowAtIndexPath:ip];
            if (![visible isKindOfClass:[CatalogAppCell class]]) return;
            if (ip.row >= (NSInteger)self.results.count) return;
            NSDictionary *appNow = self.results[ip.row];
            if (![appNow[@"title"] isEqual:expectedTitle]) return;
            visible.appIconView.image = img;
        }];
    }

    if (ip.row >= (NSInteger)self.results.count - 5) {
        [self loadMore];
    }
    return cell;
}

#pragma mark - UIScrollView (suspend icons while fast-scrolling)

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv {
    self.gridScrolling = YES;
    // Don't suspend icon loads anymore — with off-main decode + visible-first ordering, icons
    // load continuously AS you scroll (the currently-visible ones jump the queue).
    [self setVisibleRowsRasterized:NO];   // composite directly while scrolling — no re-raster spikes
    [AppTileView setSuppressTileText:NO];  // a finger-drag shows text; it's the FLING we skip it on
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)sv {
    if ([self useGrid]) [AppTileView setSuppressTileText:YES];   // fast fling → tiles draw card+icon only
}

- (void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)decel {
    if (!decel) [self gridScrollDidStop];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv {
    [self gridScrollDidStop];
}

- (void)gridScrollDidStop {
    self.gridScrolling = NO;
    [AppTileView setSuppressTileText:NO];
    for (UITableViewCell *c in [self.tableView visibleCells])
        if ([c isKindOfClass:[AppRowCell class]]) [(AppRowCell *)c redrawTiles];   // bring text back
    [self setVisibleRowsRasterized:YES];  // flatten each row to 1 cached bitmap at rest
    [self flushPendingReload];
}

// Toggle row rasterization on the currently-visible grid rows (no-op in list mode — no AppRowCells).
- (void)setVisibleRowsRasterized:(BOOL)on {
    if (![self useGrid]) return;
    for (UITableViewCell *c in [self.tableView visibleCells]) {
        if ([c isKindOfClass:[AppRowCell class]]) [(AppRowCell *)c setContentRasterized:on];
    }
}

- (void)flushPendingReload {
    if (!self.pendingReload) return;
    self.pendingReload = NO;
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if ([self useGrid]) return;  // grid taps handled by AppTileView's onTileTap; list taps fall through
    if (ip.row >= (NSInteger)self.results.count) return;
    NSDictionary *app = self.results[ip.row];
    if (self.selectionMode) {
        [self toggleSelectionForApp:app];
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:app];
    [self.navigationController pushViewController:vc animated:YES];
}

// Rotation / bounds-change fix: when the column count actually changes (at the FINAL width),
// reload so EVERY visible row uses the new tilesPerRow + row height. The old willAnimateRotation
// reload fired mid-animation at a transient width, leaving some rows with the old column count
// and others (built on later scroll) with the new one — the "mixed rows per orientation" bug.
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGFloat w = self.tableView.bounds.size.width;
    if (w < 1) return;
    NSInteger n = [self tilesPerRowForWidth:w];
    if (n != self.lastTPR) {
        self.lastTPR = n;
        self.tableView.rowHeight = [AppRowCell gridRowHeightForWidth:w];
        self.tableView.separatorStyle = (n > 1) ? UITableViewCellSeparatorStyleNone
                                                : UITableViewCellSeparatorStyleSingleLine;
        [self.tableView reloadData];
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
