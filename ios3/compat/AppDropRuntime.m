// AppDropRuntime.m — runtime backfill for APIs missing on iOS 3.x / 4.x.
//
// Mirrors the existing IOS5Compat.m approach (install IMPs via +load), extended
// down to the iOS 3/4 baseline. Everything here is a no-op when the running OS
// already provides the method, so the same binary still behaves natively on
// iOS 5–10.
//
// IMPORTANT (iOS 3 dyld): the IMPs are installed as plain static C functions,
// NOT via imp_implementationWithBlock(). imp_implementationWithBlock first
// shipped in iOS 4.3's libobjc; on iOS 3.1.3 it is absent and dyld aborts the
// process at launch with:
//     Symbol not found: _imp_implementationWithBlock
//     Expected in: /usr/lib/libobjc.A.dylib
// class_addMethod() takes a raw IMP (function pointer) directly — its signature
// is (id self, SEL _cmd, ...), which the type-encoding strings below already
// describe — so no block trampoline (and no missing runtime symbol) is needed.
//
// Covers:
//   * NSArray -firstObject              (iOS 4 API, missing pre-4)
//   * NSData base64  (encode/decode)    (iOS 7 API)
//   * NSString sizeWithAttributes: + drawAtPoint:/drawInRect:withAttributes:
//                                       (iOS 7 NSStringDrawing; bridged to the
//                                        iOS 2-era UIStringDrawing size/draw API)
//   * UIImage +imageWithData:scale:     (iOS 6 API)
//   * NSUUID                            (iOS 6 class; CFUUID-backed)
//   * NSJSONSerialization               (iOS 5 class; cJSON-backed) — see
//                                        AppDropJSON.m, installed the same way.
//   * UIScreen -scale                   (iOS 4.0; armv6 devices are all 1x)
//   * CALayer -contentsScale/-set…      (iOS 4.0; 1x no-op on iOS 3)
//   * UIGraphicsBeginImageContextWithOptions
//                                       (iOS 4.0 C function; RTLD_NEXT to the
//                                        real UIKit impl on 4+, 1x fallback on 3)
//   * Modern subscripting               (dict[key] / arr[i] read + write; the
//                                        iOS 6 SDK syntax sends objectFor-
//                                        KeyedSubscript: etc., absent pre-iOS 6.
//                                        Ported here from the build-excluded
//                                        IOS5Compat.m so it covers every site.)

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

#pragma mark - Modern subscripting (dict[key], arr[i] — iOS 6 SDK syntax)
// clang lowers `dict[key]` to -[NSDictionary objectForKeyedSubscript:],
// `arr[i]` to -[NSArray objectAtIndexedSubscript:], and the assignment forms
// to the matching setters. Those selectors first shipped in iOS 6; on iOS 3
// they are unrecognized and throw NSInvalidArgumentException (the launch crash
// we hit in setupAppearance: -[NSCFDictionary objectForKeyedSubscript:]).
//
// The IMPs delegate through the iOS-2-era selector (-objectForKey:,
// -objectAtIndex:, …) so the runtime dispatches to the CONCRETE class's real
// method (__NSCFDictionary), not the abstract-class stub. No-ops on iOS 6+
// where the OS already provides the subscript methods.

static id AppDropDictObjectForKeyedSubscript(id self, SEL _cmd, id key) {
    return [self objectForKey:key];
}
static void AppDropMDictSetObjectForKeyedSubscript(id self, SEL _cmd, id obj, id key) {
    [(NSMutableDictionary *)self setObject:obj forKey:key];
}
static id AppDropArrObjectAtIndexedSubscript(id self, SEL _cmd, NSUInteger idx) {
    return [self objectAtIndex:idx];
}
static void AppDropMArrSetObjectAtIndexedSubscript(id self, SEL _cmd, id obj, NSUInteger idx) {
    NSMutableArray *arr = (NSMutableArray *)self;
    if (idx == [arr count]) {          // assigning past the end appends (Apple semantics)
        [arr addObject:obj];
    } else {
        [arr replaceObjectAtIndex:idx withObject:obj];
    }
}

