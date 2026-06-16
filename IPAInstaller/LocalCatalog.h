#import <Foundation/Foundation.h>

// Posted on the main thread after a background freshness check downloaded a newer catalogue
// and hot-swapped it in place. Observers should rebuild any catalogue-derived UI.
extern NSString *const LocalCatalogDidUpdateNotification;

// On-device catalog: downloads ipa.json + urls.json from stuffed18.github.io
// (GitHub Pages public CDN — no private backend involved) once, caches locally, then
// provides search/filter without any backend round-trip.
// Memory: ~50 MB held in memory after parse. OK on iPad 4 (1 GB), tight on iPad 1 (256 MB).
@interface LocalCatalog : NSObject

+ (instancetype)shared;

// Returns YES if catalog data is loaded and ready for queries.
- (BOOL)isReady;

// Load the catalog (downloads from stuffed18.github.io if not cached, else loads from disk).
// Completion called on main queue. Idempotent — subsequent calls return immediately.
- (void)loadWithProgress:(void (^)(NSString *status))progressBlock
              completion:(void (^)(BOOL ok, NSError *err))completion;

// v2.0: cheap background freshness check. Compares the remote catalog.db.gz size (via HEAD)
// against the size stored at last download; if it changed, downloads + hot-swaps the DB
// (serialized, race-free) and posts LocalCatalogDidUpdateNotification. No-op if the catalogue
// isn't loaded yet or a check/update is already in flight. Safe to call on every launch /
// foreground — the HEAD probe is a few hundred bytes; the full 27 MB download happens only
// when the published catalogue actually changed.
- (void)checkForCatalogUpdate;

// 0xdead10cc fix: close the SQLite handle when the app is backgrounded so iOS never suspends the
// app while the catalog file is held open (the #1 auto-crash on iOS 5/6/7). Reads guard on
// (loaded && db), so they safely return empty in the brief gap; call loadWithProgress: on
// foreground to reopen the cached file (no re-download). Safe to call repeatedly. `completion` runs
// (on a background queue) once the handle is actually closed — the caller can hold a UIBackgroundTask
// until then so the close finishes before iOS suspends the app.
- (void)closeForBackgroundCompletion:(void (^)(void))completion;

// Settings → "Clear catalog cache": drops the freshness baseline + deletes the cached catalog .db,
// then re-downloads it now (or on next launch if offline). Used to force a fresh catalogue.
+ (void)clearCachedCatalog;

// Filtered search. Returns NSArray of NSDictionary entries matching the same shape as backend.
// SYNCHRONOUS — call only from background queue, or use searchAsyncWithQuery:... below.
// `deviceClass`: nil/@"all" = no filter, @"iphone" = apps with iPhone support (plat & 2),
//                @"ipad" = apps with iPad support (plat & 4).
// `descending`: YES = ORDER BY ... DESC, NO = ASC.
- (NSDictionary *)searchWithQuery:(NSString *)q
                            minIOS:(NSString *)minIOSStr  // "5.0" etc., nil for none
                            maxIOS:(NSString *)maxIOSStr  // nil for none
                             unique:(BOOL)unique
                               sort:(NSString *)sortKey   // "recent"/"name"/"size"/"minos"
                        descending:(BOOL)descending
                       deviceClass:(NSString *)deviceClass
                          category:(NSString *)category   // v1.7: nil/@"" = no filter (browse menu)
                          subgenre:(NSString *)subgenre   // game subgenre, nil/@"" = no filter
                             offset:(NSInteger)offset
                              limit:(NSInteger)limit;

// Async search — runs on background queue, calls completion on main.
- (void)searchAsyncWithQuery:(NSString *)q
                       minIOS:(NSString *)minIOSStr
                       maxIOS:(NSString *)maxIOSStr
                        unique:(BOOL)unique
                          sort:(NSString *)sortKey
                   descending:(BOOL)descending
                  deviceClass:(NSString *)deviceClass
                     category:(NSString *)category
                     subgenre:(NSString *)subgenre
                        offset:(NSInteger)offset
                         limit:(NSInteger)limit
                    completion:(void (^)(NSDictionary *result))completion;

// Runs `block` on the serial search queue (the SAME queue every query/write uses), so the read methods
// below (categoryCounts/iconPoolForCategory/…) can be called from inside it WITHOUT touching the main thread
// and WITHOUT racing self.db. Use this to gather catalog data off the main thread, then hop back to main to
// build UI. No-op if block is nil.
- (void)performRead:(dispatch_block_t)block;

