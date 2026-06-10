// AppDropGestures.m — self-contained UIGestureRecognizer backport for iOS 3.1.
//
// WHY THIS EXISTS
// ---------------
// The whole UIKit gesture-recognizer subsystem — UIGestureRecognizer and its
// concrete subclasses (UITap / UILongPress / UIPanGestureRecognizer), the
// -[UIView addGestureRecognizer:] plumbing, and the touch-routing engine that
// drives them — first shipped in **iOS 3.2**. (Verified against Apple's own
// docs: e.g. -[UILongPressGestureRecognizer minimumPressDuration] is marked
// "iOS 3.2+".) On iOS 3.1.3 the *class symbols* exist enough to alloc/init a
// hollow object, but the property setters and the dispatch engine are dead
// stubs, so the first launch-path call throws:
//
//     *** -[UILongPressGestureRecognizer setMinimumPressDuration:]:
//         unrecognized selector sent to instance 0x253800
//     *** Terminating app due to uncaught exception 'NSInvalidArgumentException'
//
// (CategoryViewController -viewDidLoad sets minimumPressDuration while building
// the Home tab, so the app aborts at launch before anything is on screen.)
//
// THE FIX (same strategy as ADBezierPath / AppDropJSON)
// -----------------------------------------------------
// AppDropCompat.h declares complete AD* gesture classes and macro-rewrites
// every `UI*GestureRecognizer` token in the AppDrop sources to the AD* class,
// so there are ZERO call-site edits. This file implements them using only
// iOS-2-era touch APIs that every iOS version has had since 2.0:
//
//   * -[UIView touchesBegan:withEvent:] / Moved / Ended / Cancelled
//   * -[UIWindow sendEvent:]  (the single funnel every touch passes through)
//   * UITouch / UIEvent, -locationInView:, -[UIView hitTest:withEvent:]
//
// A UIWindow -sendEvent: swizzle is the dispatch engine: for every touch phase
// it walks the hit-tested view's superview chain, feeds the touch to any AD
// recognizer attached to those views, and lets each recognizer update its
// state / fire its target-action. This reproduces the parts of UIKit's gesture
// engine that AppDrop actually uses (single-finger tap, long-press, pan) and
// nothing it doesn't.
//
// addGestureRecognizer: is ALSO 3.2+, so we install our own on every OS
// (class_addMethod when absent on 3.1; method-swizzle to our store when present
// on 3.2+). Because the app exclusively instantiates AD* recognizers (via the
// macro), routing all addGestureRecognizer: calls through our store is correct
// and identical on iOS 3.1 → 10 — UIKit's native engine is simply unused.
//
// MRC throughout (the whole project is -fno-objc-arc): retain/release by hand.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// Keep the real AD* class names in this file (undo the compat.h rewrite).
#undef UIGestureRecognizer
#undef UITapGestureRecognizer
#undef UILongPressGestureRecognizer
#undef UIPanGestureRecognizer

// AppDropCompat.h (force-included) already declares the public AD* @interfaces
// and the base class's @protected ivars, and the iOS 5.1 SDK already defines
// UIGestureRecognizerState. Here we only add the file-private engine API via a
// class extension; subclass-specific ivars live in each @implementation's
// braces (the same pattern AppDropBezier.m uses for ADBezierPath).

#pragma mark - Base recognizer (private engine API)

@interface ADGestureRecognizer ()
- (void)setView:(UIView *)view;            // header exposes -view readonly
- (BOOL)adShouldReceiveTouch:(UITouch *)touch;
- (void)adReset;
- (void)adFireIfNeeded;
- (void)adSetState:(UIGestureRecognizerState)s;
- (void)adTouchesBegan:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)adTouchesMoved:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)adTouchesEnded:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)adTouchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event;
@end

@implementation ADGestureRecognizer

- (id)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super init])) {
        _state = UIGestureRecognizerStatePossible;
        _enabled = YES;
        _targets = [[NSMutableArray alloc] init];
        if (target && action) [self addTarget:target action:action];
    }
    return self;
}

- (void)dealloc {
    [_targets release];
    [super dealloc];
}

- (void)addTarget:(id)target action:(SEL)action {
    if (!target || !action) return;
    // Store target as a non-retained box (UIKit does not retain gesture targets;
    // retaining here would create owner→recognizer→owner cycles).
    NSValue *t = [NSValue valueWithNonretainedObject:target];
    NSValue *a = [NSValue valueWithPointer:(void *)action];
    [_targets addObject:[NSArray arrayWithObjects:t, a, nil]];
}

