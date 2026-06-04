#import "CategoryTileView.h"
#import "IconLoader.h"
#import "IOS6Theme.h"

@interface CategoryTileView ()
@property (nonatomic, strong) UIImageView *bgView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIImageView *chevron;
@property (nonatomic, copy) NSString *currentIconUrl;
@property (nonatomic, copy) NSString *colorSeed;
@property (nonatomic, assign) CGSize bgDrawnSize;
@property (nonatomic, strong) NSArray *iconPool;          // cleaned URL pool (mosaic mode)
@property (nonatomic, strong) NSMutableArray *mosaicSlots;   // ≤4 URLs (NSString) or NSNull, one per cell
@property (nonatomic, strong) NSMutableArray *mosaicImgs;    // ≤4 UIImage or NSNull (loaded per cell)
@property (nonatomic, strong) NSMutableArray *mosaicReserve; // fallback URLs to backfill failed cells
@property (nonatomic, assign) NSInteger mosaicReserveIdx;
@property (nonatomic, assign) NSInteger mosaicGen;           // bumped on (re)configure → drop stale loads
@property (nonatomic, assign) CGFloat mosaicDrawnSide;       // px side the mosaic was last composited at
@property (nonatomic, strong) UIImageView *resizeHandle;    // readonly in .h; readwrite here
@property (nonatomic, strong) UIButton *deleteBadge;        // top-left ⊗ (edit mode, folders only)
@end

// Pick up to n random items from a pool (partial Fisher–Yates) — gives the mosaic variety per visit.
static NSArray *pickN(NSArray *pool, NSUInteger n) {
    if (pool.count <= n) return pool ?: @[];
    NSMutableArray *m = [pool mutableCopy];
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger j = i + arc4random_uniform((uint32_t)(m.count - i));
        [m exchangeObjectAtIndex:i withObjectAtIndex:j];
    }
    return [m subarrayWithRange:NSMakeRange(0, n)];
}

@implementation CategoryTileView

#pragma mark - Drawing helpers

// OPAQUE rounded card: corners baked over the page colour (no alpha blending at
// scroll time) + solid white interior + 1px border. Cached per size.
+ (UIImage *)cardBgForSize:(CGSize)size {
    if (size.width < 2 || size.height < 2) return nil;
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [NSMutableDictionary dictionary];
    // Key includes the theme id so cards are re-drawn (not served stale) after a theme switch.
    NSString *key = [NSString stringWithFormat:@"%@|%.0fx%.0f", [IOS6Theme currentThemeID], size.width, size.height];
    UIImage *cached = cache[key];
    if (cached) return cached;
    CGFloat scale = [UIScreen mainScreen].scale;
    UIGraphicsBeginImageContextWithOptions(size, YES, scale);   // opaque
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[IOS6Theme contentBackgroundColor] setFill];
    CGContextFillRect(ctx, CGRectMake(0, 0, size.width, size.height));
    CGRect r = CGRectMake(0.5, 0.5, size.width - 1, size.height - 1);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:12];
    [[IOS6Theme cellColor] setFill];        // white card on default, raised dark card on dark themes
    [path fill];
    [[IOS6Theme separatorColor] setStroke];
    path.lineWidth = 1.0;
    [path stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    cache[key] = img;
    return img;
}

// Stable pleasant colour from a seed string.
+ (UIColor *)colorForSeed:(NSString *)seed {
    static const CGFloat palette[][3] = {
        {0.20,0.60,0.86},{0.18,0.74,0.44},{0.90,0.49,0.13},{0.58,0.35,0.74},
        {0.91,0.30,0.39},{0.09,0.71,0.62},{0.95,0.71,0.06},{0.27,0.35,0.45},
        {0.85,0.33,0.58},{0.16,0.50,0.73},{0.83,0.44,0.16},{0.40,0.55,0.20},
    };
    NSInteger n = sizeof(palette)/sizeof(palette[0]);
    NSUInteger h = 5381;
    for (NSUInteger i = 0; i < seed.length; i++) h = ((h << 5) + h) + [seed characterAtIndex:i];
    const CGFloat *c = palette[h % n];
    return [UIColor colorWithRed:c[0] green:c[1] blue:c[2] alpha:1.0];
}

