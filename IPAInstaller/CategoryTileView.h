#import <UIKit/UIKit.h>

// A single tappable card used on the category home screen.
//  - Grid style (default): icon on top, name + count centered below.
//  - Wide/banner style: icon left, name + subtitle left-aligned, chevron right
//    (used for the "All apps" / "Show everything" entry).
// iOS 5+ safe (plain UIView + UIScrollView layout, no UICollectionView).
@interface CategoryTileView : UIView

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

// Set a drawn glyph directly (cancels any pending URL load). Used for the "Works today"
// banner so it shows a real icon instead of an emoji/placeholder letter.
- (void)setGlyphImage:(UIImage *)img;

@end
