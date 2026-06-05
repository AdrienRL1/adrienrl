#import "CollectionViewController.h"
#import "CollectionStore.h"
#import "CatalogAppCell.h"
#import "IconLoader.h"
#import "Localization.h"
#import "AppDetailViewController.h"
#import "InstallManager.h"

static const CGFloat kCollIcon = 44.0;
static const CGFloat kToolbarH = 44.0;

@interface CollectionViewController () <UIActionSheetDelegate, UIAlertViewDelegate>
@property (nonatomic, copy)   NSString *collectionId;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *apps;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIToolbar *toolbar;
@property (nonatomic, assign) BOOL selecting;
@property (nonatomic, strong) NSMutableSet *selectedKeys;
@property (nonatomic, weak)   UIBarButtonItem *editBarButton;   // anchors the edit menu popover on iPad
@end

@implementation CollectionViewController

- (instancetype)initWithCollectionId:(NSString *)cid {
    if ((self = [super init])) {
        _collectionId = [cid copy];
        _selectedKeys = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [[CollectionStore shared] nameForCollection:self.collectionId];
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.rowHeight = 76;
    self.tableView.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.tableView.separatorColor = [IOS6Theme separatorColor];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 30, 0)];
    self.emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.textColor = [IOS6Theme labelGray];
    self.emptyLabel.backgroundColor = [UIColor clearColor];
    self.emptyLabel.text = T(@"collections.empty");
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    self.toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - kToolbarH,
                                                               self.view.bounds.size.width, kToolbarH)];
    self.toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.toolbar.hidden = YES;
    [self.view addSubview:self.toolbar];

    [self themeToolbar];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
                                                 name:CollectionStoreDidChangeNotification object:nil];
    [self reload];
}

- (void)reload {
    self.apps = [[CollectionStore shared] appsInCollection:self.collectionId];
    // Drop any selected keys that no longer exist.
    NSMutableSet *live = [NSMutableSet set];
    for (NSDictionary *a in self.apps) {
        NSString *k = [CollectionStore keyForApp:a];
        if (k) [live addObject:k];
    }
    [self.selectedKeys intersectSet:live];

    BOOL empty = (self.apps.count == 0);
    self.emptyLabel.hidden = !empty;
    self.tableView.hidden = empty;
    if (empty && self.selecting) [self exitSelection];
    [self.tableView reloadData];
    [self rebuildBarButtons];
    [self rebuildToolbar];
}

#pragma mark - Bar buttons / modes

- (void)rebuildBarButtons {
    if (self.selecting) {
        self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc]
            initWithTitle:T(@"common.done") style:UIBarButtonItemStyleDone target:self action:@selector(exitSelection)]];
    } else {
        // `folder` = a USER-created folder (builtin:NO). Built-in Favoris / Télécharger plus tard
        // never get a Modifier button, so they can never be renamed or deleted from here.
        // (The "preview image" pinning feature was removed — tiles always show the auto mosaic.)
        BOOL folder = [self isFolderCollection];
        NSMutableArray *items = [NSMutableArray array];
        if (self.apps.count) {
            UIBarButtonItem *sel = [[UIBarButtonItem alloc] initWithTitle:T(@"collections.select")
                style:UIBarButtonItemStyleBordered target:self action:@selector(enterSelection)];
            if ([self.collectionId isEqualToString:CollectionLaterId]) {
                UIBarButtonItem *dlAll = [[UIBarButtonItem alloc] initWithTitle:T(@"collections.download_all")
                    style:UIBarButtonItemStyleDone target:self action:@selector(downloadAllTapped)];
                [items addObject:dlAll];
                [items addObject:sel];
            } else if (folder) {
                UIBarButtonItem *edit = [[UIBarButtonItem alloc] initWithTitle:T(@"folder.edit")
                    style:UIBarButtonItemStyleBordered target:self action:@selector(editMenu)];
                [items addObject:sel];
                [items addObject:edit];
                self.editBarButton = edit;
            } else {
                [items addObject:sel];   // built-in Favoris: just Select
            }
        } else if (folder) {
            // Empty user folder: still allow rename / DELETE.
            UIBarButtonItem *edit = [[UIBarButtonItem alloc] initWithTitle:T(@"folder.edit")
                style:UIBarButtonItemStyleBordered target:self action:@selector(editMenu)];
            [items addObject:edit];
            self.editBarButton = edit;
        }
        self.navigationItem.rightBarButtonItems = items;
    }
}

- (void)enterSelection {
    self.selecting = YES;
    [self.selectedKeys removeAllObjects];
    self.toolbar.hidden = NO;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, kToolbarH, 0);
    self.tableView.scrollIndicatorInsets = self.tableView.contentInset;
    [self rebuildBarButtons];
    [self rebuildToolbar];
    [self.tableView reloadData];
}

- (void)exitSelection {
    self.selecting = NO;
    [self.selectedKeys removeAllObjects];
    self.toolbar.hidden = YES;
    self.tableView.contentInset = UIEdgeInsetsZero;
    self.tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
    [self rebuildBarButtons];
    [self.tableView reloadData];
}

