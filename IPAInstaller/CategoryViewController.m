#import "CategoryViewController.h"
#import "CategoryTileView.h"
#import "Localization.h"
#import "LocalCatalog.h"
#import "IOS6Theme.h"
#import "SearchViewController.h"
#import "RevivalListViewController.h"
#import "CatalogViewController.h"
#import "AppRowCell.h"
#import "FeedbackViewController.h"

// Localized category/subgenre name. Keys are "cat.<English>" / "sub.<English>".
// Falls back to the English value itself if the key isn't translated.
static NSString *locName(NSString *prefix, NSString *value) {
    if (!value.length) return @"";
    NSString *k = [prefix stringByAppendingString:value];
    NSString *v = T(k);
    return [v isEqualToString:k] ? value : v;
}
static NSString *locCat(NSString *c) { return locName(@"cat.", c); }
static NSString *locSub(NSString *s) { return locName(@"sub.", s); }

// Grouped, locale-aware integer ("23 769" / "23,769").
static NSString *fmtCount(NSInteger n) {
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    return [f stringFromNumber:@(n)];
}

// A random icon URL from a pool — gives the category cards variety on each visit.
static NSString *randomIcon(NSArray *pool) {
    if (!pool.count) return nil;
    return pool[arc4random_uniform((uint32_t)pool.count)];
}

@interface CategoryViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *header;          // welcome banner (top level only)
@property (nonatomic, strong) UILabel *statusLabel;    // shown while loading
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) CategoryTileView *allBanner;
@property (nonatomic, strong) CategoryTileView *revivalBanner;   // "✅ Works today" (top level)
@property (nonatomic, strong) NSArray *tiles;          // CategoryTileView*, the grid cards
@property (nonatomic, strong) NSArray *cards;          // model: NSDictionary per tile
@property (nonatomic, assign) BOOL didFirstAppear;     // skip reshuffle on the first show
@property (nonatomic, assign) BOOL catalogLoading;     // a catalogue load is in flight
@property (nonatomic, assign) BOOL builtContent;       // grid built at least once
@property (nonatomic, strong) UITapGestureRecognizer *retryTap;  // tap the error label to retry
@end

@implementation CategoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
    BOOL sub = self.parentCategory.length > 0;
    self.title = sub ? locCat(self.parentCategory) : T(@"tab.home");
    if (!sub) [self installFeedbackBarButton];   // home root: persistent Feedback button (left)
    if (!sub) {
        // home root: localized "Support AppDrop" text button, top-right → tap copies the PayPal link.
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:T(@"support.action") style:UIBarButtonItemStyleBordered
                   target:self action:@selector(donateTapped)];
    }

    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scroll.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [UIColor grayColor];
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    self.spinner = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    // Re-lay-out the category grid when the Settings "apps per row" density changes.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(gridDensityDidChange)
            name:@"AppDropGridDensityChanged" object:nil];

    // The category grid needs the catalogue loaded. As the Catalogue tab's root we may be
    // the very first screen shown — and if that first launch is OFFLINE, the app must
    // self-heal the moment the network returns. So the load is funnelled through
    // -attemptCatalogLoad, which we also re-fire on every return to this tab
    // (viewWillAppear) and whenever the app comes back to the foreground.
    if (!sub) {
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(appDidBecomeActive)
                name:UIApplicationDidBecomeActiveNotification object:nil];
        // Rebuild the home grid when a background freshness check swaps in a newer catalogue.
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(catalogDidUpdate)
                name:LocalCatalogDidUpdateNotification object:nil];
    }
    [self attemptCatalogLoad];
}

- (void)layoutStatus {
    CGRect b = self.view.bounds;
    self.statusLabel.frame = CGRectMake(20, b.size.height/2 - 30, b.size.width - 40, 44);
    self.spinner.center = CGPointMake(b.size.width/2, b.size.height/2 - 44);
}

