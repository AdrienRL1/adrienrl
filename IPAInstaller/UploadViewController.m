#import "UploadViewController.h"
#import "FilePickerViewController.h"
#import "IOS6Theme.h"
#import "Localization.h"
#import "HTTPSClient.h"
#import "DeviceInfo.h"

static NSString *const kUploadURL = @"https://appdrop-feedback.adrienruestlorquet.workers.dev/upload";
static const long long kMaxIPABytes = 45LL * 1024 * 1024;   // mirror the Worker cap

// Section / row layout (grouped).
enum { SEC_FILE, SEC_CAT, SEC_DETAILS, SEC_ATTEST, SEC_COUNT };
enum { D_NAME, D_DESC, D_MINIOS, D_VERSION, D_MOD, D_BID, D_CREDIT, D_COUNT };

@interface UploadViewController () <UITextFieldDelegate, UITextViewDelegate>
@property (nonatomic, copy) NSString *target;
@property (nonatomic, copy) NSString *chosenPath;
@property (nonatomic, assign) long long chosenSize;
@property (nonatomic, strong) UITableViewCell *pickCell;
@property (nonatomic, strong) UISegmentedControl *categorySeg;
@property (nonatomic, strong) UITextField *nameField, *miniosField, *versionField, *modField, *bidField, *creditField;
@property (nonatomic, strong) UITextView *descView;
@property (nonatomic, strong) UISwitch *attestSwitch;
@property (nonatomic, strong) UIBarButtonItem *sendItem;
@end

@implementation UploadViewController

- (instancetype)initWithTarget:(NSString *)target {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _target = [[@"revival" isEqualToString:target] ? @"revival" : @"mods" copy];
    }
    return self;
}

- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme groupedBackgroundColor];
    self.tableView.backgroundColor = [IOS6Theme groupedBackgroundColor];
    if ([IOS6Theme isDark]) self.tableView.backgroundView = nil;
    self.tableView.separatorColor = [IOS6Theme separatorColor];
    [self.tableView reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"upload.title");
    self.view.backgroundColor = [IOS6Theme groupedBackgroundColor];
    if ([IOS6Theme isDark]) self.tableView.backgroundView = nil;

    self.sendItem = [[UIBarButtonItem alloc] initWithTitle:T(@"upload.send")
                        style:UIBarButtonItemStyleDone target:self action:@selector(sendTapped)];
    self.navigationItem.rightBarButtonItem = self.sendItem;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbShow:)
        name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbHide:)
        name:UIKeyboardWillHideNotification object:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

#pragma mark - Keyboard