// Coloured rounded-square placeholder with the first letter of `seed`.
// When `seed` is nil -> a branded blue square with a 2×2 white grid glyph ("all apps").
- (UIImage *)placeholderForSize:(CGFloat)s {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, [UIScreen mainScreen].scale);
    CGFloat radius = s * 0.225;
    CGRect rect = CGRectMake(0, 0, s, s);
    UIBezierPath *sq = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
    if (!self.colorSeed.length) {
        // branded "all apps" glyph
        [[UIColor colorWithRed:0.16 green:0.50 blue:0.86 alpha:1.0] setFill];
        [sq fill];
        [[UIColor whiteColor] setFill];
        CGFloat g = s * 0.16, gap = s * 0.10, x0 = s*0.27, y0 = s*0.27;
        for (int i = 0; i < 2; i++)
            for (int j = 0; j < 2; j++) {
                CGRect cell = CGRectMake(x0 + i*(g+gap), y0 + j*(g+gap), g, g);
                [[UIBezierPath bezierPathWithRoundedRect:cell cornerRadius:g*0.25] fill];
            }
    } else {
        [[CategoryTileView colorForSeed:self.colorSeed] setFill];
        [sq fill];
        NSString *src = self.titleLabel.text.length ? self.titleLabel.text : self.colorSeed;
        NSString *letter = [[src substringToIndex:1] uppercaseString];
        UIFont *f = [UIFont boldSystemFontOfSize:s * 0.5];
        CGSize ts;
        if ([letter respondsToSelector:@selector(sizeWithAttributes:)]) {
            ts = [letter sizeWithAttributes:@{NSFontAttributeName:f}];
        } else {
            ts = [letter sizeWithFont:f];
        }
        CGPoint p = CGPointMake((s - ts.width)/2, (s - ts.height)/2);
        if ([letter respondsToSelector:@selector(drawAtPoint:withAttributes:)]) {
            [letter drawAtPoint:p withAttributes:@{NSFontAttributeName:f,
                NSForegroundColorAttributeName:[UIColor whiteColor]}];
        } else {
            [[UIColor whiteColor] set];
            [letter drawAtPoint:p withFont:f];
        }
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Corner resize grip (shown in Home edit mode): a translucent dark disc with a double diagonal arrow.
+ (UIImage *)resizeGripGlyph {
    static UIImage *img = nil;
    if (img) return img;
    CGFloat s = 26;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor colorWithWhite:0.10 alpha:0.62] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, s-2, s-2)] fill];
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextMoveToPoint(ctx, 9, 17);  CGContextAddLineToPoint(ctx, 17, 9);  CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, 12.5, 18.5); CGContextAddLineToPoint(ctx, 18.5, 12.5); CGContextStrokePath(ctx);
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Top-left delete badge (shown in Home edit mode on removable folder tiles): a dark disc with a
// white ✕ and a thin white ring so it stays visible on any card colour. Cached static (cheap on A4).
+ (UIImage *)deleteBadgeGlyph {
    static UIImage *img = nil;
    if (img) return img;
    CGFloat s = 26;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // White ring for contrast, then the dark disc inside it.
    [[UIColor whiteColor] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, s-2, s-2)] fill];
    [[UIColor colorWithWhite:0.13 alpha:1.0] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(2.5, 2.5, s-5, s-5)] fill];
    // White ✕.
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 2.2);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextMoveToPoint(ctx, 9, 9);   CGContextAddLineToPoint(ctx, 17, 17); CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, 17, 9);  CGContextAddLineToPoint(ctx, 9, 17);  CGContextStrokePath(ctx);
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Right-pointing chevron glyph for the wide banner.
+ (UIImage *)chevronGlyph {
    static UIImage *img = nil;
    if (img) return img;
    CGFloat s = 14;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetRGBStrokeColor(ctx, 0.62, 0.64, 0.68, 1.0);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, 4, 3);
    CGContextAddLineToPoint(ctx, 9, 7);
    CGContextAddLineToPoint(ctx, 4, 11);
    CGContextStrokePath(ctx);
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Composite a 2×2 collage from up to 4 images (NSNull entries → neutral empty cell). Each cell is a
// rounded square; gaps + corners are transparent so the tile's card colour shows through.
+ (UIImage *)mosaicFromImages:(NSArray *)imgs size:(CGFloat)s {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat gap = 3.0;
    CGFloat cell = (s - gap) / 2.0;
    CGFloat rr = cell * 0.24;
    CGPoint org[4] = { {0,0}, {cell+gap,0}, {0,cell+gap}, {cell+gap,cell+gap} };
    UIColor *empty = [[IOS6Theme separatorColor] colorWithAlphaComponent:0.45];
    for (int i = 0; i < 4; i++) {
        CGRect r = CGRectMake(org[i].x, org[i].y, cell, cell);
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:rr];
        id im = (i < (int)imgs.count) ? imgs[i] : (id)[NSNull null];
        if ([im isKindOfClass:[UIImage class]]) {
            CGContextSaveGState(ctx);
            [clip addClip];
            [(UIImage *)im drawInRect:r];   // square icons → fills the square cell
            CGContextRestoreGState(ctx);
        } else {
            [empty setFill];
            [clip fill];
        }
    }
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // Opaque throughout (no alpha blending) for smooth scrolling on old GPUs.
        self.opaque = YES;
        self.backgroundColor = [IOS6Theme contentBackgroundColor];

        self.bgView = [[UIImageView alloc] initWithFrame:self.bounds];
        self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.bgView.opaque = YES;
        [self addSubview:self.bgView];

        self.iconView = [[UIImageView alloc] init];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.opaque = YES;
        self.iconView.backgroundColor = [IOS6Theme cellColor];
        [self addSubview:self.iconView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        self.titleLabel.textColor = [IOS6Theme titleColor];
        self.titleLabel.numberOfLines = 2;
        self.titleLabel.opaque = YES;
        self.titleLabel.backgroundColor = [IOS6Theme cellColor];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.font = [UIFont systemFontOfSize:11];
        self.subtitleLabel.textColor = [IOS6Theme labelGray];
        self.subtitleLabel.numberOfLines = 1;
        self.subtitleLabel.opaque = YES;
        self.subtitleLabel.backgroundColor = [IOS6Theme cellColor];
        [self addSubview:self.subtitleLabel];

        self.chevron = [[UIImageView alloc] initWithImage:[CategoryTileView chevronGlyph]];
        self.chevron.hidden = YES;
        [self addSubview:self.chevron];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(tapped)];
        [self addGestureRecognizer:tap];

        self.resizeHandle = [[UIImageView alloc] initWithImage:[CategoryTileView resizeGripGlyph]];
        self.resizeHandle.hidden = YES;
        self.resizeHandle.userInteractionEnabled = YES;   // receives the resize pan (added by the VC)
        [self addSubview:self.resizeHandle];

        self.deleteBadge = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.deleteBadge setImage:[CategoryTileView deleteBadgeGlyph] forState:UIControlStateNormal];
        self.deleteBadge.hidden = YES;
        // Generous hit area around the small disc so it's easy to tap on a tiny tile.
        self.deleteBadge.contentEdgeInsets = UIEdgeInsetsMake(7, 7, 7, 7);
        [self.deleteBadge addTarget:self action:@selector(deleteBadgeTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.deleteBadge];
    }
    return self;
}

