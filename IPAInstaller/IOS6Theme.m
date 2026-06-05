#import "IOS6Theme.h"
#import "Localization.h"

NSString * const AppDropThemeChangedNotification = @"AppDropThemeChangedNotification";

// Internal helper: cap-inset stretchable.
static UIImage *stretchable(NSString *name, NSInteger leftCap, NSInteger topCap) {
    UIImage *base = [UIImage imageNamed:name];
    if (!base) return nil;
    return [base stretchableImageWithLeftCapWidth:leftCap topCapHeight:topCap];
}

// Draw a 2×h vertical glossy iOS-6 bar gradient in code, horizontally stretchable.
static UIImage *barGradient(CGFloat h, const CGFloat top[3], const CGFloat bot[3], CGFloat glossTopAlpha) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(2.0, h), YES, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[8] = { top[0],top[1],top[2],1.0,  bot[0],bot[1],bot[2],1.0 };
    CGFloat locs[2] = { 0.0, 1.0 };
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0,0), CGPointMake(0,h), 0);
    CGGradientRelease(g);
    if (glossTopAlpha > 0.0) {
        CGFloat gc[8] = { 1,1,1,glossTopAlpha,  1,1,1,0.0 };
        CGGradientRef gg = CGGradientCreateWithColorComponents(cs, gc, locs, 2);
        CGContextDrawLinearGradient(ctx, gg, CGPointMake(0,0), CGPointMake(0,h*0.5), 0);
        CGGradientRelease(gg);
    }
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.28].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, h-1, 2, 1));   // 1px bottom hairline
    CGColorSpaceRelease(cs);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img stretchableImageWithLeftCapWidth:1 topCapHeight:0];
}

#pragma mark - Colour math (auto-contrast palette derivation)

static CGFloat ad_lum(UIColor *c) {
    CGFloat r=0,g=0,b=0,a=0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { CGFloat w=0; [c getWhite:&w alpha:&a]; r=g=b=w; }
    return 0.2126*r + 0.7152*g + 0.0722*b;
}
static UIColor *ad_mix(UIColor *x, UIColor *y, CGFloat t) {   // t=0 → x, t=1 → y
    CGFloat xr=0,xg=0,xb=0,xa=0, yr=0,yg=0,yb=0,ya=0;
    if (![x getRed:&xr green:&xg blue:&xb alpha:&xa]) { CGFloat w=0; [x getWhite:&w alpha:&xa]; xr=xg=xb=w; }
    if (![y getRed:&yr green:&yg blue:&yb alpha:&ya]) { CGFloat w=0; [y getWhite:&w alpha:&ya]; yr=yg=yb=w; }
    return [UIColor colorWithRed:xr+(yr-xr)*t green:xg+(yg-xg)*t blue:xb+(yb-xb)*t alpha:xa+(ya-xa)*t];
}
static UIColor *ad_lighten(UIColor *c, CGFloat t){ return ad_mix(c, [UIColor whiteColor], t); }
static UIColor *ad_darken (UIColor *c, CGFloat t){ return ad_mix(c, [UIColor blackColor], t); }
static UIColor *ad_contrastOn(UIColor *bg){ return ad_lum(bg) > 0.62 ? [UIColor colorWithWhite:0.10 alpha:1.0] : [UIColor whiteColor]; }
// Brighten a colour until it's light enough to read as text/accent on a DARK background.
static UIColor *ad_brightenToLum(UIColor *c, CGFloat target){ UIColor *x=c; int i=0; while (ad_lum(x) < target && i<10){ x=ad_lighten(x,0.12); i++; } return x; }
// Darken a colour until it's dark enough to read as text/accent on a WHITE background (light themes).
static UIColor *ad_darkenToLum(UIColor *c, CGFloat target){ UIColor *x=c; int i=0; while (ad_lum(x) > target && i<10){ x=ad_darken(x,0.12); i++; } return x; }
static void ad_rgb(UIColor *c, CGFloat out[3]){ CGFloat a=0; if(![c getRed:&out[0] green:&out[1] blue:&out[2] alpha:&a]){ CGFloat w=0; [c getWhite:&w alpha:&a]; out[0]=out[1]=out[2]=w; } }

#pragma mark - Theme state

static NSString *gThemeID = nil;
static UIColor  *gAccent  = nil;
static BOOL      gIsDark   = NO;
static NSMutableDictionary *gCache = nil;

