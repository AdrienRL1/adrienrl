#import "AppTileView.h"
#import "Localization.h"
#import "InstallManager.h"
#import "IconLoader.h"
#import "IOS6Theme.h"

static UIImage *_sharedCheckOn = nil;
static UIImage *_sharedCheckOff = nil;
static BOOL _suppressTileText = NO;   // YES during a fast fling → tiles draw card+icon, skip text

@interface AppTileView ()
// Icon lives in its OWN composited layer (UIImageView). When the (force-decoded) icon arrives
// we just set it — a cheap GPU composite — instead of re-running the tile's drawRect. That's
// the key to smooth scrolling: text/card are drawn once per app, never re-rendered per icon.
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, copy)   NSString *currentIconUrl;
@end

@implementation AppTileView

+ (void)setSuppressTileText:(BOOL)suppress { _suppressTileText = suppress; }

+ (NSString *)humanSize:(long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld %@", bytes, T(@"unit.b")];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.0f %@", bytes / 1024.0, T(@"unit.kb")];
    if (bytes < 1024LL * 1024 * 1024) return [NSString stringWithFormat:@"%.1f %@", bytes / (1024.0 * 1024), T(@"unit.mb")];
    return [NSString stringWithFormat:@"%.2f %@", bytes / (1024.0 * 1024 * 1024), T(@"unit.gb")];
}

// Shared OPAQUE rounded-card background, cached per pixel size. Drawn once, then every tile of
// that size just blits it in drawRect — no per-recycle bezier/stroke cost.
+ (UIImage *)cardImageForSize:(CGSize)size {
    if (size.width < 2 || size.height < 2) return nil;
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *k = [NSString stringWithFormat:@"%.0fx%.0f", size.width, size.height];
    UIImage *hit = cache[k];
    if (hit) return hit;
    UIGraphicsBeginImageContextWithOptions(size, YES, [UIScreen mainScreen].scale);
    [[IOS6Theme contentBackgroundColor] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    UIBezierPath *card = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, size.width - 1, size.height - 1)
                                                    cornerRadius:12];
    [[UIColor whiteColor] setFill];
    [card fill];
    card.lineWidth = 1.0;
    [[UIColor colorWithRed:0.78 green:0.80 blue:0.84 alpha:1.0] setStroke];
    [card stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    cache[k] = img;
    return img;
}

+ (UIImage *)checkGlyphOn {
    if (_sharedCheckOn) return _sharedCheckOn;
    CGFloat size = 26;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetRGBFillColor(ctx, 0.13, 0.55, 0.96, 1.0);
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, size-2, size-2)] fill];
    CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 1);
    CGContextSetLineWidth(ctx, 2.5);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, 7, 13);
    CGContextAddLineToPoint(ctx, 12, 18);
    CGContextAddLineToPoint(ctx, 20, 9);
    CGContextStrokePath(ctx);
    _sharedCheckOn = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return _sharedCheckOn;
}

+ (UIImage *)checkGlyphOff {
    if (_sharedCheckOff) return _sharedCheckOff;
    CGFloat size = 26;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 0.85);
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, size-2, size-2)] fill];
    CGContextSetRGBStrokeColor(ctx, 0.55, 0.58, 0.62, 1.0);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(2, 2, size-4, size-4));
    _sharedCheckOff = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return _sharedCheckOff;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = YES;
        self.backgroundColor = [IOS6Theme contentBackgroundColor];
        self.contentMode = UIViewContentModeRedraw;   // re-blit card + re-draw text on resize
        self.layer.contentsScale = [UIScreen mainScreen].scale;

        self.iconView = [[UIImageView alloc] init];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.opaque = YES;
        self.iconView.backgroundColor = [UIColor whiteColor];   // matches the white card → no blend
        [self addSubview:self.iconView];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(tapped)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

// Icon geometry, shared by layoutSubviews (positions the iconView) and nothing else.
- (CGRect)iconFrameForWidth:(CGFloat)w {
    BOOL tiny = w < 104;
    CGFloat iconTop  = tiny ? 6 : 10;
    CGFloat iconSize = MIN(w - (tiny ? 12 : 24), tiny ? 66 : 80);
    return CGRectMake((w - iconSize) / 2, iconTop, iconSize, iconSize);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.bounds.size.width >= 2) self.iconView.frame = [self iconFrameForWidth:self.bounds.size.width];
}