- (void)kbShow:(NSNotification *)n {
    // iOS 3 backport: UIKeyboardFrameEndUserInfoKey is weak-imported (iOS 3.2+) and resolves to
    // NULL on 3.1.3 — referencing the symbol crashes, and userInfo[NULL] would throw. Look the
    // key up by its literal string (its value equals its name) and fall back to the iOS-2
    // UIKeyboardBoundsUserInfoKey, which 3.x actually posts.
    NSValue *fv = [n.userInfo objectForKey:@"UIKeyboardFrameEndUserInfoKey"];
    if (!fv) fv = [n.userInfo objectForKey:@"UIKeyboardBoundsUserInfoKey"];
    if (!fv) return;
    CGRect f = [fv CGRectValue];
    f = [self.view convertRect:f fromView:nil];
    CGFloat overlap = MAX(0, self.view.bounds.size.height - f.origin.y);
    UIEdgeInsets in = self.tableView.contentInset; in.bottom = overlap;
    self.tableView.contentInset = in; self.tableView.scrollIndicatorInsets = in;
}
- (void)kbHide:(NSNotification *)n {
    UIEdgeInsets in = self.tableView.contentInset; in.bottom = 0;
    self.tableView.contentInset = in; self.tableView.scrollIndicatorInsets = in;
}
- (void)scrollToView:(UIView *)v {
    UIView *cell = v;
    while (cell && ![cell isKindOfClass:[UITableViewCell class]]) cell = cell.superview;
    if (!cell) return;
    NSIndexPath *ip = [self.tableView indexPathForCell:(UITableViewCell *)cell];
    if (ip) [self.tableView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
}

#pragma mark - Cell builders

- (UITableViewCell *)blankCell {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.backgroundColor = [IOS6Theme cellColor];
    return c;
}
- (UITextField *)fieldIn:(UITableViewCell *)c placeholder:(NSString *)ph keyboard:(UIKeyboardType)kb caps:(UITextAutocapitalizationType)caps {
    CGFloat w = self.view.bounds.size.width;
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(14, 6, w - 28 - 20, 32)];
    tf.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    tf.font = [UIFont systemFontOfSize:16];
    tf.textColor = [IOS6Theme labelDark];
    tf.placeholder = ph;
    tf.delegate = self;
    tf.keyboardType = kb;
    tf.autocapitalizationType = caps;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.returnKeyType = UIReturnKeyDone;
    [c.contentView addSubview:tf];
    return tf;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return SEC_COUNT; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == SEC_DETAILS) return D_COUNT;
    return 1;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case SEC_FILE: return T(@"upload.section_file");
        case SEC_CAT: return T(@"upload.section_category");
        case SEC_DETAILS: return T(@"upload.section_details");
        case SEC_ATTEST: return T(@"upload.section_rights");
    }
    return nil;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == SEC_FILE) return T(@"upload.intro");
    if (s == SEC_ATTEST) return T(@"upload.legal");
    return nil;
}
- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)v forSection:(NSInteger)s { [IOS6Theme styleGroupedHeaderFooter:v]; }
- (void)tableView:(UITableView *)tv willDisplayFooterView:(UIView *)v forSection:(NSInteger)s { [IOS6Theme styleGroupedHeaderFooter:v]; }

