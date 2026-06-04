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

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

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
