// AppDropBezier.m — self-contained UIBezierPath for iOS 3.1.x / armv6.
//
// UIBezierPath first shipped in iOS 3.2. On iOS 3.1.3 the class symbol is
// present in UIKit but its drawing methods are NOT implemented, so the very
// first glyph the app draws at launch (the home/star tab icons in
// AppDelegate.m, drawn from -setupAppearance) throws:
//
//     *** -[UIBezierPath addLineToPoint:]: unrecognized selector sent to
//         instance 0x2025a0
//     EXCEPTION in setup: NSInvalidArgumentException
//
// The launch @try in -application:didFinishLaunchingWithOptions: catches it and
// shows the "AppDrop failed to launch" screen. (Verified: appdrop-launch.log
// reaches "alloc CatalogVC", then the addLineToPoint: exception fires.)
//
// Rather than try to backfill methods onto Apple's partial 3.1 UIBezierPath
// (whose private ivars/CGPath we cannot reach), this ships a complete,
// self-contained class — ADBezierPath — backed by its own CGMutablePathRef,
// using only CoreGraphics primitives that have existed since iOS 2. The prefix
// header (AppDropCompat.h) does `#define UIBezierPath ADBezierPath`, so every
// existing call site uses this class with no source edits. Drawing output is
// identical (it's the same CoreGraphics fill/stroke/clip underneath), and it
// behaves the same on iOS 3.2–10 where the real class also works.
//
// This mirrors AppDropJSON.m, which likewise supplies a missing Foundation
// class (NSJSONSerialization) self-contained rather than depending on the OS.
//
// API surface implemented (exactly what the AppDrop sources use):
//   + bezierPath
//   + bezierPathWithRect:
//   + bezierPathWithOvalInRect:
//   + bezierPathWithRoundedRect:cornerRadius:
//   - moveToPoint:
//   - addLineToPoint:
//   - closePath
//   - fill
//   - stroke
//   - addClip
//   - CGPath                       (used by IconLoader: CGContextAddPath(ctx, p.CGPath))
//   @property lineWidth            (default 1.0, as UIBezierPath)
//   @property lineCapStyle         (CGLineCap)
//   @property lineJoinStyle        (CGLineJoin)
//   @property usesEvenOddFillRule  (default NO)

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

// The prefix header is force-included (-include AppDropCompat.h) and already
// declares @interface ADBezierPath + the `#define UIBezierPath ADBezierPath`.
// Undefine here so the @implementation keeps its real name (the macro must not
// rewrite the token inside this file).
#ifdef UIBezierPath
#undef UIBezierPath
#endif

@implementation ADBezierPath {
    CGMutablePathRef _path;
}

@synthesize lineWidth = _lineWidth;
@synthesize lineCapStyle = _lineCapStyle;
@synthesize lineJoinStyle = _lineJoinStyle;
@synthesize usesEvenOddFillRule = _usesEvenOddFillRule;

- (id)init {
    self = [super init];
    if (self) {
        _path = CGPathCreateMutable();
        _lineWidth = 1.0;              // UIBezierPath default
        _lineCapStyle = kCGLineCapButt;
        _lineJoinStyle = kCGLineJoinMiter;
        _usesEvenOddFillRule = NO;
    }
    return self;
}

- (void)dealloc {
    if (_path) CGPathRelease(_path);
    [super dealloc];
}

#pragma mark - Constructors

+ (ADBezierPath *)bezierPath {
    return [[[self alloc] init] autorelease];
}

+ (ADBezierPath *)bezierPathWithRect:(CGRect)rect {
    ADBezierPath *p = [self bezierPath];
    CGPathAddRect(p->_path, NULL, rect);
    return p;
}

+ (ADBezierPath *)bezierPathWithOvalInRect:(CGRect)rect {
    ADBezierPath *p = [self bezierPath];
    CGPathAddEllipseInRect(p->_path, NULL, rect);
    return p;
}

+ (ADBezierPath *)bezierPathWithRoundedRect:(CGRect)rect cornerRadius:(CGFloat)radius {
    ADBezierPath *p = [self bezierPath];
    CGFloat maxR = MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) / 2.0;
    CGFloat r = radius;
    if (r < 0) r = 0;
    if (r > maxR) r = maxR;

    if (r <= 0) {                      // degenerate -> plain rectangle
        CGPathAddRect(p->_path, NULL, rect);
        return p;
    }

    CGFloat minX = CGRectGetMinX(rect), minY = CGRectGetMinY(rect);
    CGFloat maxX = CGRectGetMaxX(rect), maxY = CGRectGetMaxY(rect);

    // Clockwise rounded rectangle (matches UIBezierPath's winding).
    CGPathMoveToPoint(p->_path, NULL, minX + r, minY);
    CGPathAddLineToPoint(p->_path, NULL, maxX - r, minY);
    CGPathAddArc(p->_path, NULL, maxX - r, minY + r, r, -M_PI_2, 0.0, NO);
    CGPathAddLineToPoint(p->_path, NULL, maxX, maxY - r);
    CGPathAddArc(p->_path, NULL, maxX - r, maxY - r, r, 0.0, M_PI_2, NO);
    CGPathAddLineToPoint(p->_path, NULL, minX + r, maxY);
    CGPathAddArc(p->_path, NULL, minX + r, maxY - r, r, M_PI_2, M_PI, NO);
    CGPathAddLineToPoint(p->_path, NULL, minX, minY + r);
    CGPathAddArc(p->_path, NULL, minX + r, minY + r, r, M_PI, M_PI + M_PI_2, NO);
    CGPathCloseSubpath(p->_path);
    return p;
}

#pragma mark - Path construction

- (void)moveToPoint:(CGPoint)point {
    CGPathMoveToPoint(_path, NULL, point.x, point.y);
}

- (void)addLineToPoint:(CGPoint)point {
    // If no current point yet, CGPathAddLineToPoint is a no-op on an empty path;
    // start the subpath so a stray addLine before move still behaves sanely.
    if (CGPathIsEmpty(_path)) {
        CGPathMoveToPoint(_path, NULL, point.x, point.y);
    } else {
        CGPathAddLineToPoint(_path, NULL, point.x, point.y);
    }
}

- (void)closePath {
    if (!CGPathIsEmpty(_path)) CGPathCloseSubpath(_path);
}

#pragma mark - Drawing

- (void)fill {
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (!c) return;
    CGContextSaveGState(c);
    CGContextAddPath(c, _path);
    if (_usesEvenOddFillRule) CGContextEOFillPath(c); else CGContextFillPath(c);
    CGContextRestoreGState(c);
}

- (void)stroke {
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (!c) return;
    CGContextSaveGState(c);
    CGContextAddPath(c, _path);
    CGContextSetLineWidth(c, _lineWidth);
    CGContextSetLineCap(c, _lineCapStyle);
    CGContextSetLineJoin(c, _lineJoinStyle);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
}

- (void)addClip {
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (!c) return;
    CGContextAddPath(c, _path);
    if (_usesEvenOddFillRule) CGContextEOClip(c); else CGContextClip(c);
}

#pragma mark - CGPath bridge

- (CGPathRef)CGPath {
    return _path;   // owned by the receiver; callers must not release (UIBezierPath semantics)
}

@end