@implementation NSDictionary (AppDropSubscriptImpl)
+ (void)load {
    if ([NSDictionary instancesRespondToSelector:@selector(objectForKeyedSubscript:)]) return;
    class_addMethod([NSDictionary class], @selector(objectForKeyedSubscript:),
                    (IMP)AppDropDictObjectForKeyedSubscript, "@@:@");
}
@end

@implementation NSMutableDictionary (AppDropSubscriptImpl)
+ (void)load {
    if ([NSMutableDictionary instancesRespondToSelector:@selector(setObject:forKeyedSubscript:)]) return;
    class_addMethod([NSMutableDictionary class], @selector(setObject:forKeyedSubscript:),
                    (IMP)AppDropMDictSetObjectForKeyedSubscript, "v@:@@");
}
@end

@implementation NSArray (AppDropSubscriptImpl)
+ (void)load {
    if ([NSArray instancesRespondToSelector:@selector(objectAtIndexedSubscript:)]) return;
    class_addMethod([NSArray class], @selector(objectAtIndexedSubscript:),
                    (IMP)AppDropArrObjectAtIndexedSubscript, "@@:L");
}
@end

@implementation NSMutableArray (AppDropSubscriptImpl)
+ (void)load {
    if ([NSMutableArray instancesRespondToSelector:@selector(setObject:atIndexedSubscript:)]) return;
    class_addMethod([NSMutableArray class], @selector(setObject:atIndexedSubscript:),
                    (IMP)AppDropMArrSetObjectAtIndexedSubscript, "v@:@L");
}
@end

#pragma mark - Attribute key constants (weak: real ones win on iOS 6+)

NSString *const NSFontAttributeName            = @"NSFont";
NSString *const NSForegroundColorAttributeName = @"NSColor";
NSString *const NSParagraphStyleAttributeName  = @"NSParagraphStyle";

#pragma mark - NSArray -firstObject

static id AppDropFirstObject(id self, SEL _cmd) {
    return [self count] ? [self objectAtIndex:0] : nil;
}

@implementation NSArray (AppDropFirstObjectImpl)
+ (void)load {
    if ([NSArray instancesRespondToSelector:@selector(firstObject)]) return;
    class_addMethod([NSArray class], @selector(firstObject), (IMP)AppDropFirstObject, "@@:");
}
@end

#pragma mark - NSString sizeWithAttributes: / draw*  (bridge to UIStringDrawing)

static UIFont *AppDropFontFromAttrs(NSDictionary *attrs) {
    UIFont *f = [attrs objectForKey:NSFontAttributeName];
    return f ?: [UIFont systemFontOfSize:[UIFont systemFontSize]];
}

static CGSize AppDropSizeWithAttributes(id self, SEL _cmd, NSDictionary *attrs) {
    return [self sizeWithFont:AppDropFontFromAttrs(attrs)];
}

static void AppDropDrawAtPoint(id self, SEL _cmd, CGPoint p, NSDictionary *attrs) {
    UIColor *c = [attrs objectForKey:NSForegroundColorAttributeName];
    if (c) [c set];
    [self drawAtPoint:p withFont:AppDropFontFromAttrs(attrs)];
}

static void AppDropDrawInRect(id self, SEL _cmd, CGRect r, NSDictionary *attrs) {
    UIColor *c = [attrs objectForKey:NSForegroundColorAttributeName];
    if (c) [c set];
    [self drawInRect:r withFont:AppDropFontFromAttrs(attrs)];
}

@implementation NSString (AppDropTextSizeImpl)
+ (void)load {
    if (![NSString instancesRespondToSelector:@selector(sizeWithAttributes:)]) {
        class_addMethod([NSString class], @selector(sizeWithAttributes:),
                        (IMP)AppDropSizeWithAttributes, "{CGSize=ff}@:@");
    }
    if (![NSString instancesRespondToSelector:@selector(drawAtPoint:withAttributes:)]) {
        class_addMethod([NSString class], @selector(drawAtPoint:withAttributes:),
                        (IMP)AppDropDrawAtPoint, "v@:{CGPoint=ff}@");
    }
    if (![NSString instancesRespondToSelector:@selector(drawInRect:withAttributes:)]) {
        class_addMethod([NSString class], @selector(drawInRect:withAttributes:),
                        (IMP)AppDropDrawInRect, "v@:{CGRect={CGPoint=ff}{CGSize=ff}}@");
    }
}
@end

