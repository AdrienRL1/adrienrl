#import "SettingsViewController.h"
#import "InstallManager.h"
#import "IconLoader.h"
#import "IOS6Theme.h"
#import "NetworkClient.h"
#import "HTTPSClient.h"
#import "Localization.h"
#import "UpdateChecker.h"
#import "UpdateNotesViewController.h"
#import "ThemePickerViewController.h"
#import "DeviceInfo.h"
#import "AppRowCell.h"
#import "CategoryViewController.h"
#import "ADNumberPickerSheet.h"
#import "CollectionStore.h"
#import "FeedbackViewController.h"
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

typedef NS_ENUM(NSInteger, SettingsSection) {
    SectionLanguage = 0,
    SectionDisplay  = 1,  // v1.4 — grid density slider (iPad only)
    SectionUpdates  = 2,  // v1.2 build 13 — in-app updater
    SectionDownload = 3,  // v1.2 build 9 — parallel-streams picker
    SectionArchive  = 4,  // archive.org S3 credentials (optional, can help with throttling)
    SectionDiag     = 5,  // HTTPS test + ipainstaller spawn test
    SectionCache    = 6,
    SectionAbout    = 7,
    SectionFeedback = 8,  // send a bug report / idea (→ GitHub issue via Worker)
    SectionSupport  = 9,  // discreet "support the dev" PayPal link (last)
    SectionsCount
};

// Available parallel-stream choices. archive.org tolerates up to ~8 well; past
// that they tend to throttle the aggregate. 4 is the sweet spot in practice.
static const NSInteger kStreamChoices[] = { 1, 2, 4, 8 };
static const NSInteger kStreamChoicesCount = 4;
static NSString * const kPrefParallelStreams = @"IPAInstall.ParallelStreams";
// v1.3.1: download-folder override + post-install archiving toggle.
// DownloadFolder is read by InstallManager+configuredDownloadFolder and
// defaults to <sandbox>/Documents/AppDrop when unset. KeepIPAAfterInstall
// gates the iOS 6-9 archive path — iOS 10+ saves unconditionally because
// ipainstaller is broken there.
static NSString * const kPrefDownloadFolder = @"IPAInstall.DownloadFolder";
static NSString * const kPrefKeepIPA        = @"IPAInstall.KeepIPAAfterInstall";
static NSString * const kPrefAllowEncrypted = @"IPAInstall.AllowEncrypted";
// v3.0: the Catalogue/Recherche grid is now configured by a COLUMN COUNT (IPAInstall.GridColumns,
// set via the native wheel in showGridColumnsPicker), read by +[AppRowCell gridColumns]. The old
// 0…1 IPAInstall.GridDensity slider pref is retired.
NSString * const kAppDropGridDensityChangedNotification = @"AppDropGridDensityChanged";
// SectionLLM removed: chat AI is now Pollinations LLM (no API keys needed).

// NSUserDefaults keys for archive.org S3 credentials. The secret is technically a
// long-lived token rather than a password, so plain NSUserDefaults is acceptable
// for this scale (jailbreak utility, single-user device). Keychain would be nicer
// but is overkill here.
static NSString * const kPrefArchiveEmail     = @"IPAInstall.ArchiveEmail";
static NSString * const kPrefArchiveAccessKey = @"IPAInstall.ArchiveAccessKey";
static NSString * const kPrefArchiveSecretKey = @"IPAInstall.ArchiveSecretKey";

// Optional "support the dev" link — last section, discreet. Empty = hide the section.
static NSString * const kSupportURL = @"https://paypal.me/adrienrl1";

@interface SettingsViewController () <UIActionSheetDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UITableView *table;
// Which archive field the visible UIAlertView prompt is editing (0=email, 1=access, 2=secret).
@property (nonatomic, assign) NSInteger pendingArchiveFieldIndex;
@end

@implementation SettingsViewController

// Live theme re-apply. Reloading also refreshes the "Thème" row's detail (active theme name)
// and any accent-coloured text, so Settings reflects the new theme immediately.
- (void)applyTheme {
    self.view.backgroundColor = [IOS6Theme groupedBackgroundColor];
    self.table.backgroundColor = [IOS6Theme groupedBackgroundColor];
    if ([IOS6Theme isDark]) self.table.backgroundView = nil;   // remove the light grouped backdrop
    self.table.separatorColor = [IOS6Theme separatorColor];
    [self.table reloadData];
}

