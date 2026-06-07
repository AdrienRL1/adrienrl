#import "CategorySuggestViewController.h"
#import "LocalCatalog.h"
#import "Localization.h"
#import "IOS6Theme.h"
#import "HTTPSClient.h"
#import "DeviceInfo.h"

static NSString *const kCategoryURL = @"https://appdrop-feedback.adrienruestlorquet.workers.dev/category";

// Localized category / subgenre names (mirrors the file-static helpers in CategoryViewController.m).
static NSString *csLocName(NSString *prefix, NSString *value) {
    if (!value.length) return @"";
    NSString *k = [prefix stringByAppendingString:value];
    NSString *v = T(k);
    return [v isEqualToString:k] ? value : v;
}
static NSString *csLocCat(NSString *c) { return csLocName(@"cat.", c); }
static NSString *csLocSub(NSString *s) { return csLocName(@"sub.", s); }

@interface CategorySuggestViewController ()
@property (nonatomic, copy)   NSString *bid;
@property (nonatomic, copy)   NSString *appName;
@property (nonatomic, copy)   NSString *currentCategory;
@property (nonatomic, copy)   NSString *currentSubgenre;
@property (nonatomic, strong) NSArray  *categories;        // category names
@property (nonatomic, strong) NSArray  *subgenres;         // subgenre names for selectedCategory
@property (nonatomic, copy)   NSString *selectedCategory;
@property (nonatomic, copy)   NSString *selectedSubgenre;  // nil = not chosen, @"" = General
@property (nonatomic, assign) BOOL sending;
@end

@implementation CategorySuggestViewController {
    // iOS 3: blocks aren't ObjC objects, so a synthesized @property(copy) block
    // setter calls objc_setProperty(copy=YES) → -copyWithZone: on the block →
    // Bus error (signal 10). Back the block manually via the C blocks runtime —
    // see AppDropBlocks.h (AD_BLOCK_ACCESSORS).
    void (^_onPickBlock)(NSString *category, NSString *subgenre);
}
@dynamic onPick;
AD_BLOCK_ACCESSORS(onPick, setOnPick, _onPickBlock, void(^)(NSString *category, NSString *subgenre))

- (void)dealloc {
    if (_onPickBlock) _Block_release((const void *)_onPickBlock);
    [super dealloc];
}

- (instancetype)initWithBundleId:(NSString *)bid name:(NSString *)name {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _bid = [bid copy];
        _appName = [name copy];
    }
    return self;
}

- (instancetype)initForPickingCategory:(NSString *)cat subgenre:(NSString *)sub {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _bid = @"";                       // no bid → pick mode (viewDidLoad skips the catalogue lookup)
        _currentCategory = [cat copy];     // preselect the caller's prior choice
        _currentSubgenre = [sub copy];
    }
    return self;
}

- (BOOL)isPickMode { return self.onPick != nil; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self isPickMode] ? T(@"upload.cat_pick_title") : T(@"suggestcat.title");
    UIColor *bg = [IOS6Theme contentBackgroundColor] ?: [UIColor whiteColor];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
    if ([IOS6Theme isDark]) self.tableView.backgroundView = nil;   // kill the light iOS-6 grouped backdrop in dark mode
    self.tableView.separatorColor = [IOS6Theme separatorColor];

    // Categories list (names only, sorted by count desc — same source as the home grid).
    NSMutableArray *cats = [NSMutableArray array];
    for (NSDictionary *d in [[LocalCatalog shared] categoryCounts]) {
        NSString *c = d[@"category"];
        if ([c isKindOfClass:[NSString class]] && c.length) [cats addObject:c];
    }
    self.categories = cats;

    // Current category/subgenre → preselect so the user corrects from a known state. In pick mode
    // there's no bid; initForPicking already seeded currentCategory/currentSubgenre.
    if (self.bid.length) {
        NSDictionary *cur = [[LocalCatalog shared] categorySubgenreForBundleId:self.bid];
        self.currentCategory = cur[@"category"];
        self.currentSubgenre = cur[@"subgenre"];
    }
    if (self.currentCategory.length) {
        self.selectedCategory = self.currentCategory;
        [self loadSubgenresForCategory:self.currentCategory];
        self.selectedSubgenre = self.currentSubgenre;   // may be @""
    }

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:([self isPickMode] ? T(@"common.ok") : T(@"suggestcat.submit"))
                style:UIBarButtonItemStyleDone target:self action:@selector(submit)];

    if ([self isPickMode]) return;   // pick mode: no "app name + current category" header

    // Header: app name + current category.
    UILabel *hdr = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 54)];
    hdr.numberOfLines = 2;
    hdr.textAlignment = NSTextAlignmentCenter;
    hdr.backgroundColor = [UIColor clearColor];
    hdr.font = [UIFont systemFontOfSize:13];
    hdr.textColor = [IOS6Theme labelGray];
    NSString *curTxt = self.currentCategory.length
        ? [NSString stringWithFormat:T(@"suggestcat.current"),
            (self.currentSubgenre.length
                ? [NSString stringWithFormat:@"%@ › %@", csLocCat(self.currentCategory), csLocSub(self.currentSubgenre)]
                : csLocCat(self.currentCategory))]
        : @"";
    hdr.text = [NSString stringWithFormat:@"%@\n%@", self.appName ?: @"", curTxt];
    self.tableView.tableHeaderView = hdr;
}

