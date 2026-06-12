// AppDropCache.m — NSCache replacement for iOS 3.x / armv6.
//
// NSCache debuts in iOS 4.0. The 5.1 SDK declares it (so call sites compile),
// but on a real iOS 3.1.3 device the class symbol is weak-imported and binds to
// NULL, so `[[NSCache alloc] init]` sends +alloc to a nil class and returns nil.
// AppDrop's IconLoader keeps every decoded icon in an NSCache; with the cache
// nil, -objectForKey: always misses and -setObject:forKey:cost: is a no-op, so
// every scroll re-reads + re-decodes icons from disk (visible stutter) and, in
// the worst case, the dead RAM tier leaves icons looking like they "never load"
// next to the iOS 6 build.
//
// ADCache is a complete, self-contained NSCache work-alike built only on
// iOS-2-era Foundation (NSMutableDictionary + @synchronized). It implements the
// subset of the API AppDrop uses — -objectForKey:, -setObject:forKey:,
// -setObject:forKey:cost:, -removeObjectForKey:, -removeAllObjects, plus the
// countLimit / totalCostLimit properties — with simple LRU eviction so both
// limits are actually honoured (real NSCache eviction is unspecified; LRU is a
// strict, predictable superset that behaves well for an icon cache).
//
// AppDropCompat.h macro-rewrites every `NSCache` token in the AppDrop sources to
// ADCache, so there are zero call-site edits and identical behaviour on iOS 3.1
// through 10 — the same strategy as ADBezierPath / ADBlockOperation / the
// gesture recognizers. This file #undefs the macro so its @implementation keeps
// the real ADCache name.
//
// Compiled MRC (-fno-objc-arc), like the rest of the compat layer.

#import "AppDropCompat.h"
#undef NSCache

@interface ADCache ()
{
    NSMutableDictionary *_store;        // key -> value (retained)
    NSMutableDictionary *_costs;        // key -> NSNumber(cost)
    NSMutableArray      *_order;        // keys, oldest (LRU) first … newest last
    NSUInteger           _totalCost;
}
@end

@implementation ADCache

@synthesize name = _name;
@synthesize countLimit = _countLimit;
@synthesize totalCostLimit = _totalCostLimit;
@synthesize delegate = _delegate;
@synthesize evictsObjectsWithDiscardedContent = _evictsObjectsWithDiscardedContent;

- (id)init {
    if ((self = [super init])) {
        _store = [[NSMutableDictionary alloc] init];
        _costs = [[NSMutableDictionary alloc] init];
        _order = [[NSMutableArray alloc] init];
        _totalCost = 0;
        _countLimit = 0;        // 0 == no limit, matching NSCache
        _totalCostLimit = 0;    // 0 == no limit, matching NSCache
    }
    return self;
}

- (void)dealloc {
    [_store release];
    [_costs release];
    [_order release];
    [_name release];
    [super dealloc];
}

// Mark `key` as most-recently-used. Caller must hold the lock.
- (void)ad_touchKey:(id)key {
    NSUInteger idx = [_order indexOfObject:key];
    if (idx != NSNotFound) [_order removeObjectAtIndex:idx];
    [_order addObject:key];
}

// Drop `key` entirely, keeping the running cost in sync. Caller holds the lock.
- (void)ad_removeKeyLocked:(id)key {
    NSNumber *c = [_costs objectForKey:key];
    if (c) _totalCost -= [c unsignedIntegerValue];
    [_store removeObjectForKey:key];
    [_costs removeObjectForKey:key];
    NSUInteger idx = [_order indexOfObject:key];
    if (idx != NSNotFound) [_order removeObjectAtIndex:idx];
}

// Evict oldest entries until both limits are satisfied. Caller holds the lock.
- (void)ad_evictLocked {
    // Honour countLimit.
    if (_countLimit > 0) {
        while ([_order count] > _countLimit) {
            id victim = [[_order objectAtIndex:0] retain];
            [self ad_removeKeyLocked:victim];
            [victim release];
        }
    }
    // Honour totalCostLimit.
    if (_totalCostLimit > 0) {
        while (_totalCost > _totalCostLimit && [_order count] > 0) {
            id victim = [[_order objectAtIndex:0] retain];
            [self ad_removeKeyLocked:victim];
            [victim release];
        }
    }
}

- (id)objectForKey:(id)key {
    if (!key) return nil;
    @synchronized (self) {
        id obj = [_store objectForKey:key];
        if (obj) [self ad_touchKey:key];
        return [[obj retain] autorelease];
    }
}

- (void)setObject:(id)obj forKey:(id)key {
    [self setObject:obj forKey:key cost:0];
}

- (void)setObject:(id)obj forKey:(id)key cost:(NSUInteger)cost {
    if (!key) return;
    if (!obj) { [self removeObjectForKey:key]; return; }
    @synchronized (self) {
        // Replace any existing entry's cost contribution first.
        NSNumber *old = [_costs objectForKey:key];
        if (old) _totalCost -= [old unsignedIntegerValue];
        [_store setObject:obj forKey:key];
        [_costs setObject:[NSNumber numberWithUnsignedInteger:cost] forKey:key];
        _totalCost += cost;
        [self ad_touchKey:key];
        [self ad_evictLocked];
    }
}

- (void)removeObjectForKey:(id)key {
    if (!key) return;
    @synchronized (self) {
        [self ad_removeKeyLocked:key];
    }
}

- (void)removeAllObjects {
    @synchronized (self) {
        [_store removeAllObjects];
        [_costs removeAllObjects];
        [_order removeAllObjects];
        _totalCost = 0;
    }
}

@end
