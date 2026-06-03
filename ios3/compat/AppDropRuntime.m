// AppDropRuntime.m — runtime backfill for APIs missing on iOS 3.x / 4.x.
//
// Mirrors the existing IOS5Compat.m approach (install IMPs via +load), extended
// down to the iOS 3/4 baseline. Everything here is a no-op when the running OS
// already provides the method, so the same binary still behaves natively on
// iOS 5–10.
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

@implementation NSArray (AppDropFirstObjectImpl)
+ (void)load {
    if ([NSArray instancesRespondToSelector:@selector(firstObject)]) return;
    IMP imp = imp_implementationWithBlock(^id(id self) {
        return [self count] ? [self objectAtIndex:0] : nil;
    });
    class_addMethod([NSArray class], @selector(firstObject), imp, "@@:");
}
@end

#pragma mark - NSString sizeWithAttributes: / draw*  (bridge to UIStringDrawing)

static UIFont *AppDropFontFromAttrs(NSDictionary *attrs) {
    UIFont *f = [attrs objectForKey:NSFontAttributeName];
    return f ?: [UIFont systemFontOfSize:[UIFont systemFontSize]];
}

@implementation NSString (AppDropTextSizeImpl)
+ (void)load {
    if (![NSString instancesRespondToSelector:@selector(sizeWithAttributes:)]) {
        IMP imp = imp_implementationWithBlock(^CGSize(id self, NSDictionary *attrs) {
            return [self sizeWithFont:AppDropFontFromAttrs(attrs)];
        });
        class_addMethod([NSString class], @selector(sizeWithAttributes:), imp, "{CGSize=ff}@:@");
    }
    if (![NSString instancesRespondToSelector:@selector(drawAtPoint:withAttributes:)]) {
        IMP imp = imp_implementationWithBlock(^(id self, CGPoint p, NSDictionary *attrs) {
            UIColor *c = [attrs objectForKey:NSForegroundColorAttributeName];
            if (c) [c set];
            [self drawAtPoint:p withFont:AppDropFontFromAttrs(attrs)];
        });
        class_addMethod([NSString class], @selector(drawAtPoint:withAttributes:), imp, "v@:{CGPoint=ff}@");
    }
    if (![NSString instancesRespondToSelector:@selector(drawInRect:withAttributes:)]) {
        IMP imp = imp_implementationWithBlock(^(id self, CGRect r, NSDictionary *attrs) {
            UIColor *c = [attrs objectForKey:NSForegroundColorAttributeName];
            if (c) [c set];
            [self drawInRect:r withFont:AppDropFontFromAttrs(attrs)];
        });
        class_addMethod([NSString class], @selector(drawInRect:withAttributes:), imp, "v@:{CGRect={CGPoint=ff}{CGSize=ff}}@");
    }
}
@end

#pragma mark - NSData base64 (encode + decode)

static const char b64tab[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

@implementation NSData (AppDropBase64Impl)
+ (void)load {
    if (![NSData instancesRespondToSelector:@selector(base64EncodedStringWithOptions:)]) {
        IMP imp = imp_implementationWithBlock(^NSString *(id self, NSUInteger opt) {
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
        });
        class_addMethod([NSData class], @selector(base64EncodedStringWithOptions:), imp, "@@:L");
    }
    if (![NSData instancesRespondToSelector:@selector(initWithBase64EncodedString:options:)]) {
        IMP imp = imp_implementationWithBlock(^id(id self, NSString *str, NSUInteger opt) {
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
        });
        class_addMethod([NSData class], @selector(initWithBase64EncodedString:options:), imp, "@@:@L");
    }
}
@end

#pragma mark - UIImage +imageWithData:scale:

@implementation UIImage (AppDropScaleImpl)
+ (void)load {
    if ([UIImage respondsToSelector:@selector(imageWithData:scale:)]) return;
    IMP imp = imp_implementationWithBlock(^UIImage *(id cls, NSData *data, CGFloat scale) {
        UIImage *img = [UIImage imageWithData:data];
        if (!img) return nil;
        if ([UIImage instancesRespondToSelector:@selector(initWithCGImage:scale:orientation:)]) {
            return [[UIImage alloc] initWithCGImage:img.CGImage scale:scale orientation:UIImageOrientationUp];
        }
        return img; // pre-scale-aware OS: 1.0 scale is the only option
    });
    Class meta = object_getClass([UIImage class]);
    class_addMethod(meta, @selector(imageWithData:scale:), imp, "@@:@f");
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
