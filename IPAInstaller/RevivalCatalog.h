#import <Foundation/Foundation.h>

// Curated list of apps that ACTUALLY work today on legacy iOS (patched / revival /
// community clients / web apps), loaded from the bundled revival.json. Separate from the
// 157k archived IPAs. See issue #4. Community suggestions arrive via the Feedback feature.
@interface RevivalCatalog : NSObject

+ (instancetype)shared;

// All curated entries (NSDictionary each).
- (NSArray *)allApps;

// Entries whose min_ios <= the running device's iOS (i.e. runnable here).
- (NSArray *)compatibleApps;

// Compatible entries mapped to catalogue-style app dicts (title, icon — pulled from the
// real app's catalogue icon via its bundle id —, url = the direct .ipa, version, minOS,
// bundleId, size). Feed these straight into AppRowCell / AppDetailViewController so revival
// apps look + install exactly like catalogue apps.
- (NSArray *)appDicts;

// The revival entry that replaces a given archived bundle id, or nil. Used to cross-link
// from a (possibly broken) archived app to its working version.
- (NSDictionary *)revivalForBundleId:(NSString *)bid;

@end
