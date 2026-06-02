#import <UIKit/UIKit.h>

@interface AppDetailViewController : UIViewController
@property (nonatomic, copy) NSDictionary *app;
// Default initializer: auto-switches to the latest version this device can run.
- (instancetype)initWithApp:(NSDictionary *)app;
// allowVersionSwitch=NO keeps the EXACT version passed (used by the Versions menu,
// where the user explicitly chose a build).
- (instancetype)initWithApp:(NSDictionary *)app allowVersionSwitch:(BOOL)allow;
@end
