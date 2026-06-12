#import "CategoryViewController.h"
#import <QuartzCore/QuartzCore.h>
#import "CategoryTileView.h"
#import "Localization.h"
#import "LocalCatalog.h"
#import "StatsClient.h"
#import "IOS6Theme.h"
#import "SearchViewController.h"
#import "RevivalListViewController.h"
#import "RevivalCatalog.h"
#import "ModdedCatalog.h"
#import "CatalogViewController.h"
#import "AppRowCell.h"
#import "FeedbackViewController.h"
#import "CollectionStore.h"
#import "CollectionViewController.h"
#import "HomeLayoutStore.h"

// Retrait des catégories « Fonctionne aujourd'hui » (Revival) et « Apps modifiées » (Modded), et
// par voie de conséquence de la fonction « Partager une app » (l'upload n'est joignable QUE depuis
// ces deux listes). Mis à NO à la demande de l'utilisateur (apps tierces / éviter tout problème de
// redistribution). Le code reste en place, juste éteint — remettre à YES pour les réafficher.
// Voir aussi kEnableAppUpload dans RevivalListViewController.m.
static const BOOL kEnableWorksTodayModded = NO;

// Localized category/subgenre name. Keys are "cat.<English>" / "sub.<English>".
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

// v3.2 — utilisateurs actifs + nombres de téléchargements : tout passe par StatsClient (Worker
// Cloudflare, HORS du serveur de l'utilisateur). L'identifiant anonyme + l'URL y sont centralisés.

@interface CategoryViewController () <UIGestureRecognizerDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *header;          // welcome banner (top level only)
@property (nonatomic, strong) UILabel *statusLabel;    // shown while loading
@property (nonatomic, copy)   NSString *welcomeSubBase; // v3.2 : sous-titre de base, sans le « X en ligne »
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray *items;          // model: one dict per tile (pinned first, then the rest)
@property (nonatomic, strong) NSArray *tiles;          // CategoryTileView*, parallel to items
@property (nonatomic, assign)   CategoryTileView *topDLTile;  // v3.2 : tuile « Plus téléchargées » (icônes = top 4)
@property (nonatomic, assign) NSInteger pinnedCount;   // first N items are in the pinned (top) zone
@property (nonatomic, strong) UIView *zoneDivider;     // thin rule between pinned + unpinned zones
@property (nonatomic, strong) UIButton *addFolderButton;   // small distinct "+ Nouveau dossier", always at top
// --- 5b: long-press → jiggle → drag-reorder edit mode ---
@property (nonatomic, assign) BOOL homeEditing;
@property (nonatomic, strong) UILongPressGestureRecognizer *longPress;
@property (nonatomic, strong) CategoryTileView *draggingTile;
@property (nonatomic, assign) NSInteger dragIndex;       // index of the dragged tile in self.items
@property (nonatomic, assign) CGPoint dragOffset;        // finger offset inside the picked-up tile
@property (nonatomic, assign) CGRect dragSlotFrame;      // computed landing frame of the dragged tile
@property (nonatomic, assign) CGFloat pinnedZoneBottom;  // y just below the pinned zone (zone hit-test)
@property (nonatomic, assign) CGFloat dividerY;          // y of the separator (when both zones shown)
@property (nonatomic, strong) NSTimer *autoScrollTimer;
@property (nonatomic, assign) CGFloat autoScrollVel;     // px/tick, sign = direction, 0 = off
@property (nonatomic, strong) UIBarButtonItem *savedRightButton;
@property (nonatomic, strong) UIBarButtonItem *savedLeftButton;
@property (nonatomic, copy) NSString *pendingDeleteCid;   // folder awaiting delete-confirm (edit-mode ⊗)
// --- 5c: resize ---
@property (nonatomic, strong) CategoryTileView *resizeTile;
@property (nonatomic, assign) NSInteger resizeIndex;
@property (nonatomic, assign) CGRect resizeStartFrame;
@property (nonatomic, copy)   NSString *resizeCurrentSpan;
@property (nonatomic, assign) BOOL didFirstAppear;
@property (nonatomic, assign) BOOL catalogLoading;
@property (nonatomic, assign) BOOL builtContent;
@property (nonatomic, strong) UITapGestureRecognizer *retryTap;
@property (nonatomic, strong) NSTimer *activeUsersTimer;   // v3.2 : rafraîchit « X en ligne » en continu
@property (nonatomic, assign) NSInteger pulseTick;        // v3.2 : cadence le refresh des téléchargements
@end

@implementation CategoryViewController

// Live theme re-apply. White tiles sit on the themed content wash; tiles redraw via the central retint.
- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.scroll.backgroundColor = [IOS6Theme contentBackgroundColor];
    UILabel *hi = (UILabel *)[self.header viewWithTag:101];
    UILabel *subL = (UILabel *)[self.header viewWithTag:102];
    if (hi) hi.textColor = [IOS6Theme titleColor];
    if (subL) subL.textColor = [IOS6Theme labelGray];
    self.statusLabel.textColor = [IOS6Theme labelGray];
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.zoneDivider.backgroundColor = [IOS6Theme separatorColor];
    [self styleNewFolderButton];
}

// Outlined pill that follows the CURRENT theme's accent. `primaryBlue` is the theme accent already
// auto-contrasted for the current background (classic blue on Défaut, a deep accent on light-colour
// themes so it reads on white, a bright accent on dark themes) → correct & legible on every theme.
- (void)styleNewFolderButton {
    UIButton *b = self.addFolderButton;
    if (!b) return;
    UIColor *tint = [IOS6Theme primaryBlue];
    [b setTitleColor:tint forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    b.backgroundColor = [UIColor clearColor];
    b.layer.cornerRadius = 8.0;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = tint.CGColor;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
    BOOL sub = self.parentCategory.length > 0;
    self.title = sub ? locCat(self.parentCategory) : T(@"tab.home");
    if (!sub) [self installFeedbackBarButton];
    if (!sub) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:T(@"support.action") style:UIBarButtonItemStyleBordered
                   target:self action:@selector(donateTapped)];
    }

    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scroll.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    if (!sub) {   // long-press → edit mode (jiggle + drag-reorder + pin). Top-level Home only.
        self.longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                       action:@selector(handleLongPress:)];
        self.longPress.minimumPressDuration = 0.5;
        self.longPress.delegate = self;   // yields to a tile's resize handle
        [self.scroll addGestureRecognizer:self.longPress];
    }

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [IOS6Theme labelGray];
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    self.spinner = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(gridDensityDidChange) name:@"AppDropGridDensityChanged" object:nil];

    if (!sub) {
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(appDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(catalogDidUpdate) name:LocalCatalogDidUpdateNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(catalogDidUpdate) name:CollectionStoreDidChangeNotification object:nil];
        // #142: rebuild the home tiles when the hosted Works-Today / Modded list refreshes mid-session.
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(catalogDidUpdate) name:RevivalCatalogDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(catalogDidUpdate) name:ModdedCatalogDidChangeNotification object:nil];
        // v3.2 : met à jour les 4 icônes du raccourci « Plus téléchargées » quand les compteurs changent.
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(statsDownloadsChanged) name:StatsDownloadsChangedNotification object:nil];
        // v3.2 : met à jour le libellé « X en ligne » dès qu'un battement renvoie un nouveau compte.
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(activeUsersChanged) name:StatsActiveUsersChangedNotification object:nil];
    }
    [self attemptCatalogLoad];
}

