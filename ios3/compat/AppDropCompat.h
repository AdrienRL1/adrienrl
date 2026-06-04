// AppDropCompat.h — iOS 3 / armv6 backport prefix header.
//
// AppDrop targets the iOS 5.1 SDK (the last SDK that ships armv6 library
// slices). That SDK predates a pile of syntax/API the codebase relies on
// (NS_ENUM, modern subscripting, @YES/@NO boxing, renamed UIKit constants,
// NSUUID, base64, attributed string drawing, …). This header is force-
// included (clang -include) into every translation unit and declares the
// missing pieces so the existing ARC source compiles unchanged. Runtime
// behaviour for the methods declared here is supplied by AppDropRuntime.m.
//
// Pair this with the static runtime shims (arc_runtime.m, blocks/, gcd_shim.c)
// so the ARC / blocks / GCD entry points resolve on a device whose libobjc /
// libSystem never shipped them (true iOS 3.x hardware).

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// ---- AD_WEAK: weak-reference qualifier for the iOS 3 MRC target ----
// True zeroing __weak needs the iOS 5+ ObjC runtime (objc_loadWeak /
// objc_storeWeak with side tables), which iOS 3/4 devices do not have. Under
// MRC we use __unsafe_unretained — a non-zeroing weak ref that breaks retain
// cycles without retaining. This matches the behaviour the old ARC shim
// already provided (its objc_storeWeak was a plain assign), but compiles
// cleanly and carries no phantom runtime dependency. Every former __weak /
// weak-property site routes through this one macro so a real zeroing-weak
// implementation can be swapped in centrally if one is ever back-ported.
#ifndef AD_WEAK
#define AD_WEAK __unsafe_unretained
#endif

// ---- NS_ENUM / NS_OPTIONS: iOS 6 SDK macros, absent from the 5.1 SDK ----
#ifndef NS_ENUM
#define NS_ENUM(_type, _name) _type _name; enum
#endif
#ifndef NS_OPTIONS
#define NS_OPTIONS(_type, _name) _type _name; enum
#endif

// ---- Modern subscripting (declared in iOS 6 SDK headers) ----
@interface NSObject (AppDropSubscript)
- (id)objectForKeyedSubscript:(id)key;
- (void)setObject:(id)obj forKeyedSubscript:(id)key;
- (id)objectAtIndexedSubscript:(NSUInteger)idx;
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)idx;
@end

// ---- Text alignment / line break: renamed in iOS 6 (UI* -> NS*) ----
#ifndef NSTextAlignmentLeft
#define NSTextAlignmentLeft      UITextAlignmentLeft
#define NSTextAlignmentCenter    UITextAlignmentCenter
#define NSTextAlignmentRight     UITextAlignmentRight
#endif
#ifndef NSLineBreakByWordWrapping
#define NSLineBreakByWordWrapping     UILineBreakModeWordWrap
#define NSLineBreakByCharWrapping     UILineBreakModeCharacterWrap
#define NSLineBreakByClipping         UILineBreakModeClip
#define NSLineBreakByTruncatingHead   UILineBreakModeHeadTruncation
#define NSLineBreakByTruncatingTail   UILineBreakModeTailTruncation
#define NSLineBreakByTruncatingMiddle UILineBreakModeMiddleTruncation
#endif

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// ---- UIInterfaceOrientationMask: iOS 6 NS_OPTIONS ----
#ifndef UIInterfaceOrientationMaskPortrait
typedef NSUInteger UIInterfaceOrientationMask;
enum {
    UIInterfaceOrientationMaskPortrait = (1 << UIInterfaceOrientationPortrait),
    UIInterfaceOrientationMaskLandscapeLeft = (1 << UIInterfaceOrientationLandscapeLeft),
    UIInterfaceOrientationMaskLandscapeRight = (1 << UIInterfaceOrientationLandscapeRight),
    UIInterfaceOrientationMaskPortraitUpsideDown = (1 << UIInterfaceOrientationPortraitUpsideDown),
    UIInterfaceOrientationMaskLandscape = (UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight),
    UIInterfaceOrientationMaskAll = (UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight | UIInterfaceOrientationMaskPortraitUpsideDown),
    UIInterfaceOrientationMaskAllButUpsideDown = (UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight),
};
#endif

// ---- UIViewController iOS 6+ autorotation selectors (absent from 5.1 SDK headers) ----
@interface UIViewController (AppDropAutorotate)
- (NSUInteger)supportedInterfaceOrientations;
- (BOOL)shouldAutorotate;
@end

// ---- UIView -tintColor (iOS 7+; runtime-guarded with respondsToSelector) ----
@interface UIView (AppDropTint)
- (void)setTintColor:(UIColor *)color;
- (UIColor *)tintColor;
@end

// ---- UISwitch -tintColor (iOS 6+; runtime-guarded with respondsToSelector) ----
@interface UISwitch (AppDropTint)
- (void)setTintColor:(UIColor *)color;
- (UIColor *)tintColor;
@end

// ---- UITableViewHeaderFooterView (iOS 6+; runtime-guarded with isKindOfClass) ----
@interface UITableViewHeaderFooterView : UIView
@property (nonatomic, retain) UIView *backgroundView;
@property (nonatomic, readonly, retain) UIView *contentView;
@property (nonatomic, readonly, retain) UILabel *textLabel;
@property (nonatomic, readonly, retain) UILabel *detailTextLabel;
@end

// ---- @YES / @NO boxed BOOL literals (5.1 SDK defines YES/NO as (BOOL)1/(BOOL)0,
//      which breaks @YES/@NO boxing; iOS 6 SDK uses __objc_yes/__objc_no builtins) ----
#undef YES
#undef NO
#define YES __objc_yes
#define NO  __objc_no

// ---- String drawing attribute keys (UIStringDrawing, iOS 6+) ----
extern NSString *const NSFontAttributeName;
extern NSString *const NSForegroundColorAttributeName;
extern NSString *const NSParagraphStyleAttributeName;

// ---- NSArray -firstObject (public since iOS 4; absent from 5.1 SDK headers) ----
@interface NSArray (AppDropFirstObject)
- (id)firstObject;
@end

// ---- NSString sizeWithAttributes: / draw*, NSData base64, UIImage imageWithData:scale: ----
@interface NSString (AppDropTextSize)
- (CGSize)sizeWithAttributes:(NSDictionary *)attrs;
- (void)drawAtPoint:(CGPoint)point withAttributes:(NSDictionary *)attrs;
- (void)drawInRect:(CGRect)rect withAttributes:(NSDictionary *)attrs;
@end
@interface NSData (AppDropBase64)
- (NSString *)base64EncodedStringWithOptions:(NSUInteger)opt;
- (id)initWithBase64EncodedString:(NSString *)str options:(NSUInteger)opt;
@end
@interface UIImage (AppDropScale)
+ (UIImage *)imageWithData:(NSData *)data scale:(CGFloat)scale;
@end

// ---- NSUUID (iOS 6+); declared so calls compile, provided at runtime via shim ----
@interface NSUUID : NSObject
+ (instancetype)UUID;
- (NSString *)UUIDString;
@end