// v1.7: category browse menu — counts per top-level category (only non-empty).
// Returns NSArray of @{ @"category": NSString, @"count": NSNumber }, sorted by count desc.
- (NSArray *)categoryCounts;

// v1.7: subgenres within a category (e.g. Games), with counts.
// Returns NSArray of @{ @"subgenre": NSString, @"count": NSNumber }, sorted by count desc.
- (NSArray *)subgenreCountsForCategory:(NSString *)category;

// #156: current category/subgenre of an app (for the "suggest category" screen), or nil.
- (NSDictionary *)categorySubgenreForBundleId:(NSString *)bid;
// #156: fetch + apply the hosted category-overrides.json (called after load; safe to re-call).
- (void)refreshCategoryOverrides;

// v3.1: fetch + merge the hosted catalog-extras.json (community apps absent from the 43k catalogue,
// moderated). New apps are INSERTed into the local DB under their category; a new version of an
// existing app is added to its versions list; an exact duplicate is skipped (unless the catalogue's
// copy is FairPlay-encrypted, in which case its download is swapped for the contributed decrypted one).
- (void)refreshCatalogExtras;

// v1.7: total number of unique apps in the catalogue (for the "All apps" row / header).
- (NSInteger)uniqueAppCount;

// v3.2: fusionne {bid_lower:count} (stats Cloudflare) dans une table `downloads` de catalog.db,
// pour permettre le tri SQL `sort=downloads` et le top des plus téléchargées. Thread-safe (file interne).
- (void)mergeDownloadCounts:(NSDictionary *)bidLowerToCount;

// v3.2: jusqu'à `n` URLs d'icônes des apps les plus téléchargées (device-runnable), ordre décroissant.
// Sert aux 4 icônes du raccourci « Plus téléchargées » sur l'accueil. Renvoie [] si rien.
- (NSArray *)topDownloadedIconURLs:(NSInteger)n;

// v1.7: pool of representative icon URLs (the ~16 biggest apps with an icon) for a
// category / subgenre, precomputed in cat_icon_pool. The category home picks one at
// random per card so the icons vary on each visit. Returns [] if unavailable.
- (NSArray *)iconPoolForCategory:(NSString *)category;
- (NSArray *)iconPoolForCategory:(NSString *)category subgenre:(NSString *)subgenre;

// All entries for a given bundle id (newest version first).
- (NSArray *)versionsForBundleId:(NSString *)bundleId;
// #120: one icon URL for a bundle id (single LIMIT-1 query) — much cheaper than versionsForBundleId
// when the caller only needs an icon (the Works Today / Modded list).
- (NSString *)iconURLForBundleId:(NSString *)bundleId;

// v1.7: the latest version of an app that this device can actually run (min iOS <=
// device iOS). Returns nil if no version is compatible. Used so "Install" grabs the
// newest COMPATIBLE build instead of a too-recent one.
- (NSDictionary *)latestCompatibleVersionForBundleId:(NSString *)bundleId;

// YES if this device's iOS is >= the given app/version minimum iOS string ("6.0").
// Unknown/empty min → YES (optimistic, jailbreak-friendly).
- (BOOL)deviceCanRunMinIOS:(NSString *)minOSStr;

// v1.6: AI-generated description + compatibility profile for a catalog entry (by pk).
// Returns nil if the app has no generated description (the ~38k obscure apps).
// Keys when present:
//   @"text"      NSString  — rich App Store style description in the CURRENT app language
//                            (falls back to English if that language is empty)
//   @"demand"    NSString  — "light" | "moderate" | "heavy" | "very_heavy"
//   @"minIOS"    NSString  — "4.3" etc. (may be empty)
//   @"minRAMMB"  NSNumber  — recommended RAM in MB (0 if unknown)
//   @"ipadOnly"  NSNumber  — bool
//   @"issues"    NSString  — (legacy, no longer displayed) AI "known issues" note
- (NSDictionary *)descriptionForPK:(NSInteger)pk;

// v1.7: same description, but resolved by BUNDLE ID instead of pk — so it shows on
// EVERY version of an app (the long-tail per-version rows live in `entries`, whose
// pks have no description; only the one `entries_unique` row per app does).
- (NSDictionary *)descriptionForBundleId:(NSString *)bundleId;

@end