- (void)deleteBadgeTapped { if (self.onDelete) self.onDelete(); }

- (void)setShowDeleteBadge:(BOOL)show {
    self.deleteBadge.hidden = !show;
    if (show) [self bringSubviewToFront:self.deleteBadge];
}

- (void)setShowResizeHandle:(BOOL)show {
    self.resizeHandle.hidden = !show;
    [self setNeedsLayout];
}

- (void)configureWithLabel:(NSString *)label
                  subtitle:(NSString *)subtitle
                   iconURL:(NSString *)iconURL
                 colorSeed:(NSString *)colorSeed {
    self.colorSeed = colorSeed;
    self.titleLabel.text = label ?: @"";
    self.subtitleLabel.text = subtitle ?: @"";
    self.titleLabel.textAlignment = self.wide ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    self.subtitleLabel.textAlignment = self.wide ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    self.chevron.hidden = !self.wide;

    self.currentIconUrl = [iconURL copy];
    [self setNeedsLayout];

    if (!iconURL.length) {
        // Placeholder drawn in layoutSubviews (needs the icon size).
        self.iconView.image = nil;
        return;
    }
    CGSize sz = CGSizeMake(self.wide ? 40 : 64, self.wide ? 40 : 64);
    UIImage *cached = [[IconLoader shared] cachedImageForURL:iconURL targetSize:sz];
    if (cached) {
        self.iconView.image = cached;
    } else {
        self.iconView.image = nil;   // placeholder applied in layoutSubviews
        [self setNeedsLayout];
        __weak typeof(self) weakSelf = self;
        [[IconLoader shared] loadImageForURL:iconURL targetSize:sz via:nil
                                  completion:^(UIImage *img) {
            __strong typeof(self) s = weakSelf;
            if (!s || !img) return;
            if (![s.currentIconUrl isEqualToString:iconURL]) return;
            s.iconView.image = img;
        }];
    }
}