// Size the category segmented control to the CELL's real content width (grouped cells are inset,
// especially on iPad) — fixes it overflowing off the right edge. Final bounds are known here.
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == SEC_CAT && self.categorySeg) {
        CGFloat cw = cell.contentView.bounds.size.width;
        if (cw > 24) self.categorySeg.frame = CGRectMake(10, 6, cw - 20, 32);
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == SEC_DETAILS && ip.row == D_DESC) return 96.0;
    return 44.0;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    CGFloat w = self.view.bounds.size.width;

    if (ip.section == SEC_FILE) {
        if (!self.pickCell) {
            self.pickCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            self.pickCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        self.pickCell.backgroundColor = [IOS6Theme cellColor];
        self.pickCell.textLabel.textColor = [IOS6Theme labelDark];
        self.pickCell.textLabel.text = T(@"upload.pick_button");
        self.pickCell.detailTextLabel.text = self.chosenPath
            ? [self.chosenPath lastPathComponent] : T(@"upload.pick_none");
        self.pickCell.detailTextLabel.textColor = [IOS6Theme labelGray];
        return self.pickCell;
    }

    if (ip.section == SEC_CAT) {
        UITableViewCell *c = [self blankCell];
        if (!self.categorySeg) {
            self.categorySeg = [[UISegmentedControl alloc] initWithItems:
                @[ T(@"categories.modded"), T(@"revival.title") ]];
            self.categorySeg.selectedSegmentIndex = [self.target isEqualToString:@"revival"] ? 1 : 0;
        }
        self.categorySeg.frame = CGRectMake(12, 6, w - 24, 32);
        self.categorySeg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [c.contentView addSubview:self.categorySeg];
        return c;
    }

    if (ip.section == SEC_ATTEST) {
        UITableViewCell *c = [self blankCell];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, w - 90, 44)];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        l.numberOfLines = 2; l.font = [UIFont systemFontOfSize:13];
        l.backgroundColor = [UIColor clearColor]; l.textColor = [IOS6Theme labelDark];
        l.text = T(@"upload.attest");
        [c.contentView addSubview:l];
        if (!self.attestSwitch) self.attestSwitch = [[UISwitch alloc] init];
        self.attestSwitch.frame = CGRectMake(w - 12 - self.attestSwitch.bounds.size.width, 6, 0, 0);
        self.attestSwitch.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [c.contentView addSubview:self.attestSwitch];
        return c;
    }

    // SEC_DETAILS
    if (ip.row == D_DESC) {
        UITableViewCell *c = [self blankCell];
        if (!self.descView) {
            self.descView = [[UITextView alloc] initWithFrame:CGRectMake(12, 4, w - 24, 88)];
            self.descView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            self.descView.font = [UIFont systemFontOfSize:15];
            self.descView.backgroundColor = [UIColor clearColor];
            self.descView.textColor = [IOS6Theme labelDark];
            self.descView.delegate = self;
            UILabel *ph = [[UILabel alloc] initWithFrame:CGRectMake(17, 12, w - 40, 20)];
            ph.text = T(@"upload.desc_ph"); ph.font = [UIFont systemFontOfSize:15];
            ph.textColor = [IOS6Theme placeholderColor]; ph.backgroundColor = [UIColor clearColor]; ph.tag = 7777;
            [c.contentView addSubview:ph];
        }
        [c.contentView addSubview:self.descView];
        ((UILabel *)[c.contentView viewWithTag:7777]).hidden = self.descView.text.length > 0;
        return c;
    }
    UITableViewCell *c = [self blankCell];
    UITextField *tf = nil;
    switch (ip.row) {
        case D_NAME:    tf = self.nameField    = self.nameField    ?: [self fieldIn:c placeholder:T(@"upload.name_ph")    keyboard:UIKeyboardTypeDefault caps:UITextAutocapitalizationTypeWords]; break;
        case D_MINIOS:  tf = self.miniosField  = self.miniosField  ?: [self fieldIn:c placeholder:T(@"upload.minios_ph")  keyboard:UIKeyboardTypeNumbersAndPunctuation caps:UITextAutocapitalizationTypeNone]; break;
        case D_VERSION: tf = self.versionField = self.versionField ?: [self fieldIn:c placeholder:T(@"upload.version_ph") keyboard:UIKeyboardTypeNumbersAndPunctuation caps:UITextAutocapitalizationTypeNone]; break;
        case D_MOD:     tf = self.modField     = self.modField     ?: [self fieldIn:c placeholder:T(@"upload.mod_ph")     keyboard:UIKeyboardTypeDefault caps:UITextAutocapitalizationTypeSentences]; break;
        case D_BID:     tf = self.bidField     = self.bidField     ?: [self fieldIn:c placeholder:T(@"upload.bid_ph")     keyboard:UIKeyboardTypeURL caps:UITextAutocapitalizationTypeNone]; break;
        case D_CREDIT:  tf = self.creditField  = self.creditField  ?: [self fieldIn:c placeholder:T(@"upload.credit_ph")  keyboard:UIKeyboardTypeDefault caps:UITextAutocapitalizationTypeWords]; break;
    }
    if (tf && tf.superview != c.contentView) [c.contentView addSubview:tf];   // re-attach on reuse
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == SEC_FILE) [self pickFile];
}

#pragma mark - Field delegates

