#import <Foundation/Foundation.h>

// Curated list of MODIFIED apps for legacy iOS (games modded for unlimited money, patched/unlocked
// builds, community mods…). Loaded from a hosted mods.json (with a bundled fallback) EXACTLY like
// RevivalCatalog — separate from the 157k archived IPAs. The list is curated by hand; community
// suggestions arrive via the Feedback feature. Content is the maintainer's responsibility.
@interface ModdedCatalog : NSObject

+ (instancetype)shared;

// All curated entries (NSDictionary each).
- (NSArray *)allApps;

// Entries whose min_ios <= the running device's iOS (i.e. runnable here).
- (NSArray *)compatibleApps;

// Compatible entries mapped to catalogue-style app dicts (title, icon, url = direct .ipa, version,
// minOS, bundleId, size, + isModded/modDesc). Feed straight into AppRowCell / AppDetailViewController
// so modded apps look + install exactly like catalogue apps.
- (NSArray *)appDicts;

@end