- (UIGestureRecognizerState)state { return _state; }
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; }
- (BOOL)enabled { return _enabled; }
- (void)setEnabled:(BOOL)e { _enabled = e; if (!e) [self adReset]; }
- (UIView *)view { return _view; }
- (void)setView:(UIView *)v { _view = v; }   // non-retained

- (NSUInteger)numberOfTouches { return _trackedTouch ? 1 : 0; }

- (CGPoint)locationInView:(UIView *)view {
    UITouch *t = _trackedTouch;
    if (!t) return CGPointZero;
    return [t locationInView:(view ?: _view)];
}

- (void)adSetState:(UIGestureRecognizerState)s {
    _state = s;
    [self adFireIfNeeded];
}

// Fire every registered target-action. UIKit passes the recognizer as the sole
// argument for `action:` selectors that take one parameter (`handleX:`); for a
// zero-arg selector (`tapped`) it sends with no argument. We mirror that by
// inspecting the selector's argument count.
- (void)adFireIfNeeded {
    if (_state != UIGestureRecognizerStateBegan &&
        _state != UIGestureRecognizerStateChanged &&
        _state != UIGestureRecognizerStateEnded &&
        _state != UIGestureRecognizerStateRecognized) {
        return;
    }
    // Copy targets first: an action may mutate the view tree / recognizers.
    NSArray *snapshot = [[_targets copy] autorelease];
    for (NSArray *pair in snapshot) {
        id target = [[pair objectAtIndex:0] nonretainedObjectValue];
        SEL action = (SEL)[[pair objectAtIndex:1] pointerValue];
        if (!target || ![target respondsToSelector:action]) continue;
        NSMethodSignature *sig = [target methodSignatureForSelector:action];
        // numberOfArguments includes self + _cmd; >2 means it takes the sender.
        if (sig && [sig numberOfArguments] > 2) {
            void (*imp)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
            imp(target, action, self);
        } else {
            void (*imp)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
            imp(target, action);
        }
    }
}

- (void)adReset {
    _state = UIGestureRecognizerStatePossible;
    _trackedTouch = nil;
}

// Default: ask the delegate whether this touch should be received.
- (BOOL)adShouldReceiveTouch:(UITouch *)touch {
    if (_delegate && [_delegate respondsToSelector:@selector(gestureRecognizer:shouldReceiveTouch:)]) {
        return [_delegate gestureRecognizer:(id)self shouldReceiveTouch:touch];
    }
    return YES;
}

- (void)adTouchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {}
- (void)adTouchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {}
- (void)adTouchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {}
- (void)adTouchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [self adReset];
}
@end

#pragma mark - Tap

@implementation ADTapGestureRecognizer {
    NSUInteger _numberOfTapsRequired;
    NSUInteger _numberOfTouchesRequired;
    CGPoint    _startPoint;
}
- (id)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        _numberOfTapsRequired = 1;
        _numberOfTouchesRequired = 1;
    }
    return self;
}
- (NSUInteger)numberOfTapsRequired { return _numberOfTapsRequired; }
- (void)setNumberOfTapsRequired:(NSUInteger)n { _numberOfTapsRequired = n; }
- (NSUInteger)numberOfTouchesRequired { return _numberOfTouchesRequired; }
- (void)setNumberOfTouchesRequired:(NSUInteger)n { _numberOfTouchesRequired = n; }

- (void)adTouchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_trackedTouch) return;
    UITouch *t = [touches anyObject];
    if (![self adShouldReceiveTouch:t]) return;
    _trackedTouch = t;
    _startPoint = [t locationInView:_view];
}
- (void)adTouchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_trackedTouch || ![touches containsObject:_trackedTouch]) return;
    CGPoint p = [_trackedTouch locationInView:_view];
    // A tap tolerates a little slop; beyond ~15pt it's a scroll/drag, not a tap.
    if (fabsf(p.x - _startPoint.x) > 15 || fabsf(p.y - _startPoint.y) > 15) {
        [self adReset];
    }
}
- (void)adTouchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_trackedTouch || ![touches containsObject:_trackedTouch]) return;
    UITouch *t = _trackedTouch;
    NSUInteger taps = 1;
    @try { taps = [t tapCount]; } @catch (__unused id e) {}
    if (taps >= _numberOfTapsRequired) {
        [self adSetState:UIGestureRecognizerStateRecognized];
    }
    [self adReset];
}
@end

