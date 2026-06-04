#import "CollectionStore.h"
#import "Localization.h"

NSString * const CollectionStoreDidChangeNotification = @"CollectionStoreDidChangeNotification";
NSString * const CollectionFavoritesId = @"favorites";
NSString * const CollectionLaterId = @"later";

@interface CollectionStore ()
@property (nonatomic, strong) NSMutableArray *cols;   // NSMutableDictionary, favorites first
@end

@implementation CollectionStore

+ (instancetype)shared {
    static CollectionStore *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[CollectionStore alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) { [self load]; }
    return self;
}

#pragma mark - Persistence

static NSString *storePath(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [dir stringByAppendingPathComponent:@"collections.plist"];
}

- (void)load {
    self.cols = [NSMutableArray array];
    NSArray *raw = [NSArray arrayWithContentsOfFile:storePath()];
    for (NSDictionary *c in raw) {
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *mc = [c mutableCopy];
        NSMutableArray *apps = [NSMutableArray array];
        for (NSDictionary *a in (c[@"apps"] ?: @[]))
            if ([a isKindOfClass:[NSDictionary class]]) [apps addObject:a];
        mc[@"apps"] = apps;
        [self.cols addObject:mc];
    }
    // Guarantee the built-in Favoris collection exists and sits first.
    NSMutableDictionary *fav = (NSMutableDictionary *)[self collectionForId:CollectionFavoritesId];
    if (!fav) {
        fav = [@{ @"id": CollectionFavoritesId, @"name": @"", @"builtin": @YES,
                  @"apps": [NSMutableArray array] } mutableCopy];
        [self.cols insertObject:fav atIndex:0];
    } else if (self.cols[0] != fav) {
        [self.cols removeObject:fav];
        [self.cols insertObject:fav atIndex:0];
    }
    // Guarantee the built-in "Télécharger plus tard" queue exists (just after Favoris).
    if (![self collectionForId:CollectionLaterId]) {
        NSMutableDictionary *later = [@{ @"id": CollectionLaterId, @"name": @"", @"builtin": @YES,
                                         @"apps": [NSMutableArray array] } mutableCopy];
        [self.cols insertObject:later atIndex:MIN((NSUInteger)1, self.cols.count)];
    }
}

- (void)saveAndNotify {
    [self.cols writeToFile:storePath() atomically:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:CollectionStoreDidChangeNotification object:nil];
}

// Keep only plist-safe (string / number) scalar fields so a favourite is self-contained + serializable.
- (NSDictionary *)sanitize:(NSDictionary *)app {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (id k in app) {
        if (![k isKindOfClass:[NSString class]]) continue;
        id v = app[k];
        if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) m[k] = v;
    }
    return m;
}

#pragma mark - Keys

+ (NSString *)keyForApp:(NSDictionary *)app {
    if (![app isKindOfClass:[NSDictionary class]]) return nil;
    NSString *b = app[@"bundleId"];
    if ([b isKindOfClass:[NSString class]] && b.length) return b;
    NSString *u = app[@"url"];
    if ([u isKindOfClass:[NSString class]] && u.length) return u;
    NSString *t = app[@"title"];
    if ([t isKindOfClass:[NSString class]] && t.length) return t;
    return nil;
}

#pragma mark - Collections

- (NSArray *)collections { return [self.cols copy]; }

- (NSDictionary *)collectionForId:(NSString *)cid {
    for (NSMutableDictionary *c in self.cols) if ([c[@"id"] isEqual:cid]) return c;
    return nil;
}

- (NSArray *)folders {
    NSMutableArray *f = [NSMutableArray array];
    for (NSDictionary *c in self.cols) if (![c[@"builtin"] boolValue]) [f addObject:c];
    return f;
}

- (NSString *)nameForCollection:(NSString *)cid {
    NSDictionary *c = [self collectionForId:cid];
    if (!c) return @"";
    if ([c[@"builtin"] boolValue])
        return [cid isEqualToString:CollectionLaterId] ? T(@"collections.later") : T(@"collections.favorites");
    return c[@"name"] ?: @"";
}

- (NSArray *)appsInCollection:(NSString *)cid {
    NSDictionary *c = [self collectionForId:cid];
    return c[@"apps"] ?: @[];
}

- (NSInteger)countInCollection:(NSString *)cid {
    return (NSInteger)[[self appsInCollection:cid] count];
}

- (BOOL)collection:(NSString *)cid containsApp:(NSString *)appKey {
    if (!appKey) return NO;
    for (NSDictionary *a in [self appsInCollection:cid])
        if ([[CollectionStore keyForApp:a] isEqual:appKey]) return YES;
    return NO;
}

