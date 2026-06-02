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

// Shared grid density: how many tiles fit across `w` points. iPhone always 1.
// On iPad it reads the "IPAInstall.GridDensity" pref (0…1, set by the Settings
// slider) so Catalogue, Recherche and Catégories stay in sync.
+ (NSInteger)tilesPerRowForWidth:(CGFloat)w;

// The current density pref (0…1), clamped. iPad slider value.
+ (double)gridDensity;

// Density-aware row height for the iPad tile grid (so tiles shrink in both
// dimensions). iPhone returns the fixed list row height (76).
+ (CGFloat)gridRowHeight;

// Toggle the row's flatten-to-bitmap rasterization. Keep it ON at rest (cheap static
// compositing) but turn it OFF during active scrolling so recycled rows don't pay a
// re-rasterization spike on every recycle — the main fling-jank source on the old A6X GPU.
- (void)setContentRasterized:(BOOL)on;

// Force every tile in this row to repaint (e.g. to bring text back after a fast fling).
- (void)redrawTiles;
@end