#pragma mark - Long press


@implementation ADLongPressGestureRecognizer {
    CFTimeInterval _minimumPressDuration;
    CGFloat        _allowableMovement;
    NSUInteger     _numberOfTapsRequired;
    NSUInteger     _numberOfTouchesRequired;
    CGPoint        _startPoint;
    BOOL           _began;
}
- (id)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        _minimumPressDuration = 0.5;     // UIKit default (Apple docs)
        _allowableMovement = 10.0;       // UIKit default
        _numberOfTapsRequired = 0;
        _numberOfTouchesRequired = 1;
    }
    return self;
}
- (CFTimeInterval)minimumPressDuration { return _minimumPressDuration; }
- (void)setMinimumPressDuration:(CFTimeInterval)d { _minimumPressDuration = d; }
- (CGFloat)allowableMovement { return _allowableMovement; }
- (void)setAllowableMovement:(CGFloat)m { _allowableMovement = m; }
- (NSUInteger)numberOfTapsRequired { return _numberOfTapsRequired; }
- (void)setNumberOfTapsRequired:(NSUInteger)n { _numberOfTapsRequired = n; }
- (NSUInteger)numberOfTouchesRequired { return _numberOfTouchesRequired; }
- (void)setNumberOfTouchesRequired:(NSUInteger)n { _numberOfTouchesRequired = n; }

- (void)adReset {
    [super adReset];
    _began = NO;
}

- (void)adTouchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_trackedTouch) return;
    UITouch *t = [touches anyObject];
    if (![self adShouldReceiveTouch:t]) return;
    _trackedTouch = t;
    _began = NO;
    _startPoint = [t locationInView:_view];
    // Fire the "Began" transition after minimumPressDuration unless the finger
    // lifted or moved too far. performSelector:afterDelay: schedules on the
    // current run loop (main), matching UIKit's main-thread delivery.
    [self performSelector:@selector(adLongPressElapsed)
               withObject:nil
               afterDelay:_minimumPressDuration];
}

- (void)adLongPressElapsed {
    if (!_trackedTouch || _began) return;
    _began = YES;
    [self adSetState:UIGestureRecognizerStateBegan];
}

- (void)adTouchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_trackedTouch || ![touches containsObject:_trackedTouch]) return;
    CGPoint p = [_trackedTouch locationInView:_view];
    if (!_began) {
        // Too much movement before the press registers → not a long press.
        if (fabsf(p.x - _startPoint.x) > _allowableMovement ||
            fabsf(p.y - _startPoint.y) > _allowableMovement) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                     selector:@selector(adLongPressElapsed)
                                                       object:nil];
            [self adReset];
        }
    } else {
        [self adSetState:UIGestureRecognizerStateChanged];
    }
}

- (void)adTouchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_trackedTouch || ![touches containsObject:_trackedTouch]) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(adLongPressElapsed)
                                               object:nil];
    if (_began) {
        [self adSetState:UIGestureRecognizerStateEnded];
    }
    [self adReset];
}

- (void)adTouchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(adLongPressElapsed)
                                               object:nil];
    if (_began) { [self adSetState:UIGestureRecognizerStateCancelled]; }
    [self adReset];
}
@end

#pragma mark - Pan


@implementation ADPanGestureRecognizer {
    NSUInteger _minimumNumberOfTouches;
    NSUInteger _maximumNumberOfTouches;
    CGPoint    _startPoint;       // in _view coords
    CGPoint    _lastPoint;
    CFTimeInterval _lastTime;
    CGPoint    _velocity;
    CGPoint    _translationOffset; // adjustment from setTranslation:inView:
    BOOL       _began;
}
- (id)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        _minimumNumberOfTouches = 1;
        _maximumNumberOfTouches = NSUIntegerMax;
    }
    return self;
}
- (NSUInteger)minimumNumberOfTouches { return _minimumNumberOfTouches; }
- (void)setMinimumNumberOfTouches:(NSUInteger)n { _minimumNumberOfTouches = n; }
- (NSUInteger)maximumNumberOfTouches { return _maximumNumberOfTouches; }
- (void)setMaximumNumberOfTouches:(NSUInteger)n { _maximumNumberOfTouches = n; }

