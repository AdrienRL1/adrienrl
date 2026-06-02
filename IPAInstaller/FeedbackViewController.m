#import "FeedbackViewController.h"
#import "Localization.h"
#import "IOS6Theme.h"
#import "HTTPSClient.h"
#import "DeviceInfo.h"
#import <QuartzCore/QuartzCore.h>

// Cloudflare Worker endpoint that turns a POST into a GitHub issue.
static NSString *const kFeedbackURL = @"https://appdrop-feedback.adrienruestlorquet.workers.dev";
static const NSUInteger kMaxImages = 5;

static inline BOOL kFbIsIPad(void) { return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad; }

// Filled speech-bubble glyph for the nav-bar Feedback button, drawn in WHITE with the same
// subtle shadow as the bar's white text buttons. It's hosted in a customView UIButton (see
// installFeedbackBarButton) so iOS shows it as-is instead of applying the dark "engraved"
// treatment that bar-button IMAGES get on the blue iOS-6 nav bar (the cause of the
// too-dark look — the icon shape itself is unchanged).
static UIImage * __attribute__((unused)) AppDropFeedbackBarIcon(void) {
    CGSize s = CGSizeMake(28, 26);
    UIGraphicsBeginImageContextWithOptions(s, NO, [UIScreen mainScreen].scale);
    CGContextRef c = UIGraphicsGetCurrentContext();
    UIColor *dark = [UIColor colorWithRed:0.12 green:0.19 blue:0.33 alpha:1.0];  // crisp navy

    UIBezierPath *bubble = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, 24, 15) cornerRadius:4.5];
    UIBezierPath *tail = [UIBezierPath bezierPath];
    [tail moveToPoint:CGPointMake(8, 16.5)];
    [tail addLineToPoint:CGPointMake(8, 22)];
    [tail addLineToPoint:CGPointMake(14.5, 16.5)];
    [tail closePath];

    // White fill (the shape) with a soft shadow to lift it off the bar.
    CGContextSetShadowWithColor(c, CGSizeMake(0, 1), 1.2, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
    [[UIColor whiteColor] setFill];
    [bubble fill];
    [tail fill];

    // Crisp dark outline + dark dots → clearly visible on the pale-blue nav bar
    // (white alone washes out), without being a heavy dark blob.
    CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
    [dark setStroke];
    bubble.lineWidth = 1.4; [bubble stroke];
    tail.lineWidth = 1.4;   [tail stroke];
    [dark setFill];
    for (int i = 0; i < 3; i++)
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(6.8 + i*5.4, 7.6, 2.6, 2.6)] fill];

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

@interface FeedbackViewController () <UITextViewDelegate, UINavigationControllerDelegate,
                                      UIImagePickerControllerDelegate>
@property (nonatomic, strong) UILabel *intro;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *placeholder;
@property (nonatomic, strong) UIScrollView *thumbStrip;      // horizontal photos row
@property (nonatomic, strong) NSMutableArray *images;        // UIImage*
@property (nonatomic, strong) UIBarButtonItem *sendItem;
@property (nonatomic, strong) id popover;                    // UIPopoverController on iPad
@property (nonatomic, assign) CGFloat introHeight;
@property (nonatomic, assign) CGFloat kbCutoff;              // view-coord Y of keyboard top (0 = none)
@end

