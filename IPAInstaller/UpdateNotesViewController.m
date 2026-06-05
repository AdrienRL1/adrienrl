#import "UpdateNotesViewController.h"
#import "Localization.h"
#import "IOS6Theme.h"

@interface UpdateNotesViewController () <UIWebViewDelegate>
@property (nonatomic, strong) UIWebView *webView;
@property (nonatomic, strong) UILabel *headerLabel;
@end

@implementation UpdateNotesViewController {
    void (^_installHandlerBlock)(void);
}

// iOS 3: blocks aren't ObjC objects, so the synthesized copy setter crashes in
// objc_msgSend. Back installHandler manually via the C blocks runtime — see
// AppDropBlocks.h (AD_BLOCK_ACCESSORS).
@dynamic installHandler;
AD_BLOCK_ACCESSORS(installHandler, setInstallHandler, _installHandlerBlock, void(^)(void))

- (void)dealloc {
    if (_installHandlerBlock) _Block_release((const void *)_installHandlerBlock);
    [super dealloc];
}

#pragma mark - Lifecycle

// Live theme re-apply (AppDelegate calls this on a theme switch — no restart). The release-notes
// web view stays white for legibility; the surface + nav bar follow the theme.
- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.title = T(@"update_notes.title");

    // Nav bar buttons. v3.0: titled (T()) so it follows the APP language, not the device's
    // (UIBarButtonSystemItemCancel localizes to the device language → mismatched the app language).
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:T(@"common.cancel")
                                         style:UIBarButtonItemStyleBordered
                                        target:self
                                        action:@selector(cancelTapped)];
    // AppDrop is distributed via the AdrienRL Cydia source — this button
    // hands off to whichever package manager the user has rather than
    // starting an in-app download.
    UIBarButtonItem *open =
        [[UIBarButtonItem alloc] initWithTitle:T(@"update_notes.open_in_cydia")
                                          style:UIBarButtonItemStyleDone
                                         target:self
                                         action:@selector(installTapped)];
    self.navigationItem.rightBarButtonItem = open;

    // Header strip: "v1.3 — released May 30, 2026"
    self.headerLabel = [[UILabel alloc] init];
    self.headerLabel.numberOfLines = 0;
    self.headerLabel.font = [UIFont systemFontOfSize:13];
    self.headerLabel.textColor = [IOS6Theme labelGray];
    self.headerLabel.backgroundColor = [IOS6Theme groupedBackgroundColor];
    self.headerLabel.textAlignment = NSTextAlignmentCenter;
    self.headerLabel.text = [self headerText];
    [self.view addSubview:self.headerLabel];

    // Body web view — UIWebView is the only thing that works on iOS 6.
    self.webView = [[UIWebView alloc] init];
    self.webView.delegate = self;
    self.webView.opaque = YES;
    self.webView.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.webView.scalesPageToFit = NO;  // we control sizing via CSS
    [self.view addSubview:self.webView];

    [self.webView loadHTMLString:[self renderHTML] baseURL:nil];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // Manual layout — works on iPhone 4S (320×480 portrait) through iPad
    // landscape (1024×768). Nav controller already accounts for nav bar
    // height, so self.view.bounds excludes that.
    CGRect b = self.view.bounds;
    CGFloat headerHeight = 36;
    self.headerLabel.frame = CGRectMake(0, 0, b.size.width, headerHeight);
    self.webView.frame = CGRectMake(0, headerHeight,
                                     b.size.width,
                                     b.size.height - headerHeight);
}

#pragma mark - Actions

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)installTapped {
    void (^handler)(void) = _installHandlerBlock;   // already heap block; never send -copy on iOS 3
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler) handler();
    }];
}

#pragma mark - Header text

- (NSString *)headerText {
    NSString *dateStr = @"";
    if (self.releaseDate) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterMediumStyle;
        fmt.timeStyle = NSDateFormatterNoStyle;
        dateStr = [fmt stringFromDate:self.releaseDate];
    }
    // "v1.3 — released May 30, 2026"
    if (dateStr.length) {
        return [NSString stringWithFormat:T(@"update_notes.header_with_date"),
                  self.version ?: @"?", dateStr];
    }
    return [NSString stringWithFormat:T(@"update_notes.header_no_date"),
              self.version ?: @"?"];
}

#pragma mark - Markdown → HTML

