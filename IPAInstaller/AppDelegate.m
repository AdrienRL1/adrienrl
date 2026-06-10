#import "AppDelegate.h"
#import "RootViewController.h"
#import "IOS6Theme.h"
#import "InstallManager.h"
#import "CatalogViewController.h"
#import "CategoryViewController.h"
#import "SearchViewController.h"
#import "CollectionViewController.h"
#import "CollectionStore.h"
#import "SettingsViewController.h"
#import "Localization.h"
#import "UpdateChecker.h"
#import "LocalCatalog.h"
#import "CheckpointLog.h"
#import "CrashReporter.h"
#import "IconLoader.h"

// v1.7: a "house" glyph for the Accueil (home) tab. Returns an alpha mask that iOS
// tints exactly like the other tab icons — no PNG to bundle, crisp at any scale.
static UIImage *AppDropHomeTabIcon(void) {
    // Memoized: the glyph is geometry-only (fixed coords + constant screen scale), so it's
    // pixel-identical every call. Draw it once per process to avoid re-rasterizing on every launch.
    static UIImage *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize s = CGSizeMake(30, 30);
        UIGraphicsBeginImageContextWithOptions(s, NO, [UIScreen mainScreen].scale);
        CGContextRef c = UIGraphicsGetCurrentContext();
        [[UIColor blackColor] setFill];
        UIBezierPath *roof = [UIBezierPath bezierPath];   // wide-eave roof
        [roof moveToPoint:CGPointMake(15, 4)];
        [roof addLineToPoint:CGPointMake(27, 15.5)];
        [roof addLineToPoint:CGPointMake(3, 15.5)];
        [roof closePath];
        [roof fill];
        [[UIBezierPath bezierPathWithRect:CGRectMake(6.5, 14, 17, 12)] fill];   // body
        CGContextClearRect(c, CGRectMake(12, 19, 6, 7));                         // door cutout
        cached = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return cached;
}

// v3.0: a filled 5-point STAR glyph for the Favoris tab (which replaces the removed AI tab). Same
// alpha-mask technique as the home glyph, so the tab bar tints it correctly in light AND dark themes.
static UIImage *AppDropFavoritesTabIcon(void) {
    // Memoized: geometry-only glyph (fixed coords + constant screen scale) → pixel-identical
    // every call. Draw it once per process instead of re-rasterizing on every launch.
    static UIImage *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize s = CGSizeMake(30, 30);
        UIGraphicsBeginImageContextWithOptions(s, NO, [UIScreen mainScreen].scale);
        [[UIColor blackColor] setFill];
        UIBezierPath *star = [UIBezierPath bezierPath];
        CGFloat cx = 15, cy = 15.5, R = 13.0, r = 5.4;
        for (int i = 0; i < 10; i++) {
            CGFloat ang = -M_PI_2 + i * (M_PI / 5.0);
            CGFloat rad = (i % 2 == 0) ? R : r;
            CGPoint p = CGPointMake(cx + rad * cosf(ang), cy + rad * sinf(ang));
            if (i == 0) [star moveToPoint:p]; else [star addLineToPoint:p];
        }
        [star closePath];
        [star fill];
        cached = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return cached;
}

