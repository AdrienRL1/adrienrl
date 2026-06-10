#import "UploadViewController.h"
#import "FilePickerViewController.h"
#import "CategorySuggestViewController.h"
#import "IOS6Theme.h"
#import "Localization.h"
#import "HTTPSClient.h"
#import "DeviceInfo.h"
#import "MachOInspector.h"
#import "IPAPackage.h"
#import "LocalCatalog.h"

static NSString *const kUploadURL = @"https://appdrop-feedback.adrienruestlorquet.workers.dev/upload";
static const long long kMaxIPABytes = 45LL * 1024 * 1024;   // mirror the Worker cap

// A text field that draws its placeholder in the THEMED placeholder colour instead of the
// fixed system grey. The upload form uses placeholders AS field labels, and the system grey was
// unreadable on the dark theme (iPad 1 / iOS 5). drawPlaceholderInRect: is the reliable hook
// across iOS 5-10 (attributedPlaceholder is iOS 6+ only, so iOS 5 needs this). (#170b)
@interface ADThemedField : UITextField @end
@implementation ADThemedField
// iOS 5/6 render the placeholder via a private `_placeholderLabel` (a UILabel) — the fixed system
// grey is unreadable on the dark theme. Recolour that label here, where it exists by layout time.
// (The earlier attempt overrode -drawPlaceholderInRect:, but on iOS 5 that runs without a graphics
// context → null-context deref → crash. This KVC approach is the safe, stable way on iOS 5-10.) (#170b)
- (void)layoutSubviews {
    [super layoutSubviews];
    @try {
        id pl = [self valueForKey:@"_placeholderLabel"];
        if ([pl isKindOfClass:[UILabel class]])
            ((UILabel *)pl).textColor = [IOS6Theme placeholderColor];
    } @catch (__unused NSException *e) { /* ivar gone on a future OS — harmless */ }
}
@end

// Upload type. Index doubles as the segmented-control segment.
typedef NS_ENUM(NSInteger, UploadKind) {
    UploadKindCatalog = 0,   // a normal app/game NOT in the 43k catalogue → merged in under a category
    UploadKindRevival = 1,   // "Fonctionne aujourd'hui"
    UploadKindMods    = 2,   // "Apps modifiées"
};
static NSString *UploadKindTarget(UploadKind k) {
    return k == UploadKindCatalog ? @"catalog" : (k == UploadKindRevival ? @"revival" : @"mods");
}

// v3.1 ⇄ v3.2 SWITCH. The "Catalogue" (normal-app) upload type + its category picker are DEFERRED to
// v3.2 — the whole feature is KEPT in the code, just dormant. Flip to YES for v3.2 to re-enable it.
// v3.1 ships only Fonctionne aujourd'hui / Apps modifiées, both with a MANDATORY description.
static const BOOL kEnableCatalogType = NO;

// Section kinds (the order/visibility is rebuilt by -rebuildSections; K_CATEGORY only shows for catalog).
enum { K_FILE, K_TYPE, K_CATEGORY, K_DETAILS, K_ATTEST };
// Detail rows.
enum { D_NAME, D_DESC, D_MINIOS, D_VERSION, D_MOD, D_BID, D_CREDIT, D_COUNT };

// Localized category / subgenre names (mirror the small file-static helpers used elsewhere).
static NSString *uvLocName(NSString *prefix, NSString *value) {
    if (!value.length) return @"";
    NSString *k = [prefix stringByAppendingString:value];
    NSString *v = T(k);
    return [v isEqualToString:k] ? value : v;
}
static NSString *uvLocCat(NSString *c) { return uvLocName(@"cat.", c); }
static NSString *uvLocSub(NSString *s) { return uvLocName(@"sub.", s); }