- (void)textFieldDidBeginEditing:(UITextField *)tf { [self scrollToView:tf]; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
- (void)textViewDidBeginEditing:(UITextView *)tv { [self scrollToView:tv]; [self syncPh:tv]; }
- (void)textViewDidChange:(UITextView *)tv { [self syncPh:tv]; }
- (void)syncPh:(UITextView *)tv { ((UILabel *)[tv.superview viewWithTag:7777]).hidden = tv.text.length > 0; }

#pragma mark - File picker

- (void)pickFile {
    [self.view endEditing:YES];
    FilePickerViewController *fp = [[FilePickerViewController alloc] initWithDirectory:nil];
    AD_WEAK UploadViewController *weakSelf = self;
    fp.onPick = ^(NSString *path) {
        UploadViewController *s = weakSelf; if (!s) return;
        s.chosenPath = path;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        s.chosenSize = attrs ? (long long)[attrs fileSize] : 0;
        [s.tableView reloadData];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fp];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Send

- (NSString *)trim:(UITextField *)f { return [(f.text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; }

- (void)sendTapped {
    NSString *name = [self trim:self.nameField];
    if (self.chosenPath.length == 0) { [self alert:T(@"upload.title") msg:T(@"upload.err_nofile")]; return; }
    if (name.length == 0)            { [self alert:T(@"upload.title") msg:T(@"upload.err_noname")]; return; }
    if (!self.attestSwitch.on)       { [self alert:T(@"upload.title") msg:T(@"upload.err_attest")]; return; }
    if (self.chosenSize > kMaxIPABytes) {
        [self alert:T(@"upload.title") msg:[NSString stringWithFormat:T(@"upload.err_toobig"), 45]];
        return;
    }
    NSData *fileData = [NSData dataWithContentsOfFile:self.chosenPath];
    if (!fileData.length) { [self alert:T(@"upload.title") msg:T(@"upload.err_read")]; return; }
    NSString *b64 = [self base64:fileData];
    if (!b64.length) { [self alert:T(@"upload.title") msg:T(@"upload.err_read")]; return; }

    [self.view endEditing:YES];
    self.sendItem.enabled = NO;
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [sp startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:sp];

    NSString *target = (self.categorySeg.selectedSegmentIndex == 1) ? @"revival" : @"mods";
    NSDictionary *payload = @{
        @"target":      target,
        @"name":        name,
        @"description": [self textViewText:self.descView],
        @"min_ios":     [self trim:self.miniosField],
        @"appver":      [self trim:self.versionField],
        @"mod":         [self trim:self.modField],
        @"bid":         [self trim:self.bidField],
        @"credit":      [self trim:self.creditField],
        @"ipa":         b64,
        @"attest":      @YES,
        @"device":      [DeviceInfo aiSummary] ?: @"",
        @"lang":        [Localization currentLanguageCode] ?: @"en",
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];

    [HTTPSClient postURL:kUploadURL headers:@{@"Content-Type": @"application/json"} body:body timeout:120
              completion:^(NSData *resp, NSInteger code, NSError *err) {
        self.navigationItem.rightBarButtonItem = self.sendItem;
        self.sendItem.enabled = YES;
        if (!err && code >= 200 && code < 300) {
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"upload.sent_title") message:T(@"upload.sent")
                                delegate:self cancelButtonTitle:T(@"common.ok") otherButtonTitles:nil];
            a.tag = 5151; [a show];
        } else {
            [self alert:T(@"common.error")
                    msg:[NSString stringWithFormat:@"%@ (%ld)", T(@"upload.err_send"), (long)code]];
        }
    }];
}

- (void)alertView:(UIAlertView *)av didDismissWithButtonIndex:(NSInteger)i {
    if (av.tag == 5151) [self.navigationController popViewControllerAnimated:YES];
}

- (NSString *)textViewText:(UITextView *)tv {
    return [(tv.text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
- (NSString *)base64:(NSData *)d {
    if ([d respondsToSelector:@selector(base64EncodedStringWithOptions:)]) return [d base64EncodedStringWithOptions:0];
    if ([d respondsToSelector:@selector(base64Encoding)]) return [d performSelector:@selector(base64Encoding)];
    return @"";
}
- (void)alert:(NSString *)t msg:(NSString *)m {
    [[[UIAlertView alloc] initWithTitle:t message:m delegate:nil cancelButtonTitle:T(@"common.ok") otherButtonTitles:nil] show];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