@implementation FeedbackViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"feedback.title");
    self.view.backgroundColor = [IOS6Theme groupedBackgroundColor];
    self.images = [NSMutableArray array];

    self.sendItem = [[UIBarButtonItem alloc] initWithTitle:T(@"feedback.send")
                                                     style:UIBarButtonItemStyleDone
                                                    target:self action:@selector(sendTapped)];
    self.navigationItem.rightBarButtonItem = self.sendItem;

    CGFloat W = self.view.bounds.size.width, pad = 16;
    self.intro = [[UILabel alloc] initWithFrame:CGRectMake(pad, 8, W - 2*pad, 50)];
    self.intro.numberOfLines = 0;
    self.intro.font = [UIFont systemFontOfSize:14];
    self.intro.textColor = [UIColor darkGrayColor];
    self.intro.backgroundColor = [UIColor clearColor];
    self.intro.text = T(@"feedback.intro");
    [self.intro sizeToFit];
    self.introHeight = MIN(60, self.intro.frame.size.height);
    [self.view addSubview:self.intro];

    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.font = [UIFont systemFontOfSize:16];
    self.textView.layer.borderColor = [UIColor colorWithRed:0.78 green:0.80 blue:0.84 alpha:1.0].CGColor;
    self.textView.layer.borderWidth = 1.0;
    self.textView.layer.cornerRadius = 8.0;
    self.textView.delegate = self;
    [self.view addSubview:self.textView];

    self.placeholder = [[UILabel alloc] initWithFrame:CGRectZero];
    self.placeholder.font = [UIFont systemFontOfSize:16];
    self.placeholder.textColor = [UIColor lightGrayColor];
    self.placeholder.backgroundColor = [UIColor clearColor];
    self.placeholder.text = T(@"feedback.placeholder");
    [self.view addSubview:self.placeholder];

    self.thumbStrip = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.thumbStrip.showsHorizontalScrollIndicator = NO;
    self.thumbStrip.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.thumbStrip];

    [self relayoutThumbs];
    [self applyLayout];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbShow:)
        name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbHide:)
        name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewWillLayoutSubviews { [super viewWillLayoutSubviews]; [self applyLayout]; }

// Position the text box so it ALWAYS sits above the keyboard (so the user sees what
// they type), with the photo strip just under it (hidden behind the keyboard while typing).
- (void)applyLayout {
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height, pad = 16;
    CGFloat y = 8;
    self.intro.frame = CGRectMake(pad, y, W - 2*pad, self.introHeight);
    y += self.introHeight + 8;

    CGFloat thumbH = 76;
    BOOL kbUp = self.kbCutoff > 0;
    CGFloat bottom = kbUp ? self.kbCutoff : H;            // usable bottom edge
    CGFloat tvBottom;
    if (kbUp) {
        self.thumbStrip.hidden = YES;
        tvBottom = bottom - 8;
    } else {
        CGFloat thumbY = H - thumbH - 8;
        self.thumbStrip.frame = CGRectMake(pad, thumbY, W - 2*pad, thumbH);
        self.thumbStrip.hidden = NO;
        tvBottom = thumbY - 8;
    }
    self.textView.frame = CGRectMake(pad, y, W - 2*pad, MAX(70, tvBottom - y));
    self.placeholder.frame = CGRectMake(pad + 5, y + 8, W - 2*pad - 10, 22);
}

#pragma mark - Keyboard

- (void)kbShow:(NSNotification *)n {
    CGRect f = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    f = [self.view convertRect:f fromView:nil];
    self.kbCutoff = f.origin.y;     // top of the keyboard, in this view's coords
    [self applyLayout];
}
- (void)kbHide:(NSNotification *)n { self.kbCutoff = 0; [self applyLayout]; }
- (void)textViewDidChange:(UITextView *)tv { self.placeholder.hidden = tv.text.length > 0; }

#pragma mark - Photos (multiple)

- (void)relayoutThumbs {
    for (UIView *v in [self.thumbStrip.subviews copy]) [v removeFromSuperview];
    CGFloat x = 2, sz = 66;
    for (NSUInteger i = 0; i < self.images.count; i++) {
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(x, 4, sz, sz)];
        iv.image = self.images[i];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.layer.cornerRadius = 6;
        iv.userInteractionEnabled = YES;
        iv.tag = (NSInteger)i;
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(thumbTapped:)];
        [iv addGestureRecognizer:t];
        [self.thumbStrip addSubview:iv];
        // little "✕" hint badge so it's clear a tap removes the photo
        UILabel *x2 = [[UILabel alloc] initWithFrame:CGRectMake(x + sz - 18, 4, 18, 18)];
        x2.text = @"✕"; x2.font = [UIFont boldSystemFontOfSize:13];
        x2.textColor = [UIColor whiteColor];
        x2.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.45];
        x2.textAlignment = NSTextAlignmentCenter; x2.layer.cornerRadius = 9; x2.clipsToBounds = YES;
        [self.thumbStrip addSubview:x2];
        x += sz + 8;
    }
    if (self.images.count < kMaxImages) {
        UIButton *add = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        add.frame = CGRectMake(x, 4, sz, sz);
        [add setTitle:@"＋" forState:UIControlStateNormal];
        add.titleLabel.font = [UIFont systemFontOfSize:34];
        add.layer.borderColor = [UIColor colorWithRed:0.7 green:0.72 blue:0.76 alpha:1].CGColor;
        add.layer.borderWidth = 1; add.layer.cornerRadius = 6;
        [add addTarget:self action:@selector(addPhotoTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.thumbStrip addSubview:add];
        x += sz + 8;
    }
    self.thumbStrip.contentSize = CGSizeMake(x, 74);
}