// UIColor → "#RRGGBB" for injecting theme colours into the notes CSS.
static NSString *ADHex(UIColor *c) {
    CGFloat r=0,g=0,b=0,a=0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { CGFloat w=0; [c getWhite:&w alpha:&a]; r=g=b=w; }
    return [NSString stringWithFormat:@"#%02X%02X%02X", (int)(r*255), (int)(g*255), (int)(b*255)];
}

// We don't bundle a markdown parser to stay light. Hand-rolled conversion is
// enough for our release notes (no nested lists, no tables, no images).
- (NSString *)renderHTML {
    NSMutableString *html = [NSMutableString string];

    // CSS:
    // - System sans-serif (Helvetica Neue on iOS 6, falls back to default on
    //   iOS 7+ via -apple-system).
    // - 14 pt body, comfortable line-height for reading on phone screens.
    // - Bold h2 a bit larger; code spans get a subtle background; links the
    //   AppDrop blue.
    // Colours follow the active theme so the notes are readable in dark mode too.
    NSString *cBg = ADHex([IOS6Theme contentBackgroundColor]);
    NSString *cText = ADHex([IOS6Theme labelDark]);
    NSString *cH = ADHex([IOS6Theme titleColor]);
    NSString *cCode = ADHex([IOS6Theme cellColor]);
    NSString *cLink = ADHex([IOS6Theme primaryBlue]);
    BOOL dk = [IOS6Theme isDark];
    NSString *bBg = dk ? @"#10243f" : @"#eef5ff";
    NSString *bBorder = dk ? @"#26456f" : @"#d0e3ff";
    NSString *bText = dk ? @"#cfe2ff" : @"#13427a";
    NSString *bBold = dk ? @"#ffffff" : @"#0a3266";

    [html appendString:@"<html><head><style>"];
    [html appendString:@"html,body{margin:0;padding:0;}"];
    [html appendFormat:@"body{font-family:-apple-system,'Helvetica Neue',Helvetica,sans-serif;"
                       @"font-size:14px;line-height:1.45;color:%@;background:%@;"
                       @"padding:14px 16px 24px 16px;-webkit-text-size-adjust:100%%;}", cText, cBg];
    [html appendFormat:@"h2{font-size:17px;margin:18px 0 6px 0;color:%@;}", cH];
    [html appendString:@"p{margin:8px 0;}"];
    [html appendString:@"ul{margin:6px 0 10px 0;padding-left:22px;}"];
    [html appendString:@"li{margin:3px 0;}"];
    [html appendFormat:@"code{font-family:Menlo,Courier,monospace;font-size:12px;"
                       @"background:%@;padding:1px 5px;border-radius:3px;}", cCode];
    [html appendString:@"strong,b{font-weight:600;}"];
    [html appendFormat:@"a{color:%@;text-decoration:none;}", cLink];
    [html appendString:@"em,i{font-style:italic;}"];
    // Banner styling — callout above the release notes so the user understands the install
    // path is Cydia, not in-app. Darkened variant on dark themes.
    [html appendFormat:@".cydia-banner{margin:0 0 14px 0;padding:10px 12px;"
                       @"background:%@;border:1px solid %@;"
                       @"border-radius:6px;font-size:13px;color:%@;}", bBg, bBorder, bText];
    [html appendFormat:@".cydia-banner b{color:%@;}", bBold];
    [html appendString:@"</style></head><body>"];

    // Cydia banner — always shown, regardless of notes presence.
    [html appendString:@"<div class=\"cydia-banner\"><b>"];
    [html appendString:[self htmlEscape:T(@"update_notes.cydia_banner_title")]];
    [html appendString:@"</b><br>"];
    [html appendString:[self htmlEscape:T(@"update_notes.cydia_banner_body")]];
    [html appendString:@"</div>"];

    if (!self.notesMarkdown.length) {
        [html appendString:@"<p><em>"];
        [html appendString:[self htmlEscape:T(@"update_notes.empty")]];
        [html appendString:@"</em></p>"];
    } else {
        [html appendString:[self markdownToHTML:self.notesMarkdown]];
    }

    [html appendString:@"</body></html>"];
    return html;
}