- (void)reshuffleIconURL:(NSString *)iconURL {
    self.currentIconUrl = [iconURL copy];
    if (!iconURL.length) return;   // nothing to load -> keep whatever is shown
    CGSize sz = CGSizeMake(self.wide ? 40 : 64, self.wide ? 40 : 64);
    UIImage *cached = [[IconLoader shared] cachedImageForURL:iconURL targetSize:sz];
    if (cached) { self.iconView.image = cached; return; }
    // Keep the current image visible (no placeholder flash) until the new one loads.
    __weak typeof(self) weakSelf = self;
    [[IconLoader shared] loadImageForURL:iconURL targetSize:sz via:nil
                              completion:^(UIImage *img) {
        __strong typeof(self) s = weakSelf;
        if (!s || !img) return;
        if (![s.currentIconUrl isEqualToString:iconURL]) return;
        s.iconView.image = img;
    }];
}

- (void)setGlyphImage:(UIImage *)img {
    self.currentIconUrl = nil;        // cancel any pending URL load / placeholder
    self.iconView.image = img;
}

#pragma mark - Mosaic

- (void)configureMosaicWithLabel:(NSString *)label
                        subtitle:(NSString *)subtitle
                        iconURLs:(NSArray *)iconURLs
                       colorSeed:(NSString *)colorSeed {
    self.colorSeed = colorSeed;
    self.titleLabel.text = label ?: @"";
    self.subtitleLabel.text = subtitle ?: @"";
    self.titleLabel.textAlignment = self.wide ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    self.subtitleLabel.textAlignment = self.wide ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    self.chevron.hidden = !self.wide;
    // Keep only real (non-empty) icon URLs — an app with no icon never enters the mosaic.
    NSMutableArray *clean = [NSMutableArray array];
    for (id u in (iconURLs ?: @[]))
        if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) [clean addObject:u];
    self.iconPool = clean;
    [self startMosaic];
    [self setNeedsLayout];
}

- (void)reshuffleMosaic {
    if (self.iconPool.count < 2) return;   // 0/1 icon → nothing to vary
    [self startMosaic];
}

// Assign 4 random icons to the 4 cells; the rest of the pool becomes a reserve used to BACKFILL any
// cell whose icon fails to load (404 on the mirror) — so a category mosaic stays full of REAL icons
// instead of showing blanks. A generation counter drops stale async results after a reshuffle/resize.
- (void)startMosaic {
    self.mosaicGen++;
    NSArray *pool = self.iconPool ?: @[];
    if (pool.count == 0) { self.mosaicSlots = nil; self.currentIconUrl = nil; self.iconView.image = nil; [self setNeedsLayout]; return; }
    if (pool.count == 1) { self.mosaicSlots = nil; self.iconView.image = nil; [self reshuffleIconURL:pool[0]]; return; }

    NSArray *picks = pickN(pool, 4);
    self.mosaicSlots = [picks mutableCopy];
    NSMutableArray *reserve = [pool mutableCopy];
    [reserve removeObjectsInArray:picks];
    self.mosaicReserve = reserve;
    self.mosaicReserveIdx = 0;
    self.mosaicImgs = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.mosaicSlots.count; i++) [self.mosaicImgs addObject:[NSNull null]];
    [self loadMosaicSlots];
}

