#import <UIKit/UIKit.h>

// One table row that holds N app tiles laid out horizontally. Used on iPad to make a grid.
@interface AppRowCell : UITableViewCell

@property (nonatomic, assign) NSInteger tilesPerRow;
@property (nonatomic, copy) void (^onTileTap)(NSDictionary *app);

// Selection support (multi-select install batch).
// In selectionMode: tiles draw a checkbox overlay and onTileTap is used as
// "toggle selection". The checkbox state is read each layout via isAppSelectedBlock
// so updates from far-away taps still reflect correctly when scrolled back.
// In default mode: onTileTap navigates to the detail screen.
@property (nonatomic, assign) BOOL selectionMode;
@property (nonatomic, copy) BOOL (^isAppSelectedBlock)(NSDictionary *app);

- (void)setApps:(NSArray *)apps;

// How many app tiles fit across `w` points — the chosen column count (IPAInstall.GridColumns,
// set by the wheel picker in Settings), clamped so tiles never get absurdly small for the width.
// v3.0: works on BOTH idioms — n==1 means single-column LIST (iPhone default), n≥2 means a
// packed grid (iPad default). Catalogue + Recherche share it.
+ (NSInteger)tilesPerRowForWidth:(CGFloat)w;

// The raw chosen column count (IPAInstall.GridColumns), idiom-aware default (iPhone 1 = list,
// iPad 4 = grid), clamped 1…12. This is what the Settings row + wheel show (before width clamping).
+ (NSInteger)gridColumns;

// Density-aware row height for a given table width. Single-column (list) rows are a fixed 76 pt;
// grid rows scale with the tile size. Prefer this over -gridRowHeight where the live width is known.
+ (CGFloat)gridRowHeightForWidth:(CGFloat)w;

// Convenience: row height using the main-screen (portrait) width. iPad grid height is
// width-independent, so this stays exact there; iPhone callers should pass the live width.
+ (CGFloat)gridRowHeight;

// Toggle the row's flatten-to-bitmap rasterization. Keep it ON at rest (cheap static
// compositing) but turn it OFF during active scrolling so recycled rows don't pay a
// re-rasterization spike on every recycle — the main fling-jank source on the old A6X GPU.
- (void)setContentRasterized:(BOOL)on;

// Force every tile in this row to repaint (e.g. to bring text back after a fast fling).
- (void)redrawTiles;
@end