// Theme the cell fill for EVERY row (background only — text colours are set per-row in
// cellForRow so accent rows keep their colour). Keeps grouped cells dark on dark themes.
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    cell.backgroundColor = [IOS6Theme cellColor];
    if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
        UISwitch *sw = (UISwitch *)cell.accessoryView;   // stock green on default, accent on dark
        if ([sw respondsToSelector:@selector(setOnTintColor:)]) sw.onTintColor = [IOS6Theme isDefaultTheme] ? nil : [IOS6Theme accent];
        // -[UISwitch setTintColor:] is iOS 6+ → guard it (it crashed Settings on iPad 1 / iOS 5.1.1).
        if ([sw respondsToSelector:@selector(setTintColor:)]) sw.tintColor = [IOS6Theme isDefaultTheme] ? nil : [IOS6Theme separatorColor];
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
    self.title = T(@"settings.title");
    self.view.backgroundColor = [IOS6Theme groupedBackgroundColor];

    // No leftBarButtonItem: Settings is a root tab (see AppDelegate), never
    // presented modally, so a "Done" button would have nothing to dismiss
    // back to. (Earlier builds had one as a leftover from when Settings was
    // a modal — removed in v1.2 build 11 after Reddit feedback.)

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds
                                                style:UITableViewStyleGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = [IOS6Theme groupedBackgroundColor];
    // iOS 6 grouped tables draw a light textured backgroundView ON TOP of backgroundColor — kill it
    // on dark themes so the dark backdrop shows (default keeps its native texture untouched).
    if ([IOS6Theme isDark]) self.table.backgroundView = nil;
    [self.view addSubview:self.table];

    // Live-refresh the Updates section when UpdateChecker reports a new
    // state (e.g. background check completes after we already showed the
    // "Checking…" cell).
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(updateCheckerChanged:)
                                                  name:UpdateCheckerStatusChangedNotification
                                                object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Kick a background check if our cached info is stale (>1h) or absent.
    // This is non-blocking — the UI shows "Tap to check" or the last-known
    // value until the response arrives.
    [[UpdateChecker shared] checkForUpdates:NO];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateCheckerChanged:(NSNotification *)note {
    // Reload just the Updates section to avoid flickering the rest of the
    // table (Archive cells, About cells, etc.).
    if (!self.table) return;
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:SectionUpdates]
              withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return SectionsCount; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == SectionLanguage) return 1;
    if (s == SectionDisplay) return 4;  // theme + catalogue density + home density + Favoris toggle (both idioms)
    if (s == SectionUpdates) return 2;   // installed version + latest release
    if (s == SectionDownload) return 6;  // simultaneous downloads + parallel streams + folder + keep-ipa + allow-encrypted + auto-switch-mirror
    if (s == SectionArchive) return 3;   // email + access key + secret key
    if (s == SectionDiag) return 2;
    if (s == SectionCache) return 1;
    if (s == SectionAbout) return 8;  // + exact model, chip, RAM
    if (s == SectionFeedback) return 1;
    if (s == SectionSupport) return kSupportURL.length ? 1 : 0;  // hidden if no link
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == SectionLanguage) return T(@"settings.language");
    if (s == SectionDisplay) return T(@"settings.section_display");
    if (s == SectionUpdates) return T(@"settings.section_updates");
    if (s == SectionDownload) return T(@"settings.section_download");
    if (s == SectionArchive) return T(@"settings.section_archive");
    if (s == SectionDiag) return T(@"settings.section_diagnostics");
    if (s == SectionCache) return T(@"settings.section_cache");
    if (s == SectionAbout) return T(@"settings.section_about");
    if (s == SectionFeedback) return T(@"feedback.section");
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == SectionDisplay) return T(@"settings.section_display_footer");
    if (s == SectionUpdates) return [self updatesSectionFooter];
    if (s == SectionDownload) return T(@"settings.section_download_footer");
    if (s == SectionArchive) return T(@"settings.section_archive_footer");
    if (s == SectionDiag) return T(@"settings.section_diagnostics_footer");
    if (s == SectionFeedback) return T(@"feedback.section_footer");
    if (s == SectionSupport) return kSupportURL.length ? T(@"settings.support_footer") : nil;
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // Support row uses a Subtitle cell so the FULL PayPal URL is visible on its own
    // line (not a tappable shortcut — those fail on old iOS; the user copies the text
    // and opens it on a newer device).
    if (ip.section == SectionSupport) {
        static NSString *scid = @"supportCell";
        UITableViewCell *sc = [tv dequeueReusableCellWithIdentifier:scid];
        if (!sc) sc = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                             reuseIdentifier:scid];
        sc.textLabel.text = T(@"settings.support_row");
        sc.textLabel.font = [UIFont systemFontOfSize:15];
        sc.textLabel.textColor = [IOS6Theme primaryBlue];
        sc.detailTextLabel.text = kSupportURL;     // full link, always visible
        sc.detailTextLabel.font = [UIFont systemFontOfSize:13];
        sc.detailTextLabel.textColor = [IOS6Theme labelGray];
        sc.detailTextLabel.numberOfLines = 1;
        sc.selectionStyle = UITableViewCellSelectionStyleBlue;
        sc.accessoryType = UITableViewCellAccessoryNone;
        return sc;
    }
    static NSString *cid = @"setCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:cid];
    }
    // Default text colours (every call, so reuse resets them) — accent rows override below.
    cell.textLabel.textColor = [IOS6Theme labelDark];
    cell.detailTextLabel.textColor = [IOS6Theme labelGray];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;       // v1.3.1: clear sticky UISwitch from row reuse
    cell.detailTextLabel.text = nil;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    // v1.7: uniform label font/colour for EVERY row. Previously the Cache + About
    // rows never set a font, so they inherited the cell default (~17 pt) and looked
    // bigger than the 14 pt rows. Branches that want bold/blue override this after.
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.textColor = [IOS6Theme labelDark];
    cell.textLabel.numberOfLines = 1;

    if (ip.section == SectionLanguage) {
        cell.textLabel.text = T(@"settings.language");
        cell.textLabel.textColor = [IOS6Theme labelDark];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:@"IPAInstall.Language"];
        if (override.length) {
            cell.detailTextLabel.text = [Localization displayNameForLanguageCode:override];
        } else {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)",
                                          T(@"settings.language_auto"),
                                          [Localization displayNameForLanguageCode:[Localization currentLanguageCode]]];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == SectionDisplay && ip.row == 0) {
        // Theme — opens a scrolling colour picker. "Défaut" keeps the classic blue iOS 6 look;
        // any colour recolours the whole app live (no restart). Detail shows the active theme.
        cell.textLabel.text = T(@"settings.theme");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        cell.detailTextLabel.text = [IOS6Theme displayNameForThemeID:[IOS6Theme currentThemeID]];
    } else if (ip.section == SectionDisplay && ip.row == 1) {
        // v3.0: catalogue columns — tap to pick the number of apps per row on a native iOS 6 wheel
        // (1 = Liste on iPhone). Drives +[AppRowCell tilesPerRowForWidth:] for Catalogue + Recherche.
        cell.textLabel.text = T(@"settings.grid_density");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        NSInteger c = [AppRowCell gridColumns];
        cell.detailTextLabel.text = (c <= 1) ? T(@"settings.cols_list")
                                             : [NSString stringWithFormat:@"%ld", (long)c];
    } else if (ip.section == SectionDisplay && ip.row == 2) {
        // v3.0: Accueil tile columns — same native wheel, separate setting. Drives
        // +[CategoryViewController homeColumnsForWidth:] (apps/folders per row on the Accueil).
        cell.textLabel.text = T(@"settings.home_grid_density");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)[CategoryViewController homeColumns]];
    } else if (ip.section == SectionDisplay && ip.row == 3) {
        // v3.0: show/hide the Favoris tile on the Accueil (the Favoris tab in the bottom bar always stays). Default ON.
        cell.textLabel.text = T(@"settings.show_favorites_home");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        UISwitch *favSw = [[UISwitch alloc] initWithFrame:CGRectZero];
        favSw.on = ([[NSUserDefaults standardUserDefaults] objectForKey:@"IPAInstall.ShowFavoritesOnHome"] == nil)
                   ? YES : [[NSUserDefaults standardUserDefaults] boolForKey:@"IPAInstall.ShowFavoritesOnHome"];
        [favSw addTarget:self action:@selector(favoritesOnHomeToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = favSw;
    } else if (ip.section == SectionUpdates) {
        cell.textLabel.textColor = [IOS6Theme labelDark];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        UpdateChecker *uc = [UpdateChecker shared];
        if (ip.row == 0) {
            // Read-only installed-version row.
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = T(@"settings.installed_version");
            cell.detailTextLabel.text = [NSString stringWithFormat:@"v%@ (build %ld)",
                                            [uc currentVersion], (long)[uc currentBuild]];
        } else {
            // Latest-release row — dynamic based on UpdateChecker.status.
            // - Available: blue tint, "Install vX.Y" + date
            // - UpToDate:  "vX.Y (Mmm dd, yyyy) ✓"
            // - Checking:  "Checking…"
            // - Error:     "Check failed — tap to retry"
            // - Unknown:   "Tap to check"
            UpdateCheckerStatus s = uc.status;
            if (s == UpdateCheckerStatusAvailable) {
                cell.textLabel.text = [NSString stringWithFormat:T(@"settings.install_update_to"),
                                          uc.latestVersion];
                cell.textLabel.textColor = [IOS6Theme primaryBlue];
                cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
                cell.detailTextLabel.text = [self formattedDate:uc.latestReleaseDate];
            } else if (s == UpdateCheckerStatusUpToDate) {
                cell.textLabel.text = T(@"settings.latest_release");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"v%@ (%@) ✓",
                                                uc.latestVersion,
                                                [self formattedDate:uc.latestReleaseDate]];
            } else if (s == UpdateCheckerStatusChecking) {
                cell.textLabel.text = T(@"settings.latest_release");
                cell.detailTextLabel.text = T(@"settings.checking");
            } else if (s == UpdateCheckerStatusError) {
                cell.textLabel.text = T(@"settings.latest_release");
                cell.detailTextLabel.text = T(@"settings.check_failed");
            } else {
                cell.textLabel.text = T(@"settings.latest_release");
                cell.detailTextLabel.text = T(@"settings.tap_to_check");
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (ip.section == SectionDownload) {
        cell.textLabel.textColor = [IOS6Theme labelDark];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        if (ip.row == 0) {
            // v2.0: max simultaneous app downloads (1–8, default 2).
            cell.textLabel.text = T(@"settings.max_downloads");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)[InstallManager maxConcurrentDownloads]];
        } else if (ip.row == 1) {
            cell.textLabel.text = T(@"settings.parallel_streams");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            NSInteger streams = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefParallelStreams];
            if (streams <= 0) streams = 4;  // default
            cell.detailTextLabel.text = (streams == 1)
                ? T(@"settings.streams_off")
                : [NSString stringWithFormat:T(@"settings.streams_n"), (long)streams];
        } else if (ip.row == 2) {
            // Download folder — shows the active path. Default value shows
            // a short "Default" label so it's distinct from a custom path.
            cell.textLabel.text = T(@"settings.download_folder");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            NSString *custom = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefDownloadFolder];
            if (custom.length) {
                cell.detailTextLabel.text = custom.lastPathComponent;
            } else {
                cell.detailTextLabel.text = T(@"settings.download_folder_default");
            }
        } else if (ip.row == 3) {
            // Keep IPA toggle — UISwitch in the accessoryView. Selection
            // disabled so the row doesn't flash blue on tap (user expects
            // toggling the switch, not the row).
            cell.textLabel.text = T(@"settings.keep_ipa");
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
            sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefKeepIPA];
            [sw addTarget:self action:@selector(keepIPAToggled:)
                forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.detailTextLabel.text = nil;
        } else if (ip.row == 4) {
            // row 4 — allow installing FairPlay-encrypted IPAs (advanced). The app normally
            // blocks them (they won't launch on a different Apple ID); power users with an
            // on-device decryptor enable this. Default OFF. (Reddit + feedback #47.)
            cell.textLabel.text = T(@"settings.allow_encrypted");
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
            UISwitch *sw2 = [[UISwitch alloc] initWithFrame:CGRectZero];
            sw2.on = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefAllowEncrypted];
            [sw2 addTarget:self action:@selector(allowEncryptedToggled:)
                forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw2;
            cell.detailTextLabel.text = nil;
        } else {
            // row 5 — #171 (AndryTheBeast, level 2): auto-switch slow mirrors. ON (default) = smart
            // auto-switch (but it leaves a near-done mirror alone); OFF = stay on the current mirror
            // no matter what, and switch manually by pausing + resuming.
            cell.textLabel.text = T(@"settings.auto_switch_mirror");
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
            UISwitch *sw3 = [[UISwitch alloc] initWithFrame:CGRectZero];
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            sw3.on = ([d objectForKey:@"IPAInstall.AutoSwitchMirror"] == nil) ? YES
                       : [d boolForKey:@"IPAInstall.AutoSwitchMirror"];
            [sw3 addTarget:self action:@selector(autoSwitchMirrorToggled:)
                forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw3;
            cell.detailTextLabel.text = nil;
        }
    } else if (ip.section == SectionArchive) {
        cell.textLabel.textColor = [IOS6Theme labelDark];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
        if (ip.row == 0) {
            cell.textLabel.text = T(@"settings.archive_email");
            NSString *val = [def stringForKey:kPrefArchiveEmail];
            cell.detailTextLabel.text = val.length ? val : T(@"settings.archive_not_set");
        } else if (ip.row == 1) {
            cell.textLabel.text = T(@"settings.archive_access_key");
            NSString *val = [def stringForKey:kPrefArchiveAccessKey];
            cell.detailTextLabel.text = val.length ? val : T(@"settings.archive_not_set");
        } else {
            cell.textLabel.text = T(@"settings.archive_secret_key");
            NSString *val = [def stringForKey:kPrefArchiveSecretKey];
            // Mask the secret with bullets so a casual onlooker can't read it,
            // but still indicate whether it's set.
            if (val.length) {
                cell.detailTextLabel.text = [@"" stringByPaddingToLength:MIN(val.length, 10)
                                                              withString:@"•"
                                                         startingAtIndex:0];
            } else {
                cell.detailTextLabel.text = T(@"settings.archive_not_set");
            }
        }
    } else if (ip.section == SectionDiag) {
        cell.textLabel.textColor = [IOS6Theme primaryBlue];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
        if (ip.row == 0) cell.textLabel.text = T(@"settings.test_https");
        else cell.textLabel.text = T(@"settings.test_ipainstaller");
    } else if (ip.section == SectionCache) {
        cell.textLabel.text = T(@"settings.clear_icons");
    } else if (ip.section == SectionFeedback) {
        cell.textLabel.text = T(@"feedback.row");
        cell.textLabel.textColor = [IOS6Theme primaryBlue];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == SectionAbout) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSBundle *b = [NSBundle mainBundle];
        UIDevice *d = [UIDevice currentDevice];
        switch (ip.row) {
            case 0:
                cell.textLabel.text = T(@"settings.about_app");
                cell.detailTextLabel.text = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"IPA Install";
                break;
            case 1:
                cell.textLabel.text = T(@"settings.about_version");
                cell.detailTextLabel.text = [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
                break;
            case 2:
                cell.textLabel.text = T(@"settings.about_bundle");
                cell.detailTextLabel.text = [b bundleIdentifier] ?: @"?";
                break;
            case 3:
                cell.textLabel.text = T(@"settings.about_min_ios");
                // v1.3.3: was "5.0 (armv7)" but iOS 5 was dropped in v2.0.22
                // when the armv7 binary started using ≥ 6.0 APIs.
                cell.detailTextLabel.text = @"6.0 (armv7)";
                break;
            case 4:
                cell.textLabel.text = T(@"settings.about_device_ios");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ %@",
                                              d.systemName ?: @"iOS", d.systemVersion ?: @"?"];
                break;
            case 5:
                cell.textLabel.text = T(@"settings.about_device_model");
                // Exact model from our hardware table (e.g. "iPad mini 2 (iPad4,4)").
                cell.detailTextLabel.text = [DeviceInfo isKnown]
                    ? [NSString stringWithFormat:@"%@ (%@)",
                         [DeviceInfo modelName], [DeviceInfo hardwareIdentifier]]
                    : [DeviceInfo hardwareIdentifier];
                break;
            case 6:
                cell.textLabel.text = T(@"settings.about_chip");
                cell.detailTextLabel.text = [DeviceInfo chip];
                break;
            case 7:
                cell.textLabel.text = T(@"settings.about_ram");
                cell.detailTextLabel.text = [DeviceInfo ram];
                break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == SectionLanguage) {
        [self showLanguagePicker];
        return;
    }
    if (ip.section == SectionDisplay && ip.row == 0) {
        [self.navigationController pushViewController:[[ThemePickerViewController alloc] init] animated:YES];
        return;
    }
    if (ip.section == SectionDisplay && ip.row == 1) { [self showGridColumnsPicker]; return; }
    if (ip.section == SectionDisplay && ip.row == 2) { [self showHomeColumnsPicker]; return; }
    if (ip.section == SectionUpdates) {
        if (ip.row == 1) [self handleUpdatesRowTap];
        return;
    }
    if (ip.section == SectionDownload) {
        if (ip.row == 0) [self showMaxDownloadsPicker];
        else if (ip.row == 1) [self showParallelStreamsPicker];
        else if (ip.row == 2) [self showDownloadFolderPicker];
        // row 3 (keep-ipa toggle) is handled by the UISwitch directly.
        return;
    }
    if (ip.section == SectionArchive) {
        [self promptArchiveFieldAtIndex:ip.row];
        return;
    }
    if (ip.section == SectionDiag) {
        if (ip.row == 0) [self testDirectHTTPS];
        else [self testIpainstaller];
    } else if (ip.section == SectionCache) {
        [[IconLoader shared] clearCache];
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"settings.cache_cleared")
                                                    message:T(@"settings.cache_cleared_msg")
                                                   delegate:nil
                                          cancelButtonTitle:T(@"common.ok")
                                          otherButtonTitles:nil];
        [a show];
    } else if (ip.section == SectionFeedback) {
        [self.navigationController pushViewController:[[FeedbackViewController alloc] init] animated:YES];
    } else if (ip.section == SectionSupport) {
        if (kSupportURL.length) {
            // Copy the full link — on old iOS the URL won't open in a browser/PayPal,
            // so the user pastes it on a newer device/computer.
            [[UIPasteboard generalPasteboard] setString:kSupportURL];
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"settings.support_row")
                message:[NSString stringWithFormat:@"%@\n\n%@", kSupportURL, T(@"settings.support_copied")]
                delegate:nil cancelButtonTitle:T(@"common.ok") otherButtonTitles:nil];
            [a show];
        }
    }
}