// Theme catalogue, in three families:
//   • "default"      — the classic LIGHT blue iOS-6 look (renders EXACTLY like v2.0: stock bars +
//                      white content). Untouchable reference.
//   • "c_*"  (dark:NO, not default) — LIGHT COLOUR themes: white/readable content like the default
//                      but with VIVID coloured bars, buttons, links and selection in the accent.
//   • the rest (dark:YES) — DARK MODE variants: dark backgrounds + light text, vivid accent chrome.
// Accents are tuned per family: light-colour accents are vivid-but-deep enough to read white text
// on their bars; dark accents are bright so they pop on dark. Both are auto-contrasted at runtime.
static NSArray *ad_themeList(void) {
    static NSArray *list = nil;
    if (!list) list = [@[
        @{@"id":@"default",   @"nameKey":@"theme.default",   @"dark":@NO,  @"color":[UIColor colorWithRed:0.118 green:0.435 blue:0.902 alpha:1.0]},
        // ── Light colour themes ────────────────────────────────────────────────
        @{@"id":@"c_rouge",   @"nameKey":@"theme.red",       @"dark":@NO,  @"color":[UIColor colorWithRed:0.84 green:0.22 blue:0.22 alpha:1.0]},
        @{@"id":@"c_orange",  @"nameKey":@"theme.orange",    @"dark":@NO,  @"color":[UIColor colorWithRed:0.92 green:0.52 blue:0.10 alpha:1.0]},
        @{@"id":@"c_vert",    @"nameKey":@"theme.green",     @"dark":@NO,  @"color":[UIColor colorWithRed:0.20 green:0.60 blue:0.32 alpha:1.0]},
        @{@"id":@"c_turquoise",@"nameKey":@"theme.teal",     @"dark":@NO,  @"color":[UIColor colorWithRed:0.09 green:0.58 blue:0.60 alpha:1.0]},
        @{@"id":@"c_indigo",  @"nameKey":@"theme.indigo",    @"dark":@NO,  @"color":[UIColor colorWithRed:0.28 green:0.33 blue:0.74 alpha:1.0]},
        @{@"id":@"c_violet",  @"nameKey":@"theme.purple",    @"dark":@NO,  @"color":[UIColor colorWithRed:0.54 green:0.31 blue:0.71 alpha:1.0]},
        @{@"id":@"c_rose",    @"nameKey":@"theme.pink",      @"dark":@NO,  @"color":[UIColor colorWithRed:0.85 green:0.28 blue:0.53 alpha:1.0]},
        // ── Dark themes ────────────────────────────────────────────────────────
        @{@"id":@"sombre",    @"nameKey":@"theme.dark_gray", @"dark":@YES, @"color":[UIColor colorWithRed:0.46 green:0.52 blue:0.62 alpha:1.0]},
        @{@"id":@"nuit_bleue",@"nameKey":@"theme.dark_blue", @"dark":@YES, @"color":[UIColor colorWithRed:0.22 green:0.52 blue:0.96 alpha:1.0]},
        @{@"id":@"indigo",    @"nameKey":@"theme.indigo",    @"dark":@YES, @"color":[UIColor colorWithRed:0.42 green:0.44 blue:0.93 alpha:1.0]},
        @{@"id":@"violet",    @"nameKey":@"theme.purple",    @"dark":@YES, @"color":[UIColor colorWithRed:0.62 green:0.40 blue:0.93 alpha:1.0]},
        @{@"id":@"rose",      @"nameKey":@"theme.pink",      @"dark":@YES, @"color":[UIColor colorWithRed:0.95 green:0.40 blue:0.66 alpha:1.0]},
        @{@"id":@"rouge",     @"nameKey":@"theme.red",       @"dark":@YES, @"color":[UIColor colorWithRed:0.95 green:0.34 blue:0.34 alpha:1.0]},
        @{@"id":@"orange",    @"nameKey":@"theme.orange",    @"dark":@YES, @"color":[UIColor colorWithRed:0.98 green:0.58 blue:0.20 alpha:1.0]},
        @{@"id":@"vert",      @"nameKey":@"theme.green",     @"dark":@YES, @"color":[UIColor colorWithRed:0.30 green:0.74 blue:0.44 alpha:1.0]},
        @{@"id":@"turquoise", @"nameKey":@"theme.teal",      @"dark":@YES, @"color":[UIColor colorWithRed:0.20 green:0.74 blue:0.74 alpha:1.0]},
    ] retain];
    return list;
}
static NSDictionary *ad_themeForID(NSString *tid){
    for (NSDictionary *t in ad_themeList()) if ([t[@"id"] isEqualToString:tid]) return t;
    return ad_themeList()[0];
}

// The dark-mode neutral base (before faint accent tint).
static UIColor *ad_darkBase(CGFloat white){ return [UIColor colorWithRed:white green:white blue:white*1.04 alpha:1.0]; }

// Glossy iOS-6 rounded button image from a base colour, stretchable from the centre.
// topLighten / glossAlpha control how bright the top edge + sheen are: the classic light look uses
// a strong sheen (0.16 / 0.30); dark themes want a subtler one so the button doesn't glare.
static UIImage *ad_glossButtonEx(UIColor *base, BOOL pressed, CGFloat topLighten, CGFloat glossAlpha) {
    CGFloat W = 30.0, H = 30.0, r = 6.0;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(W, H), NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIBezierPath *rr = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5,0.5,W-1,H-1) cornerRadius:r];
    [rr addClip];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat top[3], bot[3];
    ad_rgb(ad_lighten(base, pressed?0.02:topLighten), top);
    ad_rgb(ad_darken (base, pressed?0.22:0.10), bot);
    CGFloat comps[8] = { top[0],top[1],top[2],1, bot[0],bot[1],bot[2],1 };
    CGFloat locs[2] = {0,1};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0,0), CGPointMake(0,H), 0);
    CGGradientRelease(g);
    CGFloat ga = pressed ? glossAlpha*0.33 : glossAlpha;
    CGFloat gloss[8] = { 1,1,1, ga,  1,1,1, 0.0 };
    CGGradientRef gg = CGGradientCreateWithColorComponents(cs, gloss, locs, 2);
    CGContextDrawLinearGradient(ctx, gg, CGPointMake(0,0), CGPointMake(0,H*0.5), 0);
    CGGradientRelease(gg);
    CGColorSpaceRelease(cs);
    [ad_darken(base, 0.34) setStroke];
    rr.lineWidth = 1.0; [rr stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img stretchableImageWithLeftCapWidth:(NSInteger)(W/2) topCapHeight:(NSInteger)(H/2)];
}
static UIImage *ad_glossButton(UIColor *base, BOOL pressed) {
    return ad_glossButtonEx(base, pressed, 0.16, 0.30);   // classic bright iOS-6 sheen
}