#pragma mark - NSData base64 (encode + decode)

static const char b64tab[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static NSString *AppDropBase64Encode(id self, SEL _cmd, NSUInteger opt) {
    const unsigned char *d = [self bytes];
    NSUInteger len = [self length];
    NSMutableData *out = [NSMutableData dataWithLength:((len + 2) / 3) * 4];
    char *o = [out mutableBytes];
    NSUInteger i = 0, j = 0;
    while (i + 2 < len) {
        unsigned int n = (d[i] << 16) | (d[i+1] << 8) | d[i+2];
        o[j++] = b64tab[(n >> 18) & 63]; o[j++] = b64tab[(n >> 12) & 63];
        o[j++] = b64tab[(n >> 6) & 63];  o[j++] = b64tab[n & 63];
        i += 3;
    }
    if (i < len) {
        unsigned int n = d[i] << 16;
        if (i + 1 < len) n |= d[i+1] << 8;
        o[j++] = b64tab[(n >> 18) & 63];
        o[j++] = b64tab[(n >> 12) & 63];
        o[j++] = (i + 1 < len) ? b64tab[(n >> 6) & 63] : '=';
        o[j++] = '=';
    }
    return [[NSString alloc] initWithBytes:o length:j encoding:NSASCIIStringEncoding];
}

static id AppDropBase64Decode(id self, SEL _cmd, NSString *str, NSUInteger opt) {
    static signed char rev[256]; static BOOL init = NO;
    if (!init) { memset(rev, -1, sizeof(rev)); for (int k = 0; k < 64; k++) rev[(unsigned char)b64tab[k]] = k; init = YES; }
    const char *s = [str cStringUsingEncoding:NSASCIIStringEncoding];
    if (!s) return nil;
    NSMutableData *out = [NSMutableData data];
    int buf = 0, bits = 0;
    for (NSUInteger k = 0; s[k]; k++) {
        signed char v = rev[(unsigned char)s[k]];
        if (v < 0) continue;
        buf = (buf << 6) | v; bits += 6;
        if (bits >= 8) { bits -= 8; unsigned char b = (buf >> bits) & 0xFF; [out appendBytes:&b length:1]; }
    }
    return out;
}

@implementation NSData (AppDropBase64Impl)
+ (void)load {
    if (![NSData instancesRespondToSelector:@selector(base64EncodedStringWithOptions:)]) {
        class_addMethod([NSData class], @selector(base64EncodedStringWithOptions:),
                        (IMP)AppDropBase64Encode, "@@:L");
    }
    if (![NSData instancesRespondToSelector:@selector(initWithBase64EncodedString:options:)]) {
        class_addMethod([NSData class], @selector(initWithBase64EncodedString:options:),
                        (IMP)AppDropBase64Decode, "@@:@L");
    }
}
@end

#pragma mark - UIImage +imageWithData:scale:

static UIImage *AppDropImageWithDataScale(id cls, SEL _cmd, NSData *data, CGFloat scale) {
    UIImage *img = [UIImage imageWithData:data];
    if (!img) return nil;
    if ([UIImage instancesRespondToSelector:@selector(initWithCGImage:scale:orientation:)]) {
        return [[UIImage alloc] initWithCGImage:img.CGImage scale:scale orientation:UIImageOrientationUp];
    }
    return img; // pre-scale-aware OS: 1.0 scale is the only option
}

@implementation UIImage (AppDropScaleImpl)
+ (void)load {
    if ([UIImage respondsToSelector:@selector(imageWithData:scale:)]) return;
    Class meta = object_getClass([UIImage class]);
    class_addMethod(meta, @selector(imageWithData:scale:), (IMP)AppDropImageWithDataScale, "@@:@f");
}
@end

#pragma mark - NSUUID (CFUUID-backed)
// Defined as a real class so the linker resolves _OBJC_CLASS_$_NSUUID at call
// sites. On iOS 3/4 (no system NSUUID) this is the only implementation. On
// iOS 6+ the OS already has NSUUID; the duplicate is harmless — both are
// CFUUID-backed and only -UUIDString is used by AppDrop.

@implementation NSUUID
+ (instancetype)UUID {
    return [[self alloc] init];
}
- (NSString *)UUIDString {
    CFUUIDRef u = CFUUIDCreate(NULL);
    CFStringRef s = CFUUIDCreateString(NULL, u);
    NSString *r = [(NSString *)s copy];
    CFRelease(s);
    CFRelease(u);
    return r;
}
@end

#pragma mark - UIScreen -scale  (iOS 4.0)
// The launch path (AppDelegate's tab-icon builders) reads
// [UIScreen mainScreen].scale before anything is on screen. -[UIScreen scale]
// first shipped in iOS 4.0; on iOS 3.1.3 it is an unrecognized selector, which
// throws an uncaught NSException at launch (objc_exception_throw → terminate →
// SIGABRT). Every armv6 device (original iPhone, 3G, iPod touch 1/2g) is a
// non-Retina 1x display, so backfilling a constant 1.0 is exact. No-op on
// iOS 4+ where UIScreen already answers -scale.

static CGFloat AppDropScreenScale(id self, SEL _cmd) {
    return 1.0f;
}

@implementation UIScreen (AppDropScaleImpl)
+ (void)load {
    if ([UIScreen instancesRespondToSelector:@selector(scale)]) return;
    class_addMethod([UIScreen class], @selector(scale), (IMP)AppDropScreenScale, "f@:");
}
@end

#pragma mark - CALayer -contentsScale / -setContentsScale:  (iOS 4.0)
// AppTileView sets self.layer.contentsScale during -initWithFrame: (the catalog
// grid builds these as soon as the first tab loads). CALayer gained
// -contentsScale in iOS 4.0; on iOS 3 -setContentsScale: is an unrecognized
// selector. On a 1x display the setter is a no-op and the getter is 1.0.

static CGFloat AppDropLayerContentsScale(id self, SEL _cmd) {
    return 1.0f;
}
static void AppDropLayerSetContentsScale(id self, SEL _cmd, CGFloat scale) {
    (void)scale; // 1x display: nothing to store
}

@implementation CALayer (AppDropContentsScaleImpl)
+ (void)load {
    if (![CALayer instancesRespondToSelector:@selector(contentsScale)]) {
        class_addMethod([CALayer class], @selector(contentsScale),
                        (IMP)AppDropLayerContentsScale, "f@:");
    }
    if (![CALayer instancesRespondToSelector:@selector(setContentsScale:)]) {
        class_addMethod([CALayer class], @selector(setContentsScale:),
                        (IMP)AppDropLayerSetContentsScale, "v@:f");
    }
}
@end

#pragma mark - UIGraphicsBeginImageContextWithOptions  (iOS 4.0 C function)
// This C function (not a selector) is called in ~26 places, all in drawing
// paths reachable seconds after launch. It first shipped in iOS 4.0's UIKit;
// on iOS 3 the symbol is absent. We provide our OWN definition so the static
// linker binds every call site to this — no undefined UIKit import that would
// abort dyld on iOS 3. At runtime we look up the REAL UIKit implementation with
// RTLD_NEXT (skipping ourselves): on iOS 4+ it's found and forwarded to, so
// Retina rendering is unchanged; on iOS 3 it's NULL and we fall back to the
// iOS-2-era UIGraphicsBeginImageContext (1x is the only option on armv6).
//
// NOTE: must use RTLD_NEXT, not RTLD_DEFAULT — RTLD_DEFAULT would resolve to
// THIS function (it's a global symbol in the main executable) and recurse.

typedef void (*AppDropUBICWO)(CGSize, BOOL, CGFloat);

void UIGraphicsBeginImageContextWithOptions(CGSize size, BOOL opaque, CGFloat scale) {
    static AppDropUBICWO real = NULL;
    static int resolved = 0;
    if (!resolved) {
        real = (AppDropUBICWO)dlsym(RTLD_NEXT, "UIGraphicsBeginImageContextWithOptions");
        resolved = 1;
    }
    if (real) {
        real(size, opaque, scale);
        return;
    }
    // iOS 3 fallback: 1x bitmap context (all armv6 devices are non-Retina).
    UIGraphicsBeginImageContext(size);
}

#pragma mark - NSArray/NSMutableArray block-based sorting  (iOS 4.0)
// -[NSMutableArray sortUsingComparator:] and -[NSArray sortedArrayUsingComparator:]
// take an NSComparator block and first shipped in iOS 4.0. On iOS 3.1.3 they are
// unrecognized selectors (the launch path hits sortUsingComparator: while building
// the Catalogue category list). We bridge them to the iOS-2-era
// sortUsingFunction:context: / sortedArrayUsingFunction:context: APIs, passing the
// block through as the context and invoking it from a C trampoline. No-op on iOS 4+
// where the OS already provides the block-based variants.

typedef NSComparisonResult (^AppDropComparatorBlock)(id, id);

static NSInteger AppDropComparatorTrampoline(id a, id b, void *ctx) {
    AppDropComparatorBlock cmp = (__bridge AppDropComparatorBlock)ctx;
    return (NSInteger)cmp(a, b);
}

static void AppDropSortUsingComparator(id self, SEL _cmd, id cmp) {
    [self sortUsingFunction:AppDropComparatorTrampoline context:(void *)cmp];
}

static id AppDropSortedArrayUsingComparator(id self, SEL _cmd, id cmp) {
    return [self sortedArrayUsingFunction:AppDropComparatorTrampoline context:(void *)cmp];
}

@implementation NSArray (AppDropComparatorSortImpl)
+ (void)load {
    if (![NSArray instancesRespondToSelector:@selector(sortedArrayUsingComparator:)]) {
        class_addMethod([NSArray class], @selector(sortedArrayUsingComparator:),
                        (IMP)AppDropSortedArrayUsingComparator, "@@:@?");
    }
    if (![NSMutableArray instancesRespondToSelector:@selector(sortUsingComparator:)]) {
        class_addMethod([NSMutableArray class], @selector(sortUsingComparator:),
                        (IMP)AppDropSortUsingComparator, "v@:@?");
    }
}
@end

#pragma mark - UIWindow -rootViewController / -setRootViewController:  (iOS 4.0)
// UIWindow gained rootViewController in iOS 4.0; on iOS 3.1.3 AppDelegate's
// @catch fallback (and the normal path) send setRootViewController: which is an
// unrecognized selector. We back it with an associated object (available since
// iOS 3.1.0) and reproduce the iOS 4 behaviour: install the controller's view
// as the window's content subview, removing the previous one. No-op on iOS 4+.

static char kAppDropRootVCKey;

static id AppDropWindowGetRootVC(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, &kAppDropRootVCKey);
}

static void AppDropWindowSetRootVC(id self, SEL _cmd, id vc) {
    UIViewController *old = objc_getAssociatedObject(self, &kAppDropRootVCKey);
    if (old && old.isViewLoaded && old.view.superview == self) {
        [old.view removeFromSuperview];
    }
    objc_setAssociatedObject(self, &kAppDropRootVCKey, vc, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (vc) {
        UIViewController *newVC = (UIViewController *)vc;
        newVC.view.frame = [(UIWindow *)self bounds];
        [(UIWindow *)self addSubview:newVC.view];
    }
}

@implementation UIWindow (AppDropRootVCImpl)
+ (void)load {
    if ([UIWindow instancesRespondToSelector:@selector(setRootViewController:)]) return;
    class_addMethod([UIWindow class], @selector(rootViewController),
                    (IMP)AppDropWindowGetRootVC, "@@:");
    class_addMethod([UIWindow class], @selector(setRootViewController:),
                    (IMP)AppDropWindowSetRootVC, "v@:@");
}
@end
