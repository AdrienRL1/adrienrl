#import "SearchViewController.h"
#import "Localization.h"
#import "LocalCatalog.h"
#import "CatalogFilter.h"
#import "CatalogAppCell.h"
#import "AppDetailViewController.h"
#import "IconLoader.h"
#import "IOS6Theme.h"
#import "AppRowCell.h"
#import "AppTileView.h"
#import "FilterViewController.h"
#import "CheckpointLog.h"
#import "FeedbackViewController.h"
#import "CollectionStore.h"
#import "InstallManager.h"
#import "FolderPicker.h"

// v3.0: list vs grid is driven by the density setting via -[self useGrid], not an idiom check.

static const CGFloat kIconSize = 44;
static const NSInteger kPageLimit = 50;

@interface SearchViewController () <FilterViewControllerDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray *results;
@property (nonatomic, copy)   NSString *currentQuery;
@property (nonatomic, assign) NSInteger pageOffset;
@property (nonatomic, assign) NSInteger totalCount;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL eof;
// Monotonically-increasing token so out-of-order async responses from the
// catalog don't clobber newer results. Bump on every new query.
@property (nonatomic, assign) NSInteger queryToken;
// Category browse defaults to showing the WHOLE category (matching the card count).
// Set YES once the user explicitly applies Filters in category mode, so their
// iOS/device narrowing then takes effect.
@property (nonatomic, assign) BOOL categoryFilterApplied;
@property (nonatomic, assign) BOOL pendingReload;   // a page arrived mid-scroll; reload on stop
// iPad grid: rotation-reload guard (last tiles-per-row) + active-scroll flag (rasterize off while scrolling).
@property (nonatomic, assign) NSInteger lastTPR;
@property (nonatomic, assign) BOOL gridScrolling;
// --- Phase 3: multi-select (mirrors CatalogViewController) ---
@property (nonatomic, assign) BOOL selectionMode;
@property (nonatomic, copy)   NSString *savedTitle;   // restored when leaving selection mode
@property (nonatomic, strong) NSMutableDictionary *selectedAppsByPk;
@property (nonatomic, strong) UIToolbar *selectionToolbar;
@property (nonatomic, strong) UIBarButtonItem *installSelectionItem;
@property (nonatomic, strong) UIBarButtonItem *favSelectionItem;
@property (nonatomic, strong) UIBarButtonItem *laterSelectionItem;
@property (nonatomic, strong) UIBarButtonItem *dossierSelectionItem;
@end

@implementation SearchViewController

// Live theme re-apply (AppDelegate calls this on a theme switch — no restart).
- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.tableView.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.tableView.separatorColor = [IOS6Theme separatorColor];
    self.statusLabel.textColor = [IOS6Theme labelGray];
    self.statusLabel.backgroundColor = [UIColor clearColor];
    [IOS6Theme styleSearchBar:self.searchBar];
    [self.tableView reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"tab.search");
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.results = [NSMutableArray array];
    self.currentQuery = @"";
    // v1.4: re-lay-out the grid when the Settings density slider changes.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(gridDensityDidChange)
            name:@"AppDropGridDensityChanged" object:nil];

    CGFloat w = self.view.bounds.size.width;
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
    self.searchBar.placeholder = T(@"search.placeholder");
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.delegate = self;
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [IOS6Theme styleSearchBar:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                   style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = self.searchBar;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.rowHeight = [AppRowCell gridRowHeightForWidth:self.tableView.bounds.size.width];
    // Grid rows have no separators (they'd draw weird lines between tiles); the single-column
    // list keeps the normal single-line separators. v3.0: decided by the density setting on both idioms.
    self.tableView.separatorStyle = [self useGrid]
        ? UITableViewCellSeparatorStyleNone : UITableViewCellSeparatorStyleSingleLine;
    self.tableView.backgroundColor = [IOS6Theme contentBackgroundColor];
    [self.view addSubview:self.tableView];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 36)];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [IOS6Theme labelGray];
    self.statusLabel.backgroundColor = [UIColor clearColor];   // iOS 6 footer views default to white
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.text = T(@"search.hint_empty");
    self.tableView.tableFooterView = self.statusLabel;

    // Nav bar: Filtres + Sélectionner (→ OK in selection mode) + a bottom selection toolbar.
    self.selectedAppsByPk = [NSMutableDictionary dictionary];
    [self buildSelectionToolbar];
    [self refreshSearchNav];
    // Persistent Feedback button on the Search-tab root (left). Category-result screens
    // are pushed and need their Back button there, so skip them.
    if (self.categoryFilter.length == 0) [self installFeedbackBarButton];

    // v1.7 — category browse mode: titled by the menu, and we load the whole
    // category immediately (the search box then narrows WITHIN the category).
    if (self.categoryFilter.length) {
        self.title = self.categoryTitle.length ? self.categoryTitle : self.categoryFilter;
        [self runQuery];
    }
}

