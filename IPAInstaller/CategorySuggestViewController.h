#import <UIKit/UIKit.h>

// #156: let the user propose the correct category + subgenre for an app. The proposal is sent
// to the moderation Worker (POST /category) and only takes effect after the admin approves it.
@interface CategorySuggestViewController : UITableViewController
- (instancetype)initWithBundleId:(NSString *)bid name:(NSString *)name;

// "Pick mode": same themed category/subgenre radio picker, but instead of POSTing a suggestion it
// just returns the choice via `onPick` (subgenre = @"" when the category has none). Used by the
// upload form to choose a category for a brand-new "catalog" app. `cat`/`sub` preselect.
- (instancetype)initForPickingCategory:(NSString *)cat subgenre:(NSString *)sub;
@property (nonatomic, copy) void (^onPick)(NSString *category, NSString *subgenre);
@end