- (void)layoutStatus {
    CGRect b = self.view.bounds;
    self.statusLabel.frame = CGRectMake(20, b.size.height/2 - 30, b.size.width - 40, 44);
    self.spinner.center = CGPointMake(b.size.width/2, b.size.height/2 - 44);
}

#pragma mark - Catalog load (unchanged: safe to call repeatedly; first-offline-launch self-heals)

- (void)attemptCatalogLoad {
    if ([[LocalCatalog shared] isReady]) {
        if (!self.builtContent) {
            self.builtContent = YES;            // guard re-entry before the async build runs
            self.statusLabel.hidden = YES;
            // Defer the (heavy) grid build one runloop so the tab bar + nav bar paint immediately
            // on the A4 — the app looks open instantly, then the tiles fill in a beat later.
            dispatch_async(dispatch_get_main_queue(), ^{ [self buildContent]; });
        }
        [[LocalCatalog shared] checkForCatalogUpdate];
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
            [[LocalCatalog shared] checkForCatalogUpdate];
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

- (void)ensureRetryGesture {
    if (self.retryTap) return;
    self.retryTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(attemptCatalogLoad)];
    [self.statusLabel addGestureRecognizer:self.retryTap];
}

- (void)appDidBecomeActive {
    if (![[LocalCatalog shared] isReady]) [self attemptCatalogLoad];
    else [[LocalCatalog shared] checkForCatalogUpdate];
    // v3.2 : de retour au premier plan sur l'accueil → battement + refresh téléchargements immédiats
    // + relance le timer.
    if (!self.parentCategory.length) {
        [self pulseActiveUsers];
        [[StatsClient shared] refreshDownloads];
        [self startActiveUsersTimer];
    }
}

// v3.2 : en arrière-plan, on coupe le timer (aucune requête réseau hors écran).
- (void)appDidEnterBackground { [self stopActiveUsersTimer]; }

// Catalogue hot-swapped OR a collection changed → rebuild the whole grid from scratch.
- (void)catalogDidUpdate {
    if (![[LocalCatalog shared] isReady]) return;
    // Drop any edit/drag state before the tiles are recreated.
    [self stopAutoScroll];
    self.homeEditing = NO; self.draggingTile = nil; self.resizeTile = nil; self.scroll.scrollEnabled = YES;
    if (self.savedRightButton) { self.navigationItem.rightBarButtonItem = self.savedRightButton; self.savedRightButton = nil; }
    if (self.savedLeftButton)  { self.navigationItem.leftBarButtonItem  = self.savedLeftButton;  self.savedLeftButton = nil; }
    for (UIView *v in [self.scroll.subviews copy]) [v removeFromSuperview];
    self.header = nil; self.items = nil; self.tiles = nil; self.zoneDivider = nil; self.addFolderButton = nil;
    [self buildContent];
    self.builtContent = YES;
}

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
    if (![[LocalCatalog shared] isReady]) {
        [self attemptCatalogLoad];
    } else if (self.didFirstAppear) {
        if (self.items) [self layoutContent];   // re-apply the Home density if it changed in Settings
        [self reshuffleIcons];
    }
    self.didFirstAppear = YES;
    // v3.2 : reprend le suivi « X en ligne » + les compteurs de téléchargements en revenant sur
    // l'accueil (battement + refresh immédiats, puis le timer prend le relais).
    if (!self.parentCategory.length && [[LocalCatalog shared] isReady]) {
        [self applyActiveLabel];
        [self pulseActiveUsers];
        [[StatsClient shared] refreshDownloads];
        [self startActiveUsersTimer];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopActiveUsersTimer];   // pas de trafic réseau quand l'accueil n'est pas visible
}

- (void)reshuffleIcons {
    for (CategoryTileView *t in self.tiles) [t reshuffleMosaic];   // vary the mosaics on each visit
}

#pragma mark - Build (unified item model)