// Recursively set the text colour + keyboard style of every UITextField inside a view (used for
// the search-bar inner field, which is an "original iOS 6" light element otherwise).
static void ad_styleFields(UIView *v, UIColor *textColor, UIKeyboardAppearance kb) {
    if ([v isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)v;
        tf.textColor = textColor;
        if ([tf respondsToSelector:@selector(setKeyboardAppearance:)]) tf.keyboardAppearance = kb;
    }
    for (UIView *s in v.subviews) ad_styleFields(s, textColor, kb);
}

// Flat rounded card (fill + 1px border), stretchable from a 14pt cap so the 12pt corners stay crisp.
static UIImage *ad_roundedCard(UIColor *fill, UIColor *border) {
    CGFloat W = 30, H = 30, r = 12;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(W, H), NO, 0.0);
    UIBezierPath *rr = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5,0.5,W-1,H-1) cornerRadius:r];
    [fill setFill];   [rr fill];
    [border setStroke]; rr.lineWidth = 1.0; [rr stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img stretchableImageWithLeftCapWidth:14 topCapHeight:14];
}

@implementation IOS6Theme

+ (void)initialize {
    if (self != [IOS6Theme class]) return;
    gCache = [[NSMutableDictionary dictionary] retain];
    NSString *t = [[NSUserDefaults standardUserDefaults] stringForKey:@"IPAInstall.Theme"];
    NSDictionary *d = ad_themeForID(t ?: @"default");
    gThemeID = d[@"id"];
    gAccent  = d[@"color"];
    gIsDark  = [d[@"dark"] boolValue];
}

+ (instancetype)shared {
    static IOS6Theme *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[IOS6Theme alloc] init]; });
    return s;
}

#pragma mark - Live theme selection

+ (NSArray *)availableThemes { return ad_themeList(); }
+ (NSString *)currentThemeID { return gThemeID ?: @"default"; }
+ (BOOL)isDefaultTheme { return [[self currentThemeID] isEqualToString:@"default"]; }
+ (BOOL)isDark { return gIsDark; }
// Light COLOUR theme = a coloured-but-light variant (vivid chrome, white content). Not the default,
// not a dark theme. Bars/status bar treat these like the dark family (custom bar image, light bar
// text), while the CONTENT side treats them like the default (white backgrounds, dark text).
+ (BOOL)isLightColored { return !gIsDark && ![[self currentThemeID] isEqualToString:@"default"]; }
+ (UIColor *)accent { return gAccent ?: ad_themeForID(@"default")[@"color"]; }
+ (BOOL)isGraphite { return [[self currentThemeID] isEqualToString:@"sombre"]; }

+ (void)setThemeID:(NSString *)themeID {
    NSDictionary *d = ad_themeForID(themeID ?: @"default");
    if ([d[@"id"] isEqualToString:gThemeID]) return;
    gThemeID = d[@"id"];
    gAccent  = d[@"color"];
    gIsDark  = [d[@"dark"] boolValue];
    [gCache removeAllObjects];
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    [def setObject:gThemeID forKey:@"IPAInstall.Theme"];
    [def synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:AppDropThemeChangedNotification object:nil];
}

+ (NSString *)displayNameForThemeID:(NSString *)themeID {
    return T(ad_themeForID(themeID)[@"nameKey"]);
}

+ (BOOL)useFlatStyle {
    static BOOL flat = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *v = [[UIDevice currentDevice] systemVersion];
        NSInteger major = [[[v componentsSeparatedByString:@"."] firstObject] integerValue];
        flat = (major >= 7);
    });
    return flat;
}

#pragma mark - Bars

// For the DEFAULT theme these return nil → callers leave the bar STOCK (exactly the v2.0 look,
// since the custom PNG never showed through the unreliable appearance proxy). Dark themes return
// a code-drawn dark gradient tinted with the accent.
+ (UIImage *)navBarBackground {
    if ([self isDefaultTheme]) return nil;
    UIImage *img = gCache[@"navBar"];
    if (img) return img;
    CGFloat t[3], b[3];
    if ([self isDark]) {                       // dark theme — dark accent-tinted gradient
        ad_rgb(ad_mix(ad_darkBase(0.22), [self accent], 0.16), t);
        ad_rgb(ad_mix(ad_darkBase(0.11), [self accent], 0.16), b);
        img = barGradient(44, t, b, 0.05);
    } else {                                   // light colour — vivid glossy accent bar
        ad_rgb(ad_lighten([self accent], 0.12), t);
        ad_rgb(ad_darken ([self accent], 0.18), b);
        img = barGradient(44, t, b, 0.24);
    }
    if (img) gCache[@"navBar"] = img;
    return img;
}

+ (UIImage *)tabBarBackground {
    if ([self isDefaultTheme]) return nil;
    UIImage *img = gCache[@"tabBar"];
    if (img) return img;
    CGFloat t[3], b[3];
    if ([self isDark]) {                       // dark theme — near-black accent-tinted gradient
        ad_rgb(ad_mix(ad_darkBase(0.14), [self accent], 0.12), t);
        ad_rgb(ad_mix(ad_darkBase(0.05), [self accent], 0.12), b);
        img = barGradient(49, t, b, 0.04);
    } else {                                   // light colour — vivid accent tab bar (deeper than nav)
        ad_rgb([self accent], t);
        ad_rgb(ad_darken([self accent], 0.32), b);
        img = barGradient(49, t, b, 0.10);
    }
    if (img) gCache[@"tabBar"] = img;
    return img;
}