#pragma mark - Archive.org S3 credentials

// Show a single-line text-input alert for an archive.org field. The index maps to
// 0=email, 1=access key, 2=secret key. Pre-fills the current value so the user
// can edit rather than retype. To clear a value, the user wipes the field and Saves.
- (void)promptArchiveFieldAtIndex:(NSInteger)idx {
    self.pendingArchiveFieldIndex = idx;
    NSString *title;
    NSString *currentValue;
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    switch (idx) {
        case 0:
            title = T(@"settings.archive_email");
            currentValue = [def stringForKey:kPrefArchiveEmail];
            break;
        case 1:
            title = T(@"settings.archive_access_key");
            currentValue = [def stringForKey:kPrefArchiveAccessKey];
            break;
        default:
            title = T(@"settings.archive_secret_key");
            currentValue = [def stringForKey:kPrefArchiveSecretKey];
            break;
    }
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                     message:T(@"settings.archive_help")
                                                    delegate:self
                                           cancelButtonTitle:T(@"common.cancel")
                                           otherButtonTitles:T(@"settings.archive_save"), nil];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    alert.tag = 100;  // distinguish from other alerts in this VC
    UITextField *tf = [alert textFieldAtIndex:0];
    tf.text = currentValue ?: @"";
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.spellCheckingType = UITextSpellCheckingTypeNo;
    if (idx == 0) {
        tf.keyboardType = UIKeyboardTypeEmailAddress;
    } else {
        tf.keyboardType = UIKeyboardTypeASCIICapable;
    }
    [alert show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)buttonIndex {
    // alert.tag == 101 was the pre-v1.2-build-14 install-update confirmation
    // alert. Since v1.2 build 14 the modal UpdateNotesViewController replaced
    // it, and since v1.4-5 the install path hands off to Cydia entirely, so
    // there's no UIAlertView at tag 101 anymore.
    if (alert.tag == 102) {
        // Custom download folder input (v1.3.1).
        if (buttonIndex == alert.cancelButtonIndex) return;
        UITextField *tf = [alert textFieldAtIndex:0];
        NSString *value = [tf.text stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
        if (value.length && [value hasPrefix:@"/"]) {
            [def setObject:value forKey:kPrefDownloadFolder];
        } else {
            // Empty or relative path → revert to default. Avoids landing
            // saves in some unintended cwd.
            [def removeObjectForKey:kPrefDownloadFolder];
        }
        [def synchronize];
        [self.table reloadSections:[NSIndexSet indexSetWithIndex:SectionDownload]
                   withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    if (alert.tag != 100) return;
    if (buttonIndex == alert.cancelButtonIndex) return;
    UITextField *tf = [alert textFieldAtIndex:0];
    NSString *value = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    NSString *key;
    switch (self.pendingArchiveFieldIndex) {
        case 0: key = kPrefArchiveEmail; break;
        case 1: key = kPrefArchiveAccessKey; break;
        default: key = kPrefArchiveSecretKey; break;
    }
    if (value.length) {
        [def setObject:value forKey:key];
    } else {
        [def removeObjectForKey:key];
    }
    [def synchronize];
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:SectionArchive]
                withRowAnimation:UITableViewRowAnimationNone];
}

- (void)testIpainstaller {
    // Try to spawn /usr/bin/ipainstaller -l (list) and capture output.
    // If this works from the mobile-user app sandbox, autonomous install is feasible.
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"common.error")
                                                    message:@"pipe() a echoue"
                                                   delegate:nil cancelButtonTitle:T(@"common.ok") otherButtonTitles:nil];
        [a show]; return;
    }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addclose(&fa, pipefd[0]);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 2);
    posix_spawn_file_actions_addclose(&fa, pipefd[1]);

    const char *path = "/usr/bin/ipainstaller";
    char *const argv[] = { (char *)"ipainstaller", (char *)"-l", NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pipefd[1]);

    NSString *result;
    if (rc != 0) {
        result = [NSString stringWithFormat:@"ECHEC posix_spawn rc=%d errno=%d\n%s\n\nL'app NE PEUT PAS invoquer ipainstaller depuis le sandbox.",
                  rc, errno, strerror(errno)];
        close(pipefd[0]);
    } else {
        // Read output (max 4KB)
        char buf[4096] = {0};
        ssize_t n = read(pipefd[0], buf, sizeof(buf) - 1);
        close(pipefd[0]);
        int status = 0;
        waitpid(pid, &status, 0);
        int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

        NSString *output = (n > 0)
            ? [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding]
            : @"";
        result = [NSString stringWithFormat:@"SPAWN OK pid=%d exit=%d\n\nOutput (%ld octets):\n%@",
                  pid, exitCode, (long)n, [output substringToIndex:MIN(output.length, 500)]];
    }
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Test ipainstaller"
                                                message:result
                                               delegate:nil
                                      cancelButtonTitle:T(@"common.ok")
                                      otherButtonTitles:nil];
    [a show];
}

