#import "AppTileView.h"
#import "Localization.h"
#import "InstallManager.h"
#import "IconLoader.h"
#import "IOS6Theme.h"

static BOOL _suppressTileText = NO;   // YES during a fast fling → tiles draw card+icon, skip text

@interface AppTileView ()
// Icon lives in its OWN composited layer (UIImageView). When the (force-decoded) icon arrives
// we just set it — a cheap GPU composite — instead of re-running the tile's drawRect. That's
// the key to smooth scrolling: text/card are drawn once per app, never re-rendered per icon.
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, copy)   NSString *currentIconUrl;
// Selection check, an OVERLAY above the icon (so it stays visible even on tiny dense tiles where
// the icon fills the card). Updated imperatively → reliably reflects the selected state.
@property (nonatomic, strong) UIImageView *selectionBadge;
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
    if (!cache) cache = [[NSMutableDictionary dictionary] retain];
    NSString *k = [NSString stringWithFormat:@"%@|%.0fx%.0f", [IOS6Theme currentThemeID], size.width, size.height];
    UIImage *hit = cache[k];
    if (hit) return hit;
    UIGraphicsBeginImageContextWithOptions(size, YES, [UIScreen mainScreen].scale);
    [[IOS6Theme contentBackgroundColor] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    UIBezierPath *card = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, size.width - 1, size.height - 1)
                                                    cornerRadius:12];
    [[IOS6Theme cellColor] setFill];
    [card fill];
    card.lineWidth = 1.0;
    [[IOS6Theme separatorColor] setStroke];
    [card stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    cache[k] = img;
    return img;
}

// Both states FOLLOW THE THEME accent and are cached per theme id (cheap: regenerated only when
// the user switches theme). ON = accent-filled disc + white ring + white check; OFF = white disc +
// accent ring. The white ring/disc keep the badge legible on top of ANY app icon.
+ (UIImage *)checkGlyphOn {
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [[NSMutableDictionary dictionary] retain];
    NSString *k = [IOS6Theme currentThemeID] ?: @"_";
    UIImage *hit = cache[k];
    if (hit) return hit;
    CGFloat size = 28;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setFill];                                   // white ring for contrast
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.5, 0.5, size-1, size-1)] fill];
    [[IOS6Theme primaryBlue] setFill];                               // themed accent fill
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, size-4, size-4)] fill];
    CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 1);                      // white check
    CGContextSetLineWidth(ctx, 2.6);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, 8, 14);
    CGContextAddLineToPoint(ctx, 12.5, 19);
    CGContextAddLineToPoint(ctx, 21, 9.5);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    cache[k] = img;
    return img;
}

+ (UIImage *)checkGlyphOff {
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [[NSMutableDictionary dictionary] retain];
    NSString *k = [IOS6Theme currentThemeID] ?: @"_";
    UIImage *hit = cache[k];
    if (hit) return hit;
    CGFloat size = 28;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 0.92);                    // bright disc, visible on any icon
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, size-2, size-2)] fill];
    CGContextSetStrokeColorWithColor(ctx, [IOS6Theme primaryBlue].CGColor);   // themed ring
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(2.5, 2.5, size-5, size-5));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    cache[k] = img;
    return img;
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
        self.iconView.backgroundColor = [IOS6Theme cellColor];   // matches the card → no blend
        [self addSubview:self.iconView];

        // Selection check overlay — ABOVE the icon, hidden until selection mode. Not interactive so
        // a tap anywhere on the tile (including the badge) still toggles selection. Given a real
        // default frame so it's never zero-sized (it's resized to the tile in layoutSubviews).
        self.selectionBadge = [[UIImageView alloc] initWithFrame:CGRectMake(5, 5, 26, 26)];
        self.selectionBadge.contentMode = UIViewContentModeScaleAspectFit;
        self.selectionBadge.userInteractionEnabled = NO;
        self.selectionBadge.hidden = YES;
        [self addSubview:self.selectionBadge];

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
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w < 2 || h < 2) return;
    CGRect ic = [self iconFrameForWidth:w];
    self.iconView.frame = ic;

    // Selection badge: top-left corner, scaled to the tile, kept above the icon.
    CGFloat bs = MAX(18, MIN(28, w * 0.28));
    self.selectionBadge.frame = CGRectMake(5, 5, bs, bs);
    if (!self.selectionBadge.hidden) [self bringSubviewToFront:self.selectionBadge];
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
        AD_WEAK typeof(self) ws = self;
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
    _selectionMode = selectionMode;
    [self updateSelectionBadge];
}

- (void)setTileSelected:(BOOL)tileSelected {
    _tileSelected = tileSelected;
    [self updateSelectionBadge];
}

// Imperative update of the overlay badge — independent of drawRect, so the filled/empty state is
// always correct the instant selection changes (and visible above the icon at any density).
- (void)updateSelectionBadge {
    if (!self.selectionMode) { self.selectionBadge.hidden = YES; return; }
    self.selectionBadge.image = self.tileSelected ? [AppTileView checkGlyphOn] : [AppTileView checkGlyphOff];
    // Set the frame NOW (don't wait for layoutSubviews, which may not re-run on a reused cell), so
    // the badge is never left zero-sized → invisible.
    CGFloat w = self.bounds.size.width;
    if (w >= 2) { CGFloat bs = MAX(18, MIN(28, w * 0.28)); self.selectionBadge.frame = CGRectMake(5, 5, bs, bs); }
    self.selectionBadge.hidden = NO;
    [self bringSubviewToFront:self.selectionBadge];
    [self setNeedsLayout];
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
    [[IOS6Theme titleColor] set];
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
        [[IOS6Theme labelGray] set];
        [sub drawInRect:CGRectMake(6, h - 18, w - 12, 14)
               withFont:[UIFont systemFontOfSize:10] lineBreakMode:NSLineBreakByTruncatingTail
              alignment:NSTextAlignmentCenter];
    }
#pragma clang diagnostic pop
    // The selection check is drawn by the `selectionBadge` overlay (above the icon), not here —
    // so it stays visible on dense tiles where the icon covers the top-left corner.
}

- (void)tapped {
    if (!self.onTap || !self.app) return;
    // Selection mode: instant feedback. Flip the check NOW (optimistic) and fire onTap immediately —
    // no 0.18s press animation to wait through. The controller records it + reloads to confirm
    // (same value → no flicker).
    if (self.selectionMode) {
        self.tileSelected = !self.tileSelected;
        self.onTap(self.app);
        return;
    }
    // Normal browse: brief press flash, then open the detail screen.
    self.alpha = 0.5;
    NSDictionary *appCopy = self.app;
    void (^onTap)(NSDictionary *) = [self.onTap copy];
    [UIView animateWithDuration:0.18
                      animations:^{ self.alpha = 1.0; }
                      completion:^(BOOL done) { onTap(appCopy); }];
}

@end
