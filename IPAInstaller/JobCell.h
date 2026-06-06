#import <UIKit/UIKit.h>
@class InstallJob;

@interface JobCell : UITableViewCell
@property (nonatomic, strong, readonly) UILabel *nameLabel;
@property (nonatomic, strong, readonly) UILabel *messageLabel;
// iOS 3.1.3 has no UIProgressView track/progress tint (those are iOS 5+ APIs),
// so the progress bar is a custom track+fill made of plain UIViews. See JobCell.m.
@property (nonatomic, strong, readonly) UIView *progressBar;
- (void)configureWithJob:(InstallJob *)job;
@end