- (NSString *)markdownToHTML:(NSString *)md {
    NSMutableString *out = [NSMutableString string];
    NSArray *lines = [md componentsSeparatedByString:@"\n"];
    BOOL inList = NO;
    BOOL pendingBlank = NO;

    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];

        if (line.length == 0) {
            // Blank lines close any open list and act as paragraph separators.
            if (inList) {
                [out appendString:@"</ul>"];
                inList = NO;
            }
            pendingBlank = YES;
            continue;
        }

        // Heading: "## Foo" → <h2>Foo</h2>
        if ([line hasPrefix:@"## "]) {
            if (inList) { [out appendString:@"</ul>"]; inList = NO; }
            NSString *content = [line substringFromIndex:3];
            [out appendFormat:@"<h2>%@</h2>", [self inlineMarkdown:content]];
            pendingBlank = NO;
            continue;
        }
        if ([line hasPrefix:@"# "]) {
            if (inList) { [out appendString:@"</ul>"]; inList = NO; }
            NSString *content = [line substringFromIndex:2];
            [out appendFormat:@"<h2>%@</h2>", [self inlineMarkdown:content]];
            pendingBlank = NO;
            continue;
        }

        // Bullet: "- Foo" → <li>Foo</li> (wraps in <ul>)
        if ([line hasPrefix:@"- "]) {
            if (!inList) { [out appendString:@"<ul>"]; inList = YES; }
            NSString *content = [line substringFromIndex:2];
            [out appendFormat:@"<li>%@</li>", [self inlineMarkdown:content]];
            pendingBlank = NO;
            continue;
        }

        // Plain paragraph line.
        if (inList) { [out appendString:@"</ul>"]; inList = NO; }
        if (pendingBlank) {
            // Use <p> for proper paragraph spacing after a blank line.
            [out appendFormat:@"<p>%@</p>", [self inlineMarkdown:line]];
        } else {
            // Continuation — just append with a space.
            [out appendFormat:@" %@", [self inlineMarkdown:line]];
        }
        pendingBlank = NO;
    }
    if (inList) [out appendString:@"</ul>"];
    return out;
}

// Inline transforms: **bold**, `code`, [text](url). Escape HTML special chars
// AFTER these regex passes so the substitutions can use <b>/<code>/<a> tags
// without being escaped, but anything else stays safe.
- (NSString *)inlineMarkdown:(NSString *)s {
    // 1. HTML-escape first, but only the chars that conflict (we keep < and > out)
    s = [self htmlEscape:s];

    NSError *err = nil;
    // **bold** → <b>bold</b>
    NSRegularExpression *re;
    re = [NSRegularExpression regularExpressionWithPattern:@"\\*\\*([^*]+)\\*\\*"
                                                    options:0 error:&err];
    s = [re stringByReplacingMatchesInString:s options:0
                                        range:NSMakeRange(0, s.length)
                                  withTemplate:@"<b>$1</b>"];
    // `code` → <code>code</code>
    re = [NSRegularExpression regularExpressionWithPattern:@"`([^`]+)`"
                                                    options:0 error:&err];
    s = [re stringByReplacingMatchesInString:s options:0
                                        range:NSMakeRange(0, s.length)
                                  withTemplate:@"<code>$1</code>"];
    // [text](url) → <a href="url">text</a>
    re = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]]+)\\]\\(([^)]+)\\)"
                                                    options:0 error:&err];
    s = [re stringByReplacingMatchesInString:s options:0
                                        range:NSMakeRange(0, s.length)
                                  withTemplate:@"<a href=\"$2\">$1</a>"];
    // *italic* → <em>italic</em> (single asterisks, AFTER ** to avoid conflict)
    re = [NSRegularExpression regularExpressionWithPattern:@"(?<![\\w*])\\*([^*]+)\\*(?![\\w*])"
                                                    options:0 error:&err];
    s = [re stringByReplacingMatchesInString:s options:0
                                        range:NSMakeRange(0, s.length)
                                  withTemplate:@"<em>$1</em>"];
    return s;
}

- (NSString *)htmlEscape:(NSString *)s {
    if (!s) return @"";
    NSMutableString *out = [s mutableCopy];
    // Order matters: & first so we don't double-escape.
    [out replaceOccurrencesOfString:@"&" withString:@"&amp;"
                             options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"<" withString:@"&lt;"
                             options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@">" withString:@"&gt;"
                             options:0 range:NSMakeRange(0, out.length)];
    return out;
}

#pragma mark - UIWebViewDelegate

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request
                                            navigationType:(UIWebViewNavigationType)navigationType {
    // Allow the initial loadHTMLString to render; intercept any user-initiated
    // link tap and open it in mobile Safari instead of inside our modal.
    if (navigationType == UIWebViewNavigationTypeLinkClicked) {
        [[UIApplication sharedApplication] openURL:request.URL];
        return NO;
    }
    return YES;
}

#pragma mark - Rotation (iOS 6)

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