#pragma mark - Backgrounds

+ (UIColor *)contentBackgroundColor {
    if (![self isDark]) return [UIColor whiteColor];   // default + light colour: white content
    UIColor *c = gCache[@"content"];
    if (!c) { c = ad_mix(ad_darkBase(0.105), [self accent], 0.05); gCache[@"content"] = c; }
    return c;
}

+ (UIColor *)groupedBackgroundColor {
    UIColor *c = gCache[@"grouped"];
    if (c) return c;
    UIColor *lightGrey = [UIColor colorWithRed:0.866 green:0.875 blue:0.890 alpha:1.0];
    if ([self isDark])            c = ad_mix(ad_darkBase(0.06), [self accent], 0.05);
    else if ([self isDefaultTheme]) c = lightGrey;
    else                          c = ad_mix(lightGrey, [self accent], 0.12);   // faint accent wash
    gCache[@"grouped"] = c;
    return c;
}

// Fill for cells / cards / tiles — white on light themes (keeps text crisp), raised dark on dark.
+ (UIColor *)cellColor {
    UIColor *c = gCache[@"cell"];
    if (c) return c;
    c = [self isDark] ? ad_mix(ad_darkBase(0.17), [self accent], 0.06) : [UIColor whiteColor];
    gCache[@"cell"] = c;
    return c;
}

+ (UIColor *)chatBackgroundColor {
    UIColor *c = gCache[@"chatBg"];
    if (c) return c;
    UIColor *lightChat = [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0];
    if ([self isDark])            c = ad_mix(ad_darkBase(0.105), [self accent], 0.05);
    else if ([self isDefaultTheme]) c = lightChat;
    else                          c = ad_mix(lightChat, [self accent], 0.12);
    gCache[@"chatBg"] = c;
    return c;
}

+ (UIImage *)cellBackground {
    static UIImage *img = nil;
    if (!img) img = [stretchable(@"cell-bg", 1, 1) retain];
    return img;
}
+ (UIImage *)cellSelectedBackground {
    static UIImage *img = nil;
    if (!img) img = [stretchable(@"cell-selected", 1, 1) retain];
    return img;
}
+ (UIImage *)cardBackground {
    UIImage *img = gCache[@"card"];
    if (img) return img;
    img = ![self isDark] ? stretchable(@"card-bg", 14, 14)
                         : ad_roundedCard([self cellColor], [self separatorColor]);
    if (img) gCache[@"card"] = img;
    return img;
}

+ (UIImage *)linenPattern {
    static UIImage *img = nil;
    if (!img) img = [[UIImage imageNamed:@"linen"] retain];
    return img;
}
+ (UIImage *)linenBackground { return [self linenPattern]; }

+ (UIColor *)linenPatternColor {
    if (![self isDefaultTheme]) return [self groupedBackgroundColor];   // dark wash instead of linen
    UIColor *c = gCache[@"linen"];
    if (!c) {
        if ([self linenPattern]) c = [UIColor colorWithPatternImage:[self linenPattern]];
        if (!c) c = [self groupedBackgroundColor];
        gCache[@"linen"] = c;
    }
    return c;
}
+ (UIColor *)linenColor { return [self linenPatternColor]; }

#pragma mark - Buttons

// Deeper accent on dark themes so the big Install button reads as "the accent" without glaring
// against the dark UI; the vivid accent itself on light/colour themes (pops on white content).
+ (UIColor *)primaryButtonColor {
    if (![self isDark]) return [self accent];
    UIColor *c = gCache[@"primaryBtn"];
    if (!c) { c = ad_darken([self accent], 0.24); gCache[@"primaryBtn"] = c; }
    return c;
}

+ (UIImage *)blueButtonNormal {
    UIImage *img = gCache[@"btnN"];
    if (img) return img;
    if ([self isDefaultTheme]) img = stretchable(@"btn-blue", 12, 12);
    else if ([self isDark])    img = ad_glossButtonEx([self primaryButtonColor], NO, 0.10, 0.16);  // subtler sheen
    else                       img = ad_glossButton([self accent], NO);
    if (img) gCache[@"btnN"] = img;
    return img;
}
+ (UIImage *)blueButtonPressed {
    UIImage *img = gCache[@"btnP"];
    if (img) return img;
    if ([self isDefaultTheme]) img = stretchable(@"btn-blue-pressed", 12, 12);
    else if ([self isDark])    img = ad_glossButtonEx([self primaryButtonColor], YES, 0.10, 0.16);
    else                       img = ad_glossButton([self accent], YES);
    if (img) gCache[@"btnP"] = img;
    return img;
}
+ (UIImage *)grayButtonNormal {
    UIImage *img = gCache[@"grayN"];
    if (img) return img;
    // Dark themes need a DARK neutral button (the light PNG glares); light/default keep the PNG.
    if ([self isDark]) img = ad_glossButtonEx([UIColor colorWithWhite:0.30 alpha:1.0], NO, 0.08, 0.14);
    else               img = stretchable(@"btn-gray", 12, 12);
    if (img) gCache[@"grayN"] = img;
    return img;
}
+ (UIImage *)grayButtonPressed {
    UIImage *img = gCache[@"grayP"];
    if (img) return img;
    if ([self isDark]) img = ad_glossButtonEx([UIColor colorWithWhite:0.30 alpha:1.0], YES, 0.08, 0.14);
    else               img = stretchable(@"btn-gray-pressed", 12, 12);
    if (img) gCache[@"grayP"] = img;
    return img;
}