- (void)adReset {
    [super adReset];
    _began = NO;
    _translationOffset = CGPointZero;
    _velocity = CGPointZero;
}

- (CGPoint)translationInView:(UIView *)view {
    if (!_trackedTouch) return _translationOffset;
    CGPoint p = [_trackedTouch locationInView:(view ?: _view)];
    return CGPointMake(p.x - _startPoint.x + _translationOffset.x,
                       p.y - _startPoint.y + _translationOffset.y);
}
- (void)setTranslation:(CGPoint)t inView:(UIView *)view {
    if (_trackedTouch) {
        CGPoint p = [_trackedTouch locationInView:(view ?: _view)];
        _startPoint = p;
    }
    _translationOffset = t;
}
- (CGPoint)velocityInView:(UIView *)view { return _velocity; }

- (void)adTouchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_trackedTouch) return;
    UITouch *t = [touches anyObject];
    if (![self adShouldReceiveTouch:t]) return;
    _trackedTouch = t;
    _began = NO;
    _startPoint = [t locationInView:_view];
    _lastPoint = _startPoint;
    _lastTime = CACurrentMediaTime();
    _translationOffset = CGPointZero;
    _velocity = CGPointZero;
}
- (void)adTouchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_trackedTouch || ![touches containsObject:_trackedTouch]) return;
    CGPoint p = [_trackedTouch locationInView:_view];
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = now - _lastTime;
    if (dt > 0) {
        _velocity = CGPointMake((p.x - _lastPoint.x) / dt, (p.y - _lastPoint.y) / dt);
    }
    _lastPoint = p; _lastTime = now;
    if (!_began) {
        if (fabsf(p.x - _startPoint.x) > 4 || fabsf(p.y - _startPoint.y) > 4) {
            _began = YES;
            [self adSetState:UIGestureRecognizerStateBegan];
        }
    } else {
        [self adSetState:UIGestureRecognizerStateChanged];
    }
}
- (void)adTouchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_trackedTouch || ![touches containsObject:_trackedTouch]) return;
    if (_began) { [self adSetState:UIGestureRecognizerStateEnded]; }
    [self adReset];
}
- (void)adTouchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_began) { [self adSetState:UIGestureRecognizerStateCancelled]; }
    [self adReset];
}
@end

#pragma mark - Attachment store on UIView (addGestureRecognizer:)

static char kADRecognizersKey;

