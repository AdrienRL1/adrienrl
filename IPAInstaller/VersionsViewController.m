#import "VersionsViewController.h"
#import "InstallManager.h"
#import "AppDetailViewController.h"
#import "IOS6Theme.h"
#import "LocalCatalog.h"
#import "Localization.h"

@interface VersionsViewController ()
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *appTitle;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSArray *versions;
@end

@implementation VersionsViewController

- (instancetype)initWithBundleId:(NSString *)bundleId title:(NSString *)title {
    if ((self = [super init])) {
        _bundleId = [bundleId copy];
        _appTitle = [title copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.appTitle ?: T(@"app.versions");
    self.view.backgroundColor = [IOS6Theme linenColor];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                   style:UITableViewStyleGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.rowHeight = 80;
    self.tableView.backgroundColor = [IOS6Theme linenColor];
    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 30)];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [UIColor grayColor];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.tableView.tableFooterView = self.statusLabel;

    [self loadVersions];
}

- (void)loadVersions {
    [self.spinner startAnimating];
    self.statusLabel.text = T(@"catalog.loading_more");

    if ([[InstallManager shared] autonomousMode]) {
        if (![[LocalCatalog shared] isReady]) {
            [[LocalCatalog shared] loadWithProgress:^(NSString *s){ self.statusLabel.text = s; }
                                          completion:^(BOOL ok, NSError *e) {
                if (!ok) {
                    [self.spinner stopAnimating];
                    self.statusLabel.text = [@"Echec : " stringByAppendingString:e.localizedDescription ?: @""];
                    return;
                }
                [self queryLocalVersions];
            }];
        } else {
            [self queryLocalVersions];
        }
        return;
    }

    NSString *backend = [[InstallManager shared] backendURL];
    NSString *bid = [self.bundleId stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"";
    NSString *url = [NSString stringWithFormat:@"%@/catalog/versions?bundle_id=%@", backend, bid];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:20];
    [NSURLConnection sendAsynchronousRequest:req
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
        [self.spinner stopAnimating];
        if (e || !d) {
            self.statusLabel.text = [NSString stringWithFormat:@"Erreur : %@",
                                       e.localizedDescription ?: @""];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (!json) { self.statusLabel.text = T(@"versions.invalid_response"); return; }
        self.versions = json[@"results"] ?: @[];
        self.statusLabel.text = [NSString stringWithFormat:@"%lu version%@",
                                  (unsigned long)self.versions.count,
                                  self.versions.count > 1 ? @"s" : @""];
        [self.tableView reloadData];
    }];
}

- (void)queryLocalVersions {
    NSArray *vs = [[LocalCatalog shared] versionsForBundleId:self.bundleId];
    [self.spinner stopAnimating];
    self.versions = vs;
    self.statusLabel.text = [NSString stringWithFormat:@"%lu version%@ (local)",
                              (unsigned long)vs.count, vs.count > 1 ? @"s" : @""];
    [self.tableView reloadData];
}

- (NSString *)humanSize:(long long)b {
    if (b < 1024) return [NSString stringWithFormat:@"%lld o", b];
    if (b < 1024*1024) return [NSString stringWithFormat:@"%.0f Ko", b/1024.0];
    if (b < 1024LL*1024*1024) return [NSString stringWithFormat:@"%.1f Mo", b/(1024.0*1024)];
    return [NSString stringWithFormat:@"%.2f Go", b/(1024.0*1024*1024)];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.versions.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return [NSString stringWithFormat:@"%lu version%@ disponible%@",
              (unsigned long)self.versions.count,
              self.versions.count > 1 ? @"s" : @"",
              self.versions.count > 1 ? @"s" : @""];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return T(@"versions.footer");
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"verCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cid];
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    NSDictionary *v = self.versions[ip.row];
    long long size = [v[@"size"] longLongValue];
    NSString *sizeStr = size > 0 ? [self humanSize:size] : @"taille inconnue";
    // Mark versions this device can't run (min iOS higher than the device's iOS).
    BOOL compatible = [[LocalCatalog shared] deviceCanRunMinIOS:v[@"minOS"]];
    cell.textLabel.text = [NSString stringWithFormat:@"v%@ — %@", v[@"version"] ?: @"?", sizeStr];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
    cell.textLabel.textColor = compatible ? [UIColor blackColor] : [UIColor grayColor];

    NSString *url = v[@"url"] ?: @"";
    NSURL *u = [NSURL URLWithString:url];
    NSString *host = u.host ?: @"?";
    NSString *fileName = v[@"fileName"] ?: @"";
    NSString *tag = compatible ? @"" : [T(@"versions.incompatible") stringByAppendingString:@"  "];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@min iOS %@ • %@\n%@",
                                  tag, v[@"minOS"] ?: @"?", host, fileName];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
    cell.detailTextLabel.textColor = compatible
        ? [UIColor darkGrayColor]
        : [UIColor colorWithRed:0.62 green:0.11 blue:0.10 alpha:1.0];   // red = won't run
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *v = self.versions[ip.row];
    // Keep the EXACT version the user picked here (don't auto-switch to a compatible one).
    AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:v allowVersionSwitch:NO];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