// Pop the keyboard as soon as the user lands on this tab — search-first UX.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Auto-focus the keyboard only on the real Search tab — not when browsing a category.
    if (self.currentQuery.length == 0 && self.categoryFilter.length == 0) {
        [self.searchBar becomeFirstResponder];
    }
}

#pragma mark - Multi-select (Phase 3)

- (void)buildSelectionToolbar {
    CGRect b = self.view.bounds;
    self.selectionToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, b.size.height - 44, b.size.width, 44)];
    self.selectionToolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.selectionToolbar.hidden = YES;
    self.favSelectionItem = [[UIBarButtonItem alloc] initWithTitle:T(@"collections.favorites")
        style:UIBarButtonItemStyleBordered target:self action:@selector(addSelectedToFavorites)];
    self.laterSelectionItem = [[UIBarButtonItem alloc] initWithTitle:T(@"later.short")
        style:UIBarButtonItemStyleBordered target:self action:@selector(addSelectedToLater)];
    self.dossierSelectionItem = [[UIBarButtonItem alloc] initWithTitle:T(@"folder.short")
        style:UIBarButtonItemStyleBordered target:self action:@selector(addSelectedToFolder)];
    self.installSelectionItem = [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:T(@"catalog.install_n"), 0UL]
                style:UIBarButtonItemStyleDone target:self action:@selector(installSelectedTapped)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.selectionToolbar.items = @[self.favSelectionItem, self.laterSelectionItem,
                                    self.dossierSelectionItem, flex, self.installSelectionItem];
    [self themeSelectionToolbar];
    [self.view addSubview:self.selectionToolbar];
}

// Bottom multi-select toolbar must follow the theme (stayed light in dark mode). Same rule as the
// themed nav bar: stock for default, dark/colour bar + light button tint otherwise.
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

- (void)refreshSearchNav {
    if (self.selectionMode) {
        self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc]
            initWithTitle:T(@"common.done") style:UIBarButtonItemStyleDone target:self action:@selector(exitSelectionMode)]];
    } else {
        UIBarButtonItem *filters = [[UIBarButtonItem alloc] initWithTitle:T(@"catalog.filters")
            style:UIBarButtonItemStyleBordered target:self action:@selector(filtersTapped)];
        UIBarButtonItem *select = [[UIBarButtonItem alloc] initWithTitle:T(@"catalog.select")
            style:UIBarButtonItemStyleBordered target:self action:@selector(enterSelectionMode)];
        self.navigationItem.rightBarButtonItems = @[filters, select];
    }
}