// Green check glyph fallback for the "Works today" tile if no revival icons are available.
static UIImage *AppDropRevivalGlyph(void) {
    CGSize s = CGSizeMake(46, 46);
    // Fixed hi-res (6×, NOT the screen scale): a tile glyph is set once via setGlyphImage: and then
    // stretched by the icon view when the tile is enlarged to 2×2 (up to 128pt). On the non-Retina
    // iPad 1 the screen scale is 1.0 → a 46px glyph pixelates badly when blown up. ~276px downsamples
    // cleanly on every device (1×/2×). Same reason in the 3 sibling glyphs below.
    UIGraphicsBeginImageContextWithOptions(s, NO, 6.0);
    UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 44, 44) cornerRadius:10];
    [[UIColor colorWithRed:0.18 green:0.62 blue:0.30 alpha:1.0] setFill];
    [bg fill];
    UIBezierPath *ck = [UIBezierPath bezierPath];
    ck.lineWidth = 4.5; ck.lineCapStyle = kCGLineCapRound; ck.lineJoinStyle = kCGLineJoinRound;
    [ck moveToPoint:CGPointMake(13, 24)];
    [ck addLineToPoint:CGPointMake(20, 31)];
    [ck addLineToPoint:CGPointMake(34, 15)];
    [[UIColor whiteColor] setStroke];
    [ck stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Favoris glyph — a gold rounded badge with a white 5-point STAR (the user asked for a star, NOT a
// heart). Shown as the Favoris tile image when the collection is still empty.
static UIImage *AppDropFavoritesGlyph(void) {
    CGSize s = CGSizeMake(46, 46);
    UIGraphicsBeginImageContextWithOptions(s, NO, 6.0);   // hi-res so it stays crisp when enlarged (see AppDropRevivalGlyph)
    UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 44, 44) cornerRadius:10];
    [[UIColor colorWithRed:0.98 green:0.74 blue:0.12 alpha:1.0] setFill];   // warm gold
    [bg fill];
    UIBezierPath *star = [UIBezierPath bezierPath];
    CGFloat cx = 23, cy = 24, R = 14.5, r = 6.4;
    for (int i = 0; i < 10; i++) {
        CGFloat ang = -M_PI_2 + i * (M_PI / 5.0);
        CGFloat rad = (i % 2 == 0) ? R : r;
        CGPoint p = CGPointMake(cx + rad * cosf(ang), cy + rad * sinf(ang));
        if (i == 0) [star moveToPoint:p]; else [star addLineToPoint:p];
    }
    [star closePath];
    [[UIColor whiteColor] setFill];
    [star fill];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// "Télécharger plus tard" glyph — a slate badge with a white clock. Shown on the empty queue tile.
static UIImage *AppDropLaterGlyph(void) {
    CGSize s = CGSizeMake(46, 46);
    UIGraphicsBeginImageContextWithOptions(s, NO, 6.0);   // hi-res so it stays crisp when enlarged (see AppDropRevivalGlyph)
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 44, 44) cornerRadius:10];
    [[UIColor colorWithRed:0.36 green:0.45 blue:0.62 alpha:1.0] setFill];
    [bg fill];
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 2.5);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(13, 13, 20, 20));   // clock face
    CGContextMoveToPoint(ctx, 23, 23); CGContextAddLineToPoint(ctx, 23, 16.5); CGContextStrokePath(ctx);  // minute hand
    CGContextMoveToPoint(ctx, 23, 23); CGContextAddLineToPoint(ctx, 28, 25);   CGContextStrokePath(ctx);  // hour hand
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// "Apps modifiées" glyph — a violet badge with a white "sliders/adjustments" icon (= tweaked/modded).
// Shown on the empty Modded tile.
static UIImage *AppDropModdedGlyph(void) {
    CGSize s = CGSizeMake(46, 46);
    UIGraphicsBeginImageContextWithOptions(s, NO, 6.0);   // hi-res so it stays crisp when enlarged (see AppDropRevivalGlyph)
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 44, 44) cornerRadius:10];
    [[UIColor colorWithRed:0.55 green:0.35 blue:0.85 alpha:1.0] setFill];   // violet
    [bg fill];
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 2.5);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextMoveToPoint(ctx, 12, 18); CGContextAddLineToPoint(ctx, 34, 18); CGContextStrokePath(ctx);  // top slider
    CGContextMoveToPoint(ctx, 12, 28); CGContextAddLineToPoint(ctx, 34, 28); CGContextStrokePath(ctx);  // bottom slider
    [[UIColor whiteColor] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(26, 15, 6, 6)] fill];   // top knob (right)
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(14, 25, 6, 6)] fill];   // bottom knob (left)
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// v3.2 — glyphe « Plus téléchargées » : badge orange avec une flèche descendante vers un plateau.
// Affiché sur le raccourci tant qu'aucune app téléchargée n'a encore d'icône à montrer.
static UIImage *AppDropDownloadsGlyph(void) {
    CGSize s = CGSizeMake(46, 46);
    UIGraphicsBeginImageContextWithOptions(s, NO, 6.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 44, 44) cornerRadius:10];
    [[UIColor colorWithRed:0.95 green:0.55 blue:0.15 alpha:1.0] setFill];   // orange
    [bg fill];
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 2.8);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, 23, 12); CGContextAddLineToPoint(ctx, 23, 27); CGContextStrokePath(ctx);   // shaft
    CGContextMoveToPoint(ctx, 16, 21); CGContextAddLineToPoint(ctx, 23, 28);                              // arrowhead
    CGContextAddLineToPoint(ctx, 30, 21); CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, 14, 33); CGContextAddLineToPoint(ctx, 32, 33); CGContextStrokePath(ctx);    // tray
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// v3.0: Home/category grid — its OWN setting (Settings → Affichage), separate from the catalogue one.
// Configured by an explicit COLUMN COUNT via the native wheel picker (IPAInstall.HomeColumns), not a
// 0–1 density. Idiom-aware default reproduces the classic ~165 pt tile (iPhone 2, iPad 4). Min 2 — the
// Accueil tiles are big widgets, a single column would be huge. Exposed for SettingsViewController.
+ (NSInteger)homeColumns {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL pad = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
    NSInteger def = pad ? 4 : 2;
    NSInteger n = ([d objectForKey:@"IPAInstall.HomeColumns"] != nil)
        ? [d integerForKey:@"IPAInstall.HomeColumns"] : def;
    if (n < 2) n = 2;
    NSInteger maxN = pad ? 8 : 3;   // iPhone capped at 3 (tiles past that are too small for a name)
    if (n > maxN) n = maxN;
    return n;
}
+ (NSInteger)homeColumnsForWidth:(CGFloat)w {
    if (w < 1) w = [UIScreen mainScreen].bounds.size.width;
    NSInteger base = [self homeColumns];   // the count the user picked, defined at PORTRAIT width
    // #171: scale the column count with the ACTUAL width so the Accueil TILE SIZE stays ~constant
    // across rotation (e.g. portrait 2-up → landscape ~4-up), the same fix as the catalogue grid —
    // instead of a fixed count that's sparse in landscape and cramped again back in portrait.
    CGFloat portraitW = MIN([UIScreen mainScreen].bounds.size.width,
                            [UIScreen mainScreen].bounds.size.height);
    if (portraitW < 1) portraitW = w;
    NSInteger cols = (NSInteger)((CGFloat)base * (w / portraitW) + 0.5f);   // round to nearest
    // Cap at however many ~76 pt tiles fit, so it never makes the big widget tiles tiny.
    NSInteger maxFit = (NSInteger)floorf(w / 76.0f);
    if (maxFit < 2) maxFit = 2;
    if (cols < 2) cols = 2;            // Accueil tiles are big widgets — never a single column
    if (cols > maxFit) cols = maxFit;
    return cols;
}

