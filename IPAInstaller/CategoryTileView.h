#import <UIKit/UIKit.h>
#import "IOS6Theme.h"

// A single tappable card used on the category home screen.
//  - Grid style (default): icon on top, name + count centered below.
//  - Wide/banner style: icon left, name + subtitle left-aligned, chevron right
//    (used for the "All apps" / "Show everything" entry).
// iOS 5+ safe (plain UIView + UIScrollView layout, no UICollectionView).
@interface CategoryTileView : UIView <ADThemable>

@property (nonatomic, assign) BOOL wide;            // set BEFORE configure
@property (nonatomic, copy) void (^onTap)(void);

// `iconURL` may be nil/empty -> a colored placeholder (first letter of colorSeed) is drawn.
// `colorSeed` drives the placeholder colour/letter (pass the English category name for
// a stable colour); pass nil on the "All apps" banner to get the branded grid glyph.
- (void)configureWithLabel:(NSString *)label
                  subtitle:(NSString *)subtitle
                   iconURL:(NSString *)iconURL
                 colorSeed:(NSString *)colorSeed;

// Swap to a new icon WITHOUT flashing the placeholder — keeps the current image
// visible until the new one is decoded. Used to vary the icon on each visit.
- (void)reshuffleIconURL:(NSString *)iconURL;

// MOSAIC mode: show a 2×2 collage built from a POOL of app-icon URLs (used by category cards and
// favourites/folder tiles). Picks up to 4 at random, composites them as they decode, and fills
// any empty cells (collections with < 4 apps) with a neutral placeholder. 0 URLs → letter glyph,
// 1 URL → a single icon. Call -reshuffleMosaic to re-pick on each return to the Home tab.
- (void)configureMosaicWithLabel:(NSString *)label
                        subtitle:(NSString *)subtitle
                        iconURLs:(NSArray *)iconURLs
                       colorSeed:(NSString *)colorSeed;
- (void)reshuffleMosaic;

// Set a drawn glyph directly (cancels any pending URL load). Used for the "Works today"
// banner so it shows a real icon instead of an emoji/placeholder letter.
- (void)setGlyphImage:(UIImage *)img;

// Bottom-right resize grip, shown only in the Home edit mode (drag it to change the tile's span).
// The owning view controller attaches a pan recognizer to it.
@property (nonatomic, strong, readonly) UIImageView *resizeHandle;
- (void)setShowResizeHandle:(BOOL)show;

// Top-left delete badge (iOS-home-screen style ⊗), shown only in Home edit mode on removable tiles
// (user-created folders). Tapping it calls onDelete. Built-in tiles never show it.
@property (nonatomic, copy) void (^onDelete)(void);
- (void)setShowDeleteBadge:(BOOL)show;

@end