// Single funnel for loading the catalogue — safe to call repeatedly. Already loaded → build
// the grid once. A load already in flight → no-op. Otherwise (download +) load it, showing
// progress; on failure leave a TAPPABLE "retry" message so a first OFFLINE launch self-heals
// as soon as the network is back (also auto-retried from viewWillAppear / didBecomeActive).
- (void)attemptCatalogLoad {
    if ([[LocalCatalog shared] isReady]) {
        if (!self.builtContent) { self.statusLabel.hidden = YES; [self buildContent]; self.builtContent = YES; }
        [[LocalCatalog shared] checkForCatalogUpdate];   // already loaded → check for a newer catalogue
        return;
    }
    if (self.catalogLoading) return;
    self.catalogLoading = YES;

    self.statusLabel.userInteractionEnabled = NO;
    self.statusLabel.hidden = NO;
    self.statusLabel.text = T(@"catalog.loading");
    [self.spinner startAnimating];
    [self layoutStatus];

    [[LocalCatalog shared] loadWithProgress:^(NSString *status) {
        self.statusLabel.text = status;
        [self layoutStatus];
    } completion:^(BOOL ok, NSError *err) {
        self.catalogLoading = NO;
        [self.spinner stopAnimating];
        if (ok) {
            self.statusLabel.hidden = YES;
            if (!self.builtContent) { [self buildContent]; self.builtContent = YES; }
            [[LocalCatalog shared] checkForCatalogUpdate];   // catalogue is up → see if a newer one is published
        } else {
            self.statusLabel.text = [NSString stringWithFormat:@"%@\n%@\n%@",
                                      T(@"catalog.network_error"), err.localizedDescription ?: @"",
                                      T(@"catalog.tap_retry")];
            self.statusLabel.userInteractionEnabled = YES;
            [self ensureRetryGesture];
            [self layoutStatus];
        }
    }];
}

// Attach (once) a tap recognizer to the status label so the error state is tappable to retry.
- (void)ensureRetryGesture {
    if (self.retryTap) return;
    self.retryTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                            action:@selector(attemptCatalogLoad)];
    [self.statusLabel addGestureRecognizer:self.retryTap];
}

// App returned to the foreground (e.g. the user just connected to Wi-Fi) — retry if the
// catalogue never managed to load.
- (void)appDidBecomeActive {
    if (![[LocalCatalog shared] isReady]) [self attemptCatalogLoad];
    else [[LocalCatalog shared] checkForCatalogUpdate];   // already loaded → just look for a newer catalogue
}

// A newer catalogue was hot-swapped in by the background freshness check → rebuild the
// category cards/counts from the fresh DB (clear the old grid subviews first to avoid dupes).
- (void)catalogDidUpdate {
    if (![[LocalCatalog shared] isReady]) return;
    for (UIView *v in [self.scroll.subviews copy]) [v removeFromSuperview];
    self.header = nil; self.allBanner = nil; self.revivalBanner = nil;
    self.tiles = nil;  self.cards = nil;
    [self buildContent];          // rebuilds cards/header/banners/tiles + calls layoutContent
    self.builtContent = YES;
}

// Home-screen support button → copy the PayPal link + show it. Old-iOS Safari can't open
// paypal.me (TLS), so we copy it (same proven behaviour as Settings → Support) and the user
// pastes it on any newer device/computer to donate.
- (void)donateTapped {
    NSString *url = @"https://paypal.me/adrienrl1";
    [[UIPasteboard generalPasteboard] setString:url];
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"settings.support_row")
        message:[NSString stringWithFormat:@"%@\n\n%@", url, T(@"settings.support_copied")]
        delegate:nil cancelButtonTitle:T(@"common.ok") otherButtonTitles:nil];
    [a show];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // If a previous (offline) launch failed to load the catalogue, retry now that the user
    // is back on this tab. Otherwise just vary the card icons for a sense of freshness.
    if (![[LocalCatalog shared] isReady]) {
        [self attemptCatalogLoad];
    } else if (self.didFirstAppear) {
        [self reshuffleIcons];
    }
    self.didFirstAppear = YES;
}

- (void)reshuffleIcons {
    if (!self.tiles.count || self.cards.count != self.tiles.count) return;
    for (NSUInteger i = 0; i < self.tiles.count; i++) {
        NSArray *pool = self.cards[i][@"iconPool"];
        if (pool.count < 2) continue;   // 0 or 1 candidate -> nothing to vary
        [(CategoryTileView *)self.tiles[i] reshuffleIconURL:randomIcon(pool)];
    }
}

#pragma mark - Build

