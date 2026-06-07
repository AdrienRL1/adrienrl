#import "ADNumberPickerSheet.h"
#import "Localization.h"

#define kSheetPickerH   216.0
#define kSheetBarH       44.0
#define kSheetH         (kSheetPickerH + kSheetBarH)

@interface ADNumberPickerSheet () <UIPickerViewDataSource, UIPickerViewDelegate>
@property (nonatomic, strong) NSArray *values;   // NSNumber<int>
@property (nonatomic, strong) NSArray *labels;   // NSString
@property (nonatomic, strong) UIControl *dim;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIPickerView *picker;
@end

@implementation ADNumberPickerSheet {
    // iOS 3: blocks aren't ObjC objects, so a synthesized @property(copy) block
    // setter calls objc_setProperty(copy=YES) → -copyWithZone: on the block →
    // objc_msgSend dereferences a zeroed isa → Bus error (signal 10). This is the
    // crash when opening "Apps per row" / "Home tiles per row". Back the block
    // manually through the C blocks runtime (_Block_copy/_Block_release) — see
    // AppDropBlocks.h (AD_BLOCK_ACCESSORS).
    void (^_onPickBlock)(NSInteger value);
}
@dynamic onPick;
AD_BLOCK_ACCESSORS(onPick, setOnPick, _onPickBlock, void(^)(NSInteger value))

- (void)dealloc {
    if (_onPickBlock) _Block_release((const void *)_onPickBlock);
    [super dealloc];
}

+ (void)presentInView:(UIView *)host
                title:(NSString *)title
               values:(NSArray *)values
               labels:(NSArray *)labels
        selectedValue:(NSInteger)selectedValue
               onPick:(void (^)(NSInteger value))onPick {
    if (!host || values.count == 0 || values.count != labels.count) return;

    ADNumberPickerSheet *sheet = [[ADNumberPickerSheet alloc] initWithFrame:host.bounds];
    sheet.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sheet.values = values;
    sheet.labels = labels;
    sheet.onPick = onPick;
    [sheet buildWithTitle:title selectedValue:selectedValue];
    [host addSubview:sheet];
    [sheet animateIn];
}

- (void)buildWithTitle:(NSString *)title selectedValue:(NSInteger)selectedValue {
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;

    // Dim backdrop — tap to cancel.
    self.dim = [[UIControl alloc] initWithFrame:self.bounds];
    self.dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.0];
    [self.dim addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.dim];

    // Bottom panel (starts off-screen, slides up). Pinned to the bottom on rotation.
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, H, W, kSheetH)];
    self.panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.panel.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];   // light, matches the iOS 6 wheel
    [self addSubview:self.panel];

    // Toolbar: Annuler | title | OK  — light default bar so it looks like the era's pickers.
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, W, kSheetBarH)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    bar.barStyle = UIBarStyleDefault;
    UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:T(@"common.cancel")
                                style:UIBarButtonItemStylePlain target:self action:@selector(cancelTapped)];
    UIBarButtonItem *flexL = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *flexR = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:T(@"common.done")
                                style:UIBarButtonItemStyleDone target:self action:@selector(doneTapped)];
    NSMutableArray *items = [NSMutableArray arrayWithObjects:cancel, flexL, nil];
    if (title.length) {
        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 180, 28)];
        tl.backgroundColor = [UIColor clearColor];
        tl.textAlignment = NSTextAlignmentCenter;
        tl.font = [UIFont boldSystemFontOfSize:15];
        tl.textColor = [UIColor colorWithWhite:0.20 alpha:1.0];
        tl.text = title;
        [items addObject:[[UIBarButtonItem alloc] initWithCustomView:tl]];
        [items addObject:flexR];
    }
    [items addObject:done];
    bar.items = items;
    [self.panel addSubview:bar];

    // The wheel.
    self.picker = [[UIPickerView alloc] initWithFrame:CGRectMake(0, kSheetBarH, W, kSheetPickerH)];
    self.picker.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.picker.showsSelectionIndicator = YES;
    self.picker.dataSource = self;
    self.picker.delegate = self;
    [self.panel addSubview:self.picker];

    // Pre-select.
    NSInteger sel = 0;
    for (NSInteger i = 0; i < (NSInteger)self.values.count; i++) {
        if ([self.values[i] integerValue] == selectedValue) { sel = i; break; }
    }
    [self.picker selectRow:sel inComponent:0 animated:NO];
}

- (void)animateIn {
    CGFloat H = self.bounds.size.height;
    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
        self.panel.frame = CGRectMake(0, H - kSheetH, self.bounds.size.width, kSheetH);
    } completion:nil];
}

- (void)dismiss {
    CGFloat H = self.bounds.size.height;
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.0];
        self.panel.frame = CGRectMake(0, H, self.bounds.size.width, kSheetH);
    } completion:^(BOOL finished){
        [self removeFromSuperview];
    }];
}

- (void)cancelTapped { [self dismiss]; }

- (void)doneTapped {
    NSInteger row = [self.picker selectedRowInComponent:0];
    if (row >= 0 && row < (NSInteger)self.values.count && self.onPick) {
        self.onPick([self.values[row] integerValue]);
    }
    [self dismiss];
}

#pragma mark - UIPickerView

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pv { return 1; }
- (NSInteger)pickerView:(UIPickerView *)pv numberOfRowsInComponent:(NSInteger)c { return (NSInteger)self.values.count; }
- (NSString *)pickerView:(UIPickerView *)pv titleForRow:(NSInteger)row forComponent:(NSInteger)c {
    return (row >= 0 && row < (NSInteger)self.labels.count) ? self.labels[row] : @"";
}
- (CGFloat)pickerView:(UIPickerView *)pv rowHeightForComponent:(NSInteger)c { return 40.0; }

@end
