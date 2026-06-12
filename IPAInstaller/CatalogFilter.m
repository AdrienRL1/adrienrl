#import "CatalogFilter.h"
#import <UIKit/UIKit.h>
#import "Localization.h"

static NSString *const kKey = @"IPAInstall.CatalogFilter";

@implementation CatalogFilter

// Device class enforced based on hardware: iPhone/iPod *cannot* run iPad-only apps,
// so we force "iphone" for them. iPad can run iPhone apps (compatibility mode), so it
// gets "all" by default and the filter UI lets the user narrow down.
+ (NSString *)defaultDeviceClass {
    BOOL isPad = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad);
    return isPad ? @"all" : @"iphone";
}

// Default sort direction per sort key. Picked to match user intuition:
//   recent → DESC (newest first)
//   name   → ASC  (A → Z)
//   size   → DESC (biggest first)
//   minos  → ASC  (oldest required iOS first)
+ (BOOL)defaultDescendingForSort:(NSString *)sort {
    if ([sort isEqualToString:@"name"]) return NO;
    if ([sort isEqualToString:@"minos"]) return NO;
    return YES;  // recent / size / downloads / default → plus grand d'abord
}

+ (instancetype)defaultFilter {
    CatalogFilter *f = [[CatalogFilter alloc] init];
    f.minIOS = @"";
    f.maxIOS = [[UIDevice currentDevice] systemVersion] ?: @"";
    f.uniqueOnly = YES;
    // Default = name A-Z. "recent" used to be default but the upstream catalog has
    // a large tail of garbage rows in the recent slots; alphabetical hides this tail
    // behind a cleaner first page.
    f.sort = @"name";
    f.sortDescending = [self defaultDescendingForSort:f.sort];
    f.deviceClass = [self defaultDeviceClass];
    return f;
}

+ (instancetype)load_ {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kKey];
    if (!d) return [self defaultFilter];
    CatalogFilter *f = [[CatalogFilter alloc] init];
    f.minIOS = d[@"minIOS"] ?: @"";
    f.maxIOS = d[@"maxIOS"] ?: ([[UIDevice currentDevice] systemVersion] ?: @"");
    f.uniqueOnly = [d[@"unique"] boolValue];
    f.sort = d[@"sort"] ?: @"recent";
    // Device class : if saved as "all"/"ipad" on a device that is currently an iPhone,
    // force back to "iphone" (the user might have moved their NSUserDefaults from an iPad
    // to an iPhone via iTunes backup or similar — iPad apps still won't run).
    NSString *savedDC = d[@"deviceClass"];
    if ([UIDevice currentDevice].userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        f.deviceClass = @"iphone";
    } else {
        f.deviceClass = savedDC.length ? savedDC : @"all";
    }
    // Default sort changed to "name" in v2.0.8 (was "recent"). Existing users keep
    // their saved choice if they saved at `_v >= 4`; otherwise we override with the
    // new default. `_v < 4` users also haven't seen the sort-direction toggle, so we
    // compute a sane default from the sort key.
    NSInteger savedV = [d[@"_v"] integerValue];
    if (savedV >= 4) {
        f.sortDescending = [d[@"sortDescending"] boolValue];
    } else {
        f.sort = @"name";
        f.sortDescending = [CatalogFilter defaultDescendingForSort:f.sort];
    }
    return f;
}

- (void)save {
    NSDictionary *d = @{
        @"_v": @4,
        @"minIOS": self.minIOS ?: @"",
        @"maxIOS": self.maxIOS ?: @"",
        @"unique": @(self.uniqueOnly),
        @"sort": self.sort ?: @"name",
        @"sortDescending": @(self.sortDescending),
        @"deviceClass": self.deviceClass ?: @"all",
    };
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:kKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (id)copyWithZone:(NSZone *)zone {
    CatalogFilter *f = [[CatalogFilter alloc] init];
    f.minIOS = [self.minIOS copy];
    f.maxIOS = [self.maxIOS copy];
    f.uniqueOnly = self.uniqueOnly;
    f.sort = [self.sort copy];
    f.sortDescending = self.sortDescending;
    f.deviceClass = [self.deviceClass copy];
    return f;
}

- (NSString *)pct:(NSString *)s {
    return [s stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"";
}

- (NSString *)queryStringWithSearch:(NSString *)q offset:(NSInteger)offset limit:(NSInteger)limit {
    NSMutableArray *parts = [NSMutableArray array];
    if (q.length) [parts addObject:[NSString stringWithFormat:@"q=%@", [self pct:q]]];
    if (self.minIOS.length) [parts addObject:[NSString stringWithFormat:@"min_ios=%@", [self pct:self.minIOS]]];
    if (self.maxIOS.length) [parts addObject:[NSString stringWithFormat:@"max_ios=%@", [self pct:self.maxIOS]]];
    if (self.uniqueOnly) [parts addObject:@"unique=true"];
    if (self.sort.length) [parts addObject:[NSString stringWithFormat:@"sort=%@", [self pct:self.sort]]];
    [parts addObject:[NSString stringWithFormat:@"offset=%ld", (long)offset]];
    [parts addObject:[NSString stringWithFormat:@"limit=%ld", (long)limit]];
    return [parts componentsJoinedByString:@"&"];
}

- (NSString *)humanDescription {
    NSMutableArray *p = [NSMutableArray array];
    if (self.minIOS.length || self.maxIOS.length) {
        NSString *lo = self.minIOS.length ? self.minIOS : @"…";
        NSString *hi = self.maxIOS.length ? self.maxIOS : @"…";
        [p addObject:[NSString stringWithFormat:@"iOS %@ → %@", lo, hi]];
    } else {
        [p addObject:T(@"filter.all_versions")];
    }
    if (self.uniqueOnly) [p addObject:T(@"filter.unique")];
    NSDictionary *sortMap = @{
        @"recent":    T(@"catalog.short.recent"),
        @"name":      T(@"catalog.short.name"),
        @"size":      T(@"catalog.short.size"),
        @"minos":     T(@"catalog.short.minos"),
        @"downloads": T(@"catalog.short.downloads"),
    };
    NSString *sortLabel = sortMap[self.sort] ?: self.sort;
    [p addObject:[NSString stringWithFormat:T(@"filter.sort_label"), sortLabel]];
    return [p componentsJoinedByString:@" • "];
}

@end
