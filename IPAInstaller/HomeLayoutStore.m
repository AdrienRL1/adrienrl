#import "HomeLayoutStore.h"

static NSString *const kPinnedKey   = @"AppDrop.HomePinned";
static NSString *const kUnpinnedKey = @"AppDrop.HomeUnpinned";
static NSString *const kSpansKey    = @"AppDrop.HomeSpans";

@implementation HomeLayoutStore

+ (instancetype)shared {
    static HomeLayoutStore *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[HomeLayoutStore alloc] init]; });
    return s;
}

- (NSArray *)savedArray:(NSString *)key {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:key];
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}
- (NSDictionary *)spansDict {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSpansKey];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

- (void)resolveItems:(NSArray *)items
          intoPinned:(NSMutableArray *)pinnedIds
            unpinned:(NSMutableArray *)unpinnedIds {
    NSArray *savedP = [self savedArray:kPinnedKey];
    NSArray *savedU = [self savedArray:kUnpinnedKey];

    NSMutableSet *present = [NSMutableSet set];
    NSMutableDictionary *defPinned = [NSMutableDictionary dictionary];
    for (NSDictionary *it in items) {
        NSString *iid = it[@"id"];
        if (!iid) continue;
        [present addObject:iid];
        defPinned[iid] = @([it[@"defaultPinned"] boolValue]);
    }

    [pinnedIds removeAllObjects];
    [unpinnedIds removeAllObjects];
    NSMutableSet *placed = [NSMutableSet set];

    // 1) saved pinned still present, in saved order
    for (NSString *iid in savedP)
        if ([present containsObject:iid] && ![placed containsObject:iid]) {
            [pinnedIds addObject:iid]; [placed addObject:iid];
        }
    // 2) saved unpinned still present
    for (NSString *iid in savedU)
        if ([present containsObject:iid] && ![placed containsObject:iid]) {
            [unpinnedIds addObject:iid]; [placed addObject:iid];
        }
    // 3) new items → their default zone, appended in the items' natural order
    for (NSDictionary *it in items) {
        NSString *iid = it[@"id"];
        if (!iid || [placed containsObject:iid]) continue;
        if ([defPinned[iid] boolValue]) [pinnedIds addObject:iid];
        else                            [unpinnedIds addObject:iid];
        [placed addObject:iid];
    }
}

- (void)savePinned:(NSArray *)pinnedIds unpinned:(NSArray *)unpinnedIds {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:(pinnedIds ?: @[]) forKey:kPinnedKey];
    [d setObject:(unpinnedIds ?: @[]) forKey:kUnpinnedKey];
    [d synchronize];
}

- (NSString *)spanForItem:(NSString *)itemId {
    NSString *s = [self spansDict][itemId];
    return [s isKindOfClass:[NSString class]] ? s : nil;
}
- (void)setSpan:(NSString *)span forItem:(NSString *)itemId {
    if (!itemId) return;
    NSMutableDictionary *m = [[self spansDict] mutableCopy];
    if (span) m[itemId] = span; else [m removeObjectForKey:itemId];
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:kSpansKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)hasCustomLayout {
    return [self savedArray:kPinnedKey].count > 0
        || [self savedArray:kUnpinnedKey].count > 0
        || [self spansDict].count > 0;
}

- (void)reset {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kPinnedKey];
    [d removeObjectForKey:kUnpinnedKey];
    [d removeObjectForKey:kSpansKey];
    [d synchronize];
}

@end
