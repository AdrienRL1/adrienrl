#import <UIKit/UIKit.h>

// v1.7 — Browse the catalogue by category, and (for Games) by subgenre.
// Presented as a scrollable grid of icon cards (iOS 5+ safe, no UICollectionView).
// The actual filtered app list is shown by SearchViewController in "category mode",
// so all the usual Filters (iOS, device, sort) + in-category text search come for free.
@interface CategoryViewController : UIViewController

// nil/empty = show the top-level category list (the Catalogue tab home).
// set (e.g. @"Games") = show that category's subgenres.
@property (nonatomic, copy) NSString *parentCategory;

// v3.0: number of Accueil/category grid columns for the current width (the chosen IPAInstall.HomeColumns
// clamped to what fits). Exposed so SettingsViewController drives the same value via the wheel picker.
+ (NSInteger)homeColumnsForWidth:(CGFloat)w;

// The raw chosen Accueil column count (IPAInstall.HomeColumns), idiom-aware default (iPhone 2, iPad 4),
// clamped 2…8. This is what the Settings row + wheel show (before width clamping).
+ (NSInteger)homeColumns;

@end