- (void)testDirectHTTPS {
    UIAlertView *loading = [[UIAlertView alloc] initWithTitle:@"Test en cours..."
                                                       message:@"HTTPS vers archive.org via mbedTLS bundle"
                                                      delegate:nil
                                             cancelButtonTitle:nil
                                             otherButtonTitles:nil];
    [loading show];
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc]
                                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    sp.center = CGPointMake(loading.bounds.size.width/2, loading.bounds.size.height-50);
    [sp startAnimating];
    [loading addSubview:sp];

    NSDate *start = [NSDate date];
    // Use bundled mbedTLS (NOT iOS native TLS which is too old for archive.org)
    [HTTPSClient getURL:@"https://archive.org/about/"
                timeout:25
             completion:^(NSData *body, NSInteger status, NSError *err) {
        NSTimeInterval elapsed = -[start timeIntervalSinceNow];
        [loading dismissWithClickedButtonIndex:0 animated:NO];
        NSString *msg;
        if (err) {
            msg = [NSString stringWithFormat:@"ECHEC (%.1fs)\n\n%@\n\nLa lib mbedTLS bundle a echoue le handshake TLS avec archive.org. A investiguer.",
                     elapsed, err.localizedDescription];
        } else if (status >= 200 && status < 400) {
            msg = [NSString stringWithFormat:@"SUCCES !\n\nStatus HTTP : %ld\nTaille body : %lu octets\nTemps : %.1fs\n\nL'app peut joindre archive.org en HTTPS direct (necessaire pour installer une IPA).",
                     (long)status, (unsigned long)body.length, elapsed];
        } else {
            msg = [NSString stringWithFormat:@"REPONSE HTTP %ld (%.1fs)\nTaille : %lu octets",
                     (long)status, elapsed, (unsigned long)body.length];
        }
        UIAlertView *result = [[UIAlertView alloc] initWithTitle:@"Test mbedTLS"
                                                          message:msg
                                                         delegate:nil
                                                cancelButtonTitle:T(@"common.ok")
                                                otherButtonTitles:nil];
        [result show];
    }];
}