- (void)rebuildToolbar {
    if (!self.selecting) return;
    NSInteger n = (NSInteger)self.selectedKeys.count;
    BOOL allSelected = (n == (NSInteger)self.apps.count && self.apps.count > 0);
    UIBarButtonItem *all = [[UIBarButtonItem alloc]
        initWithTitle:(allSelected ? T(@"collections.select_none") : T(@"collections.select_all"))
        style:UIBarButtonItemStyleBordered target:self action:@selector(toggleSelectAll)];
    UIBarButtonItem *flex1 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *rm = [[UIBarButtonItem alloc] initWithTitle:T(@"collections.remove")
        style:UIBarButtonItemStyleBordered target:self action:@selector(removeSelected)];
    rm.enabled = n > 0;
    UIBarButtonItem *flex2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *dl = [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:T(@"collections.download_n"), (long)n]
        style:UIBarButtonItemStyleDone target:self action:@selector(downloadSelected)];
    dl.enabled = n > 0;
    self.toolbar.items = @[all, flex1, rm, flex2, dl];
}

- (void)toggleSelectAll {
    if ((NSInteger)self.selectedKeys.count == (NSInteger)self.apps.count) {
        [self.selectedKeys removeAllObjects];
    } else {
        for (NSDictionary *a in self.apps) {
            NSString *k = [CollectionStore keyForApp:a];
            if (k) [self.selectedKeys addObject:k];
        }
    }
    [self.tableView reloadData];
    [self rebuildToolbar];
}

#pragma mark - Actions

// Start downloads for the given apps. For the "Télécharger plus tard" queue, each app also LEAVES
// the queue once it's handed off (it's a queue, not a permanent collection).
- (NSInteger)startDownloadsForApps:(NSArray *)apps {
    BOOL later = [self.collectionId isEqualToString:CollectionLaterId];
    NSInteger started = 0;
    for (NSDictionary *app in apps) {
        NSString *url = app[@"url"];
        if ([url isKindOfClass:[NSString class]] && url.length
            && ![[InstallManager shared] hasActiveJobForURL:url]) {
            [[InstallManager shared] startInstallWithURL:url completion:^(NSString *jid, NSError *e) {}];
            started++;
        }
        if (later) [[CollectionStore shared] removeAppKey:[CollectionStore keyForApp:app] fromCollection:CollectionLaterId];
    }
    return started;
}

- (void)showDownloadStartedAlert:(NSInteger)started {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"collections.dl_started_title")
        message:[NSString stringWithFormat:T(@"collections.dl_started_msg"), (long)started]
        delegate:nil cancelButtonTitle:T(@"common.ok") otherButtonTitles:nil];
    [a show];
}

- (void)downloadSelected {
    NSMutableArray *sel = [NSMutableArray array];
    for (NSDictionary *app in self.apps)
        if ([self.selectedKeys containsObject:[CollectionStore keyForApp:app]]) [sel addObject:app];
    NSInteger started = [self startDownloadsForApps:sel];
    [self exitSelection];
    [self showDownloadStartedAlert:started];
}

// "Télécharger plus tard" → start everything in the queue + clear it.
- (void)downloadAllTapped {
    NSInteger started = [self startDownloadsForApps:[self.apps copy]];
    [self showDownloadStartedAlert:started];   // -reload fires via CollectionStoreDidChangeNotification
}

- (void)removeSelected {
    CollectionStore *s = [CollectionStore shared];
    for (NSString *key in [self.selectedKeys copy]) [s removeAppKey:key fromCollection:self.collectionId];
    // -reload fires from CollectionStoreDidChangeNotification; leave selection mode cleanly.
    [self exitSelection];
}

#pragma mark - Pinned preview image

- (BOOL)isFolderCollection {
    NSDictionary *c = [[CollectionStore shared] collectionForId:self.collectionId];
    return c && ![c[@"builtin"] boolValue];
}

// Folder "Modifier" menu — Renommer / Supprimer (the preview-image pinning feature was removed).
- (void)editMenu {
    if (![self isFolderCollection]) return;   // only user folders have a Modifier menu
    UIActionSheet *sheet = [[UIActionSheet alloc]
        initWithTitle:[[CollectionStore shared] nameForCollection:self.collectionId]
        delegate:self cancelButtonTitle:T(@"common.cancel") destructiveButtonTitle:nil otherButtonTitles:nil];
    [sheet addButtonWithTitle:T(@"folder.rename")];
    sheet.destructiveButtonIndex = [sheet addButtonWithTitle:T(@"folder.delete")];
    // On iPad an action sheet is a popover: anchor it to its bar button so it points at the right place.
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad && self.editBarButton) {
        [sheet showFromBarButtonItem:self.editBarButton animated:YES];
    } else {
        [sheet showInView:self.view];
    }
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    NSString *title = [sheet buttonTitleAtIndex:index];
    if ([title isEqualToString:T(@"folder.rename")]) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"folder.rename") message:nil
            delegate:self cancelButtonTitle:T(@"common.cancel") otherButtonTitles:T(@"folder.create"), nil];
        if ([a respondsToSelector:@selector(setAlertViewStyle:)]) a.alertViewStyle = UIAlertViewStylePlainTextInput;
        [[a textFieldAtIndex:0] setText:[[CollectionStore shared] nameForCollection:self.collectionId]];
        a.tag = 8801;
        [a show];
    } else if ([title isEqualToString:T(@"folder.delete")]) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"folder.delete_title")
            message:T(@"folder.delete_msg") delegate:self
            cancelButtonTitle:T(@"common.cancel") otherButtonTitles:T(@"folder.delete"), nil];
        a.tag = 8802;
        [a show];
    }
}