// Drawn glyph for the "Works today" banner — a green rounded badge with a white check
// (replaces the ✅ emoji, matches the app's other drawn glyphs).
static UIImage *AppDropRevivalGlyph(void) {
    CGSize s = CGSizeMake(46, 46);
    UIGraphicsBeginImageContextWithOptions(s, NO, [UIScreen mainScreen].scale);
    UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 44, 44) cornerRadius:10];
    [[UIColor colorWithRed:0.18 green:0.62 blue:0.30 alpha:1.0] setFill];
    [bg fill];
    UIBezierPath *ck = [UIBezierPath bezierPath];
    ck.lineWidth = 4.5;
    ck.lineCapStyle = kCGLineCapRound;
    ck.lineJoinStyle = kCGLineJoinRound;
    [ck moveToPoint:CGPointMake(13, 24)];
    [ck addLineToPoint:CGPointMake(20, 31)];
    [ck addLineToPoint:CGPointMake(34, 15)];
    [[UIColor whiteColor] setStroke];
    [ck stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)buildContent {
    BOOL sub = self.parentCategory.length > 0;
    LocalCatalog *cat = [LocalCatalog shared];

    // --- model ---
    NSMutableArray *cards = [NSMutableArray array];
    if (sub) {
        for (NSDictionary *d in [cat subgenreCountsForCategory:self.parentCategory]) {
            NSString *sg = d[@"subgenre"] ?: @"";
            [cards addObject:@{@"label": locSub(sg),
                               @"seed": sg,
                               @"count": d[@"count"] ?: @0,
                               @"iconPool": [cat iconPoolForCategory:self.parentCategory subgenre:sg] ?: @[],
                               @"sub": sg}];
        }
    } else {
        for (NSDictionary *d in [cat categoryCounts]) {
            NSString *cn = d[@"category"] ?: @"";
            [cards addObject:@{@"label": locCat(cn),
                               @"seed": cn,
                               @"count": d[@"count"] ?: @0,
                               @"iconPool": [cat iconPoolForCategory:cn] ?: @[],
                               @"cat": cn}];
        }
    }
    self.cards = cards;

    // --- welcome header (top level only) ---
    if (!sub) {
        self.header = [[UIView alloc] initWithFrame:CGRectZero];
        UILabel *hi = [[UILabel alloc] initWithFrame:CGRectZero];
        hi.tag = 101;
        hi.font = [UIFont boldSystemFontOfSize:21];
        hi.textColor = [UIColor colorWithRed:0.13 green:0.18 blue:0.32 alpha:1.0];
        hi.backgroundColor = [UIColor clearColor];
        hi.text = T(@"categories.welcome");
        [self.header addSubview:hi];
        UILabel *subL = [[UILabel alloc] initWithFrame:CGRectZero];
        subL.tag = 102;
        subL.font = [UIFont systemFontOfSize:13];
        subL.textColor = [UIColor grayColor];
        subL.numberOfLines = 2;
        subL.backgroundColor = [UIColor clearColor];
        subL.text = [NSString stringWithFormat:T(@"categories.welcome_sub"),
                       fmtCount([cat uniqueAppCount])];
        [self.header addSubview:subL];
        [self.scroll addSubview:self.header];
    }

    // --- "All apps" / "Show all" wide banner ---
    self.allBanner = [[CategoryTileView alloc] initWithFrame:CGRectZero];
    self.allBanner.wide = YES;
    NSString *bannerSub = sub ? @"" : [NSString stringWithFormat:T(@"categories.napps"),
                                       fmtCount([cat uniqueAppCount])];
    [self.allBanner configureWithLabel:T(@"categories.all") subtitle:bannerSub
                               iconURL:nil colorSeed:nil];
    __weak typeof(self) wself = self;
    if (sub) {
        NSString *parent = self.parentCategory;
        self.allBanner.onTap = ^{ [wself pushResultsForCategory:parent subgenre:nil
                                                          title:locCat(parent)]; };
    } else {
        self.allBanner.onTap = ^{
            CatalogViewController *vc = [[CatalogViewController alloc] init];
            vc.title = T(@"categories.all");   // "All apps" (else CatalogVC defaults to "Catalogue")
            [wself.navigationController pushViewController:vc animated:YES];
        };
    }
    [self.scroll addSubview:self.allBanner];

    // --- "✅ Works today / Revival" wide banner (top level only) — issue #4 ---
    if (!sub) {
        self.revivalBanner = [[CategoryTileView alloc] initWithFrame:CGRectZero];
        self.revivalBanner.wide = YES;
        [self.revivalBanner configureWithLabel:T(@"categories.revival")
                                      subtitle:T(@"categories.revival_sub")
                                       iconURL:nil colorSeed:@"revival"];
        [self.revivalBanner setGlyphImage:AppDropRevivalGlyph()];
        self.revivalBanner.onTap = ^{
            RevivalListViewController *vc = [[RevivalListViewController alloc] init];
            [wself.navigationController pushViewController:vc animated:YES];
        };
        [self.scroll addSubview:self.revivalBanner];
    }

    // --- category/subgenre grid tiles ---
    NSMutableArray *tiles = [NSMutableArray array];
    for (NSDictionary *card in cards) {
        CategoryTileView *t = [[CategoryTileView alloc] initWithFrame:CGRectZero];
        NSString *subtitle = [NSString stringWithFormat:T(@"categories.napps"),
                              fmtCount([card[@"count"] integerValue])];
        [t configureWithLabel:card[@"label"] subtitle:subtitle
                      iconURL:randomIcon(card[@"iconPool"])
                    colorSeed:card[@"seed"]];
        NSDictionary *c = card;
        t.onTap = ^{ [wself handleTapForCard:c]; };
        [tiles addObject:t];
        [self.scroll addSubview:t];
    }
    self.tiles = tiles;

    [self layoutContent];
}