#pragma mark - Style helpers

+ (NSDictionary *)navBarTitleTextAttributes {
    // Dark themes (and the classic blue bar) carry white titles; the auto-contrast keeps it right
    // even if a future accent is very light.
    // Approximate the bar colour so the title auto-contrasts: vivid accent on default/light-colour
    // bars, a darkened accent on the dark family's near-black bars.
    UIColor *barApprox = [self isDark] ? ad_darken([self accent], 0.5) : [self accent];
    UIColor *txt = ad_contrastOn(barApprox);
    BOOL light = (ad_lum(txt) > 0.5);
    UIColor *shadow = light ? [UIColor colorWithWhite:0 alpha:0.5] : [UIColor colorWithWhite:1 alpha:0.5];
    return @{
        UITextAttributeTextColor: txt,
        UITextAttributeTextShadowColor: shadow,
        UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, -1)],
        UITextAttributeFont: [UIFont boldSystemFontOfSize:18],
    };
}

+ (UIColor *)bubbleUserTextColor { return ad_contrastOn([self accent]); }

+ (UIColor *)embossShadowColor {
    // The iOS-6 light emboss shadow only makes sense on light themes (default + light colour);
    // on dark it would glow.
    return [self isDark] ? [UIColor clearColor] : [UIColor colorWithWhite:1 alpha:0.5];
}

+ (void)applyToNavigationBar:(UINavigationBar *)nav {
    if (!nav) return;
    if ([self isDefaultTheme]) {
        if ([nav respondsToSelector:@selector(setBackgroundImage:forBarMetrics:)])
            [nav setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
        nav.tintColor = nil;
        if ([nav respondsToSelector:@selector(setTitleTextAttributes:)]) nav.titleTextAttributes = nil;
        return;
    }
    if ([nav respondsToSelector:@selector(setBackgroundImage:forBarMetrics:)]) {
        UIImage *bg = [self navBarBackground];
        if (bg) [nav setBackgroundImage:bg forBarMetrics:UIBarMetricsDefault];
    }
    nav.tintColor = [self navBarButtonTint];   // dark glossy bar buttons on dark themes
    if ([nav respondsToSelector:@selector(setTitleTextAttributes:)])
        nav.titleTextAttributes = [self navBarTitleTextAttributes];
}

+ (void)applyToTabBar:(UITabBar *)tab {
    if (!tab) return;
    if ([self isDefaultTheme]) {
        if ([tab respondsToSelector:@selector(setBackgroundImage:)]) tab.backgroundImage = nil;
        if ([tab respondsToSelector:@selector(setTintColor:)]) tab.tintColor = nil;
        return;
    }
    if ([tab respondsToSelector:@selector(setBackgroundImage:)]) {
        UIImage *bg = [self tabBarBackground];
        if (bg) tab.backgroundImage = bg;
    }
    if ([tab respondsToSelector:@selector(setTintColor:)]) tab.tintColor = [self barTintColor];
}

+ (void)styleButton:(UIButton *)button {
    if (!button) return;
    [button setBackgroundImage:[self blueButtonNormal] forState:UIControlStateNormal];
    [button setBackgroundImage:[self blueButtonPressed] forState:UIControlStateHighlighted];
    // Contrast against the ACTUAL button fill (deeper accent on dark themes) — not the raw accent —
    // so dark-theme buttons get readable white text rather than dark-on-dark.
    UIColor *title = [self isDefaultTheme] ? [UIColor whiteColor] : ad_contrastOn([self primaryButtonColor]);
    [button setTitleColor:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateDisabled];
    button.titleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.4];
    button.titleLabel.shadowOffset = CGSizeMake(0, -1);
    button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
}

+ (void)styleGrayButton:(UIButton *)button {
    if (!button) return;
    [button setBackgroundImage:[self grayButtonNormal] forState:UIControlStateNormal];
    [button setBackgroundImage:[self grayButtonPressed] forState:UIControlStateHighlighted];
    [button setTitleColor:[self labelDark] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor grayColor] forState:UIControlStateDisabled];
    button.titleLabel.shadowColor = [self embossShadowColor];
    button.titleLabel.shadowOffset = CGSizeMake(0, 1);
    button.titleLabel.font = [UIFont boldSystemFontOfSize:14];
}

+ (void)styleSmallInstallButton:(UIButton *)button {
    if (!button) return;
    [button setBackgroundImage:[self grayButtonNormal] forState:UIControlStateNormal];
    [button setBackgroundImage:[self blueButtonPressed] forState:UIControlStateHighlighted];
    [button setTitleColor:[self primaryBlue] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    button.titleLabel.shadowColor = nil;
}

+ (void)styleSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) return;
    // DEFAULT + LIGHT COLOUR = stock iOS 6 search bar (light field on white content; v2.0 never
    // styled it). Reset everything so switching back from a dark theme restores the original look.
    if (![self isDark]) {
        searchBar.barStyle = UIBarStyleDefault;
        searchBar.tintColor = nil;
        if ([searchBar respondsToSelector:@selector(setBackgroundImage:)]) searchBar.backgroundImage = nil;
        if ([searchBar respondsToSelector:@selector(setSearchFieldBackgroundImage:forState:)])
            [searchBar setSearchFieldBackgroundImage:nil forState:UIControlStateNormal];
        ad_styleFields(searchBar, [UIColor blackColor], UIKeyboardAppearanceDefault);
        return;
    }
    // Dark themes: dark bar + dark rounded inner field + light text + dark keyboard.
    searchBar.barStyle = UIBarStyleBlack;
    searchBar.tintColor = ad_darken([self accent], 0.3);
    if ([searchBar respondsToSelector:@selector(setBackgroundImage:)]) {
        UIColor *bar = ad_mix(ad_darkBase(0.16), [self accent], 0.10);
        UIGraphicsBeginImageContext(CGSizeMake(1, 1));
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(ctx, bar.CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, 1, 1));
        UIImage *bg = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        searchBar.backgroundImage = bg;
    }
    if ([searchBar respondsToSelector:@selector(setSearchFieldBackgroundImage:forState:)])
        [searchBar setSearchFieldBackgroundImage:ad_roundedCard([self cellColor], [self separatorColor])
                                        forState:UIControlStateNormal];
    ad_styleFields(searchBar, [self labelDark], UIKeyboardAppearanceAlert);
}