// iOS 5 does NOT forward rotation from a UINavigationController to its visible view
// controller (iOS 6+ does). Since every tab is nav-wrapped, that left the whole app
// portrait-locked on iPad iOS 5.1.1 (feedback #13: "goes crazy"/"won't rotate"). This
// subclass forwards every rotation query to the top view controller, so the app rotates
// based on what's actually on screen — and it's a no-op relative to the default on iOS 6+.
@interface ADNavigationController : UINavigationController
- (void)applyADTheme;
@end
@implementation ADNavigationController
- (void)viewDidLoad {
    [super viewDidLoad];
    [self applyADTheme];
}
// Nav-bar styling. For the DEFAULT theme this leaves the bar STOCK (exactly the published v2.0
// look — the custom PNG never showed through iOS 6's unreliable appearance proxy). For a dark
// theme it applies a code-drawn dark gradient + white title directly on the instance (the proxy
// has no visible effect on iOS 6, so per-instance styling is the only thing that works).
// Factored out so the central applier can re-run it live on every tab's nav bar — no restart.
- (void)applyADTheme {
    [IOS6Theme applyToNavigationBar:self.navigationBar];
    // Default = stock light bar (UIBarStyleDefault). Both the DARK family AND the light-COLOUR
    // family carry a custom vivid/dark bar image whose text + status bar must be light → BarStyleBlack.
    self.navigationBar.barStyle = [IOS6Theme isDefaultTheme] ? UIBarStyleDefault : UIBarStyleBlack;
}
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o {   // iOS 5
    UIViewController *top = self.topViewController;
    return top ? [top shouldAutorotateToInterfaceOrientation:o] : YES;
}
- (NSUInteger)supportedInterfaceOrientations {                               // iOS 6+
    UIViewController *top = self.topViewController;
    return top ? [top supportedInterfaceOrientations] : UIInterfaceOrientationMaskAll;
}
- (BOOL)shouldAutorotate {                                                   // iOS 6+
    UIViewController *top = self.topViewController;
    return top ? [top shouldAutorotate] : YES;
}
@end

