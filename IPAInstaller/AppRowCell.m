#import "AppRowCell.h"
#import "AppTileView.h"
#import "IOS6Theme.h"

@interface AppRowCell ()
@property (nonatomic, strong) NSMutableArray *tiles;
@property (nonatomic, copy) NSArray *appsCache;
@end

@implementation AppRowCell

+ (double)gridDensity {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    double density = ([d objectForKey:@"IPAInstall.GridDensity"] != nil)
        ? [d doubleForKey:@"IPAInstall.GridDensity"] : 0.55;  // default ≈ 165 pt tiles
    if (density < 0) density = 0;
    if (density > 1) density = 1;
    return density;
}

+ (NSInteger)tilesPerRowForWidth:(CGFloat)w {
    if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad) return 1;
    // dense(1) = 88 pt tiles (many, tiny) … sparse(0) = 240 pt tiles (few, large).
    CGFloat tileW = 240.0 - [self gridDensity] * 152.0;
    NSInteger n = MAX(2, (NSInteger)(w / tileW));
    return MIN(n, 12);   // was 8 — allow denser grids per user request
}

// Row height tracks the density so tiles shrink in BOTH dimensions, not just width.
// dense(1) = 118 pt … sparse(0) = 196 pt.
+ (CGFloat)gridRowHeight {
    if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad) return 76;
    return 196.0 - [self gridDensity] * 78.0;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        // Opaque page-coloured cell — the gaps between tiles don't blend at scroll time.
        UIColor *bg = [IOS6Theme contentBackgroundColor];
        self.opaque = YES;
        self.backgroundColor = bg;
        self.contentView.opaque = YES;
        self.contentView.backgroundColor = bg;
        // Flatten the whole row (up to ~11 tiles × several layers each) into ONE cached
        // bitmap. While a row stays on screen it then composites as a single opaque layer
        // instead of dozens — the decisive win for the old A6X / iPad 1 GPU. CA re-renders
        // a row only when its content actually changes (on cell reuse), which during a
        // fling is just the 1–2 rows entering from the edge, not every visible row.
        self.contentView.layer.shouldRasterize = YES;
        self.contentView.layer.rasterizationScale = [UIScreen mainScreen].scale;
        self.tiles = [NSMutableArray array];
        self.tilesPerRow = 4;
    }
    return self;
}

- (void)ensureTileCount {
    while ((NSInteger)self.tiles.count < self.tilesPerRow) {
        AppTileView *t = [[AppTileView alloc] initWithFrame:CGRectZero];
        __weak typeof(self) ws = self;
        t.onTap = ^(NSDictionary *app) {
            if (ws.onTileTap) ws.onTileTap(app);
        };
        [self.tiles addObject:t];
        [self.contentView addSubview:t];
    }
    while ((NSInteger)self.tiles.count > self.tilesPerRow) {
        AppTileView *t = [self.tiles lastObject];
        [t removeFromSuperview];
        [self.tiles removeLastObject];
    }
}

- (void)setApps:(NSArray *)apps {
    self.appsCache = apps;
    [self ensureTileCount];
    for (NSInteger i = 0; i < self.tilesPerRow; i++) {
        AppTileView *t = self.tiles[i];
        t.selectionMode = self.selectionMode;
        NSDictionary *appI = (i < (NSInteger)apps.count) ? apps[i] : nil;
        // Pull selection state from the controller's block (source of truth).
        // This re-runs on every reuse, so far-away selections are reflected
        // correctly when the cell scrolls back into view.
        t.tileSelected = appI && self.isAppSelectedBlock
            ? self.isAppSelectedBlock(appI) : NO;
        t.app = appI;  // setting last so all flags above are visible at layout time
    }
    [self setNeedsLayout];
}

- (void)setSelectionMode:(BOOL)selectionMode {
    if (_selectionMode == selectionMode) return;
    _selectionMode = selectionMode;
    for (AppTileView *t in self.tiles) t.selectionMode = selectionMode;
}

- (void)setTilesPerRow:(NSInteger)n {
    if (_tilesPerRow == n) return;
    _tilesPerRow = MAX(1, n);
    [self ensureTileCount];
    [self setNeedsLayout];
}

- (void)setContentRasterized:(BOOL)on {
    if (self.contentView.layer.shouldRasterize == on) return;
    self.contentView.layer.shouldRasterize = on;
    if (on) self.contentView.layer.rasterizationScale = [UIScreen mainScreen].scale;
}

- (void)redrawTiles {
    for (AppTileView *t in self.tiles) [t setNeedsDisplay];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat outerPad = 8;
    CGFloat gap = 8;
    NSInteger n = self.tilesPerRow;
    CGFloat available = b.size.width - outerPad * 2 - gap * (n - 1);
    CGFloat tileWf = available / (CGFloat)n;        // fractional ideal width
    CGFloat top = outerPad;
    CGFloat tileH = round(b.size.height - outerPad * 2);
    for (NSInteger i = 0; i < self.tilesPerRow; i++) {
        AppTileView *t = self.tiles[i];
        // Snap each tile's LEFT and RIGHT edge to whole points. With a fractional tile
        // width the rounded-card's 1px border lands between pixels and resamples into a
        // faint "double line" on the right of every tile (made worse by the row's
        // shouldRasterize, which bakes the blur in). Whole-point edges → integer widths →
        // the cached card bitmap is drawn 1:1, so the border stays crisp with no seam.
        CGFloat leftf = outerPad + i * (tileWf + gap);
        CGFloat left  = round(leftf);
        CGFloat right = round(leftf + tileWf);
        t.frame = CGRectMake(left, top, right - left, tileH);
    }
}

@end