- (void)alertView:(UIAlertView *)av clickedButtonAtIndex:(NSInteger)index {
    if (index == av.cancelButtonIndex) return;
    if (av.tag == 8801) {   // rename
        NSString *name = [[[av textFieldAtIndex:0] text]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length) { [[CollectionStore shared] renameCollection:self.collectionId to:name]; self.title = name; }
    } else if (av.tag == 8802) {   // delete folder
        [[CollectionStore shared] deleteCollection:self.collectionId];
        [self.navigationController popViewControllerAnimated:YES];
    }
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)self.apps.count; }

- (NSString *)humanSize:(long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld %@", bytes, T(@"unit.b")];
    if (bytes < 1024*1024) return [NSString stringWithFormat:@"%.0f %@", bytes/1024.0, T(@"unit.kb")];
    if (bytes < 1024LL*1024*1024) return [NSString stringWithFormat:@"%.1f %@", bytes/(1024.0*1024), T(@"unit.mb")];
    return [NSString stringWithFormat:@"%.2f %@", bytes/(1024.0*1024*1024), T(@"unit.gb")];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"collCell";
    CatalogAppCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[CatalogAppCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    if (ip.row >= (NSInteger)self.apps.count) return cell;
    NSDictionary *app = self.apps[ip.row];

    cell.appTitleLabel.text = app[@"title"] ?: @"?";
    long long size = [app[@"size"] longLongValue];
    NSString *sizeStr = size > 0 ? [self humanSize:size] : @"?";
    cell.appSubtitleLabel.text = [NSString stringWithFormat:@"v%@ — min iOS %@ — %@",
                                   app[@"version"] ?: @"?", ADDisplayIOS(app[@"minOS"]), sizeStr];

    NSString *key = [CollectionStore keyForApp:app];
    if (self.selecting) {
        cell.accessoryType = [self.selectedKeys containsObject:key]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;

    NSString *iconUrl = app[@"icon"];
    CGSize sz = CGSizeMake(kCollIcon, kCollIcon);
    UIImage *cached = [[IconLoader shared] cachedImageForURL:iconUrl targetSize:sz];
    if (cached) {
        cell.appIconView.image = cached;
    } else {
        cell.appIconView.image = nil;
        NSString *expected = key;
        [[IconLoader shared] loadImageForURL:iconUrl targetSize:sz via:nil completion:^(UIImage *img) {
            if (!img) return;
            CatalogAppCell *vis = (CatalogAppCell *)[self.tableView cellForRowAtIndexPath:ip];
            if (![vis isKindOfClass:[CatalogAppCell class]]) return;
            if (ip.row >= (NSInteger)self.apps.count) return;
            if (![[CollectionStore keyForApp:self.apps[ip.row]] isEqual:expected]) return;
            vis.appIconView.image = img;
        }];
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)self.apps.count) return;
    NSDictionary *app = self.apps[ip.row];
    NSString *key = [CollectionStore keyForApp:app];

    if (self.selecting) {
        if ([self.selectedKeys containsObject:key]) [self.selectedKeys removeObject:key];
        else if (key)                               [self.selectedKeys addObject:key];
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        [self rebuildToolbar];
        return;
    }
    AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:app];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Theme

- (void)themeToolbar {
    BOOL canBg = [self.toolbar respondsToSelector:@selector(setBackgroundImage:forToolbarPosition:barMetrics:)];
    if ([IOS6Theme isDefaultTheme]) {
        self.toolbar.barStyle = UIBarStyleDefault;
        self.toolbar.tintColor = nil;
        if (canBg) [self.toolbar setBackgroundImage:nil forToolbarPosition:UIToolbarPositionAny barMetrics:UIBarMetricsDefault];
    } else {
        // Match the themed nav bar: vivid accent bar on light-colour themes, dark gradient on dark.
        self.toolbar.barStyle = UIBarStyleBlack;
        self.toolbar.tintColor = [IOS6Theme navBarButtonTint];
        UIImage *bg = [IOS6Theme navBarBackground];
        if (bg && canBg) [self.toolbar setBackgroundImage:bg forToolbarPosition:UIToolbarPositionAny barMetrics:UIBarMetricsDefault];
    }
}

- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.tableView.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.tableView.separatorColor = [IOS6Theme separatorColor];
    self.emptyLabel.textColor = [IOS6Theme labelGray];
    [self themeToolbar];
    [self.tableView reloadData];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

@end