@interface UploadViewController () <UITextFieldDelegate, UITextViewDelegate>
@property (nonatomic, assign) UploadKind kind;
@property (nonatomic, strong) NSArray *kinds;              // section layout (array of NSNumber kind)
@property (nonatomic, copy) NSString *chosenPath;
@property (nonatomic, assign) long long chosenSize;
@property (nonatomic, assign) BOOL analyzing;             // inspecting/extracting the picked .ipa
@property (nonatomic, copy) NSString *iconB64;            // auto-extracted icon (standard PNG, base64)
@property (nonatomic, copy) NSString *pickedCategory;     // for catalog uploads
@property (nonatomic, copy) NSString *pickedSubgenre;
@property (nonatomic, assign) BOOL bidInCatalog;          // current bid already present in the catalogue
@property (nonatomic, strong) UITableViewCell *pickCell;
@property (nonatomic, strong) UISegmentedControl *typeSeg;
@property (nonatomic, strong) UITextField *nameField, *miniosField, *versionField, *modField, *bidField, *creditField;
@property (nonatomic, strong) UITextView *descView;
@property (nonatomic, strong) UILabel *descPh;
@property (nonatomic, strong) UISwitch *attestSwitch;
@property (nonatomic, strong) UIBarButtonItem *sendItem;
@end

@implementation UploadViewController

- (instancetype)initWithTarget:(NSString *)target {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        if ([@"revival" isEqualToString:target]) _kind = UploadKindRevival;
        else if ([@"mods" isEqualToString:target]) _kind = UploadKindMods;
        else _kind = UploadKindCatalog;
        if (!kEnableCatalogType && _kind == UploadKindCatalog) _kind = UploadKindRevival;   // v3.1: no catalog type
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
    [self rebuildSections];

    self.sendItem = [[UIBarButtonItem alloc] initWithTitle:T(@"upload.send")
                        style:UIBarButtonItemStyleDone target:self action:@selector(sendTapped)];
    self.navigationItem.rightBarButtonItem = self.sendItem;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbShow:)
        name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbHide:)
        name:UIKeyboardWillHideNotification object:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self];  [super dealloc]; }

- (void)rebuildSections {
    NSMutableArray *k = [@[ @(K_FILE), @(K_TYPE) ] mutableCopy];
    if (self.kind == UploadKindCatalog) [k addObject:@(K_CATEGORY)];
    [k addObject:@(K_DETAILS)];
    [k addObject:@(K_ATTEST)];
    self.kinds = k;
}
- (NSInteger)kindForSection:(NSInteger)s {
    if (s < 0 || s >= (NSInteger)self.kinds.count) return -1;
    return [self.kinds[s] integerValue];
}

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
    UITextField *tf = [[ADThemedField alloc] initWithFrame:CGRectMake(14, 6, w - 28 - 20, 32)];
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)self.kinds.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return [self kindForSection:s] == K_DETAILS ? D_COUNT : 1;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch ([self kindForSection:s]) {
        case K_FILE:     return T(@"upload.section_file");
        case K_TYPE:     return T(@"upload.section_type");
        case K_CATEGORY: return T(@"upload.section_category");
        case K_DETAILS:  return T(@"upload.section_details");
        case K_ATTEST:   return T(@"upload.section_rights");
    }
    return nil;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    switch ([self kindForSection:s]) {
        case K_FILE:     return T(@"upload.intro");
        case K_CATEGORY: return self.bidInCatalog ? T(@"upload.cat_inherited") : T(@"upload.cat_footer");
        case K_ATTEST:   return T(@"upload.legal");
    }
    return nil;
}
- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)v forSection:(NSInteger)s { [IOS6Theme styleGroupedHeaderFooter:v]; }
- (void)tableView:(UITableView *)tv willDisplayFooterView:(UIView *)v forSection:(NSInteger)s { [IOS6Theme styleGroupedHeaderFooter:v]; }
// iOS 5 has no willDisplay…View: hooks, so the default grouped header/footer keep a light-mode emboss
// unreadable in dark mode ("Fichier"/"Type"/"Détails" + the footer notes). Supply themed views on
// iOS 5; iOS 6+ returns nil/auto so the willDisplay… paths above stay unchanged. (#170b)
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    if (![IOS6Theme needsManualGroupedHeaderFooter]) return nil;
    return [IOS6Theme manualGroupedHeaderViewForTitle:[self tableView:tv titleForHeaderInSection:s]
                                                width:tv.bounds.size.width];
}
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    if (![IOS6Theme needsManualGroupedHeaderFooter]) return UITableViewAutomaticDimension;
    return [IOS6Theme manualGroupedHeaderHeightForTitle:[self tableView:tv titleForHeaderInSection:s]];
}
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    if (![IOS6Theme needsManualGroupedHeaderFooter]) return nil;
    return [IOS6Theme manualGroupedFooterViewForText:[self tableView:tv titleForFooterInSection:s]
                                               width:tv.bounds.size.width];
}
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    if (![IOS6Theme needsManualGroupedHeaderFooter]) return UITableViewAutomaticDimension;
    return [IOS6Theme manualGroupedFooterHeightForText:[self tableView:tv titleForFooterInSection:s]
                                                 width:tv.bounds.size.width];
}