#pragma mark - Updates section (v1.2 build 13)

// Footer copy below the Updates section. Either "Last checked: <relative time>"
// or instructional text when we've never checked.
- (NSString *)updatesSectionFooter {
    UpdateChecker *uc = [UpdateChecker shared];
    if (!uc.lastCheckedAt) {
        return T(@"settings.updates_footer_initial");
    }
    NSTimeInterval ago = -[uc.lastCheckedAt timeIntervalSinceNow];
    NSString *whenAgo;
    if (ago < 60) {
        whenAgo = T(@"settings.last_checked_just_now");
    } else if (ago < 3600) {
        whenAgo = [NSString stringWithFormat:T(@"settings.last_checked_minutes"),
                     (long)(ago / 60)];
    } else if (ago < 86400) {
        whenAgo = [NSString stringWithFormat:T(@"settings.last_checked_hours"),
                     (long)(ago / 3600)];
    } else {
        whenAgo = [self formattedDate:uc.lastCheckedAt];
    }
    return [NSString stringWithFormat:T(@"settings.updates_footer_checked"), whenAgo];
}

// Locale-aware medium date format ("May 27, 2026" / "27 mai 2026" / "2026年5月27日" etc.).
- (NSString *)formattedDate:(NSDate *)date {
    if (!date) return @"?";
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterMediumStyle;
        fmt.timeStyle = NSDateFormatterNoStyle;
        // Locale defaults to user's current locale — already what we want.
    });
    return [fmt stringFromDate:date];
}