static NSMutableArray *ADViewRecognizers(UIView *view, BOOL create) {
    NSMutableArray *arr = objc_getAssociatedObject(view, &kADRecognizersKey);
    if (!arr && create) {
        arr = [NSMutableArray array];
        objc_setAssociatedObject(view, &kADRecognizersKey, arr,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return arr;
}

static BOOL ADViewHasControlAncestor(UIView *view) {
    while (view) {
        if ([view isKindOfClass:[UIControl class]]) return YES;
        view = view.superview;
    }
    return NO;
}

static UIScrollView *ADNearestScrollView(UIView *view) {
    while (view) {
        if ([view isKindOfClass:[UIScrollView class]]) return (UIScrollView *)view;
        view = view.superview;
    }
    return nil;
}

static UITouch *gADScrollTouch = nil;
static UIScrollView *gADScrollView = nil;
static CGPoint gADScrollStartPoint = { 0, 0 };
static CGPoint gADScrollStartOffset = { 0, 0 };
static CGPoint gADScrollLastPoint = { 0, 0 };
static CFTimeInterval gADScrollLastTime = 0;
static CGFloat gADScrollVelocityY = 0;
static BOOL gADScrollEngaged = NO;
static BOOL gADScrollDidWriteOffset = NO;
static BOOL gADScrollMomentumActive = NO;
static NSTimer *gADScrollMomentumTimer = nil;
static id gADScrollMomentumDriver = nil;

static BOOL ADScrollTouchIsActive(UITouch *touch) {
    if (!touch) return NO;
    switch ([touch phase]) {
        case UITouchPhaseBegan:
        case UITouchPhaseMoved:
        case UITouchPhaseStationary:
            return YES;
        default:
            return NO;
    }
}

static CGFloat ADScrollClampedY(UIScrollView *sv, CGFloat proposedY) {
    UIEdgeInsets inset = sv.contentInset;
    CGFloat minY = -inset.top;
    CGFloat maxY = sv.contentSize.height + inset.bottom - sv.bounds.size.height;
    if (maxY < minY) maxY = minY;
    if (proposedY < minY) return minY;
    if (proposedY > maxY) return maxY;
    return proposedY;
}

static void ADScrollStopMomentum(void) {
    [gADScrollMomentumTimer invalidate];
    gADScrollMomentumTimer = nil;
}

static void ADScrollReset(void) {
    ADScrollStopMomentum();
    if (gADScrollView) {
        [gADScrollView release];
        gADScrollView = nil;
    }
    gADScrollTouch = nil;
    gADScrollStartPoint = CGPointZero;
    gADScrollStartOffset = CGPointZero;
    gADScrollLastPoint = CGPointZero;
    gADScrollLastTime = 0;
    gADScrollVelocityY = 0;
    gADScrollEngaged = NO;
    gADScrollDidWriteOffset = NO;
    gADScrollMomentumActive = NO;
}

@interface ADScrollMomentumDriver : NSObject
- (void)adScrollMomentumTick:(NSTimer *)timer;
@end

@implementation ADScrollMomentumDriver
- (void)adScrollMomentumTick:(NSTimer *)timer {
    (void)timer;
    UIScrollView *sv = gADScrollView;
    if (!sv || !gADScrollMomentumActive || !gADScrollDidWriteOffset) {
        ADScrollReset();
        return;
    }
    if (!sv.window) {
        ADScrollReset();
        return;
    }
    CGFloat speed = fabsf(gADScrollVelocityY);
    if (speed < 18.0f) {
        ADScrollReset();
        return;
    }
    CGFloat currentY = sv.contentOffset.y;
    CGFloat nextY = ADScrollClampedY(sv, currentY - (gADScrollVelocityY / 60.0f));
    if (fabsf(nextY - currentY) < 0.05f) {
        gADScrollVelocityY *= 0.5f;
    } else {
        [sv setContentOffset:CGPointMake(sv.contentOffset.x, nextY) animated:NO];
        gADScrollVelocityY *= 0.94f;
    }
    if (fabsf(gADScrollVelocityY) < 18.0f) {
        ADScrollReset();
    }
}
@end

static void ADScrollBeginIfNeeded(UITouch *touch, UIView *hitView) {
    if (!touch || !hitView) return;
    if (ADViewHasControlAncestor(hitView)) return;
    if (gADScrollTouch && !ADScrollTouchIsActive(gADScrollTouch)) {
        ADScrollReset();
    }
    if (gADScrollTouch && touch != gADScrollTouch) return;
    UIScrollView *sv = ADNearestScrollView(hitView);
    if (!sv || !sv.scrollEnabled) return;
    if (!gADScrollTouch) {
        // A fresh touch always stops any in-flight momentum scroll (and releases
        // the previously retained scroll view) — classic touch-to-stop.
        ADScrollReset();
        gADScrollTouch = touch;
        gADScrollView = [sv retain];
        // Window coordinates: deltas must NOT be measured in the scroll view's own
        // coordinate space, because our setContentOffset: changes that space and
        // would feed back into the delta (scroll would run at half speed).
        gADScrollStartPoint = [touch locationInView:sv.window];
        gADScrollStartOffset = sv.contentOffset;
        gADScrollLastPoint = gADScrollStartPoint;
        gADScrollLastTime = CACurrentMediaTime();
        gADScrollVelocityY = 0;
        gADScrollEngaged = NO;
        gADScrollDidWriteOffset = NO;
    }
}

static void ADScrollUpdateIfNeeded(UITouch *touch) {
    if (!gADScrollTouch || touch != gADScrollTouch || !gADScrollView) return;
    if (!ADScrollTouchIsActive(touch)) return;
    CGPoint p = [touch locationInView:gADScrollView.window];
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = now - gADScrollLastTime;
    CGFloat stepY = p.y - gADScrollLastPoint.y;
    if (dt > 0) {
        CGFloat frameVelocityY = stepY / dt;
        gADScrollVelocityY = (gADScrollVelocityY * 0.35f) + (frameVelocityY * 0.65f);
    }
    gADScrollLastPoint = p;
    gADScrollLastTime = now;

    CGFloat dx = p.x - gADScrollStartPoint.x;
    CGFloat dy = p.y - gADScrollStartPoint.y;
    if (!gADScrollEngaged) {
        if (fabsf(dx) < 4.0f && fabsf(dy) < 4.0f) return;
        if (fabsf(dy) < fabsf(dx)) return;
        gADScrollEngaged = YES;
    }
    if ([gADScrollView respondsToSelector:@selector(isDragging)] && [gADScrollView isDragging]) return;
    // INCREMENTAL scrolling: move relative to the CURRENT contentOffset by this
    // frame's finger delta, instead of "startOffset - totalDelta". The absolute
    // formula snaps the content back whenever the offset changed under us mid-
    // drag — UIKit's own tracking taking a few frames, a table reloadData from
    // infinite-scroll loadMore, contentSize growth, etc. — which is exactly the
    // visible "scroll suddenly jumps" bug. Per-frame deltas are immune: each
    // frame only ever moves by what the finger moved since the previous frame.
    CGFloat ny = ADScrollClampedY(gADScrollView, gADScrollView.contentOffset.y - stepY);
    if (fabsf(ny - gADScrollView.contentOffset.y) > 0.05f) {
        [gADScrollView setContentOffset:CGPointMake(gADScrollView.contentOffset.x, ny) animated:NO];
        gADScrollDidWriteOffset = YES;
    }
}

static void ADScrollFinishIfNeeded(UITouch *touch) {
    if (!gADScrollTouch || touch != gADScrollTouch) return;
    gADScrollTouch = nil;
    gADScrollMomentumActive = YES;
    gADScrollEngaged = NO;
    gADScrollStartPoint = CGPointZero;
    gADScrollLastPoint = CGPointZero;
    gADScrollLastTime = 0;
    if (!gADScrollView) return;
    if (![gADScrollView respondsToSelector:@selector(isDragging)] || [gADScrollView isDragging]) {
        ADScrollReset();
        return;
    }
    if (!gADScrollDidWriteOffset || fabsf(gADScrollVelocityY) < 18.0f) {
        ADScrollReset();
        return;
    }
    if (!gADScrollMomentumDriver) {
        gADScrollMomentumDriver = [[ADScrollMomentumDriver alloc] init];
    }
    ADScrollStopMomentum();
    gADScrollMomentumTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 60.0)
                                                              target:gADScrollMomentumDriver
                                                            selector:@selector(adScrollMomentumTick:)
                                                            userInfo:nil
                                                             repeats:YES];
}

