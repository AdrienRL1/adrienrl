#import <UIKit/UIKit.h>

// Reusable "add to folder" chooser: shows an action sheet of the user's folders + "New folder…",
// (and creates the folder via a text prompt when needed), then calls `completion` with the chosen
// collection id — or nil if cancelled. iOS 5+ safe (UIActionSheet + UIAlertViewStylePlainTextInput).
@interface FolderPicker : NSObject

+ (void)presentAddToFolderFrom:(UIViewController *)vc
                    completion:(void (^)(NSString *collectionId))completion;

@end
