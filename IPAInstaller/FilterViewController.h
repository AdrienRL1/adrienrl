#import <UIKit/UIKit.h>
#import "CatalogFilter.h"

@protocol FilterViewControllerDelegate;

@interface FilterViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) CatalogFilter *filter;
@property (nonatomic, assign) id<FilterViewControllerDelegate> delegate;  // MRC: non-zeroing weak (was weak under ARC)
@end

@protocol FilterViewControllerDelegate <NSObject>
- (void)filterViewController:(FilterViewController *)vc didSaveFilter:(CatalogFilter *)filter;
- (void)filterViewControllerDidCancel:(FilterViewController *)vc;
@end