- (void)loadMosaicSlots {
    CGSize sz = CGSizeMake(64, 64);
    NSInteger gen = self.mosaicGen;
    __weak typeof(self) ws = self;
    for (NSUInteger i = 0; i < self.mosaicSlots.count; i++) {
        if ([self.mosaicImgs[i] isKindOfClass:[UIImage class]]) continue;
        id slotURL = self.mosaicSlots[i];
        if (![slotURL isKindOfClass:[NSString class]]) continue;
        UIImage *c = [[IconLoader shared] cachedImageForURL:slotURL targetSize:sz];
        if (c) { self.mosaicImgs[i] = c; continue; }
        NSUInteger slot = i;
        [[IconLoader shared] loadImageForURL:slotURL targetSize:sz via:nil completion:^(UIImage *img) {
            __strong typeof(self) s = ws; if (!s || s.mosaicGen != gen) return;
            if (img) { s.mosaicImgs[slot] = img; [s compositeMosaic]; }
            else     { [s backfillSlot:slot gen:gen]; }   // 404 → pull a reserve icon
        }];
    }
    [self compositeMosaic];
}

// A cell's icon failed → swap in the next reserve icon and load that; empty the cell only once the
// reserve is exhausted.
- (void)backfillSlot:(NSUInteger)slot gen:(NSInteger)gen {
    if (self.mosaicGen != gen || slot >= self.mosaicSlots.count) return;
    if (self.mosaicReserveIdx >= (NSInteger)self.mosaicReserve.count) {
        self.mosaicSlots[slot] = [NSNull null];
        self.mosaicImgs[slot]  = [NSNull null];
        [self compositeMosaic];
        return;
    }
    NSString *next = self.mosaicReserve[self.mosaicReserveIdx++];
    self.mosaicSlots[slot] = next;
    self.mosaicImgs[slot]  = [NSNull null];
    CGSize sz = CGSizeMake(64, 64);
    UIImage *c = [[IconLoader shared] cachedImageForURL:next targetSize:sz];
    if (c) { self.mosaicImgs[slot] = c; [self compositeMosaic]; return; }
    __weak typeof(self) ws = self;
    [[IconLoader shared] loadImageForURL:next targetSize:sz via:nil completion:^(UIImage *img) {
        __strong typeof(self) s = ws; if (!s || s.mosaicGen != gen) return;
        if (img) { s.mosaicImgs[slot] = img; [s compositeMosaic]; }
        else     { [s backfillSlot:slot gen:gen]; }
    }];
}