// Size the type segmented control to the CELL's real content width (grouped cells are inset).
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    // iOS 5/6 grouped tables override a cell.backgroundColor set in cellForRow: with the default
    // light backdrop, so in dark mode the cells stayed WHITE and the (light) text was unreadable.
    // Re-apply the themed cell colour here — the only place it reliably sticks for grouped cells.
    cell.backgroundColor = [IOS6Theme cellColor];
    if ([self kindForSection:ip.section] == K_TYPE && self.typeSeg) {
        CGFloat cw = cell.contentView.bounds.size.width;
        if (cw > 24) self.typeSeg.frame = CGRectMake(10, 6, cw - 20, 32);
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if ([self kindForSection:ip.section] == K_DETAILS && ip.row == D_DESC) return 96.0;
    return 44.0;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    CGFloat w = self.view.bounds.size.width;
    NSInteger kind = [self kindForSection:ip.section];

    if (kind == K_FILE) {
        if (!self.pickCell) {
            self.pickCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            self.pickCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        self.pickCell.backgroundColor = [IOS6Theme cellColor];
        self.pickCell.textLabel.textColor = [IOS6Theme labelDark];
        self.pickCell.textLabel.text = T(@"upload.pick_button");
        self.pickCell.detailTextLabel.text = self.analyzing ? T(@"upload.analyzing")
            : (self.chosenPath ? [self.chosenPath lastPathComponent] : T(@"upload.pick_none"));
        self.pickCell.detailTextLabel.textColor = [IOS6Theme labelGray];
        return self.pickCell;
    }

    if (kind == K_TYPE) {
        UITableViewCell *c = [self blankCell];
        if (!self.typeSeg) {
            NSArray *segItems = kEnableCatalogType
                ? @[ T(@"upload.type_catalog"), T(@"upload.type_revival"), T(@"upload.type_mods") ]
                : @[ T(@"upload.type_revival"), T(@"upload.type_mods") ];   // v3.1: 2-way (catalog deferred)
            self.typeSeg = [[UISegmentedControl alloc] initWithItems:segItems];
            self.typeSeg.selectedSegmentIndex = [self segIndexForKind:self.kind];
            [self.typeSeg addTarget:self action:@selector(typeChanged:) forControlEvents:UIControlEventValueChanged];
        }
        self.typeSeg.frame = CGRectMake(12, 6, w - 24, 32);
        self.typeSeg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [c.contentView addSubview:self.typeSeg];
        return c;
    }

    if (kind == K_CATEGORY) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.backgroundColor = [IOS6Theme cellColor];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (self.pickedCategory.length) {
            c.textLabel.textColor = [IOS6Theme labelDark];
            c.textLabel.text = self.pickedSubgenre.length
                ? [NSString stringWithFormat:@"%@ › %@", uvLocCat(self.pickedCategory), uvLocSub(self.pickedSubgenre)]
                : uvLocCat(self.pickedCategory);
        } else {
            c.textLabel.textColor = [IOS6Theme labelGray];
            c.textLabel.text = T(@"upload.cat_choose");
        }
        return c;
    }

    if (kind == K_ATTEST) {
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

    // K_DETAILS
    if (ip.row == D_DESC) {
        UITableViewCell *c = [self blankCell];
        if (!self.descView) {
            self.descView = [[UITextView alloc] initWithFrame:CGRectMake(12, 4, w - 24, 88)];
            self.descView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            self.descView.font = [UIFont systemFontOfSize:15];
            self.descView.backgroundColor = [UIColor clearColor];
            self.descView.textColor = [IOS6Theme labelDark];
            self.descView.delegate = self;
            self.descPh = [[UILabel alloc] initWithFrame:CGRectMake(17, 12, w - 40, 20)];
            self.descPh.font = [UIFont systemFontOfSize:15];
            self.descPh.textColor = [IOS6Theme placeholderColor];
            self.descPh.backgroundColor = [UIColor clearColor]; self.descPh.tag = 7777;
        }
        // Placeholder reflects whether the description is required for this type. Re-attach both views
        // on cell reuse (each reloadData builds a fresh cell).
        self.descPh.text = (self.kind == UploadKindCatalog) ? T(@"upload.desc_ph_opt") : T(@"upload.desc_ph_req");
        if (self.descPh.superview != c.contentView)   [c.contentView addSubview:self.descPh];
        if (self.descView.superview != c.contentView) [c.contentView addSubview:self.descView];
        self.descPh.hidden = self.descView.text.length > 0;
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
    NSInteger kind = [self kindForSection:ip.section];
    if (kind == K_FILE) [self pickFile];
    else if (kind == K_CATEGORY) [self pickCategory];
}

#pragma mark - Type / category

// Map between the segmented-control index and UploadKind. ON (v3.2) → [Catalogue,Fonctionne,Modifiée]
// (index == kind). OFF (v3.1) → [Fonctionne,Modifiée].
- (NSInteger)segIndexForKind:(UploadKind)k {
    if (kEnableCatalogType) return (NSInteger)k;
    return (k == UploadKindMods) ? 1 : 0;
}
- (UploadKind)kindForSegIndex:(NSInteger)i {
    if (kEnableCatalogType) return (UploadKind)i;
    return (i == 1) ? UploadKindMods : UploadKindRevival;
}

- (void)typeChanged:(UISegmentedControl *)seg {
    self.kind = [self kindForSegIndex:seg.selectedSegmentIndex];
    [self.view endEditing:YES];
    [self rebuildSections];
    [self.tableView reloadData];
}

- (void)pickCategory {
    [self.view endEditing:YES];
    CategorySuggestViewController *p = [[CategorySuggestViewController alloc]
        initForPickingCategory:self.pickedCategory subgenre:self.pickedSubgenre];
    AD_WEAK UploadViewController *weakSelf = self;
    p.onPick = ^(NSString *category, NSString *subgenre) {
        UploadViewController *s = weakSelf; if (!s) return;
        s.pickedCategory = category;
        s.pickedSubgenre = subgenre;
        [s.tableView reloadData];
    };
    [self.navigationController pushViewController:p animated:YES];
}

#pragma mark - Field delegates

- (void)textFieldDidBeginEditing:(UITextField *)tf { [self scrollToView:tf]; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
- (void)textFieldDidEndEditing:(UITextField *)tf {
    if (tf == self.bidField) { [self refreshBidInCatalog]; }   // typed bid → re-check catalogue
}
- (void)textViewDidBeginEditing:(UITextView *)tv { [self scrollToView:tv]; [self syncPh:tv]; }
- (void)textViewDidChange:(UITextView *)tv { [self syncPh:tv]; }
- (void)syncPh:(UITextView *)tv { ((UILabel *)[tv.superview viewWithTag:7777]).hidden = tv.text.length > 0; }

// Is the current bundle id already in the catalogue? Drives the catalogue footer + "category optional".
- (void)refreshBidInCatalog {
    NSString *bid = [self trim:self.bidField];
    BOOL was = self.bidInCatalog;
    NSString *prevCat = self.pickedCategory;
    if (bid.length) {
        NSDictionary *cur = [[LocalCatalog shared] categorySubgenreForBundleId:bid];
        self.bidInCatalog = (cur != nil);
        // Inherit the catalogue's category for display when the user hasn't picked one.
        if (cur && !self.pickedCategory.length) {
            self.pickedCategory = cur[@"category"];
            self.pickedSubgenre = cur[@"subgenre"];
        }
    } else {
        self.bidInCatalog = NO;
    }
    if (was != self.bidInCatalog || prevCat != self.pickedCategory) [self.tableView reloadData];
}

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
        [s analyzePickedIPA:path];
        [s.tableView reloadData];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fp];
    [self presentViewController:nav animated:YES completion:nil];
}

// Off-main: verify the .ipa isn't FairPlay-encrypted, and auto-fill name/version/min-iOS/bid + icon.
- (void)analyzePickedIPA:(NSString *)path {
    self.analyzing = YES;
    self.iconB64 = nil;
    AD_WEAK UploadViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        MachOInspectionResult enc = [MachOInspector inspectIPA:path];
        NSDictionary *meta = (enc == MachOInspectionResultEncrypted) ? nil : [IPAPackage metadataForIPA:path];
        NSData *icon       = (enc == MachOInspectionResultEncrypted) ? nil : [IPAPackage iconPNGForIPA:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            UploadViewController *s = weakSelf; if (!s) return;
            if (![s.chosenPath isEqualToString:path]) return;   // user picked another file meanwhile
            s.analyzing = NO;
            if (enc == MachOInspectionResultEncrypted) {
                s.chosenPath = nil; s.chosenSize = 0; s.iconB64 = nil;
                [s alert:T(@"upload.title") msg:T(@"upload.err_encrypted")];
                [s.tableView reloadData];
                return;
            }
            if ([meta[@"name"] length]    && !s.nameField.text.length)    s.nameField.text    = meta[@"name"];
            if ([meta[@"version"] length] && !s.versionField.text.length) s.versionField.text = meta[@"version"];
            if ([meta[@"min_ios"] length] && !s.miniosField.text.length)  s.miniosField.text  = meta[@"min_ios"];
            if ([meta[@"bid"] length]     && !s.bidField.text.length)     s.bidField.text     = meta[@"bid"];
            if (icon.length) s.iconB64 = [s base64:icon];
            [s refreshBidInCatalog];
            [s.tableView reloadData];
        });
    });
}