- (void)handleTapForCard:(NSDictionary *)card {
    if (self.parentCategory.length) {
        NSString *subv = card[@"sub"];
        NSString *title = [NSString stringWithFormat:@"%@ › %@",
                           locCat(self.parentCategory), locSub(subv)];
        [self pushResultsForCategory:self.parentCategory subgenre:subv title:title];
        return;
    }
    NSString *cat = card[@"cat"];
    // A category with subgenres (Games) -> drill in; else straight to the list.
    if ([[LocalCatalog shared] subgenreCountsForCategory:cat].count > 0) {
        CategoryViewController *vc = [[CategoryViewController alloc] init];
        vc.parentCategory = cat;
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        [self pushResultsForCategory:cat subgenre:nil title:locCat(cat)];
    }
}

- (void)pushResultsForCategory:(NSString *)cat subgenre:(NSString *)sub title:(NSString *)title {
    SearchViewController *vc = [[SearchViewController alloc] init];
    vc.categoryFilter = cat;
    vc.subgenreFilter = sub;
    vc.categoryTitle = title;
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Layout

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (self.cards) [self layoutContent];
    else [self layoutStatus];
}

- (void)layoutContent {
    CGFloat W = self.view.bounds.size.width;
    CGFloat margin = 12, gap = 10;
    CGFloat y = 12;

    if (self.header) {
        CGFloat hH = 66;
        self.header.frame = CGRectMake(margin, y, W - 2*margin, hH);
        UILabel *hi = (UILabel *)[self.header viewWithTag:101];
        UILabel *subL = (UILabel *)[self.header viewWithTag:102];
        hi.frame = CGRectMake(4, 4, W - 2*margin - 8, 28);
        subL.frame = CGRectMake(4, 34, W - 2*margin - 8, 30);
        y += hH + 4;
    }

    // wide banner
    CGFloat bannerH = 58;
    self.allBanner.frame = CGRectMake(margin, y, W - 2*margin, bannerH);
    y += bannerH + (self.revivalBanner ? 10 : 16);
    if (self.revivalBanner) {
        self.revivalBanner.frame = CGRectMake(margin, y, W - 2*margin, bannerH);
        y += bannerH + 16;
    }

    // grid — column count follows the Settings "apps per row" density (gentle range
    // so the category cards stay readable): dense → more/smaller, sparse → fewer/larger.
    CGFloat minTile = 200.0 - [AppRowCell gridDensity] * 96.0;   // dense≈104 … sparse=200
    CGFloat tileH = 150;
    NSInteger cols = (NSInteger)floorf((W - 2*margin + gap) / (minTile + gap));
    if (cols < 2) cols = 2;
    if (cols > 8) cols = 8;
    CGFloat tileW = floorf((W - 2*margin - (cols - 1)*gap) / cols);

    for (NSUInteger i = 0; i < self.tiles.count; i++) {
        NSInteger col = i % cols, rowi = i / cols;
        CGFloat x = margin + col*(tileW + gap);
        CGFloat ty = y + rowi*(tileH + gap);
        ((UIView *)self.tiles[i]).frame = CGRectMake(x, ty, tileW, tileH);
    }
    NSInteger nrows = (self.tiles.count + cols - 1) / cols;
    CGFloat contentH = y + nrows*tileH + (nrows > 0 ? (nrows - 1)*gap : 0) + 16;
    self.scroll.contentSize = CGSizeMake(W, contentH);
}

- (void)gridDensityDidChange {
    if (self.cards) [self layoutContent];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