- (void)enterSelectionMode {
    self.selectionMode = YES;
    self.savedTitle = self.navigationItem.title;
    if ([self.searchBar isFirstResponder]) [self.searchBar resignFirstResponder];
    [self refreshSearchNav]; [self updateSelectionToolbar]; [self.tableView reloadData];
}
- (void)exitSelectionMode {
    self.selectionMode = NO;
    [self.selectedAppsByPk removeAllObjects];
    self.navigationItem.title = self.savedTitle;
    [self refreshSearchNav]; [self updateSelectionToolbar]; [self.tableView reloadData];
}
- (void)toggleSelectionForApp:(NSDictionary *)app {
    NSNumber *pk = app[@"id"]; if (!pk) return;
    if ([self.selectedAppsByPk objectForKey:pk]) [self.selectedAppsByPk removeObjectForKey:pk];
    else                                          [self.selectedAppsByPk setObject:[app copy] forKey:pk];
    [self updateSelectionToolbar];
    // Grid: the tapped tile already flipped its own check instantly (no reload → snappier).
    // List: the row's checkmark accessory needs a refresh.
    if (![self useGrid]) [self.tableView reloadData];
}
- (void)updateSelectionToolbar {
    NSUInteger n = self.selectedAppsByPk.count;
    if (self.selectionMode)
        self.navigationItem.title = [NSString stringWithFormat:T(@"select.count"), (unsigned long)n];
    self.installSelectionItem.title = [NSString stringWithFormat:T(@"catalog.install_n"), (unsigned long)n];
    self.installSelectionItem.enabled = (n > 0);
    self.favSelectionItem.enabled = (n > 0);
    self.laterSelectionItem.enabled = (n > 0);
    self.dossierSelectionItem.enabled = (n > 0);
    BOOL show = self.selectionMode;
    if (show != !self.selectionToolbar.hidden) {
        self.selectionToolbar.hidden = !show;
        UIEdgeInsets ci = self.tableView.contentInset; ci.bottom = show ? 44 : 0; self.tableView.contentInset = ci;
        UIEdgeInsets si = self.tableView.scrollIndicatorInsets; si.bottom = show ? 44 : 0; self.tableView.scrollIndicatorInsets = si;
    }
}
- (void)installSelectedTapped {
    NSArray *batch = [self.selectedAppsByPk.allValues copy];
    if (!batch.count) return;
    NSUInteger started = 0;
    for (NSDictionary *app in batch) {
        NSString *url = app[@"url"];
        if (![url isKindOfClass:[NSString class]] || !url.length) continue;
        if ([[InstallManager shared] hasActiveJobForURL:url]) continue;
        [[InstallManager shared] startInstallWithURL:url completion:^(NSString *j, NSError *e) {}];
        started++;
    }
    self.statusLabel.text = [NSString stringWithFormat:T(@"catalog.install_started_n"), (unsigned long)started];
    [self exitSelectionMode];
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
    AD_WEAK typeof(self) ws = self;
    [FolderPicker presentAddToFolderFrom:self completion:^(NSString *cid) {
        if (!cid) return;
        for (NSDictionary *app in batch) [[CollectionStore shared] addApp:app toCollection:cid];
        ws.statusLabel.text = [NSString stringWithFormat:T(@"select.added_folder"), (unsigned long)batch.count];
        [ws exitSelectionMode];
    }];
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    self.currentQuery = text ?: @"";
    // 150 ms debounce — feels instant while still coalescing rapid keystrokes.
    // The Catalog tab uses 400 ms because its underlying query has a heavier
    // filter+sort path; Search uses the simpler query and can afford the speed.
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(runQuery)
                                               object:nil];
    [self performSelector:@selector(runQuery) withObject:nil afterDelay:0.15];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)sb {
    [sb setShowsCancelButton:YES animated:YES];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)sb {
    [sb setShowsCancelButton:NO animated:YES];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)sb {
    sb.text = @"";
    self.currentQuery = @"";
    [sb resignFirstResponder];
    [self.results removeAllObjects];
    self.statusLabel.text = T(@"search.hint_empty");
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
}

#pragma mark - Query

- (void)runQuery {
    self.pageOffset = 0;
    self.eof = NO;
    [self.results removeAllObjects];
    self.queryToken++;
    // CRITICAL: clear `loading` so a new query starts immediately even if a
    // previous one is still in flight on LocalCatalog's serial _searchQueue.
    // Without this, fast typing piles up the loading guard and new queries
    // never start ("Searching..." spinner hangs forever). The previous in-flight
    // query will still complete, but its response gets discarded by the
    // queryToken check below.
    self.loading = NO;
    [self.tableView reloadData];
    if (self.currentQuery.length == 0 && self.categoryFilter.length == 0) {
        self.statusLabel.text = T(@"search.hint_empty");
        return;
    }
    [self loadMore];
}