- (void)buildContent {
    BOOL sub = self.parentCategory.length > 0;
    LocalCatalog *cat = [LocalCatalog shared];

    NSMutableArray *items = [NSMutableArray array];
    self.pinnedCount = 0;   // subgenre screens have no pinned zone; set below for the top level

    if (sub) {
        // "All <category>" tile FIRST so the user can browse the WHOLE category without being
        // forced to pick a subgenre (feedback #152 — v3.0 regression; subgenre=nil → all apps in cat).
        NSInteger catTotal = 0;
        for (NSDictionary *cc in [cat categoryCounts]) {
            if ([(cc[@"category"] ?: @"") isEqualToString:self.parentCategory]) {
                catTotal = [cc[@"count"] integerValue]; break;
            }
        }
        [items addObject:@{ @"id": [@"allcat:" stringByAppendingString:self.parentCategory],
            @"kind": @"all-cat", @"cat": self.parentCategory,
            @"label": T(@"categories.all_in_cat"),
            @"seed": [@"allcat_" stringByAppendingString:self.parentCategory],
            @"defSpan": @"1x1", @"defaultPinned": @NO,
            @"subtitle": [NSString stringWithFormat:T(@"categories.napps"), fmtCount(catTotal)],
            @"iconPool": [cat iconPoolForCategory:self.parentCategory] ?: @[] }];
        // Subgenre tiles (this is a drilled-in screen — no collections / reorder).
        for (NSDictionary *d in [cat subgenreCountsForCategory:self.parentCategory]) {
            NSString *sg = d[@"subgenre"] ?: @"";
            [items addObject:@{ @"id": [@"sub:" stringByAppendingString:sg], @"kind": @"sub", @"sub": sg,
                @"label": locSub(sg), @"seed": sg, @"defSpan": @"1x1", @"defaultPinned": @NO,
                @"subtitle": [NSString stringWithFormat:T(@"categories.napps"), fmtCount([d[@"count"] integerValue])],
                @"iconPool": [cat iconPoolForCategory:self.parentCategory subgenre:sg] ?: @[] }];
        }
    } else {
        // ---- Welcome header ----
        self.header = [[UIView alloc] initWithFrame:CGRectZero];
        UILabel *hi = [[UILabel alloc] initWithFrame:CGRectZero];
        hi.tag = 101; hi.font = [UIFont boldSystemFontOfSize:21];
        hi.textColor = [IOS6Theme titleColor]; hi.backgroundColor = [UIColor clearColor];
        hi.text = T(@"categories.welcome");
        [self.header addSubview:hi];
        UILabel *subL = [[UILabel alloc] initWithFrame:CGRectZero];
        subL.tag = 102; subL.font = [UIFont systemFontOfSize:13];
        subL.textColor = [IOS6Theme labelGray]; subL.numberOfLines = 2;
        subL.backgroundColor = [UIColor clearColor];
        self.welcomeSubBase = [NSString stringWithFormat:T(@"categories.welcome_sub"), fmtCount([cat uniqueAppCount])];
        subL.text = self.welcomeSubBase;
        [self.header addSubview:subL];
        [self.scroll addSubview:self.header];
        [self refreshActiveUsers];   // v3.2 : affiche les utilisateurs actifs (+ envoie un battement anonyme)

        // Small, DISTINCT "+ Nouveau dossier" button — always pinned at the top (NOT a grid tile,
        // not reorderable/resizable). A green outlined pill, clearly unlike the app/category cards.
        self.addFolderButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.addFolderButton setTitle:[@"+  " stringByAppendingString:T(@"folder.new")] forState:UIControlStateNormal];
        [self.addFolderButton addTarget:self action:@selector(promptNewFolder)
                       forControlEvents:UIControlEventTouchUpInside];
        [self styleNewFolderButton];
        [self.scroll addSubview:self.addFolderButton];

        // ---- Category cards first (so we can sample their icons for the "All apps" mosaic) ----
        NSMutableArray *catItems = [NSMutableArray array];
        NSMutableArray *allSample = [NSMutableArray array];
        for (NSDictionary *d in [cat categoryCounts]) {
            NSString *cn = d[@"category"] ?: @"";
            NSArray *pool = [cat iconPoolForCategory:cn] ?: @[];
            [catItems addObject:@{ @"id": [@"cat:" stringByAppendingString:cn], @"kind": @"cat", @"cat": cn,
                @"label": locCat(cn), @"seed": cn, @"defSpan": @"1x1", @"defaultPinned": @NO,   // « Non triées » en bas comme les autres (triée par nombre)
                @"subtitle": [NSString stringWithFormat:T(@"categories.napps"), fmtCount([d[@"count"] integerValue])],
                @"iconPool": pool }];
            for (NSInteger i = 0; i < 2 && i < (NSInteger)pool.count; i++) [allSample addObject:pool[i]];
        }

        // ---- Collections (Favoris + folders) ----
        CollectionStore *store = [CollectionStore shared];
        BOOL showFavHome = ([[NSUserDefaults standardUserDefaults] objectForKey:@"IPAInstall.ShowFavoritesOnHome"] == nil)
                           ? YES : [[NSUserDefaults standardUserDefaults] boolForKey:@"IPAInstall.ShowFavoritesOnHome"];
        for (NSDictionary *col in [store collections]) {
            NSString *cid = col[@"id"];
            if (!showFavHome && [cid isEqualToString:CollectionFavoritesId]) continue;   // v3.0: Favoris tile hidden from Home via Settings toggle (default shown; the Favoris tab stays)
            NSArray *pool = [store iconPoolForCollection:cid];
            NSDictionary *it = @{ @"id": [@"col:" stringByAppendingString:cid], @"kind": @"col", @"cid": cid,
                @"label": [store nameForCollection:cid], @"seed": cid, @"defSpan": @"1x1",
                @"defaultPinned": @([cid isEqualToString:CollectionFavoritesId] || [cid isEqualToString:CollectionLaterId]),   // Favoris + Plus tard pinned; folders not
                @"subtitle": [NSString stringWithFormat:T(@"categories.napps"), fmtCount([store countInCollection:cid])],
                @"iconPool": pool ?: @[] };   // tiles always show the auto mosaic (preview-image pinning removed)
            [items addObject:it];
        }
        // Big-by-default tiles span 2×1 on iPad, but only 1×1 on a small phone screen (3GS / iPod
        // touch) so the pinned zone stays compact. The user can still resize them manually.
        CGSize scr = [UIScreen mainScreen].bounds.size;
        NSString *bigSpan = (MIN(scr.width, scr.height) < 480) ? @"1x1" : @"2x1";

        // ---- All apps (wide by default) ----
        [items addObject:@{ @"id": @"item.all", @"kind": @"all", @"label": T(@"categories.all"),
            @"seed": @"all_apps", @"defSpan": bigSpan, @"defaultPinned": @YES,
            @"subtitle": [NSString stringWithFormat:T(@"categories.napps"), fmtCount([cat uniqueAppCount])],
            @"iconPool": allSample }];
        // ---- v3.2 : raccourci « Plus téléchargées » (tout le catalogue trié par téléchargements). Ses 4
        // icônes = les 4 apps EN CE MOMENT les plus téléchargées (mises à jour via statsDownloadsChanged). ----
        [items addObject:@{ @"id": @"item.topdl", @"kind": @"topdl", @"label": T(@"categories.top_downloads"),
            @"seed": @"top_downloads", @"defSpan": bigSpan, @"defaultPinned": @YES,
            @"subtitle": [NSString stringWithFormat:T(@"categories.napps"), fmtCount([cat uniqueAppCount])],
            @"iconPool": [cat topDownloadedIconURLs:4] ?: @[] }];
        // ---- Works today / Revival + Apps modifiées / Modded ----
        // Retirées de l'accueil (kEnableWorksTodayModded = NO). Le code des tuiles + listes + upload
        // reste en place mais inatteignable tant que le flag est NO.
        if (kEnableWorksTodayModded) {
            // ---- Works today / Revival (wide by default), mosaic of the curated apps' icons ----
            NSMutableArray *revIcons = [NSMutableArray array];
            for (NSDictionary *r in [[RevivalCatalog shared] appDicts]) {
                NSString *ic = r[@"icon"];
                if ([ic isKindOfClass:[NSString class]] && ic.length) [revIcons addObject:ic];
            }
            [items addObject:@{ @"id": @"item.revival", @"kind": @"revival", @"label": T(@"categories.revival"),
                @"seed": @"revival", @"defSpan": bigSpan, @"defaultPinned": @YES,
                @"subtitle": T(@"categories.revival_sub"), @"iconPool": revIcons }];
            // ---- Apps modifiées / Modded (mosaic of the modded apps' icons) ----
            NSMutableArray *modIcons = [NSMutableArray array];
            for (NSDictionary *m in [[ModdedCatalog shared] appDicts]) {
                NSString *ic = m[@"icon"];
                if ([ic isKindOfClass:[NSString class]] && ic.length) [modIcons addObject:ic];
            }
            [items addObject:@{ @"id": @"item.modded", @"kind": @"modded", @"label": T(@"categories.modded"),
                @"seed": @"modded", @"defSpan": @"1x1", @"defaultPinned": @YES,
                @"subtitle": T(@"categories.modded_sub"), @"iconPool": modIcons }];
        }
        // ---- Then the categories ----
        [items addObjectsFromArray:catItems];

        // Resolve into the PINNED (top) zone + the rest, honoring the user's saved layout. New
        // items land in their default zone, appended.
        NSMutableArray *defItems = [NSMutableArray array];
        for (NSDictionary *it in items)
            [defItems addObject:@{ @"id": it[@"id"], @"defaultPinned": it[@"defaultPinned"] ?: @NO }];
        NSMutableArray *pIds = [NSMutableArray array], *uIds = [NSMutableArray array];
        [[HomeLayoutStore shared] resolveItems:defItems intoPinned:pIds unpinned:uIds];
        NSMutableDictionary *byId = [NSMutableDictionary dictionary];
        for (NSDictionary *it in items) byId[it[@"id"]] = it;
        NSMutableArray *ordered = [NSMutableArray array];
        for (NSString *iid in pIds) if (byId[iid]) [ordered addObject:byId[iid]];
        self.pinnedCount = (NSInteger)ordered.count;
        for (NSString *iid in uIds) if (byId[iid]) [ordered addObject:byId[iid]];
        items = ordered;

        // Thin rule shown between the pinned zone and the rest.
        if (!self.zoneDivider) {
            self.zoneDivider = [[UIView alloc] initWithFrame:CGRectZero];
            self.zoneDivider.backgroundColor = [IOS6Theme separatorColor];
        }
        [self.scroll addSubview:self.zoneDivider];
    }

    self.items = items;

    // ---- Tiles ----
    NSMutableArray *tiles = [NSMutableArray array];
    AD_WEAK typeof(self) wself = self;
    for (NSDictionary *it in self.items) {
        CategoryTileView *t = [[CategoryTileView alloc] initWithFrame:CGRectZero];
        // Tiles always show the auto mosaic (preview-image pinning was removed).
        [t configureMosaicWithLabel:it[@"label"] subtitle:it[@"subtitle"]
                           iconURLs:it[@"iconPool"] colorSeed:it[@"seed"]];
        if ([it[@"iconPool"] count] == 0) {
            // Empty collection → show its identity glyph instead of a letter placeholder.
            if ([it[@"kind"] isEqualToString:@"revival"]) [t setGlyphImage:AppDropRevivalGlyph()];
            else if ([it[@"kind"] isEqualToString:@"modded"]) [t setGlyphImage:AppDropModdedGlyph()];
            else if ([it[@"kind"] isEqualToString:@"col"] &&
                     [it[@"cid"] isEqualToString:CollectionFavoritesId]) [t setGlyphImage:AppDropFavoritesGlyph()];
            else if ([it[@"kind"] isEqualToString:@"col"] &&
                     [it[@"cid"] isEqualToString:CollectionLaterId]) [t setGlyphImage:AppDropLaterGlyph()];
            else if ([it[@"kind"] isEqualToString:@"topdl"]) [t setGlyphImage:AppDropDownloadsGlyph()];
        }
        if ([it[@"kind"] isEqualToString:@"topdl"]) self.topDLTile = t;   // v3.2 : pour rafraîchir ses 4 icônes
        NSDictionary *item = it;
        t.onTap = ^{ [wself handleTapForItem:item]; };
        if ([self isUserFolderItem:it]) t.onDelete = ^{ [wself confirmDeleteFolderForItem:item]; };
        UIPanGestureRecognizer *rp = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(handleResizePan:)];
        [t.resizeHandle addGestureRecognizer:rp];   // only fires when the handle is visible (edit mode)
        [tiles addObject:t];
        [self.scroll addSubview:t];
    }
    self.tiles = tiles;

    [self layoutContent];
}