// Tap on the "Latest release" row dispatches based on current state:
//   - Available  → confirm + install
//   - Up to date → re-check (force)
//   - Error      → re-check (force)
//   - Checking   → no-op (already in flight)
//   - Unknown    → trigger first check
- (void)handleUpdatesRowTap {
    UpdateChecker *uc = [UpdateChecker shared];
    if (uc.status == UpdateCheckerStatusChecking) return;
    if (uc.status == UpdateCheckerStatusAvailable) {
        // Present the release-notes modal. AppDrop is distributed via the
        // AdrienRL Cydia source now, so the right-bar button reads
        // "Open Cydia" and the handler deep-links into the package manager
        // instead of starting an in-app download.
        UpdateNotesViewController *vc = [[UpdateNotesViewController alloc] init];
        vc.version = uc.latestVersion;
        vc.releaseDate = uc.latestReleaseDate;
        vc.notesMarkdown = uc.latestReleaseNotes;
        __weak typeof(self) weakSelf = self;
        vc.installHandler = ^{
            __strong typeof(self) s = weakSelf;
            if (s) [s openCydiaForUpdate];
        };
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:vc];
        // Full-screen on iPhone (always), form-sheet (centered) on iPad
        // for a bit of breathing room on the big screen.
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
        }
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }
    // Any other state → re-check.
    [uc checkForUpdates:YES];
}

// AppDrop is distributed exclusively via the AdrienRL Cydia repo. AppDrop only
// supports iOS 5-10 and Cydia is the only package manager that runs on those
// versions (Sileo is iOS 11+, Zebra is iOS 9+, Saily is iOS 15+). So we just
// try cydia:// directly; if it's missing for any reason, fall back to opening
// the repo landing page in Safari.
- (void)openCydiaForUpdate {
    UIApplication *app = [UIApplication sharedApplication];
    NSURL *cydiaURL = [NSURL URLWithString:@"cydia://package/ca.adrien.appdrop"];
    if ([app canOpenURL:cydiaURL]) {
        [app openURL:cydiaURL];
        return;
    }
    [app openURL:[NSURL URLWithString:@"https://adrienrl1.github.io/cydia/"]];
}

#pragma mark - Download folder + keep-ipa toggle (v1.3.1)