// Our addGestureRecognizer: — stores the AD recognizer on the view (retained by
// the associated array, matching UIKit's "view owns its recognizers"), sets the
// recognizer's non-retained back-pointer, and ensures touch handling is on.
static void ADView_addGestureRecognizer(id self, SEL _cmd, id gr) {
    if (![gr isKindOfClass:[ADGestureRecognizer class]]) return;
    UIView *view = (UIView *)self;
    NSMutableArray *arr = ADViewRecognizers(view, YES);
    if (![arr containsObject:gr]) [arr addObject:gr];
    [(ADGestureRecognizer *)gr setView:view];
    view.userInteractionEnabled = YES;
}

static void ADView_removeGestureRecognizer(id self, SEL _cmd, id gr) {
    NSMutableArray *arr = ADViewRecognizers((UIView *)self, NO);
    if (arr) [arr removeObject:gr];
    if ([gr isKindOfClass:[ADGestureRecognizer class]]) [(ADGestureRecognizer *)gr setView:nil];
}

#pragma mark - Dispatch engine: UIWindow -sendEvent: swizzle

// Walk the hit view's superview chain and deliver `touches` (phase `phase`) to
// every AD recognizer attached to those views. This is the heart of the engine.
static void ADDeliver(UIView *startView, NSSet *touches, UIEvent *event, NSInteger phase) {
    UIView *v = startView;
    while (v) {
        NSMutableArray *recs = ADViewRecognizers(v, NO);
        if (recs.count) {
            // Copy: a recognizer's action can mutate the tree mid-iteration.
            NSArray *snap = [[recs copy] autorelease];
            for (ADGestureRecognizer *r in snap) {
                if (!r.enabled) continue;
                switch (phase) {
                    case 0: [r adTouchesBegan:touches withEvent:event]; break;
                    case 1: [r adTouchesMoved:touches withEvent:event]; break;
                    case 2: [r adTouchesEnded:touches withEvent:event]; break;
                    default: [r adTouchesCancelled:touches withEvent:event]; break;
                }
            }
        }
        v = v.superview;
    }
}

