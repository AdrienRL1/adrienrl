#import <UIKit/UIKit.h>

@interface VersionsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithBundleId:(NSString *)bundleId title:(NSString *)title;
// #171: an EXPLICIT version list (Works Today / Modded grouped uploads — these versions live in
// revival.json/mods.json, not the SQLite catalogue, so there's no bundleId to query). Each element
// is a full app dict (title/icon/url/version/minOS/size/fileName/isRevival|isModded/…).
- (instancetype)initWithVersions:(NSArray *)versions title:(NSString *)title;
@end