- (void)thumbTapped:(UITapGestureRecognizer *)g {
    NSUInteger i = (NSUInteger)g.view.tag;
    if (i < self.images.count) { [self.images removeObjectAtIndex:i]; [self relayoutThumbs]; }
}

- (void)addPhotoTapped {
    [self.textView resignFirstResponder];
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) return;
    UIImagePickerController *p = [[UIImagePickerController alloc] init];
    p.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    p.delegate = self;
    if (kFbIsIPad()) {
        Class pop = NSClassFromString(@"UIPopoverController");
        if (pop) {
            self.popover = [[pop alloc] initWithContentViewController:p];
            [self.popover presentPopoverFromRect:self.thumbStrip.frame inView:self.view
                        permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
            return;
        }
    }
    [self presentViewController:p animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
        didFinishPickingMediaWithInfo:(NSDictionary *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    if (img && self.images.count < kMaxImages) { [self.images addObject:img]; [self relayoutThumbs]; }
    [self dismissPicker:picker];
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker { [self dismissPicker:picker]; }
- (void)dismissPicker:(UIImagePickerController *)picker {
    if (self.popover) { [self.popover dismissPopoverAnimated:YES]; self.popover = nil; }
    else [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Send

- (void)sendTapped {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length < 3) { [self alert:T(@"feedback.title") msg:T(@"feedback.empty")]; return; }
    if (kFeedbackURL.length == 0) { [self alert:T(@"feedback.title") msg:T(@"feedback.not_configured")]; return; }
    [self.textView resignFirstResponder];
    self.sendItem.enabled = NO;
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [sp startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:sp];

    NSMutableArray *b64s = [NSMutableArray array];
    for (UIImage *img in self.images) {
        NSData *jpeg = UIImageJPEGRepresentation(img, 0.85);
        if (jpeg.length) { NSString *b = [self base64:jpeg]; if (b.length) [b64s addObject:b]; }
    }
    NSBundle *b = [NSBundle mainBundle];
    NSDictionary *payload = @{
        @"text": text,
        @"images": b64s,                                 // array (multiple photos)
        @"image": (b64s.count ? b64s[0] : @""),          // back-compat single
        @"device": [DeviceInfo aiSummary] ?: @"",
        @"version": [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
        @"build": [b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?",
        @"lang": [Localization currentLanguageCode] ?: @"en",
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];

    [HTTPSClient postURL:kFeedbackURL
                 headers:@{@"Content-Type": @"application/json"}
                    body:body timeout:90
              completion:^(NSData *resp, NSInteger code, NSError *err) {
        self.navigationItem.rightBarButtonItem = self.sendItem;
        self.sendItem.enabled = YES;
        if (!err && code >= 200 && code < 300) {
            [self alert:T(@"feedback.sent_title") msg:T(@"feedback.sent")];
            self.textView.text = @""; self.placeholder.hidden = NO;
            [self.images removeAllObjects]; [self relayoutThumbs];
        } else {
            [self alert:T(@"common.error")
                    msg:[NSString stringWithFormat:@"%@ (%ld)", T(@"feedback.error"), (long)code]];
        }
    }];
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:title message:msg delegate:nil
                                      cancelButtonTitle:T(@"common.ok") otherButtonTitles:nil];
    [a show];
}

- (NSString *)base64:(NSData *)d {
    if ([d respondsToSelector:@selector(base64EncodedStringWithOptions:)])
        return [d base64EncodedStringWithOptions:0];
    if ([d respondsToSelector:@selector(base64Encoding)])
        return [d performSelector:@selector(base64Encoding)];
    return @"";
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end

@implementation UIViewController (AppDropFeedback)

- (void)installFeedbackBarButton {
    // Localized TEXT button (replaces the speech-bubble icon) on the left of root screens.
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:T(@"feedback.title") style:UIBarButtonItemStyleBordered
               target:self action:@selector(appdropOpenFeedback)];
}

- (void)appdropOpenFeedback {
    FeedbackViewController *fb = [[FeedbackViewController alloc] init];
    [self.navigationController pushViewController:fb animated:YES];
}

@end