// Text field: keep the stock iOS-6 rounded field on the default theme; on dark themes give it a
// dark fill + light text + 1px border + dark keyboard (otherwise it's a glaring light box).
+ (void)styleTextField:(UITextField *)tf {
    if (!tf) return;
    if (![self isDark]) {   // default + light colour: stock rounded field on white content
        tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.backgroundColor = [UIColor clearColor];
        tf.textColor = [UIColor blackColor];
        tf.layer.borderWidth = 0.0;
        tf.leftView = nil;
        tf.keyboardAppearance = UIKeyboardAppearanceDefault;
        return;
    }
    tf.borderStyle = UITextBorderStyleNone;
    tf.backgroundColor = [self cellColor];
    tf.textColor = [self labelDark];
    tf.layer.cornerRadius = 6.0;
    tf.layer.borderWidth = 1.0;
    tf.layer.borderColor = [self separatorColor].CGColor;
    tf.keyboardAppearance = UIKeyboardAppearanceAlert;
    if (!tf.leftView) {   // restore the text inset lost when borderStyle is None
        tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 1)];
        tf.leftViewMode = UITextFieldViewModeAlways;
    }
}

// Grouped section header/footer. On iOS 6 these default to a dark blue-grey label (unreadable on
// dark) and, once the table's backgroundView is removed, can render an opaque BLACK background
// (the black bands the user saw — even in the default theme after a live switch). We force a CLEAR
// backgroundView so the table backdrop shows through, and recolour the label light on dark themes.
+ (void)styleGroupedHeaderFooter:(UIView *)view {
    Class hfClass = NSClassFromString(@"UITableViewHeaderFooterView");
    if (!hfClass || ![view isKindOfClass:hfClass]) return;
    UITableViewHeaderFooterView *hf = (UITableViewHeaderFooterView *)view;
    UIView *clear = [[UIView alloc] initWithFrame:hf.bounds];
    clear.backgroundColor = [UIColor clearColor];
    hf.backgroundView = clear;
    hf.contentView.backgroundColor = [UIColor clearColor];
    if ([self isDark]) {                          // default + light colour keep iOS 6's grey emboss
        hf.textLabel.textColor = [self labelGray];
        hf.textLabel.shadowColor = [UIColor clearColor];
        hf.detailTextLabel.textColor = [self labelGray];
    }
}

#pragma mark - Manual grouped header/footer (iOS 5 fallback)

+ (BOOL)needsManualGroupedHeaderFooter {
    // iOS 5 doesn't call willDisplay{Header,Footer}View:, so it never re-tints these labels.
    return [[[UIDevice currentDevice] systemVersion] compare:@"6.0" options:NSNumericSearch] == NSOrderedAscending;
}

// Side inset for manual header/footer text — generous on iPad (grouped tables are inset from the
// screen edges), tight on iPhone. Roughly matches where the system places the default labels.
+ (CGFloat)ad_ghfInset {
    return (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) ? 51.0 : 16.0;
}

+ (CGFloat)ad_ghfFooterTextHeight:(NSString *)text width:(CGFloat)width {
    CGFloat tw = width - 2 * [self ad_ghfInset];
    if (tw < 40) tw = 40;
    CGSize sz = [text sizeWithFont:[UIFont systemFontOfSize:13]
                 constrainedToSize:CGSizeMake(tw, 4000)
                     lineBreakMode:NSLineBreakByWordWrapping];   // iOS 5/6 API (this path is iOS 5 only)
    return ceilf(sz.height);
}

+ (UIView *)manualGroupedHeaderViewForTitle:(NSString *)title width:(CGFloat)width {
    if (!title.length) return nil;
    CGFloat ins = [self ad_ghfInset];
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 34)];
    v.backgroundColor = [UIColor clearColor];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(ins + 4, 12, width - 2 * ins - 8, 20)];
    l.backgroundColor = [UIColor clearColor];
    l.font = [UIFont boldSystemFontOfSize:16];
    l.textColor = [self labelGray];
    l.text = title;
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [v addSubview:l];
    return v;
}
+ (CGFloat)manualGroupedHeaderHeightForTitle:(NSString *)title {
    return title.length ? 34.0 : 16.0;
}

+ (UIView *)manualGroupedFooterViewForText:(NSString *)text width:(CGFloat)width {
    if (!text.length) return nil;
    CGFloat ins = [self ad_ghfInset];
    CGFloat th  = [self ad_ghfFooterTextHeight:text width:width];
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, th + 16)];
    v.backgroundColor = [UIColor clearColor];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(ins, 7, width - 2 * ins, th)];
    l.backgroundColor = [UIColor clearColor];
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [self labelGray];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;   // iPad grouped footers are centred
    l.text = text;
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [v addSubview:l];
    return v;
}
+ (CGFloat)manualGroupedFooterHeightForText:(NSString *)text width:(CGFloat)width {
    if (!text.length) return 16.0;   // inter-group gap when a section has no footer text
    return [self ad_ghfFooterTextHeight:text width:width] + 16.0;
}