// v1.3.1: alert delegate so the AppDelegate can react to the Filza-launch
// confirmation. The dismissed-path is stored on the alert itself (via tag
// + an associated property) so we can fire filza://view/<path> at the right
// time without re-deriving anything from the notification userInfo.
@interface AppDelegate () <UIAlertViewDelegate>
@property (nonatomic, copy) NSString *pendingFilzaPath;
// Tab bar + the full set of 5 tab nav controllers (built once at launch). The AI/chat tab can
// be hidden live via Settings, so we keep all 5 alive and just toggle which ones are shown.
@property (nonatomic, strong) UITabBarController *tabBarVC;
@property (nonatomic, strong) NSArray *allTabNavs;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // v1.5 — checkpoint log so we can diagnose iOS 5 launch crashes after the
    // fact via SSH (file at /var/mobile/Documents/appdrop-launch.log).
    CPLogReset();
    CPLog([NSString stringWithFormat:@"iOS %@ device=%@",
              [[UIDevice currentDevice] systemVersion],
              [[UIDevice currentDevice] model]]);

    @try {
        CPLog(@"setupAppearance");
        [self setupAppearance];

        CPLog(@"window alloc");
        self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        self.window.backgroundColor = [IOS6Theme contentBackgroundColor];

        // Build the 4 tabs: Catalogue (default), IA, Installer, Réglages.
        // Each tab has its own UINavigationController stack so push/pop works inside.
        CPLog(@"alloc CatalogVC");
        // v1.7: the Catalogue tab opens on the category menu (with a "All apps" row
        // at the top that pushes the full filtered list — the classic CatalogViewController).
        CategoryViewController *catalog = [[CategoryViewController alloc] init];
        UINavigationController *catalogNav = [[ADNavigationController alloc] initWithRootViewController:catalog];
        catalogNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:T(@"tab.home")
                                                                image:AppDropHomeTabIcon()
                                                                  tag:0];

        CPLog(@"alloc SearchVC");
        SearchViewController *search = [[SearchViewController alloc] init];
        UINavigationController *searchNav = [[ADNavigationController alloc] initWithRootViewController:search];
        searchNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:T(@"tab.search")
                                                              image:[UIImage imageNamed:@"tab-search"]
                                                                tag:1];

        CPLog(@"alloc FavVC");
        // v3.0: Favoris tab (replaces the removed AI tab) — opens the built-in Favorites collection.
        CollectionViewController *fav = [[CollectionViewController alloc] initWithCollectionId:CollectionFavoritesId];
        UINavigationController *favNav = [[ADNavigationController alloc] initWithRootViewController:fav];
        favNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:T(@"collections.favorites")
                                                          image:AppDropFavoritesTabIcon()
                                                            tag:2];

        CPLog(@"alloc RootVC");
        RootViewController *install = [[RootViewController alloc] init];  // legacy URL/jobs screen
        UINavigationController *installNav = [[ADNavigationController alloc] initWithRootViewController:install];
        installNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:T(@"tab.install")
                                                              image:[UIImage imageNamed:@"tab-install"]
                                                                tag:3];

        CPLog(@"alloc SettingsVC");
        SettingsViewController *settings = [[SettingsViewController alloc] init];
        UINavigationController *settingsNav = [[ADNavigationController alloc] initWithRootViewController:settings];
        settingsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:T(@"tab.settings")
                                                               image:[UIImage imageNamed:@"tab-settings"]
                                                                 tag:4];

        CPLog(@"alloc TabBarController");
        UITabBarController *tabs = [[UITabBarController alloc] init];
        self.tabBarVC = tabs;
        self.allTabNavs = @[catalogNav, searchNav, favNav, installNav, settingsNav];
        tabs.viewControllers = self.allTabNavs;
        // Tab-bar theming: STOCK for the default theme (= v2.0), code-drawn dark gradient for dark
        // themes. Done directly on the instance (the UIAppearance proxy is unreliable on iOS 6).
        [IOS6Theme applyToTabBar:tabs.tabBar];
        tabs.selectedIndex = 0;  // Catalogue first (it's the main feature)
        self.window.rootViewController = tabs;
        CPLog(@"makeKeyAndVisible");
        [self.window makeKeyAndVisible];
    } @catch (NSException *e) {
        CPLog([NSString stringWithFormat:@"EXCEPTION in setup: %@ — %@", e.name, e.reason]);
        // Show a minimal error UI instead of crashing silently.
        self.window = self.window ?: [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        self.window.backgroundColor = [UIColor whiteColor];
        UIViewController *errVC = [[UIViewController alloc] init];
        errVC.view.backgroundColor = [UIColor whiteColor];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectInset(errVC.view.bounds, 20, 80)];
        l.numberOfLines = 0;
        l.font = [UIFont systemFontOfSize:13];
        l.text = [NSString stringWithFormat:@"AppDrop failed to launch.\n\n%@ — %@\n\nSee /tmp/appdrop-launch.log for details.",
                  e.name, e.reason];
        [errVC.view addSubview:l];
        self.window.rootViewController = errVC;
        [self.window makeKeyAndVisible];
        return YES;
    }

    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (launchURL) {
        [self application:application openURL:launchURL sourceApplication:nil annotation:nil];
    }

    // v1.2.1.1: red "1" badge on the Settings tab when an update is available.
    // We observe UpdateChecker so it auto-updates as the status changes
    // (e.g., user opens Settings → fresh check fires → badge flips on).
    // Cache TTL inside UpdateChecker is 1 h so the launch check is cheap
    // even if the user re-launches the app frequently.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(refreshSettingsTabBadge)
                                                  name:UpdateCheckerStatusChangedNotification
                                                object:nil];
    [self refreshSettingsTabBadge];  // initial state (probably no badge yet)
    // Defer the launch update-check off the critical path: on a slow A4 the first content build
    // (Accueil grid) should own the CPU/network for the first couple of seconds, not a version ping.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [[UpdateChecker shared] checkForUpdates:NO]; });

    // v1.3.1: pop an "Open in Filza?" prompt whenever InstallManager archives
    // a .ipa. Fires for iOS 10+ (always) and iOS 6-9 when "Keep IPA after
    // install" is on. The alert is global (UIAlertView is window-level) so it
    // appears regardless of which tab the user is on.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(installManagerSaved:)
                                                  name:InstallManagerJobSavedNotification
                                                object:nil];

    // Apply a theme change instantly across the whole app (no restart). Posted by IOS6Theme
    // when the user picks a colour in Settings → Thème.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(applyThemeEverywhere)
                                                  name:AppDropThemeChangedNotification
                                                object:nil];
    if (![IOS6Theme isDefaultTheme]) [self applyStatusBarStyle];   // dark + light-colour bars need a light status bar; default keeps stock

    // Catalog-quality reminder: some catalog rows have a wrong title/icon (a data issue in the
    // public source, out of our control), so the user should double-check before installing.
    // Shown at every cold launch UNLESS the user tapped "Don't show again" on the alert itself
    // (no Settings toggle — the opt-out lives on the notice). Deferred ~0.6 s so the tab bar /
    // catalog paints first, then the alert pops over it.
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"AppDropHideCatalogNotice"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // Re-check inside the block in case the flag changed in the meantime.
            if ([[NSUserDefaults standardUserDefaults] boolForKey:@"AppDropHideCatalogNotice"]) return;
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"onboarding.catalog_quality_title")
                                                        message:T(@"onboarding.catalog_quality_msg")
                                                       delegate:self
                                              cancelButtonTitle:T(@"common.understood")
                                              otherButtonTitles:T(@"onboarding.dont_show_again"), nil];
            a.tag = 9911;
            [a show];
        });
    }

    // If AppDrop crashed during the previous session, offer (one prompt per crash) to send
    // the on-device crash log via the anonymous feedback channel. This is how we get real
    // backtraces for crashes on iOS versions / devices we can't reproduce (e.g. the iPhone 4S
    // iOS 9.3.6 rotation crash). Deferred well past launch so it never competes with the first
    // content build, and so it queues AFTER the catalog-quality notice rather than racing it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [CrashReporter checkAndOfferReport]; });

    return YES;
}

