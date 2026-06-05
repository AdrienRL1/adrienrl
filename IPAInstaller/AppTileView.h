#import <UIKit/UIKit.h>

// Single app "tile" used in the iPad grid catalog.
// Designed for GPU efficiency: opaque, no offscreen rendering, no layer effects.
// Background image is pre-rendered once and shared across tiles.
@interface AppTileView : UIView

@property (nonatomic, copy) NSDictionary *app;
@property (nonatomic, copy) void (^onTap)(NSDictionary *app);

// #171: how many tiles per row this tile lives in (set by AppRowCell). Drives the "name only"
// rule: iPad ≥5 columns, or iPhone ≥3 columns → drop the meta line under the icon (it doesn't
// display well at that size), keep just the app name.
@property (nonatomic, assign) NSInteger columnCount;

// v2.0.30: the quick-install button overlay was removed entirely. The user
// installs apps via the detail view's "Installer" button or by multi-select
// + the bottom toolbar. Selection mode still shows a check overlay.
@property (nonatomic, assign) BOOL selectionMode;
@property (nonatomic, assign) BOOL tileSelected;

// During a FAST fling, tiles skip drawing their text (unreadable at that speed anyway) so the
// main thread isn't laying out text on every recycled tile. Set NO + redraw when scrolling
// settles. Icons (separate composited layer) keep showing throughout.
+ (void)setSuppressTileText:(BOOL)suppress;

@end