- (void)handleTapForItem:(NSDictionary *)it {
    if (self.homeEditing) return;   // taps do nothing while rearranging
    NSString *kind = it[@"kind"];
    if ([kind isEqualToString:@"col"]) {
        [self.navigationController pushViewController:
            [[CollectionViewController alloc] initWithCollectionId:it[@"cid"]] animated:YES];
    } else if ([kind isEqualToString:@"all"]) {
        CatalogViewController *vc = [[CatalogViewController alloc] init];
        vc.title = T(@"categories.all");
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([kind isEqualToString:@"topdl"]) {
        // v3.2 : tout le catalogue, trié par téléchargements (sans toucher au filtre sauvegardé).
        CatalogViewController *vc = [[CatalogViewController alloc] init];
        vc.title = T(@"categories.top_downloads");
        vc.initialSort = @"downloads";
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([kind isEqualToString:@"revival"]) {
        RevivalListViewController *vc = [[RevivalListViewController alloc] init];
        vc.uploadTarget = @"revival";   // users can share apps that work today (they have the right to)
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([kind isEqualToString:@"modded"]) {
        // Reuse the Revival list screen, fed with the curated MODDED catalog.
        RevivalListViewController *vc = [[RevivalListViewController alloc] init];
        vc.customAppDicts = [[ModdedCatalog shared] appDicts];
        vc.customTitle = T(@"categories.modded");
        vc.customIntro = T(@"modded.intro");
        vc.uploadTarget = @"mods";      // users can share their own modded apps
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([kind isEqualToString:@"all-cat"]) {
        NSString *cn = it[@"cat"];
        [self pushResultsForCategory:cn subgenre:nil title:locCat(cn)];
    } else if ([kind isEqualToString:@"sub"]) {
        NSString *subv = it[@"sub"];
        [self pushResultsForCategory:self.parentCategory subgenre:subv
                               title:[NSString stringWithFormat:@"%@ › %@", locCat(self.parentCategory), locSub(subv)]];
    } else if ([kind isEqualToString:@"cat"]) {
        NSString *cn = it[@"cat"];
        if ([[LocalCatalog shared] subgenreCountsForCategory:cn].count > 0) {
            CategoryViewController *vc = [[CategoryViewController alloc] init];
            vc.parentCategory = cn;
            [self.navigationController pushViewController:vc animated:YES];
        } else {
            [self pushResultsForCategory:cn subgenre:nil title:locCat(cn)];
        }
    }
}

- (void)pushResultsForCategory:(NSString *)cat subgenre:(NSString *)sub title:(NSString *)title {
    SearchViewController *vc = [[SearchViewController alloc] init];
    vc.categoryFilter = cat;
    vc.subgenreFilter = sub;
    vc.categoryTitle = title;
    [self.navigationController pushViewController:vc animated:YES];
}

// A tile that represents a USER-created folder (deletable). Built-in Favoris / Télécharger plus tard,
// categories, All apps and Works-today are NOT folders → never deletable from the grid.
- (BOOL)isUserFolderItem:(NSDictionary *)it {
    if (![it[@"kind"] isEqualToString:@"col"]) return NO;
    NSString *cid = it[@"cid"];
    if (!cid || [cid isEqualToString:CollectionFavoritesId] || [cid isEqualToString:CollectionLaterId]) return NO;
    NSDictionary *c = [[CollectionStore shared] collectionForId:cid];
    return c && ![c[@"builtin"] boolValue];
}

// ⊗ tapped in edit mode → confirm, then delete. deleteCollection: posts the change notification,
// which runs catalogDidUpdate → the whole grid rebuilds without the folder (and edit mode ends).
- (void)confirmDeleteFolderForItem:(NSDictionary *)it {
    if (![self isUserFolderItem:it]) return;   // hard guard: never delete a built-in
    self.pendingDeleteCid = it[@"cid"];
    NSString *name = [[CollectionStore shared] nameForCollection:it[@"cid"]];
    UIAlertView *a = [[UIAlertView alloc]
        initWithTitle:[NSString stringWithFormat:T(@"folder.delete_title_named"), name ?: @""]
        message:T(@"folder.delete_msg") delegate:self
        cancelButtonTitle:T(@"common.cancel") otherButtonTitles:T(@"folder.delete"), nil];
    a.tag = 7801;
    [a show];
}

#pragma mark - Layout (first-fit span packing)

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (self.items) [self layoutContent];
    else [self layoutStatus];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

static void parseSpan(NSString *s, int *w, int *h) {
    *w = 1; *h = 1;
    NSArray *p = [s componentsSeparatedByString:@"x"];
    if (p.count == 2) { *w = MAX(1, [p[0] intValue]); *h = MAX(1, [p[1] intValue]); }
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
        y += hH + 6;
    }

    // "+ Nouveau dossier" — small pill, always at the very top (above the pinned zone).
    if (self.addFolderButton) {
        self.addFolderButton.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
        [self.addFolderButton sizeToFit];
        CGRect f = self.addFolderButton.frame;
        self.addFolderButton.frame = CGRectMake(margin, y, f.size.width, 32);
        y += 32 + 12;
    }

    // Base grid: column count from the Home density setting (Settings → Display). Default (0.5)
    // reproduces the classic ~165pt tile; denser = more, smaller tiles. tileH tracks tileW so tiles
    // shrink in BOTH dimensions, and the tile text adapts its size (see CategoryTileView).
    NSInteger cols = [CategoryViewController homeColumnsForWidth:W];
    CGFloat tileW = floorf((W - 2*margin - (cols - 1)*gap) / cols);
    CGFloat tileH = floorf(tileW * 0.85);

    NSInteger pin = self.pinnedCount;
    if (pin > (NSInteger)self.tiles.count) pin = (NSInteger)self.tiles.count;
    BOOL bothZones = (pin > 0 && pin < (NSInteger)self.tiles.count);

    // Pinned (top) zone.
    if (pin > 0)
        y = [self packTiles:NSMakeRange(0, pin) atY:y cols:cols tileW:tileW tileH:tileH margin:margin gap:gap];
    self.pinnedZoneBottom = y;   // for drag zone hit-testing

    // Separator + breathing space between pinned and the rest.
    if (bothZones) {
        y += 9;
        self.zoneDivider.hidden = NO;
        self.zoneDivider.frame = CGRectMake(margin, y, W - 2*margin, 1);
        self.dividerY = y;
        y += 1 + 14;
    } else {
        self.zoneDivider.hidden = YES;
        self.dividerY = self.pinnedZoneBottom + 8;
    }

    // Unpinned zone.
    NSInteger rest = (NSInteger)self.tiles.count - pin;
    if (rest > 0)
        y = [self packTiles:NSMakeRange(pin, rest) atY:y cols:cols tileW:tileW tileH:tileH margin:margin gap:gap];

    self.scroll.contentSize = CGSizeMake(W, y + 16);
}

// First-fit span packer for a RANGE of tiles starting at `y` (fresh occupancy per zone).
// Returns the y just below the last row.
- (CGFloat)packTiles:(NSRange)range atY:(CGFloat)y cols:(NSInteger)cols
               tileW:(CGFloat)tileW tileH:(CGFloat)tileH margin:(CGFloat)margin gap:(CGFloat)gap {
    NSMutableArray *occ = [NSMutableArray array];   // flat NSNumber bool grid, row-major
    NSInteger maxRow = 0;
    for (NSUInteger i = range.location; i < range.location + range.length && i < self.tiles.count; i++) {
        NSString *iid = self.items[i][@"id"];
        NSString *span = [[HomeLayoutStore shared] spanForItem:iid] ?: (self.items[i][@"defSpan"] ?: @"1x1");
        int sw = 1, sh = 1; parseSpan(span, &sw, &sh);
        if (sw > cols) sw = (int)cols;

        int placeRow = 0, placeCol = 0; BOOL found = NO;
        for (int row = 0; !found && row < 4096; row++) {
            while ((NSInteger)occ.count < (row + sh) * cols) [occ addObject:@NO];
            for (int col = 0; col + sw <= cols; col++) {
                BOOL free = YES;
                for (int dr = 0; dr < sh && free; dr++)
                    for (int dc = 0; dc < sw && free; dc++)
                        if ([occ[(row+dr)*cols + (col+dc)] boolValue]) free = NO;
                if (free) { placeRow = row; placeCol = col; found = YES; break; }
            }
        }
        for (int dr = 0; dr < sh; dr++)
            for (int dc = 0; dc < sw; dc++)
                occ[(placeRow+dr)*cols + (placeCol+dc)] = @YES;
        if (placeRow + sh > maxRow) maxRow = placeRow + sh;

        CGFloat x = margin + placeCol*(tileW + gap);
        CGFloat ty = y + placeRow*(tileH + gap);
        CGRect f = CGRectMake(x, ty, sw*tileW + (sw-1)*gap, sh*tileH + (sh-1)*gap);
        // The tile being dragged keeps following the finger — record its slot, don't move it here.
        if (self.tiles[i] == self.draggingTile) self.dragSlotFrame = f;
        else ((UIView *)self.tiles[i]).frame = f;
    }
    return y + maxRow*tileH + (maxRow > 0 ? (maxRow - 1)*gap : 0);
}

#pragma mark - Edit mode (long-press → jiggle → drag-reorder + pin)

- (void)handleLongPress:(UILongPressGestureRecognizer *)gr {
    CGPoint p = [gr locationInView:self.scroll];
    if (gr.state == UIGestureRecognizerStateBegan) {
        if (!self.items.count) return;
        if (!self.homeEditing) [self enterEditMode];
        NSInteger idx = [self tileIndexAtPoint:p];
        if (idx >= 0) [self beginDraggingIndex:idx atPoint:p];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        if (self.draggingTile) [self updateDragToPoint:p];
    } else {   // ended / cancelled / failed
        if (self.draggingTile) [self endDragging];
    }
}

- (NSInteger)tileIndexAtPoint:(CGPoint)p {
    for (NSUInteger i = 0; i < self.tiles.count; i++)
        if (CGRectContainsPoint(((UIView *)self.tiles[i]).frame, p)) return (NSInteger)i;
    return -1;
}

- (void)enterEditMode {
    self.homeEditing = YES;
    self.savedRightButton = self.navigationItem.rightBarButtonItem;
    self.savedLeftButton = self.navigationItem.leftBarButtonItem;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:T(@"common.done") style:UIBarButtonItemStyleDone target:self action:@selector(doneEditingTapped)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:T(@"home.reset") style:UIBarButtonItemStyleBordered target:self action:@selector(resetLayoutTapped)];
    for (NSUInteger i = 0; i < self.tiles.count; i++) {
        CategoryTileView *t = self.tiles[i];
        [self startJiggle:t];
        [t setShowResizeHandle:YES];
        // The ⊗ delete badge appears only on USER folders — never on Favoris / Télécharger plus tard
        // / categories / All / Works-today (those have no onDelete and isUserFolderItem returns NO).
        [t setShowDeleteBadge:[self isUserFolderItem:self.items[i]]];
    }
}

- (void)doneEditingTapped { [self exitEditMode]; }

- (void)exitEditMode {
    if (self.draggingTile) [self endDragging];
    self.homeEditing = NO;
    for (CategoryTileView *t in self.tiles) { [self stopJiggle:t]; [t setShowResizeHandle:NO]; [t setShowDeleteBadge:NO]; }
    if (self.savedRightButton) { self.navigationItem.rightBarButtonItem = self.savedRightButton; self.savedRightButton = nil; }
    self.navigationItem.leftBarButtonItem = self.savedLeftButton; self.savedLeftButton = nil;
    [self persistLayout];
}

// Light presentational wobble: an ADDITIVE rotation animation on the layer (the view's transform /
// frame stay identity, so the drag-reorder reflow still works). Cheap on A4 — pure GPU.
- (void)startJiggle:(UIView *)t {
    if (!t || t == self.draggingTile) return;
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
    a.values = @[@(-0.028), @(0.028), @(-0.028)];
    a.duration = 0.16;
    a.additive = YES;
    a.repeatCount = HUGE_VALF;
    a.timeOffset = (CFTimeInterval)(arc4random_uniform(160)) / 1000.0;   // desync the tiles
    [t.layer addAnimation:a forKey:@"jiggle"];
}
- (void)stopJiggle:(UIView *)t { [t.layer removeAnimationForKey:@"jiggle"]; }

- (void)beginDraggingIndex:(NSInteger)idx atPoint:(CGPoint)p {
    self.dragIndex = idx;
    self.draggingTile = (CategoryTileView *)self.tiles[idx];
    [self stopJiggle:self.draggingTile];
    [self.scroll bringSubviewToFront:self.draggingTile];
    self.scroll.scrollEnabled = NO;   // we hand-scroll near the edges instead
    CGRect f = self.draggingTile.frame;
    self.dragOffset = CGPointMake(p.x - CGRectGetMidX(f), p.y - CGRectGetMidY(f));
    [UIView animateWithDuration:0.18 animations:^{
        self.draggingTile.transform = CGAffineTransformMakeScale(1.07, 1.07);
        self.draggingTile.alpha = 0.92;
    }];
}

- (void)updateDragToPoint:(CGPoint)p {
    self.draggingTile.center = CGPointMake(p.x - self.dragOffset.x, p.y - self.dragOffset.y);
    [self maybeReorderForPoint:p];
    [self updateAutoScrollForPoint:p];
}

// Decide the target zone (above/below the separator) + insertion index, and reorder if it changed.
- (void)maybeReorderForPoint:(CGPoint)p {
    BOOL toPinned = (p.y < self.dividerY);
    NSInteger pinnedExcl = self.pinnedCount - ((self.dragIndex < self.pinnedCount) ? 1 : 0);
    NSInteger insertion = 0;
    for (NSUInteger i = 0; i < self.tiles.count; i++) {
        if ((NSInteger)i == self.dragIndex) continue;
        BOOL iPinned = ((NSInteger)i < self.pinnedCount);
        if (iPinned != toPinned) continue;                 // only count tiles in the TARGET zone
        CGRect f = ((UIView *)self.tiles[i]).frame;
        CGFloat cx = CGRectGetMidX(f), cy = CGRectGetMidY(f);
        BOOL before = (cy < p.y - f.size.height*0.35) ||
                      (fabs(cy - p.y) <= f.size.height*0.65 && cx < p.x);   // reading order
        if (before) insertion++;
    }
    NSInteger target = toPinned ? insertion : (pinnedExcl + insertion);
    NSInteger newPinned = toPinned ? (pinnedExcl + 1) : pinnedExcl;
    if (target == self.dragIndex && newPinned == self.pinnedCount) return;   // unchanged → no churn

    NSMutableArray *items = [self.items mutableCopy];
    NSMutableArray *tiles = [self.tiles mutableCopy];
    id item = items[self.dragIndex]; id tile = tiles[self.dragIndex];
    [items removeObjectAtIndex:self.dragIndex];
    [tiles removeObjectAtIndex:self.dragIndex];
    NSInteger t = MAX(0, MIN(target, (NSInteger)items.count));
    [items insertObject:item atIndex:t];
    [tiles insertObject:tile atIndex:t];
    self.items = items; self.tiles = tiles;
    self.dragIndex = t; self.pinnedCount = newPinned;
    [UIView animateWithDuration:0.18 delay:0
                        options:UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self layoutContent]; } completion:nil];
}