#pragma mark - Live re-tint of a view subtree

+ (void)retintViewTree:(UIView *)view {
    if (!view) return;
    for (UIView *sub in view.subviews) {
        if ([sub conformsToProtocol:@protocol(ADThemable)]) {
            [(id<ADThemable>)sub applyTheme];
        } else if ([sub isKindOfClass:[UITableView class]]) {
            [(UITableView *)sub reloadData];                   // cells re-read theme; bg owned by VC
        } else if ([sub isKindOfClass:[UISearchBar class]]) {
            [self styleSearchBar:(UISearchBar *)sub];
        } else if ([sub isKindOfClass:[UISwitch class]]) {
            // Default theme keeps the stock green switch; dark themes tint it with the accent.
            UISwitch *sw = (UISwitch *)sub;
            if ([sw respondsToSelector:@selector(setOnTintColor:)]) sw.onTintColor = [self isDefaultTheme] ? nil : [self accent];
            // -[UISwitch setTintColor:] is iOS 6+ → guard (crashed on iPad 1 / iOS 5.1.1).
            if ([sw respondsToSelector:@selector(setTintColor:)]) sw.tintColor = [self isDefaultTheme] ? nil : [self separatorColor];
        } else if ([sub isKindOfClass:[UISegmentedControl class]]) {
            if ([sub respondsToSelector:@selector(setTintColor:)]) sub.tintColor = [self accent];
        }
        [self retintViewTree:sub];
    }
}

#pragma mark - Color palette

// The accent as used on the CURRENT background: classic blue on the light default; on dark themes
// it's brightened so links / install text / progress tints pop and stay readable.
+ (UIColor *)primaryBlue {
    if ([self isDefaultTheme]) return [UIColor colorWithRed:0.118 green:0.435 blue:0.902 alpha:1.0];
    UIColor *c = gCache[@"accentText"];
    if (!c) {
        // Links / install text / progress tints: brighten the accent to read on DARK, darken it to
        // read on the WHITE content of a light-colour theme.
        c = [self isDark] ? ad_brightenToLum([self accent], 0.62) : ad_darkenToLum([self accent], 0.5);
        gCache[@"accentText"] = c;
    }
    return c;
}

// Tab-bar selected glyph tint — bright accent on the dark tab bar; near-white on a light-colour
// theme's vivid tab bar (so the selected glyph stands out against the saturated background).
+ (UIColor *)barTintColor {
    if ([self isDefaultTheme]) return [self primaryBlue];
    UIColor *c = gCache[@"barTint"];
    if (!c) {
        c = [self isDark] ? ad_brightenToLum([self accent], 0.66) : ad_lighten([self accent], 0.82);
        gCache[@"barTint"] = c;
    }
    return c;
}

// Nav-bar bordered-button tint. On iOS 6 a UIBarButtonItem renders as a glossy pill in this colour.
// Dark themes: a dark accent-tinted shade (the bright accent looked too light). Light-colour themes:
// a slightly deeper accent than the bar so the pill reads against the vivid nav bar.
+ (UIColor *)navBarButtonTint {
    if ([self isDefaultTheme]) return [self primaryBlue];
    UIColor *c = gCache[@"navBtn"];
    if (!c) {
        c = [self isDark] ? ad_mix(ad_darkBase(0.12), [self accent], 0.18) : ad_darken([self accent], 0.14);
        gCache[@"navBtn"] = c;
    }
    return c;
}

+ (UIColor *)separatorColor {
    UIColor *c = gCache[@"sep"];
    if (c) return c;
    c = [self isDark]
        ? [UIColor colorWithRed:0.27 green:0.27 blue:0.30 alpha:1.0]
        : [UIColor colorWithRed:0.784 green:0.784 blue:0.804 alpha:1.0];
    gCache[@"sep"] = c;
    return c;
}

// Primary body text. Dark themes → near-white; default + light colour → near-black (on white).
+ (UIColor *)labelDark {
    UIColor *c = gCache[@"labelDark"];
    if (c) return c;
    c = [self isDark] ? [UIColor colorWithRed:0.95 green:0.95 blue:0.96 alpha:1.0]
                      : [UIColor colorWithWhite:0.12 alpha:1.0];
    gCache[@"labelDark"] = c;
    return c;
}

// Secondary / detail text.
+ (UIColor *)labelGray {
    UIColor *c = gCache[@"labelGray"];
    if (c) return c;
    c = [self isDark] ? [UIColor colorWithRed:0.69 green:0.70 blue:0.74 alpha:1.0]
                      : [UIColor colorWithWhite:0.45 alpha:1.0];
    gCache[@"labelGray"] = c;
    return c;
}

// Emphasis / list-item titles. Dark → near-white; default → navy; light colour → a deep accent
// tint (so titles pick up the theme colour while staying readable on white).
+ (UIColor *)titleColor {
    UIColor *c = gCache[@"title"];
    if (c) return c;
    if ([self isDark])              c = [UIColor colorWithRed:0.97 green:0.97 blue:0.98 alpha:1.0];
    else if ([self isDefaultTheme]) c = [UIColor colorWithRed:0.13 green:0.18 blue:0.32 alpha:1.0];
    else                            c = ad_darkenToLum([self accent], 0.30);
    gCache[@"title"] = c;
    return c;
}