static IMP gOrigSendEvent = NULL;

static void ADWindow_sendEvent(id self, SEL _cmd, UIEvent *event) {
    NSSet *touches = nil;
    UIView *deliverFrom = nil;
    NSMutableSet *began = nil, *moved = nil, *ended = nil, *cancelled = nil;

    @try {
        touches = [event allTouches];
        UITouch *any = [touches anyObject];
        if (any) {
            UIView *hit = [any view];   // the view the touch landed in
            // Group touches by phase (AppDrop only ever uses single-finger
            // gestures, but handle the set generally and cheaply).
            for (UITouch *t in touches) {
                UITouchPhase ph = [t phase];
                NSMutableSet **bucket =
                    (ph == UITouchPhaseBegan)     ? &began :
                    (ph == UITouchPhaseMoved)     ? &moved :
                    (ph == UITouchPhaseStationary)? &moved :
                    (ph == UITouchPhaseEnded)     ? &ended : &cancelled;
                if (!*bucket) *bucket = [NSMutableSet set];
                [*bucket addObject:t];
            }
            deliverFrom = hit ?: self;
        }
    } @catch (id e) {
        // Never let gesture bookkeeping take down event delivery.
    }

    // First let UIKit process the touch normally so scroll views, tables and
    // controls get the earliest possible chance to begin tracking a drag.
    ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);

    // Then feed the same touch stream to AppDrop's backported recognizers.
    // Keeping this after UIKit is what makes the custom gesture layer coexist
    // with scrolling instead of fighting it.
    @try {
        if (deliverFrom) {
            if (began) {
                for (UITouch *t in began) ADScrollBeginIfNeeded(t, deliverFrom);
                ADDeliver(deliverFrom, began, event, 0);
            }
            if (moved) {
                for (UITouch *t in moved) ADScrollUpdateIfNeeded(t);
                ADDeliver(deliverFrom, moved, event, 1);
            }
            if (ended) {
                for (UITouch *t in ended) ADScrollFinishIfNeeded(t);
                ADDeliver(deliverFrom, ended, event, 2);
            }
            if (cancelled) {
                for (UITouch *t in cancelled) ADScrollFinishIfNeeded(t);
                ADDeliver(deliverFrom, cancelled, event, 3);
            }
        }
    } @catch (id e) {
        // Never let gesture dispatch take down event delivery.
    }
}

#pragma mark - Install

@interface ADGestureRecognizer (Install)
@end

@implementation ADGestureRecognizer (Install)
+ (void)load {
    @autoreleasepool {
        // 1) addGestureRecognizer: / removeGestureRecognizer: on UIView.
        //    iOS 3.1: absent  → class_addMethod installs ours.
        //    iOS 3.2+: present → method_setImplementation routes to our store
        //              (the app uses AD* recognizers exclusively, so UIKit's
        //               native engine is intentionally bypassed).
        Class viewCls = [UIView class];
        SEL addSel = @selector(addGestureRecognizer:);
        SEL remSel = @selector(removeGestureRecognizer:);
        Method addM = class_getInstanceMethod(viewCls, addSel);
        if (addM) {
            method_setImplementation(addM, (IMP)ADView_addGestureRecognizer);
        } else {
            class_addMethod(viewCls, addSel, (IMP)ADView_addGestureRecognizer, "v@:@");
        }
        Method remM = class_getInstanceMethod(viewCls, remSel);
        if (remM) {
            method_setImplementation(remM, (IMP)ADView_removeGestureRecognizer);
        } else {
            class_addMethod(viewCls, remSel, (IMP)ADView_removeGestureRecognizer, "v@:@");
        }

        // 2) Swizzle UIWindow -sendEvent: to run our dispatch engine on every
        //    touch, then forward to the original.
        Class winCls = [UIWindow class];
        SEL seSel = @selector(sendEvent:);
        Method seM = class_getInstanceMethod(winCls, seSel);
        if (seM) {
            gOrigSendEvent = method_getImplementation(seM);
            method_setImplementation(seM, (IMP)ADWindow_sendEvent);
        }
    }
}
@end