- (void)endDragging {
    [self stopAutoScroll];
    self.scroll.scrollEnabled = YES;
    CategoryTileView *t = self.draggingTile;
    [self layoutContent];                       // recompute others + store self.dragSlotFrame (t skipped)
    CGRect slot = self.dragSlotFrame;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        t.transform = CGAffineTransformIdentity;
        t.alpha = 1.0;
        if (!CGRectIsEmpty(slot)) t.frame = slot;
    } completion:^(BOOL done) {
        if (self.homeEditing && t) [self startJiggle:t];   // resume wobble if still editing
    }];
    self.draggingTile = nil;
    [self persistLayout];
}

- (void)persistLayout {
    NSMutableArray *pinned = [NSMutableArray array], *unpinned = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.items.count; i++) {
        NSString *iid = self.items[i][@"id"];
        if (!iid) continue;
        if ((NSInteger)i < self.pinnedCount) [pinned addObject:iid]; else [unpinned addObject:iid];
    }
    [[HomeLayoutStore shared] savePinned:pinned unpinned:unpinned];
}

// v3.2 — premier affichage : envoie un battement anonyme (via StatsClient → Worker Cloudflare),
// affiche « X en ligne » et rafraîchit aussi la table downloads (tri + top + détail). Démarre
// ensuite le timer qui garde le compteur à jour en continu tant que l'accueil est visible.
- (void)refreshActiveUsers {
    [[StatsClient shared] sendHeartbeatWithCompletion:nil];   // le libellé se met à jour via la notification
    [[StatsClient shared] refreshDownloads];                  // table downloads (tri/top) + notifie
    [self applyActiveLabel];                                  // affiche tout de suite la valeur en cache
    [self startActiveUsersTimer];
}

