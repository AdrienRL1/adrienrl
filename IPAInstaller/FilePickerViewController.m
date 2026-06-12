#import "FilePickerViewController.h"
#import "IOS6Theme.h"
#import "Localization.h"

@interface FilePickerViewController ()
@property (nonatomic, strong) NSArray *shortcuts;   // absolute dir paths (root mode)
@property (nonatomic, strong) NSArray *dirs;        // subdir names
@property (nonatomic, strong) NSArray *ipas;        // .ipa file names
@end

@implementation FilePickerViewController {
    void (^_onPickBlock)(NSString *);
}

// iOS 3: blocks aren't ObjC objects, so the synthesized copy setter crashes in
// objc_msgSend. Back onPick manually via the C blocks runtime — see
// AppDropBlocks.h (AD_BLOCK_ACCESSORS).
@dynamic onPick;
AD_BLOCK_ACCESSORS(onPick, setOnPick, _onPickBlock, void(^)(NSString *))

- (void)dealloc {
    if (_onPickBlock) _Block_release((const void *)_onPickBlock);
    [super dealloc];
}

- (instancetype)initWithDirectory:(NSString *)dir {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) { _directory = [dir copy]; }
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
    self.view.backgroundColor = [IOS6Theme groupedBackgroundColor];
    if ([IOS6Theme isDark]) self.tableView.backgroundView = nil;

    if (self.directory.length == 0) {
        self.title = T(@"upload.pick_title");
        // Cancel only on the root picker (it's the modal's root).
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:T(@"common.cancel") style:UIBarButtonItemStyleBordered target:self action:@selector(cancel)];
        [self buildShortcuts];
    } else {
        self.title = [self.directory lastPathComponent];
        [self loadDirectory];
    }
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)buildShortcuts {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cand = [NSMutableArray array];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs) [cand addObject:docs];
    [cand addObjectsFromArray:@[ @"/var/mobile/Documents", @"/var/mobile/Downloads",
                                 @"/var/mobile/Media/Downloads", @"/var/mobile", @"/" ]];
    NSMutableArray *exist = [NSMutableArray array];
    BOOL isDir;
    for (NSString *p in cand)
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir && ![exist containsObject:p])
            [exist addObject:p];
    self.shortcuts = exist;
}

- (void)loadDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:self.directory error:NULL] ?: @[];
    NSMutableArray *d = [NSMutableArray array], *f = [NSMutableArray array];
    for (NSString *n in names) {
        if ([n hasPrefix:@"."]) continue;
        BOOL isDir = NO;
        [fm fileExistsAtPath:[self.directory stringByAppendingPathComponent:n] isDirectory:&isDir];
        if (isDir) [d addObject:n];
        else if ([[n pathExtension] caseInsensitiveCompare:@"ipa"] == NSOrderedSame) [f addObject:n];
    }
    SEL cmp = @selector(localizedCaseInsensitiveCompare:);
    self.dirs = [d sortedArrayUsingSelector:cmp];
    self.ipas = [f sortedArrayUsingSelector:cmp];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.directory.length ? 2 : 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (self.directory.length == 0) return (NSInteger)self.shortcuts.count;
    return s == 0 ? (NSInteger)self.dirs.count : (NSInteger)self.ipas.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (self.directory.length == 0) return T(@"upload.pick_shortcuts");
    if (s == 0) return self.dirs.count ? T(@"upload.pick_folders") : nil;
    return self.ipas.count ? T(@"upload.pick_files") : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (self.directory.length && self.dirs.count == 0 && self.ipas.count == 0 && s == 1)
        return T(@"upload.pick_empty");
    return nil;
}

- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)v forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:v];
}
- (void)tableView:(UITableView *)tv willDisplayFooterView:(UIView *)v forSection:(NSInteger)s {
    [IOS6Theme styleGroupedHeaderFooter:v];
}

// iOS 5/6 grouped tables drop a cell.backgroundColor set in cellForRow:, so dark-mode cells
// stayed white with unreadable (light) text. Re-apply the themed colour here (where it sticks).
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    cell.backgroundColor = [IOS6Theme cellColor];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"fp"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"fp"];
    c.backgroundColor = [IOS6Theme cellColor];
    c.textLabel.textColor = [IOS6Theme labelDark];
    c.textLabel.font = [UIFont systemFontOfSize:15];
    BOOL isFolderRow;
    NSString *label;
    if (self.directory.length == 0) { label = [self.shortcuts[ip.row] isEqual:@"/"] ? @"/" : self.shortcuts[ip.row]; isFolderRow = YES; }
    else if (ip.section == 0) { label = self.dirs[ip.row]; isFolderRow = YES; }
    else { label = self.ipas[ip.row]; isFolderRow = NO; }
    c.textLabel.text = [NSString stringWithFormat:@"%@ %@", isFolderRow ? @"📁" : @"📦", label];
    c.accessoryType = isFolderRow ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleBlue;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *next = nil; BOOL isFolderRow = YES; NSString *chosenFile = nil;
    if (self.directory.length == 0) {
        next = self.shortcuts[ip.row];
    } else if (ip.section == 0) {
        next = [self.directory stringByAppendingPathComponent:self.dirs[ip.row]];
    } else {
        isFolderRow = NO;
        chosenFile = [self.directory stringByAppendingPathComponent:self.ipas[ip.row]];
    }
    if (isFolderRow) {
        FilePickerViewController *child = [[FilePickerViewController alloc] initWithDirectory:next];
        child.onPick = self.onPick;   // forward the callback down the stack
        [self.navigationController pushViewController:child animated:YES];
    } else if (chosenFile) {
        void (^cb)(NSString *) = self.onPick;
        [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(chosenFile); }];
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