// Action sheet for the download-folder choice. Two presets + a free-form
// custom path. Custom path is entered via a UIAlertView text input so users
// on jailbroken devices can point to /var/mobile/Documents/AppDrop/ (browsable
// by Filza without spelunking into the sandboxed Application/<UUID>/ path).
- (void)showDownloadFolderPicker {
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:T(@"settings.download_folder")
                                                       delegate:self
                                              cancelButtonTitle:nil
                                         destructiveButtonTitle:nil
                                              otherButtonTitles:nil];
    sheet.tag = 97;
    NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefDownloadFolder];
    BOOL hasCustom = (current.length > 0);

    NSString *defaultLabel = T(@"settings.download_folder_default");
    if (!hasCustom) defaultLabel = [defaultLabel stringByAppendingString:@" ✓"];
    [sheet addButtonWithTitle:defaultLabel];

    NSString *jbLabel = @"/var/mobile/Documents/AppDrop";
    if (hasCustom && [current isEqualToString:jbLabel]) {
        jbLabel = [jbLabel stringByAppendingString:@" ✓"];
    }
    [sheet addButtonWithTitle:jbLabel];

    [sheet addButtonWithTitle:T(@"settings.download_folder_custom")];
    [sheet addButtonWithTitle:T(@"common.cancel")];
    sheet.cancelButtonIndex = 3;
    [sheet showInView:self.view];
}

// UISwitch action — fires on every flip. Persists immediately so a backgrounded
// kill doesn't lose the value.
- (void)keepIPAToggled:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:kPrefKeepIPA];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Allow installing FairPlay-encrypted IPAs (Settings → Download). Default OFF.
- (void)allowEncryptedToggled:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:kPrefAllowEncrypted];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// #171 (AndryTheBeast, level 2): auto-switch slow mirrors (Settings → Download). Default ON.
// OFF = AppDrop stays on the current mirror; the user switches by pausing + resuming.
- (void)autoSwitchMirrorToggled:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"IPAInstall.AutoSwitchMirror"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// v3.0: catalogue columns — a native iOS 6 wheel to pick the number of apps per row (1 = Liste on
// iPhone). Persists IPAInstall.GridColumns + posts the shared notification so Catalogue + Recherche
// re-lay-out live; the Settings row's value refreshes too.
- (void)showGridColumnsPicker {
    BOOL pad = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
    NSArray *vals = pad ? @[@2,@3,@4,@5,@6,@7,@8] : @[@1,@2,@3,@4];
    NSMutableArray *labels = [NSMutableArray array];
    for (NSNumber *v in vals) {
        [labels addObject:(v.integerValue <= 1) ? T(@"settings.cols_list")
                                                : [NSString stringWithFormat:@"%ld", (long)v.integerValue]];
    }
    __weak typeof(self) ws = self;
    [ADNumberPickerSheet presentInView:self.view
                                 title:T(@"settings.grid_density")
                                values:vals
                                labels:labels
                         selectedValue:[AppRowCell gridColumns]
                                onPick:^(NSInteger value) {
        [[NSUserDefaults standardUserDefaults] setInteger:value forKey:@"IPAInstall.GridColumns"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [[NSNotificationCenter defaultCenter] postNotificationName:kAppDropGridDensityChangedNotification object:nil];
        // Update the row's value IN PLACE (not reloadSections:) — rebuilding the cell drops its
        // dark-theme text colour until willDisplayCell: re-fires on scroll (the "texte illisible" bug).
        UITableViewCell *c = [ws.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:SectionDisplay]];
        if (c) c.detailTextLabel.text = (value <= 1) ? T(@"settings.cols_list")
                                                     : [NSString stringWithFormat:@"%ld", (long)value];
    }];
}

// v3.0: Accueil columns — the same native wheel, picking the number of tiles (apps/folders) per row.
// Persists IPAInstall.HomeColumns; the same notification makes the Accueil grid relayout live.
- (void)showHomeColumnsPicker {
    BOOL pad = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
    // iPhone is capped at 3 columns for the Accueil (beyond that the tiles get too small for the
    // folder name; at 3 the tiles show the name only — see CategoryTileView). iPad goes up to 8.
    NSArray *vals = pad ? @[@2,@3,@4,@5,@6,@7,@8] : @[@2,@3];
    NSMutableArray *labels = [NSMutableArray array];
    for (NSNumber *v in vals) [labels addObject:[NSString stringWithFormat:@"%ld", (long)v.integerValue]];
    __weak typeof(self) ws = self;
    [ADNumberPickerSheet presentInView:self.view
                                 title:T(@"settings.home_grid_density")
                                values:vals
                                labels:labels
                         selectedValue:[CategoryViewController homeColumns]
                                onPick:^(NSInteger value) {
        [[NSUserDefaults standardUserDefaults] setInteger:value forKey:@"IPAInstall.HomeColumns"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [[NSNotificationCenter defaultCenter] postNotificationName:kAppDropGridDensityChangedNotification object:nil];
        // In-place value update (see showGridColumnsPicker — avoids the dark-theme reload bug).
        UITableViewCell *c = [ws.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:SectionDisplay]];
        if (c) c.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)value];
    }];
}

// v3.0: show/hide the Favoris tile on the Accueil (the Favoris tab stays). Default ON. Posts the
// collection-change notification so the Accueil rebuilds its grid live, with/without the tile.
- (void)favoritesOnHomeToggled:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"IPAInstall.ShowFavoritesOnHome"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:CollectionStoreDidChangeNotification object:nil];
}

#pragma mark - Simultaneous-downloads picker (v2.0 → v3.1.1 native wheel)

// Same iOS 5/6 spinning wheel as the apps-per-row picker (ADNumberPickerSheet), per user request.
- (void)showMaxDownloadsPicker {
    NSArray *vals = @[@1,@2,@3,@4,@5,@6,@7,@8];
    NSMutableArray *labels = [NSMutableArray array];
    for (NSNumber *v in vals) [labels addObject:[NSString stringWithFormat:@"%ld", (long)v.integerValue]];
    __weak typeof(self) ws = self;
    [ADNumberPickerSheet presentInView:self.view
                                 title:T(@"settings.max_downloads")
                                values:vals
                                labels:labels
                         selectedValue:[InstallManager maxConcurrentDownloads]
                                onPick:^(NSInteger value) {
        [[NSUserDefaults standardUserDefaults] setInteger:value forKey:@"IPAInstall.MaxConcurrentDownloads"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [[InstallManager shared] pumpQueue];   // apply now: if raised, start more queued installs
        // In-place value update (avoids the dark-theme reload bug — see showGridColumnsPicker).
        UITableViewCell *c = [ws.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:SectionDownload]];
        if (c) c.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)value];
    }];
}