- (void)addApp:(NSDictionary *)app toCollection:(NSString *)cid {
    NSString *key = [CollectionStore keyForApp:app];
    if (!key) return;
    NSMutableDictionary *col = (NSMutableDictionary *)[self collectionForId:cid];
    if (!col) return;
    NSMutableArray *apps = col[@"apps"];
    for (NSDictionary *a in apps) if ([[CollectionStore keyForApp:a] isEqual:key]) return;   // dedup
    [apps addObject:[self sanitize:app]];
    [self saveAndNotify];
}

- (void)removeAppKey:(NSString *)appKey fromCollection:(NSString *)cid {
    NSMutableDictionary *col = (NSMutableDictionary *)[self collectionForId:cid];
    if (!col) return;
    NSMutableArray *keep = [NSMutableArray array];
    for (NSDictionary *a in (NSArray *)col[@"apps"])
        if (![[CollectionStore keyForApp:a] isEqual:appKey]) [keep addObject:a];
    col[@"apps"] = keep;
    if ([col[@"pinned"] isEqual:appKey]) [col removeObjectForKey:@"pinned"];   // pinned app left → auto
    [self saveAndNotify];
}

#pragma mark - Favoris convenience

- (BOOL)isFavorite:(NSString *)appKey { return [self collection:CollectionFavoritesId containsApp:appKey]; }

- (void)toggleFavorite:(NSDictionary *)app {
    NSString *key = [CollectionStore keyForApp:app];
    if (!key) return;
    if ([self isFavorite:key]) [self removeAppKey:key fromCollection:CollectionFavoritesId];
    else                       [self addApp:app toCollection:CollectionFavoritesId];
}

- (BOOL)isInLater:(NSString *)appKey { return [self collection:CollectionLaterId containsApp:appKey]; }

- (void)toggleLater:(NSDictionary *)app {
    NSString *key = [CollectionStore keyForApp:app];
    if (!key) return;
    if ([self isInLater:key]) [self removeAppKey:key fromCollection:CollectionLaterId];
    else                      [self addApp:app toCollection:CollectionLaterId];
}

#pragma mark - Folders (Phase 4)

- (NSString *)createFolderNamed:(NSString *)name {
    NSString *cid = [NSString stringWithFormat:@"folder_%08x", arc4random()];
    NSMutableDictionary *f = [@{ @"id": cid, @"name": name ?: @"", @"builtin": @NO,
                                 @"apps": [NSMutableArray array] } mutableCopy];
    [self.cols addObject:f];
    [self saveAndNotify];
    return cid;
}

- (void)renameCollection:(NSString *)cid to:(NSString *)name {
    NSMutableDictionary *c = (NSMutableDictionary *)[self collectionForId:cid];
    if (!c || [c[@"builtin"] boolValue]) return;
    c[@"name"] = name ?: @"";
    [self saveAndNotify];
}

- (void)deleteCollection:(NSString *)cid {
    NSMutableDictionary *c = (NSMutableDictionary *)[self collectionForId:cid];
    if (!c || [c[@"builtin"] boolValue]) return;   // can't delete Favoris
    [self.cols removeObject:c];
    [self saveAndNotify];
}

#pragma mark - Pinned preview

- (NSString *)pinnedKeyForCollection:(NSString *)cid {
    NSString *p = [self collectionForId:cid][@"pinned"];
    return [p isKindOfClass:[NSString class]] ? p : nil;
}

- (void)setPinnedKey:(NSString *)appKey forCollection:(NSString *)cid {
    NSMutableDictionary *c = (NSMutableDictionary *)[self collectionForId:cid];
    if (!c) return;
    if (appKey) c[@"pinned"] = appKey;
    else        [c removeObjectForKey:@"pinned"];
    [self saveAndNotify];
}

- (NSArray *)iconPoolForCollection:(NSString *)cid {
    NSString *pinned = [self pinnedKeyForCollection:cid];
    NSMutableArray *pool = [NSMutableArray array];
    NSString *pinnedIcon = nil;
    for (NSDictionary *a in [self appsInCollection:cid]) {
        NSString *icon = a[@"icon"];
        if (![icon isKindOfClass:[NSString class]] || !icon.length) continue;
        if (pinned && [[CollectionStore keyForApp:a] isEqual:pinned]) pinnedIcon = icon;
        else [pool addObject:icon];
    }
    if (pinnedIcon) [pool insertObject:pinnedIcon atIndex:0];   // pinned app's icon first
    return pool;
}

@end
