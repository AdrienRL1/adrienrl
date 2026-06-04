#import "AppRowCell.h"
#import "AppTileView.h"
#import "IOS6Theme.h"

@interface AppRowCell ()
@property (nonatomic, strong) NSMutableArray *tiles;
@property (nonatomic, copy) NSArray *appsCache;
@end

@implementation AppRowCell

// v3.0: the catalogue grid is configured by an explicit COLUMN COUNT (chosen via the native wheel
// picker in Settings → Affichage), not a 0–1 density. Idiom-aware default: iPhone 1 = single-column
// LIST (the historical layout), iPad 4 = grid. Stored per-device in IPAInstall.GridColumns.
+ (NSInteger)gridColumns {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL pad = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
    NSInteger def = pad ? 4 : 1;
    NSInteger n = ([d objectForKey:@"IPAInstall.GridColumns"] != nil)
        ? [d integerForKey:@"IPAInstall.GridColumns"] : def;
    if (n < 1)  n = 1;
    if (n > 12) n = 12;
    return n;
}

+ (NSInteger)tilesPerRowForWidth:(CGFloat)w {
    if (w < 1) w = [UIScreen mainScreen].bounds.size.width;
    NSInteger n = [self gridColumns];
    BOOL pad = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
    // Never make tiles absurdly small for the width: cap at however many ~76 pt tiles fit.
    NSInteger maxFit = (NSInteger)(w / 76.0);
    NSInteger floorCols = pad ? 2 : 1;   // iPad is always a grid (≥2); iPhone can be a 1-col list
    if (maxFit < floorCols) maxFit = floorCols;
    if (n < floorCols) n = floorCols;
    if (n > maxFit) n = maxFit;
    return n;
}

// Row height for a given table width. Single-column (list) rows are a fixed 76 pt; grid rows scale
// with the ACTUAL tile width (w / columns) so tiles shrink in BOTH dimensions as columns rise.
+ (CGFloat)gridRowHeightForWidth:(CGFloat)w {
    if (w < 1) w = [UIScreen mainScreen].bounds.size.width;
    NSInteger n = [self tilesPerRowForWidth:w];
    if (n <= 1) return 76;   // single-column list row (CatalogAppCell)
    CGFloat tileW = w / (CGFloat)n;
    CGFloat h = tileW * 0.42 + 82.0;   // ≈ the old iPad proportions (4-up → ~163, 8-up → ~122)
    if (h < 96)  h = 96;
    if (h > 230) h = 230;
    return h;
}

// Convenience using the main-screen (portrait) width. iPad grid height is width-independent so
// this stays exact there; iPhone callers that have the live table width should pass it instead.
+ (CGFloat)gridRowHeight {
    return [self gridRowHeightForWidth:[UIScreen mainScreen].bounds.size.width];
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
        // NOTE: row-level layer rasterization was removed. It only ran AT REST (scrolling was already
        // plain), so it gave ~no scroll benefit, but its cached bitmap wasn't invalidated when a tile's
        // selection badge / themed card changed → the badge only appeared after a rotation. Compositing
        // the (opaque, cached-card) tiles live is cheap at rest and correct.
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
    // Refresh the page colour (the gaps between tiles) on every reuse so a live theme switch
    // recolours the row — init only runs once, but reloadData re-runs setApps.
    UIColor *bg = [IOS6Theme contentBackgroundColor];
    self.backgroundColor = bg;
    self.contentView.backgroundColor = bg;
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
    _selectionMode = selectionMode;
    for (AppTileView *t in self.tiles) t.selectionMode = selectionMode;
}

- (void)setTilesPerRow:(NSInteger)n {
    if (_tilesPerRow == n) return;
    _tilesPerRow = MAX(1, n);
    [self ensureTileCount];
    [self setNeedsLayout];
}

// Kept as a no-op so the controllers' scroll handlers still compile; rasterization was removed
// (see init) because its cached bitmap broke live selection-badge / theme updates.
- (void)setContentRasterized:(BOOL)on { (void)on; }

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