#pragma mark - Send

- (NSString *)trim:(UITextField *)f { return [(f.text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; }

- (void)sendTapped {
    NSString *name = [self trim:self.nameField];
    NSString *desc = [self textViewText:self.descView];
    if (self.chosenPath.length == 0) { [self alert:T(@"upload.title") msg:T(@"upload.err_nofile")]; return; }
    if (self.analyzing)              { [self alert:T(@"upload.title") msg:T(@"upload.analyzing")]; return; }
    if (name.length == 0)            { [self alert:T(@"upload.title") msg:T(@"upload.err_noname")]; return; }
    // Description: required for Works-Today / Modded; optional for a plain catalogue app.
    if (self.kind != UploadKindCatalog && desc.length == 0) {
        [self alert:T(@"upload.title") msg:T(@"upload.err_nodesc")]; return;
    }
    // Category: required for a catalogue app that ISN'T already in AppDrop (else it's inherited).
    if (self.kind == UploadKindCatalog && !self.bidInCatalog && !self.pickedCategory.length) {
        [self alert:T(@"upload.title") msg:T(@"upload.cat_required")]; return;
    }
    if (!self.attestSwitch.on)       { [self alert:T(@"upload.title") msg:T(@"upload.err_attest")]; return; }
    if (self.chosenSize > kMaxIPABytes) {
        [self alert:T(@"upload.title") msg:[NSString stringWithFormat:T(@"upload.err_toobig"), 45]];
        return;
    }
    // Defensive re-check: never upload an encrypted build, even if the async probe was skipped.
    if ([MachOInspector inspectIPA:self.chosenPath] == MachOInspectionResultEncrypted) {
        [self alert:T(@"upload.title") msg:T(@"upload.err_encrypted")]; return;
    }
    NSString *b64;
    {
        NSData *fileData = [NSData dataWithContentsOfFile:self.chosenPath];
        if (!fileData.length) { [self alert:T(@"upload.title") msg:T(@"upload.err_read")]; return; }
        b64 = [self base64:fileData];
    }
    if (!b64.length) { [self alert:T(@"upload.title") msg:T(@"upload.err_read")]; return; }

    [self.view endEditing:YES];
    self.sendItem.enabled = NO;
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [sp startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:sp];

    NSMutableDictionary *payload = [@{
        @"target":      UploadKindTarget(self.kind),
        @"name":        name,
        @"description": desc,
        @"min_ios":     [self trim:self.miniosField],
        @"appver":      [self trim:self.versionField],
        @"mod":         [self trim:self.modField],
        @"bid":         [self trim:self.bidField],
        @"credit":      [self trim:self.creditField],
        @"ipa":         b64,
        @"attest":      @YES,
        @"decrypted":   @YES,
        @"device":      [DeviceInfo aiSummary] ?: @"",
        @"lang":        [Localization currentLanguageCode] ?: @"en",
    } mutableCopy];
    if (self.kind == UploadKindCatalog) {
        payload[@"category"] = self.pickedCategory ?: @"";
        payload[@"subgenre"] = self.pickedSubgenre ?: @"";
    }
    if (self.iconB64.length) payload[@"icon_png"] = self.iconB64;
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