// App-wide memory-warning hook. On the low-RAM A4 devices (iPad 1 / iPhone 4, 256 MB) the OS
// fires this under pressure; drop the two largest discardable caches so we're less likely to be
// jetsammed. Both caches regenerate identically on next access, so this is purely a reclaim —
// no reloadData (the visible UI keeps its current images and refetches lazily as needed).
- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    [[IconLoader shared] clearCache];
    [IOS6Theme purgeImageCache];
}

// 0xdead10cc fix: close the catalog SQLite handle before iOS suspends us, so the app is never
// suspended while holding the catalog file open (the #1 auto-crash on iOS 5/6/7). Reopened on
// foreground from the cached file (no re-download).
- (void)applicationDidEnterBackground:(UIApplication *)application {
    __block UIBackgroundTaskIdentifier bg = [application beginBackgroundTaskWithExpirationHandler:^{
        if (bg != UIBackgroundTaskInvalid) { [application endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
    }];
    [[LocalCatalog shared] closeForBackgroundCompletion:^{
        if (bg != UIBackgroundTaskInvalid) { [application endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
    }];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [[LocalCatalog shared] loadWithProgress:nil completion:nil];
}

// URL scheme handler. The ipainstall:// scheme is registered in Info.plist for future
// deep linking but currently has no handlers. Returns NO so the system handles the
// URL through default channels (or fails silently for unknown schemes).
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url
   sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    return NO;
}

// v1.2.1.1: Sync the Settings tab's UITabBarItem badge with UpdateChecker.status.
// Called both from the UpdateCheckerStatusChangedNotification observer and once
// during didFinishLaunchingWithOptions so the badge is correct from the first
// frame even before the launch update check completes.
- (void)refreshSettingsTabBadge {
    UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
    if (![tabs isKindOfClass:[UITabBarController class]]) return;
    UpdateChecker *uc = [UpdateChecker shared];
    NSString *badge = (uc.status == UpdateCheckerStatusAvailable) ? @"1" : nil;
    // Find the Settings tab by its root VC class — its index shifts when the AI tab is hidden.
    for (UIViewController *vc in tabs.viewControllers) {
        UIViewController *root = [vc isKindOfClass:[UINavigationController class]]
            ? [(UINavigationController *)vc viewControllers].firstObject : vc;
        if ([root isKindOfClass:[SettingsViewController class]]) {
            vc.tabBarItem.badgeValue = badge;
            return;
        }
    }
}

// Re-apply the active theme to every live screen so a theme switch takes effect immediately
// (no app restart). Walks ALL tab nav stacks — not just the visible one — so when the user
// flips to another tab it's already themed. Newly-pushed screens read the theme fresh at load.
- (void)applyThemeEverywhere {
    // Tab bar chrome (resets to STOCK when switching back to the default theme).
    [IOS6Theme applyToTabBar:self.tabBarVC.tabBar];

    // Each tab's nav bar + every loaded view controller in its stack.
    for (UINavigationController *nav in self.allTabNavs) {
        if ([nav isKindOfClass:[ADNavigationController class]])
            [(ADNavigationController *)nav applyADTheme];
        for (UIViewController *vc in nav.viewControllers) {
            if (![vc isViewLoaded]) continue;                      // themes itself on first load
            if ([vc respondsToSelector:@selector(applyTheme)])
                [(id<ADThemable>)vc applyTheme];                   // screen-specific re-theme
            [IOS6Theme retintViewTree:vc.view];                   // generic controls (switches, search…)
        }
    }
    [self applyStatusBarStyle];
}

- (void)applyStatusBarStyle {
    // Every non-default theme (dark AND light-colour) gets a solid dark status bar with light
    // glyphs so it reads over the custom bar; only the classic blue default keeps the stock style.
    // Best-effort: on iOS 7+ this is a no-op when status-bar appearance is view-controller-based.
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:@selector(setStatusBarStyle:animated:)]) return;
    UIStatusBarStyle style = [IOS6Theme isDefaultTheme] ? UIStatusBarStyleDefault : UIStatusBarStyleBlackOpaque;
    [app setStatusBarStyle:style animated:YES];
}

// v1.3.1: hook for the "Open in Filza?" prompt. Posted by InstallManager after
// each archive save. We try filza://view/<path> on the user's tap; falls back
// silently if Filza isn't installed (UIApplication openURL: returns NO).
- (void)installManagerSaved:(NSNotification *)note {
    NSString *path = note.userInfo[@"savedPath"];
    if (!path.length) return;
    self.pendingFilzaPath = path;
    NSString *body = [NSString stringWithFormat:T(@"install.saved_alert_msg"), path];
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"install.saved_alert_title")
                                                 message:body
                                                delegate:self
                                       cancelButtonTitle:T(@"common.ok")
                                       otherButtonTitles:T(@"install.open_in_filza"), nil];
    a.tag = 200;  // distinct from any per-VC tag
    [a show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alert.tag == 9911) {   // catalog-quality notice: the non-cancel button is "Don't show again"
        if (buttonIndex != alert.cancelButtonIndex) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"AppDropHideCatalogNotice"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        return;
    }
    if (alert.tag != 200) return;
    if (buttonIndex == alert.cancelButtonIndex) {
        self.pendingFilzaPath = nil;
        return;
    }
    NSString *path = self.pendingFilzaPath;
    self.pendingFilzaPath = nil;
    if (!path.length) return;

    // Percent-encode the path for use as a URL component. Filza expects
    // filza://view/<absolute path>; spaces, ampersands, etc. must be escaped.
    NSString *encoded = [path stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    if (!encoded) encoded = path;

    UIApplication *app = [UIApplication sharedApplication];
    NSURL *filza = [NSURL URLWithString:[@"filza://view/" stringByAppendingString:encoded]];
    NSURL *ifile = [NSURL URLWithString:[@"ifile://view/" stringByAppendingString:encoded]];
    if (filza && [app canOpenURL:filza]) {
        [app openURL:filza];
        return;
    }
    if (ifile && [app canOpenURL:ifile]) {
        [app openURL:ifile];
        return;
    }
    // Neither is installed (or LSApplicationQueriesSchemes hides them on iOS 9+).
    // Stash the path on the system pasteboard so the user can paste it into
    // whichever file manager they prefer.
    [UIPasteboard generalPasteboard].string = path;
    UIAlertView *fallback = [[UIAlertView alloc]
        initWithTitle:T(@"install.no_filza_title")
              message:T(@"install.no_filza_msg")
             delegate:nil
    cancelButtonTitle:T(@"common.ok")
    otherButtonTitles:nil];
    [fallback show];
}