// Placeholder / hint text.
+ (UIColor *)placeholderColor {
    UIColor *c = gCache[@"placeholder"];
    if (c) return c;
    c = [self isDark] ? [UIColor colorWithRed:0.50 green:0.50 blue:0.54 alpha:1.0]
                      : [UIColor lightGrayColor];
    gCache[@"placeholder"] = c;
    return c;
}

+ (UIColor *)bubbleBlueColor { return [self accent]; }

+ (UIColor *)bubbleGrayColor {
    UIColor *c = gCache[@"bubbleGray"];
    if (c) return c;
    c = [self isDark] ? [UIColor colorWithRed:0.23 green:0.23 blue:0.255 alpha:1.0]
                      : [UIColor colorWithRed:0.91 green:0.91 blue:0.93 alpha:1.0];
    gCache[@"bubbleGray"] = c;
    return c;
}

#pragma mark - Fonts

+ (UIFont *)bodyFont { return [UIFont systemFontOfSize:15]; }
+ (UIFont *)bodyBoldFont { return [UIFont boldSystemFontOfSize:15]; }
+ (UIFont *)titleFont { return [UIFont boldSystemFontOfSize:17]; }
+ (UIFont *)caption { return [UIFont systemFontOfSize:11]; }

#pragma mark - Bubble drawing (iOS 6 Messages-style with tail)

+ (void)drawChatBubbleInRect:(CGRect)rect isUser:(BOOL)isUser {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGFloat tailW = 10.0, tailH = 14.0, radius = 14.0;
    CGFloat bodyLeft, bodyRight;
    if (isUser) { bodyLeft = CGRectGetMinX(rect); bodyRight = CGRectGetMaxX(rect) - tailW; }
    else        { bodyLeft = CGRectGetMinX(rect) + tailW; bodyRight = CGRectGetMaxX(rect); }
    CGFloat top = CGRectGetMinY(rect), bottom = CGRectGetMaxY(rect);

    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, bodyLeft + radius, top);
    CGPathAddLineToPoint(path, NULL, bodyRight - radius, top);
    CGPathAddArc(path, NULL, bodyRight - radius, top + radius, radius, -M_PI_2, 0, NO);
    if (isUser) {
        CGPathAddLineToPoint(path, NULL, bodyRight, bottom - tailH - 2);
        CGPathAddLineToPoint(path, NULL, bodyRight + tailW, bottom - 2);
        CGPathAddLineToPoint(path, NULL, bodyRight, bottom);
    } else {
        CGPathAddLineToPoint(path, NULL, bodyRight, bottom - radius);
        CGPathAddArc(path, NULL, bodyRight - radius, bottom - radius, radius, 0, M_PI_2, NO);
    }
    CGPathAddLineToPoint(path, NULL, bodyLeft + radius, bottom);
    if (isUser) {
        CGPathAddArc(path, NULL, bodyLeft + radius, bottom - radius, radius, M_PI_2, M_PI, NO);
    } else {
        CGPathAddLineToPoint(path, NULL, bodyLeft, bottom);
        CGPathAddLineToPoint(path, NULL, bodyLeft - tailW, bottom - 2);
        CGPathAddLineToPoint(path, NULL, bodyLeft, bottom - tailH - 2);
    }
    CGPathAddLineToPoint(path, NULL, bodyLeft, top + radius);
    CGPathAddArc(path, NULL, bodyLeft + radius, top + radius, radius, M_PI, M_PI + M_PI_2, NO);
    CGPathCloseSubpath(path);

    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat locs[2] = { 0.0, 1.0 };
    CGFloat uTop[3], uBot[3], aTop[3], aBot[3];
    if ([self isDefaultTheme]) {
        uTop[0]=0.18; uTop[1]=0.62; uTop[2]=1.0;  uBot[0]=0.00; uBot[1]=0.42; uBot[2]=0.96;
    } else {
        ad_rgb(ad_lighten([self accent], 0.14), uTop);
        ad_rgb(ad_darken ([self accent], 0.08), uBot);
    }
    ad_rgb(ad_lighten([self bubbleGrayColor], 0.05), aTop);     // assistant bubble (light grey / dark grey)
    ad_rgb([self bubbleGrayColor], aBot);

    CGFloat *t = isUser ? uTop : aTop;
    CGFloat *b = isUser ? uBot : aBot;
    CGFloat colors[8] = { t[0],t[1],t[2],1.0,  b[0],b[1],b[2],1.0 };
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, colors, locs, 2);
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, top), CGPointMake(0, bottom), 0);
    CGGradientRelease(grad);

    CGFloat highlightHeight = (bottom - top) * 0.5;
    CGFloat glossAlpha = ![self isDark] ? (isUser ? 0.30 : 0.55) : (isUser ? 0.18 : 0.10);
    CGFloat glossColors[8] = { 1,1,1, glossAlpha,  1,1,1, 0.0 };
    CGGradientRef glossGrad = CGGradientCreateWithColorComponents(cs, glossColors, locs, 2);
    CGContextDrawLinearGradient(ctx, glossGrad, CGPointMake(0, top), CGPointMake(0, top + highlightHeight), 0);
    CGGradientRelease(glossGrad);

    CGColorSpaceRelease(cs);
    CGContextRestoreGState(ctx);

    CGFloat borderAlpha = [self isDark] ? 0.30 : 0.18;
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:borderAlpha].CGColor);
    CGContextSetLineWidth(ctx, 0.5);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);

    CGPathRelease(path);
}

@end
