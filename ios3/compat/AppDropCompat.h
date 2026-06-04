// AppDropCompat.h — iOS 3 / armv6 backport prefix header.
//
// AppDrop targets the iOS 5.1 SDK (the last SDK that ships armv6 library
// slices). That SDK predates a pile of syntax/API the codebase relies on
// (NS_ENUM, modern subscripting, @YES/@NO boxing, renamed UIKit constants,
// NSUUID, base64, attributed string drawing, …). This header is force-
// included (clang -include) into every translation unit and declares the
// missing pieces so the MRC source compiles. Runtime behaviour for the
// methods declared here is supplied by AppDropRuntime.m.
//
// The app is compiled with -fno-objc-arc: memory management uses native
// retain/release message sends (present since iOS 2), so no ARC runtime shim
// or libarclite is needed. Pair this header only with the static blocks/ and
// gcd_shim.c runtimes, which iOS 3's libSystem never shipped (true 3.x
// hardware has no blocks runtime and no libdispatch).

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

// ---- UIBezierPath: present but NON-FUNCTIONAL on iOS 3.1 (real class debuts
//      in iOS 3.2). On 3.1.3 the class symbol exists yet its drawing methods
//      (moveToPoint:/addLineToPoint:/fill/stroke/...) are unimplemented, so the
//      first glyph drawn at launch throws:
//          *** -[UIBezierPath addLineToPoint:]: unrecognized selector
//      and the launch @try shows "AppDrop failed to launch".
//
//      ADBezierPath (AppDropBezier.m) is a complete, self-contained CGPath-
//      backed replacement using only iOS-2-era CoreGraphics. The macro below
//      transparently rewrites every `UIBezierPath` token in the AppDrop sources
//      to ADBezierPath, so there are zero call-site edits and identical drawing
//      output on iOS 3.1 through 10. (Same strategy as AppDropJSON.m, which
//      ships its own NSJSONSerialization.) AppDropBezier.m #undefs this so its
//      @implementation keeps the real ADBezierPath name. ----
@interface ADBezierPath : NSObject
@property (nonatomic, assign) CGFloat lineWidth;
@property (nonatomic, assign) CGLineCap lineCapStyle;
@property (nonatomic, assign) CGLineJoin lineJoinStyle;
@property (nonatomic, assign) BOOL usesEvenOddFillRule;
+ (ADBezierPath *)bezierPath;
+ (ADBezierPath *)bezierPathWithRect:(CGRect)rect;
+ (ADBezierPath *)bezierPathWithOvalInRect:(CGRect)rect;
+ (ADBezierPath *)bezierPathWithRoundedRect:(CGRect)rect cornerRadius:(CGFloat)radius;
- (void)moveToPoint:(CGPoint)point;
- (void)addLineToPoint:(CGPoint)point;
- (void)closePath;
- (void)fill;
- (void)stroke;
- (void)addClip;
- (CGPathRef)CGPath;
@end
#ifndef UIBezierPath
#define UIBezierPath ADBezierPath
#endif

// ---- UIGestureRecognizer family: present but NON-FUNCTIONAL on iOS 3.1 ----
//      The whole gesture-recognizer subsystem (UIGestureRecognizer + the
//      UITap/UILongPress/UIPan subclasses, -[UIView addGestureRecognizer:],
//      and the touch-routing engine that drives them) debuts in iOS 3.2. On
//      3.1.3 the class symbols exist enough to alloc/init a hollow object, but
//      the property setters and the dispatch engine are dead stubs, so the
//      first launch-path call throws:
//          *** -[UILongPressGestureRecognizer setMinimumPressDuration:]:
//              unrecognized selector  →  uncaught NSException  →  SIGABRT
//      (CategoryViewController -viewDidLoad sets minimumPressDuration while
//      building the Home tab — crash before any UI is shown). Verified against
//      Apple's docs: minimumPressDuration is marked "iOS 3.2+".
//
//      AppDropGestures.m provides complete, self-contained AD* replacements
//      built only on iOS-2-era touch APIs (-[UIView touchesBegan:…],
//      -[UIWindow sendEvent:], UITouch/UIEvent) plus a UIWindow dispatch
//      swizzle. The macros below rewrite every UIKit gesture token in the
//      AppDrop sources to the AD* class, so there are zero call-site edits and
//      identical behaviour on iOS 3.1 through 10 — exactly the ADBezierPath /
//      AppDropJSON strategy. AppDropGestures.m #undefs these so its
//      @implementation keeps the real AD* names.
@class ADGestureRecognizer, ADTapGestureRecognizer,
       ADLongPressGestureRecognizer, ADPanGestureRecognizer;
@protocol UIGestureRecognizerDelegate;   // (declared in the 5.1 SDK headers)

@interface ADGestureRecognizer : NSObject {
@protected
    UIGestureRecognizerState _state;
    UIView         *_view;          // non-retained (UIKit: view owns recognizer)
    id              _delegate;      // non-retained
    BOOL            _enabled;
    NSMutableArray *_targets;       // [target(unsafe), NSValue(SEL)] pairs
    UITouch        *_trackedTouch;  // single touch this recognizer follows (non-retained)
}
- (id)initWithTarget:(id)target action:(SEL)action;
- (void)addTarget:(id)target action:(SEL)action;
@property (nonatomic, readonly) UIGestureRecognizerState state;
@property (nonatomic, assign)   id delegate;
@property (nonatomic, assign)   BOOL enabled;
@property (nonatomic, readonly) UIView *view;
- (CGPoint)locationInView:(UIView *)view;
- (NSUInteger)numberOfTouches;
@end

@interface ADTapGestureRecognizer : ADGestureRecognizer
@property (nonatomic) NSUInteger numberOfTapsRequired;
@property (nonatomic) NSUInteger numberOfTouchesRequired;
@end

@interface ADLongPressGestureRecognizer : ADGestureRecognizer
@property (nonatomic) CFTimeInterval minimumPressDuration;
@property (nonatomic) CGFloat allowableMovement;
@property (nonatomic) NSUInteger numberOfTapsRequired;
@property (nonatomic) NSUInteger numberOfTouchesRequired;
@end

@interface ADPanGestureRecognizer : ADGestureRecognizer
@property (nonatomic) NSUInteger minimumNumberOfTouches;
@property (nonatomic) NSUInteger maximumNumberOfTouches;
- (CGPoint)translationInView:(UIView *)view;
- (void)setTranslation:(CGPoint)t inView:(UIView *)view;
- (CGPoint)velocityInView:(UIView *)view;
@end

#ifndef UIGestureRecognizer
#define UIGestureRecognizer          ADGestureRecognizer
#define UITapGestureRecognizer       ADTapGestureRecognizer
#define UILongPressGestureRecognizer ADLongPressGestureRecognizer
#define UIPanGestureRecognizer       ADPanGestureRecognizer
#endif

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