// Met à jour le libellé « X en ligne » depuis la dernière valeur connue (cache StatsClient). Appelé
// au build, sur la notification StatsActiveUsersChanged, et à chaque battement périodique.
- (void)applyActiveLabel {
    NSInteger active = [[StatsClient shared] cachedActiveUsers];
    if (active <= 0) return;
    UILabel *subL = (UILabel *)[self.header viewWithTag:102];
    if (subL && self.welcomeSubBase.length) {
        NSString *k = (active == 1) ? @"home.active_one" : @"home.active_other";
        subL.text = [NSString stringWithFormat:@"%@ · %@", self.welcomeSubBase,
                     [NSString stringWithFormat:T(k), fmtCount(active)]];
    }
}

- (void)activeUsersChanged { [self applyActiveLabel]; }

// Battement périodique. Le heartbeat (léger) part à chaque tick (30 s) → garde CET appareil compté
// et met à jour « X en ligne » via la notification. Les compteurs de téléchargements (« Plus
// téléchargées » + nombre par app) sont rafraîchis une fois sur deux (≈60 s) : assez pour rester à
// jour en continu sans re-télécharger la table downloads trop souvent (perf vieux appareils).
- (void)pulseActiveUsers {
    [[StatsClient shared] sendHeartbeatWithCompletion:nil];
    if ((++self.pulseTick % 2) == 0) [[StatsClient shared] refreshDownloads];
}

// Le timer ne tourne QUE pendant que l'accueil est visible au premier plan (perf : pas de trafic
// réseau en arrière-plan ni hors écran ; important pour les vieux appareils / le futur iOS 3-4).
- (void)startActiveUsersTimer {
    if (self.activeUsersTimer || self.parentCategory.length) return;   // accueil racine seulement
    self.activeUsersTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self
        selector:@selector(pulseActiveUsers) userInfo:nil repeats:YES];
}

- (void)stopActiveUsersTimer {
    [self.activeUsersTimer invalidate];
    self.activeUsersTimer = nil;
}