- (void)setApp:(NSDictionary *)app {
    _app = [app copy];
    if (!app) {
        self.currentIconUrl = nil;
        self.iconView.image = nil;
        self.hidden = YES;
        [self setNeedsDisplay];
        return;
    }
    self.hidden = NO;

    NSString *iconUrl = app[@"icon"];
    self.currentIconUrl = [iconUrl copy];
    CGSize sz = CGSizeMake(80, 80);
    UIImage *cached = iconUrl.length ? [[IconLoader shared] cachedImageForURL:iconUrl targetSize:sz] : nil;
    self.iconView.image = cached;   // already force-decoded by IconLoader → pure composite
    if (iconUrl.length && !cached) {
        __weak typeof(self) ws = self;
        [[IconLoader shared] loadImageForURL:iconUrl targetSize:sz via:nil completion:^(UIImage *img) {
            if (!img) return;
            __strong typeof(self) s = ws;
            if (!s || ![s.currentIconUrl isEqualToString:iconUrl]) return;
            s.iconView.image = img;   // composite only — does NOT trigger drawRect
        }];
    }
    [self setNeedsDisplay];   // re-blit card + re-draw the text (once per app, not per icon)
}

- (void)setSelectionMode:(BOOL)selectionMode {
    if (_selectionMode == selectionMode) return;
    _selectionMode = selectionMode;
    [self setNeedsDisplay];
}

- (void)setTileSelected:(BOOL)tileSelected {
    if (_tileSelected == tileSelected) return;
    _tileSelected = tileSelected;
    if (self.selectionMode) [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGRect b = self.bounds;
    CGFloat w = b.size.width, h = b.size.height;
    if (w < 2 || h < 2) return;

    // 1. Cached opaque rounded card (blit — no bezier per recycle). The iconView (subview)
    //    composites its icon on top of the card's white icon area.
    [[AppTileView cardImageForSize:b.size] drawInRect:b];
    if (!self.app) return;
    // Fast fling: draw only the (cheap, cached) card — the icon still shows via its own layer.
    // Skipping the per-tile TEXT layout here is the remaining main-thread win; the text is
    // redrawn the instant scrolling settles (AppRowCell -redrawTiles).
    if (_suppressTileText) return;

    BOOL compact = w < 132;
    BOOL tiny    = w < 104;
    CGRect iconR = [self iconFrameForWidth:w];
    CGFloat tY = iconR.origin.y + iconR.size.height + (tiny ? 2 : 6);

    NSString *title = self.app[@"title"] ?: @"";
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[UIColor colorWithRed:0.13 green:0.18 blue:0.32 alpha:1.0] set];
    if (compact) {
        UIFont *tf = [UIFont boldSystemFontOfSize:(tiny ? 10 : 11)];
        CGRect tr = CGRectMake(2, tY, w - 4, 14);
        CGSize ts = [title sizeWithFont:tf constrainedToSize:tr.size lineBreakMode:NSLineBreakByTruncatingTail];
        tr.origin.y += MAX(0, (tr.size.height - ts.height) / 2);
        [title drawInRect:tr withFont:tf lineBreakMode:NSLineBreakByTruncatingTail alignment:NSTextAlignmentCenter];
    } else {
        UIFont *tf = [UIFont boldSystemFontOfSize:12];
        CGRect tr = CGRectMake(6, tY, w - 12, 28);
        CGSize ts = [title sizeWithFont:tf constrainedToSize:tr.size lineBreakMode:NSLineBreakByWordWrapping];
        tr.origin.y += MAX(0, (tr.size.height - ts.height) / 2);
        [title drawInRect:tr withFont:tf lineBreakMode:NSLineBreakByWordWrapping alignment:NSTextAlignmentCenter];

        long long size = [self.app[@"size"] longLongValue];
        NSString *sizeStr = size > 0 ? [AppTileView humanSize:size] : @"?";
        NSString *sub = [NSString stringWithFormat:@"v%@ • iOS %@ • %@",
                           self.app[@"version"] ?: @"?", self.app[@"minOS"] ?: @"?", sizeStr];
        [[UIColor grayColor] set];
        [sub drawInRect:CGRectMake(6, h - 18, w - 12, 14)
               withFont:[UIFont systemFontOfSize:10] lineBreakMode:NSLineBreakByTruncatingTail
              alignment:NSTextAlignmentCenter];
    }
#pragma clang diagnostic pop

    if (self.selectionMode) {
        UIImage *g = self.tileSelected ? [AppTileView checkGlyphOn] : [AppTileView checkGlyphOff];
        [g drawInRect:CGRectMake(6, 6, 26, 26)];
    }
}

- (void)tapped {
    if (!self.onTap || !self.app) return;
    self.alpha = 0.5;
    NSDictionary *appCopy = self.app;
    void (^onTap)(NSDictionary *) = [self.onTap copy];
    [UIView animateWithDuration:0.18
                      animations:^{ self.alpha = 1.0; }
                      completion:^(BOOL done) { onTap(appCopy); }];
}

@end