- (void)compositeMosaic {
    if (self.mosaicSlots.count == 0) return;
    NSMutableArray *imgs = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.mosaicImgs.count; i++) {
        id v = self.mosaicImgs[i];
        [imgs addObject:([v isKindOfClass:[UIImage class]] ? v : (id)[NSNull null])];
    }
    self.currentIconUrl = nil;   // mosaic owns the image now
    CGFloat side = self.iconView.frame.size.width > 1 ? self.iconView.frame.size.width : 64;
    self.mosaicDrawnSide = side;
    self.iconView.image = [CategoryTileView mosaicFromImages:imgs size:side];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (!CGSizeEqualToSize(b.size, self.bgDrawnSize)) {
        self.bgView.image = [CategoryTileView cardBgForSize:b.size];
        self.bgDrawnSize = b.size;
    }

    if (self.wide) {
        CGFloat icon = 40, pad = 12;
        self.iconView.frame = CGRectMake(pad, (b.size.height - icon)/2, icon, icon);
        self.chevron.frame = CGRectMake(b.size.width - 20, (b.size.height - 14)/2, 14, 14);
        CGFloat tx = pad + icon + 12;
        CGFloat tw = b.size.width - tx - 26;
        BOOL hasSub = self.subtitleLabel.text.length > 0;
        if (hasSub) {
            self.titleLabel.frame = CGRectMake(tx, b.size.height/2 - 19, tw, 20);
            self.subtitleLabel.frame = CGRectMake(tx, b.size.height/2 + 1, tw, 16);
        } else {
            self.titleLabel.frame = CGRectMake(tx, (b.size.height - 22)/2, tw, 22);
        }
    } else {
        // Adaptive icon size so a resized tile (2×1 / 2×2) shows a bigger mosaic instead of a tiny
        // 64px one floating in a large card. Clamped so 1×1 tiles still look right.
        CGFloat icon = floorf(MIN(b.size.height * 0.46, b.size.width * 0.52));
        if (icon < 40)  icon = 40;
        if (icon > 128) icon = 128;
        CGFloat topPad = MAX(8, floorf(b.size.height * 0.10));
        self.iconView.frame = CGRectMake((b.size.width - icon)/2, topPad, icon, icon);

        // v3.0: shrink the text WITH the tile so it stays fully visible when the Home density packs
        // many small tiles per row — smaller font, single line + no "N apps" count on the tiniest tiles.
        CGFloat fs = b.size.width / 165.0; if (fs > 1.0) fs = 1.0; if (fs < 0.66) fs = 0.66;
        self.titleLabel.font    = [UIFont boldSystemFontOfSize:floorf(13.0 * fs + 0.5)];
        self.subtitleLabel.font = [UIFont systemFontOfSize:floorf(11.0 * fs + 0.5)];
        // v3.0: on small tiles (iPhone Accueil at 3 columns ≈ 92 pt, or dense iPad grids) the subtitle
        // — the description / "N apps" — can't fit cleanly, so show the NAME only.
        self.subtitleLabel.hidden = (b.size.width < 115);
        BOOL oneLine = (b.size.width < 88);
        self.titleLabel.numberOfLines = oneLine ? 1 : 2;

        CGFloat tY = CGRectGetMaxY(self.iconView.frame) + 5;
        CGFloat titleH = floorf((oneLine ? 18.0 : 34.0) * fs);
        if (self.subtitleLabel.hidden) {
            // Name-only tile: centre the title in the space below the icon (no empty band at the bottom).
            CGFloat avail = b.size.height - tY - 4;
            if (avail < titleH) avail = titleH;
            self.titleLabel.frame = CGRectMake(3, tY + floorf((avail - titleH) / 2.0), b.size.width - 6, titleH);
        } else {
            self.titleLabel.frame = CGRectMake(3, tY, b.size.width - 6, titleH);
            self.subtitleLabel.frame = CGRectMake(3, b.size.height - 20, b.size.width - 6, 16);
        }
    }

    // Apply placeholder once we know the icon frame (only if no real image set).
    if (!self.iconView.image) {
        self.iconView.image = [self placeholderForSize:self.iconView.frame.size.width];
    }
    // Mosaic: recomposite at the new icon size for crispness when the tile is resized.
    if (self.mosaicSlots.count && fabs(self.iconView.frame.size.width - self.mosaicDrawnSide) > 2.0) {
        [self compositeMosaic];
    }

    CGFloat hs = 26;
    self.resizeHandle.frame = CGRectMake(b.size.width - hs - 5, b.size.height - hs - 5, hs, hs);
    if (!self.resizeHandle.hidden) [self bringSubviewToFront:self.resizeHandle];

    // Delete badge: the 26pt disc sits ~3px from the top-left corner (button has 7px padding for a
    // bigger tap target), fully inside bounds so every part of the disc stays tappable on old devices.
    self.deleteBadge.frame = CGRectMake(-4, -4, 40, 40);
    if (!self.deleteBadge.hidden) [self bringSubviewToFront:self.deleteBadge];
}

// <ADThemable> — re-theme live: recolour labels + force the cached card to redraw.
- (void)applyTheme {
    self.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.iconView.backgroundColor = [IOS6Theme cellColor];
    self.titleLabel.textColor = [IOS6Theme titleColor];
    self.titleLabel.backgroundColor = [IOS6Theme cellColor];
    self.subtitleLabel.textColor = [IOS6Theme labelGray];
    self.subtitleLabel.backgroundColor = [IOS6Theme cellColor];
    self.bgDrawnSize = CGSizeZero;          // force the card image to be re-fetched for the new theme
    if (self.mosaicSlots.count) [self compositeMosaic];   // empty-cell fill is theme-coloured
    [self setNeedsLayout];
}

- (void)tapped {
    if (!self.onTap) return;
    void (^cb)(void) = [self.onTap copy];
    self.alpha = 0.55;
    [UIView animateWithDuration:0.16 animations:^{ self.alpha = 1.0; }
                     completion:^(BOOL done) { cb(); }];
}

@end
