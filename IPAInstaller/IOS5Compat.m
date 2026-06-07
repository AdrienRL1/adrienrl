// Runtime shim that makes the modern subscript syntax (dict[key], arr[idx],
// dict[key] = obj, arr[idx] = obj) work on iOS 5.
//
// History of this file:
//   v1.5     — naive: `class_addMethod` aliased objectForKey:'s IMP to
//              objectForKeyedSubscript: on NSDictionary. BROKEN on iOS 5
//              because NSDictionary's -objectForKey: IMP is the abstract-
//              class stub that throws "method only defined for abstract
//              class" — concrete classes (__NSCFDictionary) override
//              -objectForKey: but inherit the broken subscript alias.
//   v1.5-5   — fixed: install custom C IMPs that explicitly delegate via
//              -objectForKey: (NSDictionary), -setObject:forKey: (mutable),
//              -objectAtIndex: (array), -addObject:/-replaceObjectAtIndex:
//              (mutable array). These IMPs route through the receiver, so
//              the runtime picks the concrete class's real method.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "IOS5Compat.h"

#pragma mark - Adaptive concurrency helpers

// Returns the active core count (>= 1). activeProcessorCount is available
// since iOS 2, so no runtime guard is required. Single-core A4 devices
// (iPad 1 / iPhone 4) return 1, which callers use to avoid over-subscribing
// the one slow core.
NSUInteger ADRecommendedConcurrency(void) {
    NSUInteger n = [[NSProcessInfo processInfo] activeProcessorCount];
    return n < 1 ? 1 : n;
}

NSUInteger ADRecommendedConcurrencyCapped(NSUInteger maxCap) {
    NSUInteger n = ADRecommendedConcurrency();
    return (maxCap && n > maxCap) ? maxCap : n;
}

#pragma mark - C trampolines (delegate via the iOS-5-era selector)

static id appdrop_dict_objectForKeyedSubscript(id self, SEL _cmd, id key) {
    return [self objectForKey:key];
}

static void appdrop_mdict_setObjectForKeyedSubscript(id self, SEL _cmd, id obj, id key) {
    [(NSMutableDictionary *)self setObject:obj forKey:key];
}

static id appdrop_arr_objectAtIndexedSubscript(id self, SEL _cmd, NSUInteger idx) {
    return [self objectAtIndex:idx];
}

static void appdrop_marr_setObjectAtIndexedSubscript(id self, SEL _cmd, id obj, NSUInteger idx) {
    // Per Apple docs, assigning past the end appends. Match that.
    NSMutableArray *arr = (NSMutableArray *)self;
    if (idx == [arr count]) {
        [arr addObject:obj];
    } else {
        [arr replaceObjectAtIndex:idx withObject:obj];
    }
}

#pragma mark - +load installers

@interface NSDictionary (AppDropIOS5Subscript) @end
@implementation NSDictionary (AppDropIOS5Subscript)
+ (void)load {
    if ([NSDictionary instancesRespondToSelector:@selector(objectForKeyedSubscript:)]) return;
    // "@@:@" = returns id, takes id self + SEL + id key.
    class_addMethod([NSDictionary class],
                    @selector(objectForKeyedSubscript:),
                    (IMP)appdrop_dict_objectForKeyedSubscript,
                    "@@:@");
}
@end

@interface NSMutableDictionary (AppDropIOS5Subscript) @end
@implementation NSMutableDictionary (AppDropIOS5Subscript)
+ (void)load {
    if ([NSMutableDictionary instancesRespondToSelector:@selector(setObject:forKeyedSubscript:)]) return;
    // "v@:@@" = returns void, self + SEL + obj + key.
    class_addMethod([NSMutableDictionary class],
                    @selector(setObject:forKeyedSubscript:),
                    (IMP)appdrop_mdict_setObjectForKeyedSubscript,
                    "v@:@@");
}
@end

@interface NSArray (AppDropIOS5Subscript) @end
@implementation NSArray (AppDropIOS5Subscript)
+ (void)load {
    if ([NSArray instancesRespondToSelector:@selector(objectAtIndexedSubscript:)]) return;
    // "@@:L" = returns id, self + SEL + NSUInteger (L on 32-bit arm).
    class_addMethod([NSArray class],
                    @selector(objectAtIndexedSubscript:),
                    (IMP)appdrop_arr_objectAtIndexedSubscript,
                    "@@:L");
}
@end

@interface NSMutableArray (AppDropIOS5Subscript) @end
@implementation NSMutableArray (AppDropIOS5Subscript)
+ (void)load {
    if ([NSMutableArray instancesRespondToSelector:@selector(setObject:atIndexedSubscript:)]) return;
    // "v@:@L" = returns void, self + SEL + obj + NSUInteger.
    class_addMethod([NSMutableArray class],
                    @selector(setObject:atIndexedSubscript:),
                    (IMP)appdrop_marr_setObjectAtIndexedSubscript,
                    "v@:@L");
}
@end
