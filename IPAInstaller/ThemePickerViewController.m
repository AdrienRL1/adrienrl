#import "ThemePickerViewController.h"
#import "Localization.h"

// A rounded colour swatch shown at the leading edge of each row.
static UIImage *ADThemeSwatch(UIColor *color) {
    CGFloat s = 29.0;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 0.0);
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, s-1, s-1) cornerRadius:6.0];
    [color setFill];
    [p fill];
    [[UIColor colorWithWhite:0 alpha:0.20] setStroke];
    p.lineWidth = 1.0;
    [p stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

@implementation ThemePickerViewController

- (instancetype)init {
    return [self initWithStyle:UITableViewStyleGrouped];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    self = [super initWithStyle:UITableViewStyleGrouped];   // always grouped, whatever was passed
    if (self) self.title = T(@"settings.theme");
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self applyTheme];
}

// <ADThemable> — re-tint live when the theme changes (also covers our own nav bar via AppDelegate).
- (void)applyTheme {
    self.tableView.backgroundColor = [IOS6Theme groupedBackgroundColor];
    if ([IOS6Theme isDark]) self.tableView.backgroundView = nil;   // kill the light grouped backdrop
    self.tableView.separatorColor = [IOS6Theme separatorColor];
    [self.tableView reloadData];
}

#pragma mark - Table

// Section 0 = "Clair" (the single light Défaut theme); section 1 = "Mode sombre" (the dark variants).
- (NSArray *)themesForSection:(NSInteger)s {
    NSMutableArray *m = [NSMutableArray array];
    for (NSDictionary *t in [IOS6Theme availableThemes]) {
        BOOL dark = [t[@"dark"] boolValue];
        if ((s == 0 && !dark) || (s == 1 && dark)) [m addObject:t];
    }
    return m;
}

- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:view];
}
- (void)tableView:(UITableView *)tv willDisplayFooterView:(UIView *)view forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:view];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)[[self themesForSection:s] count];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? T(@"theme.section_light") : T(@"theme.section_dark");
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == 1 ? T(@"theme.footer") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"themeRow";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];

    NSArray *themes = [self themesForSection:ip.section];
    if (ip.row >= (NSInteger)themes.count) return cell;
    NSDictionary *t = themes[ip.row];

    cell.textLabel.text = T(t[@"nameKey"]);
    cell.textLabel.textColor = [IOS6Theme labelDark];
    cell.imageView.image = ADThemeSwatch(t[@"color"]);
    cell.backgroundColor = [IOS6Theme cellColor];

    BOOL active = [[IOS6Theme currentThemeID] isEqualToString:t[@"id"]];
    cell.accessoryType = active ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *themes = [self themesForSection:ip.section];
    if (ip.row >= (NSInteger)themes.count) return;
    NSDictionary *t = themes[ip.row];
    // Posts AppDropThemeChangedNotification → AppDelegate re-themes the whole live app instantly.
    [IOS6Theme setThemeID:t[@"id"]];
    [tv reloadData];   // refresh the checkmark immediately
}

@end