#pragma mark - Parallel-streams picker (v1.2 build 9 → v3.1.1 native wheel)

- (void)showParallelStreamsPicker {
    NSMutableArray *vals = [NSMutableArray array];
    NSMutableArray *labels = [NSMutableArray array];
    for (NSInteger i = 0; i < kStreamChoicesCount; i++) {
        NSInteger n = kStreamChoices[i];
        [vals addObject:[NSNumber numberWithInteger:n]];
        [labels addObject:(n == 1) ? T(@"settings.streams_off")
                                   : [NSString stringWithFormat:T(@"settings.streams_n"), (long)n]];
    }
    NSInteger current = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefParallelStreams];
    if (current <= 0) current = 4;
    __weak typeof(self) ws = self;
    [ADNumberPickerSheet presentInView:self.view
                                 title:T(@"settings.parallel_streams")
                                values:vals
                                labels:labels
                         selectedValue:current
                                onPick:^(NSInteger value) {
        [[NSUserDefaults standardUserDefaults] setInteger:value forKey:kPrefParallelStreams];
        [[NSUserDefaults standardUserDefaults] synchronize];
        UITableViewCell *c = [ws.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:SectionDownload]];
        if (c) c.detailTextLabel.text = (value == 1) ? T(@"settings.streams_off")
                                                     : [NSString stringWithFormat:T(@"settings.streams_n"), (long)value];
    }];
}

#pragma mark - Language picker

- (void)showLanguagePicker {
    // Build an action-sheet-like picker. Use UIActionSheet (iOS 5/6 compatible).
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:T(@"settings.language")
                                                       delegate:self
                                              cancelButtonTitle:nil
                                         destructiveButtonTitle:nil
                                              otherButtonTitles:nil];
    sheet.tag = 99;
    // First option = Auto, then each supported language
    [sheet addButtonWithTitle:T(@"settings.language_auto")];
    NSArray *codes = [Localization availableLanguageCodes];
    for (NSString *code in codes) {
        NSString *display = [Localization displayNameForLanguageCode:code];
        [sheet addButtonWithTitle:display];
    }
    [sheet addButtonWithTitle:T(@"common.cancel")];
    sheet.cancelButtonIndex = (NSInteger)codes.count + 1;
    [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)idx {
    if (sheet.tag == 97) {
        // Download-folder picker. 0 = default, 1 = /var/mobile preset,
        // 2 = custom (prompt), 3 = cancel.
        if (idx == sheet.cancelButtonIndex) return;
        NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
        if (idx == 0) {
            // Default — clear the override so configuredDownloadFolder falls
            // back to the sandbox path.
            [def removeObjectForKey:kPrefDownloadFolder];
            [def synchronize];
            [self.table reloadSections:[NSIndexSet indexSetWithIndex:SectionDownload]
                       withRowAnimation:UITableViewRowAnimationNone];
        } else if (idx == 1) {
            [def setObject:@"/var/mobile/Documents/AppDrop" forKey:kPrefDownloadFolder];
            [def synchronize];
            [self.table reloadSections:[NSIndexSet indexSetWithIndex:SectionDownload]
                       withRowAnimation:UITableViewRowAnimationNone];
        } else if (idx == 2) {
            // Custom path — UIAlertView text input.
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"settings.download_folder_custom")
                                                         message:T(@"settings.download_folder_custom_msg")
                                                        delegate:self
                                               cancelButtonTitle:T(@"common.cancel")
                                               otherButtonTitles:T(@"settings.archive_save"), nil];
            a.alertViewStyle = UIAlertViewStylePlainTextInput;
            a.tag = 102;  // distinguish from archive (100) + update (101)
            UITextField *tf = [a textFieldAtIndex:0];
            tf.text = [def stringForKey:kPrefDownloadFolder] ?: @"";
            tf.placeholder = @"/var/mobile/Documents/AppDrop";
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            tf.spellCheckingType = UITextSpellCheckingTypeNo;
            tf.keyboardType = UIKeyboardTypeASCIICapable;
            [a show];
        }
        return;
    }
    // (Simultaneous-downloads tag 96 + parallel-streams tag 98 now use the native wheel
    //  ADNumberPickerSheet — see showMaxDownloadsPicker / showParallelStreamsPicker.)
    if (sheet.tag != 99) return;
    if (idx == sheet.cancelButtonIndex) return;
    if (idx == 0) {
        [Localization setLanguageCode:nil];
    } else {
        NSArray *codes = [Localization availableLanguageCodes];
        if (idx - 1 < (NSInteger)codes.count) {
            [Localization setLanguageCode:codes[idx - 1]];
        }
    }
    // Re-create the entire tab bar with new translations and re-select the Settings tab.
    // Important: re-fetch the window AFTER the relaunch (the old `win` would be orphaned).
    [(id)[[UIApplication sharedApplication] delegate]
        application:[UIApplication sharedApplication]
        didFinishLaunchingWithOptions:nil];
    UIWindow *newWin = [[[UIApplication sharedApplication] delegate] window];
    UITabBarController *tabs = (UITabBarController *)newWin.rootViewController;
    // Settings is tab index 4 since v1.2 restored the Search tab (order: catalog,
    // search, ai, install, settings).
    if ([tabs isKindOfClass:[UITabBarController class]]) tabs.selectedIndex = 4;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end