- (void)loadMore {
    if (self.loading || self.eof ||
        (self.currentQuery.length == 0 && self.categoryFilter.length == 0)) return;
    self.loading = YES;
    self.statusLabel.text = T(@"search.searching");
    NSInteger token = self.queryToken;
    CatalogFilter *cf = [CatalogFilter load_];
    BOOL catMode = self.categoryFilter.length > 0;
    // Category browse needs the deduped table (entries_unique holds the category column).
    BOOL uniq = catMode ? YES : cf.uniqueOnly;
    // By default a category shows ALL its apps (so the list matches the count on the
    // category card). Only once the user explicitly opens Filters in this view do we
    // apply their iOS/device narrowing.
    NSString *useMin = cf.minIOS, *useMax = cf.maxIOS, *useDev = cf.deviceClass;
    if (catMode && !self.categoryFilterApplied) {
        // Default category browse: show the whole category EXCEPT apps no version of
        // which can run on this device. So drop the user's narrow min-iOS/device
        // bounds, but keep a max-iOS ceiling at the device's iOS (uses min_minos in
        // unique mode → "has a runnable version"). Hides iOS 11+-only apps.
        useMin = nil; useDev = @"all";
        useMax = [[UIDevice currentDevice] systemVersion];
    }
    [[LocalCatalog shared] searchAsyncWithQuery:self.currentQuery
                                          minIOS:useMin
                                          maxIOS:useMax
                                          unique:uniq
                                            sort:cf.sort
                                      descending:cf.sortDescending
                                     deviceClass:useDev
                                        category:self.categoryFilter
                                        subgenre:self.subgenreFilter
                                          offset:self.pageOffset
                                           limit:kPageLimit
                                      completion:^(NSDictionary *res) {
        self.loading = NO;
        // Drop stale responses — if the user kept typing, our queryToken moved
        // on and these results are no longer relevant.
        if (token != self.queryToken) return;
        NSArray *page = res[@"results"];
        NSInteger total = [res[@"total"] integerValue];
        self.totalCount = total;
        if (!page.count) {
            self.eof = YES;
        } else {
            [self.results addObjectsFromArray:page];
            self.pageOffset += page.count;
            if (self.pageOffset >= total) self.eof = YES;
        }
        if (self.results.count == 0) {
            self.statusLabel.text = T(@"search.no_results");
        } else {
            self.statusLabel.text = [NSString stringWithFormat:T(@"search.results_count"),
                                       (unsigned long)self.results.count, (long)total];
        }
        // Reloading mid-fling re-lays-out every visible tile → a visible hitch on the
        // dense grid. Defer the reload to when scrolling stops (flushed in the
        // scroll-end delegates); the data is already appended so nothing is lost.
        BOOL scrolling = self.tableView.dragging || self.tableView.decelerating;
        if (scrolling) {
            self.pendingReload = YES;
        } else {
            [self.tableView reloadData];
            // Auto-fill (only when stationary): if a page didn't fill the screen, keep
            // loading so the user can scroll to reach the rest of the category.
            if (!self.eof) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!self.loading && !self.eof &&
                        !self.tableView.dragging && !self.tableView.decelerating &&
                        self.tableView.contentSize.height <= self.tableView.bounds.size.height + 80) {
                        [self loadMore];
                    }
                });
            }
        }
    }];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    NSInteger n = [AppRowCell tilesPerRowForWidth:tv.bounds.size.width];
    if (n <= 1) return self.results.count;   // list: one app per row
    return (NSInteger)(self.results.count + n - 1) / n;  // ceil — tiles packed per row
}

- (NSString *)humanSize:(long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld %@", bytes, T(@"unit.b")];
    if (bytes < 1024*1024) return [NSString stringWithFormat:@"%.0f %@", bytes/1024.0, T(@"unit.kb")];
    if (bytes < 1024LL*1024*1024) return [NSString stringWithFormat:@"%.1f %@", bytes/(1024.0*1024), T(@"unit.mb")];
    return [NSString stringWithFormat:@"%.2f %@", bytes/(1024.0*1024*1024), T(@"unit.gb")];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // ===== Grid: multi-tile row (iPad always; iPhone when density > list) =====
    if ([AppRowCell tilesPerRowForWidth:tv.bounds.size.width] > 1) {
        static NSString *rowId = @"searchRow";
        AppRowCell *row = [tv dequeueReusableCellWithIdentifier:rowId];
        if (!row) row = [[AppRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:rowId];
        NSInteger n = [AppRowCell tilesPerRowForWidth:tv.bounds.size.width];
        row.tilesPerRow = n;
        [row setContentRasterized:!self.gridScrolling];   // rasterize at rest, plain while scrolling
        row.selectionMode = self.selectionMode;
        AD_WEAK typeof(self) ws = self;
        row.isAppSelectedBlock = ^BOOL(NSDictionary *app) {
            NSNumber *pk = app[@"id"];
            return pk && ws.selectedAppsByPk[pk] != nil;
        };
        row.onTileTap = ^(NSDictionary *app) {
            if (ws.selectionMode) { [ws toggleSelectionForApp:app]; return; }
            if ([ws.searchBar isFirstResponder]) [ws.searchBar resignFirstResponder];
            AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:app];
            [ws.navigationController pushViewController:vc animated:YES];
        };
        NSInteger startIdx = ip.row * n;
        NSMutableArray *slice = [NSMutableArray array];
        for (NSInteger i = startIdx; i < startIdx + n && i < (NSInteger)self.results.count; i++) {
            [slice addObject:self.results[i]];
        }
        [row setApps:slice];
        NSInteger totalRows = (NSInteger)(self.results.count + n - 1) / n;
        if (ip.row >= totalRows - 2) [self loadMore];   // prefetch next page near the end
        return row;
    }

    // ===== iPhone: single-app list row =====
    static NSString *cellId = @"searchCell";
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
                            app[@"version"] ?: @"?", app[@"minOS"] ?: @"?", sizeStr];
    cell.appSubtitleLabel.text = fname.length
        ? [NSString stringWithFormat:@"%@\n%@", metaLine, fname]
        : metaLine;
    if (self.selectionMode) {
        NSNumber *pk = app[@"id"];
        cell.accessoryType = (pk && self.selectedAppsByPk[pk]) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;

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
            if (![self.results[ip.row][@"title"] isEqual:expectedTitle]) return;
            visible.appIconView.image = img;
        }];
    }

    if (ip.row >= (NSInteger)self.results.count - 5) [self loadMore];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if ([self useGrid]) return;   // grid taps are handled by AppRowCell tiles (onTileTap)
    [tv deselectRowAtIndexPath:ip animated:YES];
    if ([self.searchBar isFirstResponder]) [self.searchBar resignFirstResponder];
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