- (void)loadSubgenresForCategory:(NSString *)cat {
    NSMutableArray *subs = [NSMutableArray array];
    for (NSDictionary *d in [[LocalCatalog shared] subgenreCountsForCategory:cat]) {
        NSString *s = d[@"subgenre"];
        if ([s isKindOfClass:[NSString class]] && s.length) [subs addObject:s];
    }
    self.subgenres = subs;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    // The "section" (subgenre) list only appears for categories that HAVE subgenres — in the
    // catalogue that's only "Games" — and there picking one is mandatory (#156 refinement).
    return (self.selectedCategory.length && self.subgenres.count > 0) ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? T(@"suggestcat.pick_category") : T(@"suggestcat.pick_subgenre");
}
- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)v forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:v];
}
// iOS 5 has no willDisplayHeaderView: hook, so the default grouped header keeps a light-mode emboss
// that's unreadable in dark mode ("Choisir une catégorie"). Supply a themed header on iOS 5; iOS 6+
// returns nil/auto so the willDisplayHeaderView: path above is used unchanged. (#170b)
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    if (![IOS6Theme needsManualGroupedHeaderFooter]) return nil;
    return [IOS6Theme manualGroupedHeaderViewForTitle:[self tableView:tv titleForHeaderInSection:s]
                                                width:tv.bounds.size.width];
}
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    if (![IOS6Theme needsManualGroupedHeaderFooter]) return UITableViewAutomaticDimension;
    return [IOS6Theme manualGroupedHeaderHeightForTitle:[self tableView:tv titleForHeaderInSection:s]];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return (NSInteger)self.categories.count;
    return (NSInteger)self.subgenres.count;   // section only exists when there ARE subgenres (Games)
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
    cell.backgroundColor = [IOS6Theme cellColor];
    cell.textLabel.textColor = [IOS6Theme labelDark];
    BOOL chosen = NO;
    if (ip.section == 0) {
        NSString *c = self.categories[ip.row];
        cell.textLabel.text = csLocCat(c);
        chosen = [c isEqualToString:self.selectedCategory];
    } else {
        NSString *s = self.subgenres[ip.row];
        cell.textLabel.text = csLocSub(s);
        chosen = [s isEqualToString:self.selectedSubgenre];
    }
    cell.accessoryType = chosen ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

// iOS 5/6 grouped tables override a cell.backgroundColor set in cellForRow: with the default
// light backdrop, leaving dark-mode cells WHITE with unreadable (light) text. Re-apply the
// themed colour here — the same fix SettingsViewController uses. (The earlier #157 fix only
// removed the table's backdrop, not the per-cell white background.)
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    cell.backgroundColor = [IOS6Theme cellColor];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        NSString *c = self.categories[ip.row];
        if ([c isEqualToString:self.selectedCategory]) return;
        self.selectedCategory = c;
        [self loadSubgenresForCategory:c];
        // Categories without subgenres send an empty section; "Games" requires a real pick.
        self.selectedSubgenre = (self.subgenres.count > 0) ? nil : @"";
        [tv reloadData];
    } else {
        self.selectedSubgenre = self.subgenres[ip.row];
        [tv reloadData];
    }
}

#pragma mark - Submit

- (void)submit {
    if (self.sending) return;
    if (!self.selectedCategory.length) {
        [[[UIAlertView alloc] initWithTitle:T(@"suggestcat.title")
                                    message:T(@"suggestcat.pick_category")
                                   delegate:nil cancelButtonTitle:T(@"common.ok")
                          otherButtonTitles:nil] show];
        return;
    }
    // "Games" (the only category with subgenres) requires a section to be chosen.
    if (self.subgenres.count > 0 && !self.selectedSubgenre.length) {
        [[[UIAlertView alloc] initWithTitle:T(@"suggestcat.title")
                                    message:T(@"suggestcat.subgenre_required")
                                   delegate:nil cancelButtonTitle:T(@"common.ok")
                          otherButtonTitles:nil] show];
        return;
    }
    // Pick mode: hand the choice back to the caller instead of POSTing a suggestion.
    if ([self isPickMode]) {
        if (self.onPick) self.onPick(self.selectedCategory ?: @"", self.selectedSubgenre ?: @"");
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    self.sending = YES;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    NSDictionary *payload = @{
        @"bid":              self.bid ?: @"",
        @"name":             self.appName ?: @"",
        @"current_category": self.currentCategory ?: @"",
        @"current_subgenre": self.currentSubgenre ?: @"",
        @"category":         self.selectedCategory ?: @"",
        @"subgenre":         self.selectedSubgenre ?: @"",
        @"device":           [DeviceInfo aiSummary] ?: @"",
        @"lang":             [Localization currentLanguageCode] ?: @"en",
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    [HTTPSClient postURL:kCategoryURL
                headers:@{@"Content-Type": @"application/json"}
                   body:body
                timeout:60
             completion:^(NSData *resp, NSInteger code, NSError *err) {
        self.sending = NO;
        self.navigationItem.rightBarButtonItem.enabled = YES;
        if (!err && code >= 200 && code < 300) {
            [[[UIAlertView alloc] initWithTitle:T(@"suggestcat.title")
                                        message:T(@"suggestcat.thanks")
                                       delegate:nil cancelButtonTitle:T(@"common.ok")
                              otherButtonTitles:nil] show];
            [self.navigationController popViewControllerAnimated:YES];
        } else {
            [[[UIAlertView alloc] initWithTitle:T(@"suggestcat.title")
                                        message:[NSString stringWithFormat:T(@"versions.load_failed"),
                                                   err.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)code]]
                                       delegate:nil cancelButtonTitle:T(@"common.ok")
                              otherButtonTitles:nil] show];
        }
    }];
}

@end
