#import "RevivalListViewController.h"
#import "RevivalCatalog.h"
#import "Localization.h"
#import "IOS6Theme.h"
#import "AppRowCell.h"
#import "AppDetailViewController.h"
#import "CatalogFilter.h"
#import "FilterViewController.h"

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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"revival.title");
    UIColor *bg = [IOS6Theme contentBackgroundColor] ?: [UIColor whiteColor];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    // Same "Filtres" button as the catalogue.
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:T(@"catalog.filters") style:UIBarButtonItemStyleBordered
               target:self action:@selector(filtersTapped)];
    self.allApps = [[RevivalCatalog shared] appDicts];
    self.apps = [self applyFilter:[CatalogFilter load_] to:self.allApps];
    self.tpr = MAX(1, [AppRowCell tilesPerRowForWidth:[self gridWidth]]);
    self.tableView.rowHeight = [AppRowCell gridRowHeight];
    [self installHeader];
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
    NSString *t = T(@"revival.intro");
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
    intro.textColor = [UIColor grayColor];
    intro.backgroundColor = [UIColor clearColor];
    intro.text = t;
    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, ceilf(sz.height) + 20)];
    [hdr addSubview:intro];
    self.tableView.tableHeaderView = hdr;
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (self.tpr < 1) self.tpr = 1;
    return (self.apps.count + self.tpr - 1) / self.tpr;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
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

@end
