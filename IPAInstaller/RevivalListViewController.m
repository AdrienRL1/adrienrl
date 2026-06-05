#import "RevivalListViewController.h"
#import "RevivalCatalog.h"
#import "ModdedCatalog.h"
#import "Localization.h"
#import "IOS6Theme.h"
#import "AppRowCell.h"
#import "AppDetailViewController.h"
#import "CatalogFilter.h"
#import "FilterViewController.h"
#import "CatalogAppCell.h"
#import "IconLoader.h"
#import "UploadViewController.h"

// numeric version compare: -1 (a<b), 0 (a==b), 1 (a>b)
static int RevVerCmp(NSString *a, NSString *b) {
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

static const CGFloat kRevIconSize = 44;   // iPhone row icon (matches the catalogue)

static NSString *RevHumanSize(long long bytes) {
    if (bytes <= 0) return @"?";
    double b = (double)bytes;
    if (b >= 1024.0*1024.0) return [NSString stringWithFormat:@"%.1f MB", b/(1024.0*1024.0)];
    if (b >= 1024.0)        return [NSString stringWithFormat:@"%.0f KB", b/1024.0];
    return [NSString stringWithFormat:@"%lld B", bytes];
}

// Same UI as the catalogue: a grid of AppRowCell tiles + the same Filters screen. Tapping a
// tile opens AppDetailViewController (allowVersionSwitch:NO) → direct in-app install of the .ipa.
@interface RevivalListViewController () <FilterViewControllerDelegate>
@property (nonatomic, strong) NSArray *allApps;   // all mapped dicts (unfiltered)
@property (nonatomic, strong) NSArray *apps;       // after filter + sort
@property (nonatomic, assign) NSInteger tpr;
@end

@implementation RevivalListViewController

- (instancetype)init { return [super initWithStyle:UITableViewStylePlain]; }

- (CGFloat)gridWidth {
    CGFloat w = self.view.bounds.size.width;
    return w > 0 ? w : [UIScreen mainScreen].bounds.size.width;
}

// Live theme re-apply (AppDelegate calls this on a theme switch — no restart).
- (void)applyTheme {
    UIColor *bg = [IOS6Theme contentBackgroundColor] ?: [UIColor whiteColor];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
    [self.tableView reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.customTitle ?: T(@"revival.title");
    UIColor *bg = [IOS6Theme contentBackgroundColor] ?: [UIColor whiteColor];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    // Same "Filtres" button as the catalogue.
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:T(@"catalog.filters") style:UIBarButtonItemStyleBordered
               target:self action:@selector(filtersTapped)];
    self.allApps = self.customAppDicts ?: [[RevivalCatalog shared] appDicts];
    self.apps = [self applyFilter:[CatalogFilter load_] to:self.allApps];
    self.tpr = MAX(1, [AppRowCell tilesPerRowForWidth:[self gridWidth]]);
    self.tableView.rowHeight = [AppRowCell gridRowHeight];
    [self installHeader];
    // #142: refresh in-session when the hosted Works-Today / Modded list updates.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(revivalListDidChange) name:RevivalCatalogDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(revivalListDidChange) name:ModdedCatalogDidChangeNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// #142: the hosted Works-Today / Modded list was refreshed mid-session → reload our data + view.
- (void)revivalListDidChange {
    self.allApps = [self.uploadTarget isEqualToString:@"mods"]
        ? [[ModdedCatalog shared] appDicts]
        : (self.customAppDicts ?: [[RevivalCatalog shared] appDicts]);
    self.apps = [self applyFilter:[CatalogFilter load_] to:self.allApps];
    [self.tableView reloadData];
}

- (NSArray *)applyFilter:(CatalogFilter *)f to:(NSArray *)apps {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *a in apps) {
        NSString *m = a[@"minOS"] ?: @"";
        if (f.minIOS.length && m.length && RevVerCmp(m, f.minIOS) < 0) continue;
        if (f.maxIOS.length && m.length && RevVerCmp(m, f.maxIOS) > 0) continue;
        NSInteger plat = [a[@"platform"] integerValue];
        if ([f.deviceClass isEqualToString:@"iphone"] && !(plat & 2)) continue;
        if ([f.deviceClass isEqualToString:@"ipad"]   && !(plat & 4)) continue;
        [out addObject:a];
    }
    NSString *s = f.sort ?: @"name";
    BOOL desc = f.sortDescending;
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        NSComparisonResult r;
        if ([s isEqualToString:@"minos"])
            r = (NSComparisonResult)RevVerCmp(x[@"minOS"], y[@"minOS"]);
        else
            r = [(x[@"title"] ?: @"") caseInsensitiveCompare:(y[@"title"] ?: @"")];
        return desc ? (NSComparisonResult)(-r) : r;
    }];
    return out;
}

#pragma mark - Filters (same screen as the catalogue)

- (void)filtersTapped {
    FilterViewController *fvc = [[FilterViewController alloc] init];
    fvc.filter = [CatalogFilter load_];
    fvc.delegate = self;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fvc];
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)filterViewController:(FilterViewController *)vc didSaveFilter:(CatalogFilter *)filter {
    [self dismissViewControllerAnimated:YES completion:nil];
    self.apps = [self applyFilter:filter to:self.allApps];
    [self.tableView reloadData];
}
- (void)filterViewControllerDidCancel:(FilterViewController *)vc {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Layout

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    NSInteger t = MAX(1, [AppRowCell tilesPerRowForWidth:[self gridWidth]]);
    if (t != self.tpr) {
        self.tpr = t;
        self.tableView.rowHeight = [AppRowCell gridRowHeight];
        [self.tableView reloadData];
    }
}

