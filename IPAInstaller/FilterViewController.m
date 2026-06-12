#import "FilterViewController.h"
#import "Localization.h"
#import "IOS6Theme.h"

static NSArray *iOSChoices(void) {
    return @[@"", @"3.0", @"4.0", @"5.0", @"5.1.1", @"6.0", @"6.1.3", @"7.0", @"7.1", @"8.0", @"9.0", @"10.0"];
}

static NSArray *sortChoices(void) {
    return @[@"downloads", @"recent", @"name", @"size", @"minos"];
}

static NSString *sortLabel(NSString *key) {
    if ([key isEqualToString:@"downloads"]) return T(@"filter.sort.downloads_long");
    if ([key isEqualToString:@"recent"]) return T(@"filter.sort.recent_long");
    if ([key isEqualToString:@"name"]) return T(@"filter.sort.name_long");
    if ([key isEqualToString:@"size"]) return T(@"filter.sort.size_long");
    if ([key isEqualToString:@"minos"]) return T(@"filter.sort.minos_long");
    return key;
}

// On iPad we expose 5 sections including DeviceClass. On iPhone/iPod the device class is
// forced to "iphone" (iPad-only apps don't run), so we hide that section entirely.
typedef NS_ENUM(NSInteger, FilterSection) {
    SectionVersion = 0,
    SectionDeviceClass = 1,   // iPad only
    SectionOptions = 2,
    SectionSort = 3,
    SectionReset = 4,
    SectionCount
};

static BOOL kShowDeviceClass(void) {
    return [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
}

// Compact the section index for non-iPad devices that skip SectionDeviceClass.
static NSInteger kSectionFor(NSInteger displayedIndex) {
    if (kShowDeviceClass()) return displayedIndex;
    // Map displayed index back to real enum: 0=Version, 1=Options, 2=Sort, 3=Reset
    static NSInteger map[] = { SectionVersion, SectionOptions, SectionSort, SectionReset };
    return (displayedIndex >= 0 && displayedIndex < 4) ? map[displayedIndex] : -1;
}

static NSArray *deviceClassChoices(void) {
    return @[@"all", @"iphone", @"ipad"];
}
static NSString *deviceClassLabel(NSString *key) {
    if ([key isEqualToString:@"all"])    return T(@"filter.device.all");
    if ([key isEqualToString:@"iphone"]) return T(@"filter.device.iphone");
    if ([key isEqualToString:@"ipad"])   return T(@"filter.device.ipad");
    return key;
}

@interface FilterViewController () <UIActionSheetDelegate>
@property (nonatomic, strong) UITableView *table;
@end

@implementation FilterViewController

// Filter is presented MODALLY in its OWN navigation controller (not the themed ADNavigationController),
// so its top bar stays stock/light unless we theme it here. Default → stock; dark → dark bar.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [IOS6Theme applyToNavigationBar:self.navigationController.navigationBar];
    self.navigationController.navigationBar.barStyle = [IOS6Theme isDark] ? UIBarStyleBlack : UIBarStyleDefault;
}

// Live theme re-apply (AppDelegate calls this on a theme switch — no restart).
- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme groupedBackgroundColor];
    self.table.backgroundColor = [IOS6Theme groupedBackgroundColor];
    if ([IOS6Theme isDark]) self.table.backgroundView = nil;
    self.table.separatorColor = [IOS6Theme separatorColor];
    [IOS6Theme applyToNavigationBar:self.navigationController.navigationBar];
    self.navigationController.navigationBar.barStyle = [IOS6Theme isDark] ? UIBarStyleBlack : UIBarStyleDefault;
    [self.table reloadData];
}

// Theme every cell: dark fill + light text, with the "Reset" row kept red (brightened on dark).
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ipDisplayed {
    cell.backgroundColor = [IOS6Theme cellColor];
    cell.detailTextLabel.textColor = [IOS6Theme labelGray];
    if (kSectionFor(ipDisplayed.section) == SectionReset) {
        cell.textLabel.textColor = [IOS6Theme isDark]
            ? [UIColor colorWithRed:0.98 green:0.45 blue:0.45 alpha:1.0]
            : [UIColor colorWithRed:0.70 green:0.10 blue:0.10 alpha:1.0];
    } else {
        cell.textLabel.textColor = [IOS6Theme labelDark];
    }
    if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
        UISwitch *sw = (UISwitch *)cell.accessoryView;   // stock green on default, accent on dark
        if ([sw respondsToSelector:@selector(setOnTintColor:)]) sw.onTintColor = [IOS6Theme isDefaultTheme] ? nil : [IOS6Theme accent];
        if ([sw respondsToSelector:@selector(setTintColor:)]) sw.tintColor = [IOS6Theme isDefaultTheme] ? nil : [IOS6Theme separatorColor];   // iOS 6+ (crashes iOS 5)
    }
}

