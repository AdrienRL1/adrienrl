#import <UIKit/UIKit.h>

// Minimal iOS 5/6-safe file browser to pick an .ipa to share. Presented modally (in its own
// nav controller). With directory==nil it shows a list of useful starting points (shortcuts);
// otherwise it lists the sub-folders + .ipa files of `directory`, pushing a child picker per
// folder. onPick is called with the chosen absolute path; the picker then dismisses itself.
@interface FilePickerViewController : UITableViewController
@property (nonatomic, copy) NSString *directory;            // nil = shortcuts root
@property (nonatomic, copy) void (^onPick)(NSString *path);
- (instancetype)initWithDirectory:(NSString *)dir;
@end