// v3.2 — rafraîchit les 4 icônes de la tuile « Plus téléchargées » quand les compteurs changent.
- (void)statsDownloadsChanged {
    CategoryTileView *tile = self.topDLTile;
    if (!tile) return;
    NSArray *icons = [[LocalCatalog shared] topDownloadedIconURLs:4];
    if (icons.count) {
        [tile configureMosaicWithLabel:T(@"categories.top_downloads")
                              subtitle:[NSString stringWithFormat:T(@"categories.napps"), fmtCount([[LocalCatalog shared] uniqueAppCount])]
                              iconURLs:icons colorSeed:@"top_downloads"];
    } else {
        [tile setGlyphImage:AppDropDownloadsGlyph()];
    }
}

#pragma mark Auto-scroll while dragging near an edge

- (void)updateAutoScrollForPoint:(CGPoint)p {
    CGFloat visibleY = p.y - self.scroll.contentOffset.y;
    CGFloat h = self.scroll.bounds.size.height, edge = 70.0;
    CGFloat vel = 0;
    if (visibleY < edge)            vel = -((edge - visibleY) / edge) * 9.0;
    else if (visibleY > h - edge)   vel =  ((visibleY - (h - edge)) / edge) * 9.0;
    self.autoScrollVel = vel;
    if (vel != 0 && !self.autoScrollTimer) {
        self.autoScrollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 target:self
                                    selector:@selector(autoScrollTick) userInfo:nil repeats:YES];
    } else if (vel == 0) {
        [self stopAutoScroll];
    }
}

- (void)autoScrollTick {
    CGFloat maxY = MAX(0, self.scroll.contentSize.height - self.scroll.bounds.size.height);
    CGFloat ny = self.scroll.contentOffset.y + self.autoScrollVel;
    if (ny < 0) ny = 0; if (ny > maxY) ny = maxY;
    if (ny == self.scroll.contentOffset.y) return;
    self.scroll.contentOffset = CGPointMake(0, ny);
    self.draggingTile.center = CGPointMake(self.draggingTile.center.x,
                                           self.draggingTile.center.y + self.autoScrollVel);
}

- (void)stopAutoScroll {
    [self.autoScrollTimer invalidate];
    self.autoScrollTimer = nil;
    self.autoScrollVel = 0;
}

#pragma mark Resize (corner handle → snap to 1×1 / 2×1 / 2×2)

- (void)handleResizePan:(UIPanGestureRecognizer *)gr {
    CategoryTileView *tile = (CategoryTileView *)gr.view.superview;
    if (![tile isKindOfClass:[CategoryTileView class]]) return;
    NSInteger idx = [self.tiles indexOfObject:tile];
    if (idx == NSNotFound) return;
    CGPoint p = [gr locationInView:self.scroll];

    if (gr.state == UIGestureRecognizerStateBegan) {
        self.scroll.scrollEnabled = NO;
        self.resizeTile = tile; self.resizeIndex = idx;
        self.resizeStartFrame = tile.frame;
        self.resizeCurrentSpan = [[HomeLayoutStore shared] spanForItem:self.items[idx][@"id"]]
                                 ?: (self.items[idx][@"defSpan"] ?: @"1x1");
        [self stopJiggle:tile];
        [self.scroll bringSubviewToFront:tile];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        NSString *span = [self snapSpanForResizePoint:p];
        if (![span isEqualToString:self.resizeCurrentSpan]) {
            self.resizeCurrentSpan = span;
            [[HomeLayoutStore shared] setSpan:span forItem:self.items[idx][@"id"]];
            [UIView animateWithDuration:0.16 delay:0
                                options:UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ [self layoutContent]; } completion:nil];
        }
    } else {   // ended / cancelled
        self.scroll.scrollEnabled = YES;
        CategoryTileView *t = self.resizeTile;
        self.resizeTile = nil;
        [UIView animateWithDuration:0.18 animations:^{ [self layoutContent]; }
                         completion:^(BOOL d) { if (self.homeEditing && t) [self startJiggle:t]; }];
    }
}

// The finger's offset from the tile's top-left → one of the 3 allowed spans (snap, widget-style).
- (NSString *)snapSpanForResizePoint:(CGPoint)p {
    CGFloat W = self.view.bounds.size.width, margin = 12, gap = 10;
    NSInteger cols = [CategoryViewController homeColumnsForWidth:W];
    CGFloat tileW = floorf((W - 2*margin - (cols - 1)*gap) / cols);
    CGFloat tileH = floorf(tileW * 0.85);
    CGFloat dw = p.x - self.resizeStartFrame.origin.x;
    CGFloat dh = p.y - self.resizeStartFrame.origin.y;
    BOOL wide = (dw > 1.5 * tileW) && (cols >= 2);
    BOOL tall = (dh > 1.5 * tileH);
    if (wide && tall) return @"2x2";
    if (wide)         return @"2x1";
    return @"1x1";
}

- (void)resetLayoutTapped {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"home.reset_title")
                                                message:T(@"home.reset_msg")
                                               delegate:self
                                      cancelButtonTitle:T(@"common.cancel")
                                      otherButtonTitles:T(@"home.reset"), nil];
    a.tag = 7799;
    [a show];
}

- (void)promptNewFolder {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"folder.new") message:nil
        delegate:self cancelButtonTitle:T(@"common.cancel") otherButtonTitles:T(@"folder.create"), nil];
    if ([a respondsToSelector:@selector(setAlertViewStyle:)]) a.alertViewStyle = UIAlertViewStylePlainTextInput;
    a.tag = 7800;
    [a show];
}

- (void)alertView:(UIAlertView *)av clickedButtonAtIndex:(NSInteger)index {
    if (index == av.cancelButtonIndex) return;
    if (av.tag == 7799) {
        [self exitEditMode];               // restore nav buttons + stop jiggle/handles
        [[HomeLayoutStore shared] reset];
        [self catalogDidUpdate];           // rebuild the grid from the automatic defaults
    } else if (av.tag == 7800) {           // create folder
        NSString *name = [[[av textFieldAtIndex:0] text]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length) [[CollectionStore shared] createFolderNamed:name];   // rebuilds via notification
    } else if (av.tag == 7801) {           // delete folder (⊗ badge confirm)
        NSString *cid = self.pendingDeleteCid;
        self.pendingDeleteCid = nil;
        // deleteCollection: is a no-op on built-ins, and posts CollectionStoreDidChange →
        // catalogDidUpdate rebuilds the grid (folder gone, edit mode cleared).
        if (cid) [[CollectionStore shared] deleteCollection:cid];
    }
}

#pragma mark Gesture delegate

// While editing, a touch that lands on a (visible) resize handle must NOT trigger the long-press —
// let the handle's own pan recognizer take it.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    if (gr != self.longPress || !self.homeEditing) return YES;
    CGPoint p = [touch locationInView:self.scroll];
    // A touch on the (visible) resize handle is for the resize pan, not a drag.
    for (CategoryTileView *t in self.tiles) {
        if (t.resizeHandle.hidden) continue;
        CGRect hf = [t convertRect:t.resizeHandle.frame toView:self.scroll];
        if (CGRectContainsPoint(CGRectInset(hf, -6, -6), p)) return NO;
    }
    // A touch on the (visible) ⊗ delete badge is a delete tap, not the start of a drag —
    // let the button's own action fire instead of beginning a reorder.
    if ([touch.view isKindOfClass:[UIControl class]]) return NO;
    return YES;
}

- (void)gridDensityDidChange {
    if (self.items) [self layoutContent];
}

- (void)dealloc {
    [self.activeUsersTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

@end