// Kept as a private helper in case future code needs to surface a system-wide alert
// without owning a view controller (e.g. background notification handlers).
- (void)showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:title
                                                message:msg
                                               delegate:nil
                                      cancelButtonTitle:T(@"common.ok")
                                      otherButtonTitles:nil];
    [a show];
}

- (void)setupAppearance {
    // DEFAULT THEME = exactly the published v2.0 look: STOCK iOS 6 bars. v2.0 only ever set the
    // UIAppearance proxy (which has no visible effect on iOS 6 in this app), so it rendered stock
    // bars. We replicate that by applying NO chrome styling at all for the default theme — neither
    // proxy nor direct — leaving the system to draw its native bars. Dark themes do the real work
    // via per-instance styling (ADNavigationController / tab bar), with the proxy below as a
    // harmless belt-and-suspenders for anything not reached directly.
    if ([IOS6Theme isDefaultTheme]) return;

    id navProxy = [UINavigationBar appearance];
    {
        UIImage *navBg = [IOS6Theme navBarBackground];
        if (navBg && [navProxy respondsToSelector:@selector(setBackgroundImage:forBarMetrics:)])
            [navProxy setBackgroundImage:navBg forBarMetrics:UIBarMetricsDefault];
    }
    if ([navProxy respondsToSelector:@selector(setTitleTextAttributes:)]) {
        NSDictionary *attrs = @{
            UITextAttributeTextColor: [UIColor whiteColor],
            UITextAttributeTextShadowColor: [UIColor colorWithWhite:0 alpha:0.5],
            UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, -1)],
            UITextAttributeFont: [UIFont boldSystemFontOfSize:18],
        };
        [navProxy setTitleTextAttributes:attrs];
    }
    if ([navProxy respondsToSelector:@selector(setTintColor:)]) {
        // iOS 6: the bar's color comes from tintColor (the setBackgroundImage: appearance call is
        // unreliably reported as unsupported by the proxy). So the TINT is the real theme lever.
        [navProxy setTintColor:[IOS6Theme barTintColor]];
    }

    // Tab bar (iOS 5+)
    id tabProxy = [UITabBar appearance];
    if ([tabProxy respondsToSelector:@selector(setBackgroundImage:)]) {
        UIImage *tabBg = [IOS6Theme tabBarBackground];
        if (tabBg) [tabProxy setBackgroundImage:tabBg];
    }
    if ([tabProxy respondsToSelector:@selector(setTintColor:)]) {
        [tabProxy setTintColor:[IOS6Theme primaryBlue]];
    }

    // Default bar button items styled to match nav bar
    id barButtonProxy = [UIBarButtonItem appearance];
    if ([barButtonProxy respondsToSelector:@selector(setTitleTextAttributes:forState:)]) {
        NSDictionary *bbAttrs = @{
            UITextAttributeTextColor: [UIColor whiteColor],
            UITextAttributeTextShadowColor: [UIColor colorWithWhite:0 alpha:0.4],
            UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, -1)],
            UITextAttributeFont: [UIFont boldSystemFontOfSize:13],
        };
        [barButtonProxy setTitleTextAttributes:bbAttrs forState:UIControlStateNormal];
    }
}

@end
