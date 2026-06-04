#import <UIKit/UIKit.h>

// The "✅ Works today" screen — lists curated revival/patched/working apps for legacy iOS
// (from RevivalCatalog). Tapping a row installs (IPA) or opens (web/project) the entry.
@interface RevivalListViewController : UITableViewController
// Optional: drive this same screen with a different curated source (e.g. ModdedCatalog). When
// customAppDicts is set it's shown instead of RevivalCatalog, with customTitle / customIntro.
@property (nonatomic, copy) NSArray *customAppDicts;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *customIntro;
// When set (@"mods" or @"revival"), a "Partager une app" button appears under the intro → opens
// the upload screen with that target category (users share apps they have the right to share).
@property (nonatomic, copy) NSString *uploadTarget;
@end