// Section header AND footer: clear the (else black/textured) backdrop + recolour the label.
- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:view];
}
- (void)tableView:(UITableView *)tv willDisplayFooterView:(UIView *)view forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:view];
}

// iOS 5 never calls the willDisplay hooks above → on iOS 5 we supply our own readable header/footer
// views (light label on dark themes). iOS 6+ returns nil/automatic → unchanged system look.
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    if (![IOS6Theme needsManualGroupedHeaderFooter]) return nil;
    return [IOS6Theme manualGroupedHeaderViewForTitle:[self tableView:tv titleForHeaderInSection:s] width:tv.bounds.size.width];
}
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    if (![IOS6Theme needsManualGroupedHeaderFooter]) return UITableViewAutomaticDimension;
    return [IOS6Theme manualGroupedHeaderHeightForTitle:[self tableView:tv titleForHeaderInSection:s]];
}
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    if (![IOS6Theme needsManualGroupedHeaderFooter]) return nil;
    return [IOS6Theme manualGroupedFooterViewForText:[self tableView:tv titleForFooterInSection:s] width:tv.bounds.size.width];
}
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    if (![IOS6Theme needsManualGroupedHeaderFooter]) return UITableViewAutomaticDimension;
    return [IOS6Theme manualGroupedFooterHeightForText:[self tableView:tv titleForFooterInSection:s] width:tv.bounds.size.width];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"filter.title");
    if (!self.filter) self.filter = [CatalogFilter load_];

    // v3.0: titled buttons (T()) instead of UIBarButtonSystemItem — system items follow the DEVICE
    // language, which mismatched the app language (e.g. "Annuler" while the app was in English).
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:T(@"common.cancel")
                                         style:UIBarButtonItemStyleBordered
                                        target:self
                                        action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:T(@"common.done")
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(doneTapped)];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds
                                                style:UITableViewStyleGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = [IOS6Theme groupedBackgroundColor];
    if ([IOS6Theme isDark]) self.table.backgroundView = nil;   // kill the light iOS-6 grouped backdrop
    [self.view addSubview:self.table];
}

- (void)cancelTapped {
    if ([self.delegate respondsToSelector:@selector(filterViewControllerDidCancel:)]) {
        [self.delegate filterViewControllerDidCancel:self];
    }
}

- (void)doneTapped {
    [self.filter save];
    if ([self.delegate respondsToSelector:@selector(filterViewController:didSaveFilter:)]) {
        [self.delegate filterViewController:self didSaveFilter:self.filter];
    }
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return kShowDeviceClass() ? SectionCount : SectionCount - 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)displayed {
    NSInteger s = kSectionFor(displayed);
    if (s == SectionVersion) return 2;
    if (s == SectionDeviceClass) return deviceClassChoices().count;
    if (s == SectionOptions) return 1;  // unique only (hideSuspect removed in v2.0.8)
    if (s == SectionSort) return sortChoices().count;
    if (s == SectionReset) return 1;
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)displayed {
    NSInteger s = kSectionFor(displayed);
    if (s == SectionVersion) return T(@"filter.section.version");
    if (s == SectionDeviceClass) return T(@"filter.section.device");
    if (s == SectionOptions) return T(@"filter.section.options");
    if (s == SectionSort) return T(@"filter.section.sort");
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)displayed {
    NSInteger s = kSectionFor(displayed);
    if (s == SectionVersion) return T(@"filter.footer.version");
    if (s == SectionDeviceClass) return T(@"filter.footer.device");
    if (s == SectionOptions) return T(@"filter.footer.options");
    if (s == SectionSort) return T(@"filter.footer.sort");  // explains tap-again-to-toggle
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ipDisplayed {
    NSInteger sec = kSectionFor(ipDisplayed.section);
    NSIndexPath *ip = [NSIndexPath indexPathForRow:ipDisplayed.row inSection:sec];
    if (ip.section == SectionDeviceClass) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"dc"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                 reuseIdentifier:@"dc"];
        NSString *key = deviceClassChoices()[ip.row];
        cell.textLabel.text = deviceClassLabel(key);
        cell.accessoryType = [key isEqualToString:self.filter.deviceClass]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return cell;
    }
    if (ip.section == SectionVersion) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"ver"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                          reuseIdentifier:@"ver"];
        }
        if (ip.row == 0) {
            cell.textLabel.text = T(@"filter.min_ios_row");
            cell.detailTextLabel.text = self.filter.minIOS.length ? self.filter.minIOS : T(@"filter.none");
        } else {
            cell.textLabel.text = T(@"filter.max_ios_row");
            cell.detailTextLabel.text = self.filter.maxIOS.length ? self.filter.maxIOS : T(@"filter.none");
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (ip.section == SectionOptions) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"optUnique"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"optUnique"];
            UISwitch *sw = [[UISwitch alloc] init];
            sw.tag = 1001;
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            [sw addTarget:self action:@selector(uniqueToggled:)
                 forControlEvents:UIControlEventValueChanged];
        }
        cell.textLabel.text = T(@"filter.unique_switch");
        UISwitch *sw = (UISwitch *)cell.accessoryView;
        sw.on = self.filter.uniqueOnly;
        return cell;
    }
    if (ip.section == SectionSort) {
        // Sort rows: each shows the sort key label. The currently-selected sort has a
        // checkmark accessory plus an arrow (↑ ascending, ↓ descending) appended to its
        // label. Tapping the selected row toggles direction; tapping another row switches
        // sort key (and resets direction to the default for that key).
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"sort"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"sort"];
        }
        NSString *key = sortChoices()[ip.row];
        BOOL isSelected = [key isEqualToString:self.filter.sort];
        NSString *base = sortLabel(key);
        if (isSelected) {
            NSString *arrow = self.filter.sortDescending ? @" ↓" : @" ↑";
            cell.textLabel.text = [base stringByAppendingString:arrow];
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.textLabel.text = base;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        return cell;
    }
    if (ip.section == SectionReset) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"reset"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"reset"];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.textColor = [UIColor colorWithRed:0.7 green:0.1 blue:0.1 alpha:1.0];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
        }
        cell.textLabel.text = T(@"filter.reset");
        return cell;
    }
    return [[UITableViewCell alloc] init];
}

