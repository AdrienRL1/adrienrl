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
@end

@implementation CategoryTileView

#pragma mark - Drawing helpers

// OPAQUE rounded card: corners baked over the page colour (no alpha blending at
// scroll time) + solid white interior + 1px border. Cached per size.
+ (UIImage *)cardBgForSize:(CGSize)size {
    if (size.width < 2 || size.height < 2) return nil;
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%.0fx%.0f", size.width, size.height];
    UIImage *cached = cache[key];
    if (cached) return cached;
    CGFloat scale = [UIScreen mainScreen].scale;
    UIGraphicsBeginImageContextWithOptions(size, YES, scale);   // opaque
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[IOS6Theme contentBackgroundColor] setFill];
    CGContextFillRect(ctx, CGRectMake(0, 0, size.width, size.height));
    CGRect r = CGRectMake(0.5, 0.5, size.width - 1, size.height - 1);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:12];
    [[UIColor whiteColor] setFill];
    [path fill];
    CGContextSetRGBStrokeColor(ctx, 0.78, 0.80, 0.84, 1.0);
    CGContextSetLineWidth(ctx, 1.0);
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
        self.iconView.backgroundColor = [UIColor whiteColor];
        [self addSubview:self.iconView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        self.titleLabel.textColor = [UIColor colorWithRed:0.13 green:0.18 blue:0.32 alpha:1.0];
        self.titleLabel.numberOfLines = 2;
        self.titleLabel.opaque = YES;
        self.titleLabel.backgroundColor = [UIColor whiteColor];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.font = [UIFont systemFontOfSize:11];
        self.subtitleLabel.textColor = [UIColor grayColor];
        self.subtitleLabel.numberOfLines = 1;
        self.subtitleLabel.opaque = YES;
        self.subtitleLabel.backgroundColor = [UIColor whiteColor];
        [self addSubview:self.subtitleLabel];

        self.chevron = [[UIImageView alloc] initWithImage:[CategoryTileView chevronGlyph]];
        self.chevron.hidden = YES;
        [self addSubview:self.chevron];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(tapped)];
        [self addGestureRecognizer:tap];
    }
    return self;
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
        CGFloat icon = 64;
        self.iconView.frame = CGRectMake((b.size.width - icon)/2, 14, icon, icon);
        CGFloat tY = 14 + icon + 6;
        self.titleLabel.frame = CGRectMake(4, tY, b.size.width - 8, 34);
        self.subtitleLabel.frame = CGRectMake(4, b.size.height - 22, b.size.width - 8, 16);
    }

    // Apply placeholder once we know the icon frame (only if no real image set).
    if (!self.iconView.image) {
        self.iconView.image = [self placeholderForSize:self.iconView.frame.size.width];
    }
}

- (void)tapped {
    if (!self.onTap) return;
    void (^cb)(void) = [self.onTap copy];
    self.alpha = 0.55;
    [UIView animateWithDuration:0.16 animations:^{ self.alpha = 1.0; }
                     completion:^(BOOL done) { cb(); }];
}

@end