- (void)installHeader {
    CGFloat W = [self gridWidth];
    NSString *t = self.customIntro ?: T(@"revival.intro");
    if (self.allApps.count == 0) t = [t stringByAppendingFormat:@"\n\n%@", T(@"revival.empty")];
    UIFont *f = [UIFont systemFontOfSize:13];
    CGSize sz;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    sz = [t sizeWithFont:f constrainedToSize:CGSizeMake(W - 24, 99999)
           lineBreakMode:NSLineBreakByWordWrapping];
#pragma clang diagnostic pop
    UILabel *intro = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, W - 24, ceilf(sz.height))];
    intro.numberOfLines = 0;
    intro.font = f;
    intro.textColor = [IOS6Theme labelGray];
    intro.backgroundColor = [UIColor clearColor];
    intro.text = t;
    CGFloat hdrH = ceilf(sz.height) + 20;
    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, hdrH)];
    [hdr addSubview:intro];

    // Glossy iOS-6 accent button to share an app the user has the right to share (→ upload screen).
    if (self.uploadTarget.length) {
        CGFloat by = hdrH, bh = 40;
        UIButton *share = [UIButton buttonWithType:UIButtonTypeCustom];
        share.frame = CGRectMake(12, by, W - 24, bh);
        share.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [share setTitle:T(@"upload.share_button") forState:UIControlStateNormal];
        share.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [IOS6Theme styleButton:share];
        [share addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];
        [hdr addSubview:share];
        hdr.frame = CGRectMake(0, 0, W, by + bh + 12);
    }
    self.tableView.tableHeaderView = hdr;
}

- (void)shareTapped {
    UploadViewController *vc = [[UploadViewController alloc] initWithTarget:self.uploadTarget];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad) return self.apps.count;  // iPhone: one row per app
    if (self.tpr < 1) self.tpr = 1;
    return (self.apps.count + self.tpr - 1) / self.tpr;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // ===== iPhone: single-app list row. AppRowCell is an iPad-grid component and renders
    // wrong stretched full-width on a phone (icon centered over the text — feedback #12/#35);
    // mirror the catalogue's iPhone row (CatalogAppCell) instead. =====
    if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad) {
        static NSString *cellId = @"revCell";
        CatalogAppCell *cell = [tv dequeueReusableCellWithIdentifier:cellId];
        if (!cell) cell = [[CatalogAppCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                reuseIdentifier:cellId];
        NSDictionary *app = (ip.row < (NSInteger)self.apps.count) ? self.apps[ip.row] : nil;
        cell.appTitleLabel.text = app[@"title"] ?: @"?";
        long long size = [app[@"size"] longLongValue];
        cell.appSubtitleLabel.text = [NSString stringWithFormat:@"v%@ — min iOS %@ — %@",
                                        app[@"version"] ?: @"?", app[@"minOS"] ?: @"?", RevHumanSize(size)];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        NSString *iconUrl = app[@"icon"];
        CGSize sz = CGSizeMake(kRevIconSize, kRevIconSize);
        UIImage *cached = [[IconLoader shared] cachedImageForURL:iconUrl targetSize:sz];
        if (cached) {
            cell.appIconView.image = cached;
        } else {
            cell.appIconView.image = nil;
            NSString *expected = app[@"title"];
            [[IconLoader shared] loadImageForURL:iconUrl targetSize:sz via:nil completion:^(UIImage *img) {
                if (!img) return;
                CatalogAppCell *vis = (CatalogAppCell *)[self.tableView cellForRowAtIndexPath:ip];
                if (![vis isKindOfClass:[CatalogAppCell class]]) return;
                if (ip.row >= (NSInteger)self.apps.count) return;
                if (![self.apps[ip.row][@"title"] isEqual:expected]) return;
                vis.appIconView.image = img;
            }];
        }
        return cell;
    }

    // ===== iPad: multi-tile grid row =====
    static NSString *rid = @"revrow";
    AppRowCell *c = [tv dequeueReusableCellWithIdentifier:rid];
    if (!c) c = [[AppRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    c.tilesPerRow = self.tpr;
    __weak typeof(self) ws = self;
    c.onTileTap = ^(NSDictionary *app) {
        if (!app) return;
        AppDetailViewController *d = [[AppDetailViewController alloc] initWithApp:app allowVersionSwitch:NO];
        [ws.navigationController pushViewController:d animated:YES];
    };
    NSInteger start = ip.row * self.tpr;
    NSMutableArray *slice = [NSMutableArray array];
    for (NSInteger i = start; i < start + self.tpr && i < (NSInteger)self.apps.count; i++)
        [slice addObject:self.apps[i]];
    [c setApps:slice];
    return c;
}

// iPhone taps go through the table row (iPad taps are handled by the tile's onTileTap).
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) return;
    if (ip.row >= (NSInteger)self.apps.count) return;
    NSDictionary *app = self.apps[ip.row];
    AppDetailViewController *d = [[AppDetailViewController alloc] initWithApp:app allowVersionSwitch:NO];
    [self.navigationController pushViewController:d animated:YES];
}

@end