- (void)scrollViewDidScroll:(UIScrollView *)sv {
    // Robust infinite scroll: load the next page well before the bottom, regardless
    // of the per-cell prefetch heuristic (which can miss on the iPad grid). Guarded
    // by loading/eof so it never double-loads.
    if (self.loading || self.eof) return;
    if (self.currentQuery.length == 0 && self.categoryFilter.length == 0) return;
    CGFloat remaining = sv.contentSize.height - (sv.contentOffset.y + sv.bounds.size.height);
    if (remaining < 800) [self loadMore];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv {
    self.gridScrolling = YES;
    // Don't suspend icon loads anymore — off-main decode + visible-first ordering means icons
    // load continuously AS you scroll (currently-visible ones jump the queue).
    [self setVisibleRowsRasterized:NO];   // composite directly while scrolling — no re-raster spikes
    [AppTileView setSuppressTileText:NO];  // a finger-drag shows text; it's the FLING we skip it on
    if ([self.searchBar isFirstResponder]) [self.searchBar resignFirstResponder];
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

// Apply a reload that was deferred because a page arrived while the user was scrolling.
- (void)flushPendingReload {
    if (!self.pendingReload) return;
    self.pendingReload = NO;
    [self.tableView reloadData];
}

#pragma mark - Filters

- (void)filtersTapped {
    FilterViewController *fvc = [[FilterViewController alloc] init];
    fvc.filter = [CatalogFilter load_];
    fvc.delegate = self;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fvc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)filterViewController:(FilterViewController *)vc didSaveFilter:(CatalogFilter *)filter {
    // FilterViewController already persisted it; re-run the current query so the new
    // min/max iOS, device class, unique & sort apply to the search results.
    [self dismissViewControllerAnimated:YES completion:nil];
    if (self.categoryFilter.length) {
        self.categoryFilterApplied = YES;  // user opted into filtering this category
        [self runQuery];
    } else if (self.currentQuery.length) {
        [self runQuery];
    }
}

- (void)filterViewControllerDidCancel:(FilterViewController *)vc {
    [self dismissViewControllerAnimated:YES completion:nil];
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

// Rotation / bounds-change fix: reload when the column count actually changes (at the FINAL
// width) so all rows use the new tilesPerRow + row height — otherwise some rows keep the old
// column count while later-built ones use the new one (mixed rows after rotating).
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGFloat w = self.tableView.bounds.size.width;
    if (w < 1) return;
    NSInteger n = [AppRowCell tilesPerRowForWidth:w];
    if (n != self.lastTPR) {
        self.lastTPR = n;
        self.tableView.rowHeight = [AppRowCell gridRowHeightForWidth:w];
        self.tableView.separatorStyle = (n > 1) ? UITableViewCellSeparatorStyleNone
                                                : UITableViewCellSeparatorStyleSingleLine;
        [self.tableView reloadData];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