- (void)uniqueToggled:(UISwitch *)sw {
    self.filter.uniqueOnly = sw.on;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ipDisplayed {
    [tv deselectRowAtIndexPath:ipDisplayed animated:YES];
    NSInteger sec = kSectionFor(ipDisplayed.section);
    if (sec == SectionVersion) {
        [self pickIOSForRow:ipDisplayed.row];
        return;
    }
    if (sec == SectionDeviceClass) {
        self.filter.deviceClass = deviceClassChoices()[ipDisplayed.row];
        [self.table reloadSections:[NSIndexSet indexSetWithIndex:ipDisplayed.section]
                  withRowAnimation:UITableViewRowAnimationNone];
    }
    if (sec == SectionSort) {
        NSString *tappedKey = sortChoices()[ipDisplayed.row];
        if ([tappedKey isEqualToString:self.filter.sort]) {
            // Tap on the currently-selected sort row → toggle direction.
            self.filter.sortDescending = !self.filter.sortDescending;
        } else {
            // Tap on a different sort row → switch sort key + reset direction to default.
            self.filter.sort = tappedKey;
            self.filter.sortDescending = [CatalogFilter defaultDescendingForSort:tappedKey];
        }
        [self.table reloadSections:[NSIndexSet indexSetWithIndex:ipDisplayed.section]
                  withRowAnimation:UITableViewRowAnimationNone];
    }
    if (sec == SectionReset) {
        self.filter = [CatalogFilter defaultFilter];
        [self.table reloadData];
    }
}

- (void)pickIOSForRow:(NSInteger)row {
    NSArray *choices = iOSChoices();
    NSString *title = row == 0 ? T(@"filter.min_ios_row") : T(@"filter.max_ios_row");
    UIActionSheet *a = [[UIActionSheet alloc] initWithTitle:title
                                                    delegate:self
                                           cancelButtonTitle:nil
                                      destructiveButtonTitle:nil
                                           otherButtonTitles:nil];
    for (NSString *v in choices) {
        [a addButtonWithTitle:v.length ? v : T(@"filter.choose_none")];
    }
    a.cancelButtonIndex = [a addButtonWithTitle:T(@"common.cancel")];
    a.tag = row + 1; // 1 = min, 2 = max
    [a showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)idx {
    if (idx == sheet.cancelButtonIndex) return;
    NSArray *choices = iOSChoices();
    if (idx >= (NSInteger)choices.count) return;
    NSString *v = choices[idx];
    if (sheet.tag == 1) self.filter.minIOS = v;
    else if (sheet.tag == 2) self.filter.maxIOS = v;
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:SectionVersion]
              withRowAnimation:UITableViewRowAnimationNone];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
