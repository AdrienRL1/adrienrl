#import <UIKit/UIKit.h>

// v1.7 — Browse the catalogue by category, and (for Games) by subgenre.
// Presented as a scrollable grid of icon cards (iOS 5+ safe, no UICollectionView).
// The actual filtered app list is shown by SearchViewController in "category mode",
// so all the usual Filters (iOS, device, sort) + in-category text search come for free.
@interface CategoryViewController : UIViewController

// nil/empty = show the top-level category list (the Catalogue tab home).
// set (e.g. @"Games") = show that category's subgenres.
@property (nonatomic, copy) NSString *parentCategory;

@end
