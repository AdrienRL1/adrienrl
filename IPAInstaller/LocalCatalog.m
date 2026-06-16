#import "LocalCatalog.h"
#import "Localization.h"
#import "HTTPSClient.h"   // first-launch catalog download (via bundled mbedTLS)
#import "MachOInspector.h"  // v3.1: cached FairPlay status when merging community apps
#import <UIKit/UIKit.h>   // UIDevice — for device-iOS icon filtering
#import <sqlite3.h>
#import <zlib.h>          // gunzip the downloaded catalog.db.gz

// The catalog is NO LONGER bundled in the .deb (kept it ~1 MB so it installs on any
// device). It's downloaded once on first launch — gzip'd to ~22 MB — via the app's
// own mbedTLS (which reaches github.io even on old iOS, unlike Cydia/system TLS),
// then cached in Caches/. archive.org/github Pages are both free, no private server.
static NSString *const kCatalogURL = @"https://adrienrl1.github.io/cydia/catalog.db.gz";
static NSString *const kCategoryOverridesURL = @"https://adrienrl1.github.io/cydia/category-overrides.json";  // #156
static NSString *const kCatalogExtrasURL     = @"https://adrienrl1.github.io/cydia/catalog-extras.json";      // v3.1
// #37 de-recommandation : apps pour adultes retirées des surfaces de RECO (accueil/compteurs/mosaïques),
// mais toujours trouvables UNIQUEMENT par recherche textuelle. Format : { "version":N, "hidden":[bid,...] }.
static NSString *const kHiddenAppsURL        = @"https://adrienrl1.github.io/cydia/hidden.json";              // #37
// v3.1 ⇄ v3.2 SWITCH (must match kEnableCatalogType in UploadViewController.m). The community-app
// catalog-extras merge is DEFERRED to v3.2 — methods are KEPT but not called. Flip to YES for v3.2.
static const BOOL kEnableCatalogExtras = YES;   // v3.2 : fusionne les apps contribuées (catégorie « Non triées »)
// Inserted "extra" rows are tagged base_idx = -1 so a re-apply can purge + rebuild them idempotently
// (real catalogue rows always have base_idx >= 0).
// Size (bytes) of the catalog.db.gz we last downloaded — the freshness baseline for
// -checkForCatalogUpdate. Any re-publish re-gzips → a different byte count → triggers a refresh.
static NSString *const kCatalogGzSizeKey = @"IPACatalog.GzSize";

// Posted on the main thread after a background freshness check downloaded a newer catalogue
// and hot-swapped it in place. UI that caches catalogue-derived content should rebuild.
NSString *const LocalCatalogDidUpdateNotification = @"LocalCatalogDidUpdateNotification";

// SQLite-backed catalog: bundled catalog.db in the IPA contains:
//   - entries        (157k rows, all versions)
//   - entries_unique (~50k rows, latest version per bundle id)
//   - urls           (27k url base prefixes)
// All tables indexed on pk DESC, minos, title_lower, bid_lower for instant queries.
// Memory footprint: ~3-5 MB (SQLite's page cache), vs ~80 MB for the in-memory NSArray approach.
// Startup: ~10ms to open the db + first SELECT, vs 3-5s for NSPropertyListSerialization.

// SQL-08: adaptive SQLite page-cache size by device RAM. Negative cache_size = KiB of cache.
// Keep the historical -8000 (≈8 MB) on the 256 MB-class devices (iPad 1 / iPhone 4); give roomier
// machines more cache. Purely a perf knob — it changes no query RESULT.
static void ADApplyAdaptiveCacheSize(sqlite3 *db) {
    if (!db) return;
    unsigned long long ram = [[NSProcessInfo processInfo] physicalMemory];
    const char *pragma;
    if (ram <= 320ULL * 1024 * 1024)        pragma = "PRAGMA cache_size = -8000";    // ≤256 MB → 8 MB (unchanged)
    else if (ram <= 640ULL * 1024 * 1024)   pragma = "PRAGMA cache_size = -16000";   // ≤512 MB → 16 MB
    else                                    pragma = "PRAGMA cache_size = -24000";   // more → 24 MB
    sqlite3_exec(db, pragma, NULL, NULL, NULL);
}

// 0xdead10cc fix (belt-and-suspenders with closeForBackground): take the catalog DB out of any
// data-protection class so iOS can't kill the app for holding the file open while the device is
// locked and the app is suspended. No-op on devices without a passcode (no data protection anyway),
// and safe on jailbroken systems. Covers the main file + any SQLite sidecars.
static void ADSetNoFileProtection(NSString *path) {
    if (!path.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = @{ NSFileProtectionKey: NSFileProtectionNone };
    [fm setAttributes:attr ofItemAtPath:path error:NULL];
    for (NSString *sfx in @[@"-wal", @"-shm", @"-journal"]) {
        NSString *p = [path stringByAppendingString:sfx];
        if ([fm fileExistsAtPath:p]) [fm setAttributes:attr ofItemAtPath:p error:NULL];
    }
}

@interface LocalCatalog ()
@property (nonatomic, assign) sqlite3 *db;
@property (nonatomic, strong) NSDictionary *urls;  // cached at open (only 27k entries, ~2 MB)
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL updateInFlight;   // a background freshness check/update is running
// v3.1 community apps (catalog-extras): in-memory overrides for the inserted rows, since they carry no
// real base_idx/img_pk. Atomic so dictFromRow can read a consistent snapshot off the search queue.
@property (atomic, strong) NSDictionary *extraURLs;   // "bid_lower|version" -> .ipa URL
@property (atomic, strong) NSDictionary *extraIcons;  // "bid_lower"          -> icon URL
// #37 de-recommandation : fragments SQL " NOT IN (...)" construits depuis hidden.json. Atomiques car lus
// depuis _searchQueue. hiddenBidList exclut par bid_lower ; hiddenImgList exclut par img_pk (cat_icon_pool
// n'a pas de colonne bid). nil si aucune app cachée.
@property (atomic, strong) NSString *hiddenBidList;   // "('com.x','com.y',...)" ou nil
@property (atomic, strong) NSString *hiddenImgList;   // "(123,456,...)" ou nil
@end

@implementation LocalCatalog {
    dispatch_queue_t _searchQueue;
    NSString *_dbPath;
    // SQL-01: cache the COUNT(*) for loadMore. The count depends only on (table|whereClause|qLike),
    // not on offset/limit — so paging through a constant filter reuses it. Touched ONLY on _searchQueue
    // (every search, hot-swap, and override/extras re-apply run there), so no extra locking is needed.
    NSString *_countCacheKey;     // table|whereClause|qLike of the cached total, or nil = invalid
    long long _countCacheTotal;   // the memoized COUNT(*) for _countCacheKey
    BOOL _emptyCatalogRetried;    // "0 apps" recovery: re-download an empty cached catalog at most once
}

+ (instancetype)shared {
    static LocalCatalog *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[LocalCatalog alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _searchQueue = dispatch_queue_create("LocalCatalog.search", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (_db) {
        sqlite3_close(_db);
        _db = NULL;
    }
}

- (BOOL)isReady { return self.loaded; }

// Helper: encode "5.0" → 50000, "6.1.3" → 60103 (matches Python build script).
- (NSInteger)encodeIOSVersion:(NSString *)v {
    if (!v.length) return -1;
    NSArray *parts = [v componentsSeparatedByString:@"."];
    NSInteger major = parts.count > 0 ? [parts[0] integerValue] : 0;
    NSInteger minor = parts.count > 1 ? [parts[1] integerValue] : 0;
    NSInteger patch = parts.count > 2 ? [parts[2] integerValue] : 0;
    return major * 10000 + minor * 100 + patch;
}

- (NSString *)decodeIOSVersion:(NSInteger)n {
    return [NSString stringWithFormat:@"%ld.%ld.%ld", (long)(n/10000), (long)((n/100)%100), (long)(n%100)];
}

#pragma mark - Database provisioning (download on first launch)

// Runs on the background _searchQueue (may block). Returns a readable catalog.db path:
//   1. the cached copy in Caches/ (downloaded on a previous launch), if valid;
//   2. the bundled copy (only if a build still ships one — fallback/safety);
//   3. otherwise downloads catalog.db.gz via mbedTLS, gunzips it into Caches/.
- (NSString *)resolveDatabasePathWithProgress:(void (^)(NSString *))progressBlock
                                      errorOut:(NSError **)errOut {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *cached = [caches stringByAppendingPathComponent:@"appdrop_catalog.db"];

    // 1. Valid cached copy.
    if ([fm fileExistsAtPath:cached]) {
        unsigned long long sz = [[fm attributesOfItemAtPath:cached error:NULL] fileSize];
        if (sz > 1000000) return cached;
        [fm removeItemAtPath:cached error:NULL];   // partial/corrupt → re-download
    }

    // 2. Bundled fallback (older builds shipped catalog.db inside the app).
    NSString *bundled = [[NSBundle mainBundle] pathForResource:@"catalog" ofType:@"db"];
    if (bundled) return bundled;

    // 3. Download + gunzip.
    void (^say)(NSString *) = ^(NSString *s) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (progressBlock) progressBlock(s); });
    };
    say(T(@"catalog.downloading"));
    NSString *gzTmp = [cached stringByAppendingString:@".gz"];
    [fm removeItemAtPath:gzTmp error:NULL];

    // Stall watchdog (feedback #14/#83/#146 — iPad 1 / iOS 5.1.1 stuck on "Downloading
    // catalog…" forever). The download must keep making progress: if NO bytes arrive for
    // kCatalogStallTimeout seconds — e.g. an mbedTLS handshake/read that hangs and never
    // honors SO_RCVTIMEO on iOS 5.1.1 — we abort instead of waiting on DISPATCH_TIME_FOREVER.
    // A slow-but-progressing 27 MB download on an iPad 1 is NOT killed; only a true stall is.
    static const NSTimeInterval kCatalogStallTimeout = 90.0;
    __block BOOL ok = NO; __block NSError *dlErr = nil; __block BOOL done = NO; __block BOOL aborted = NO;
    __block NSTimeInterval lastProgress = [NSDate timeIntervalSinceReferenceDate];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [HTTPSClient downloadURL:kCatalogURL
                      toFile:gzTmp
                 isCancelled:^BOOL{
        // Polled inside the recv loop → lets the download thread bail as soon as it can.
        return aborted || ([NSDate timeIntervalSinceReferenceDate] - lastProgress > kCatalogStallTimeout);
    }
                    progress:^(long long received, long long total) {
        lastProgress = [NSDate timeIntervalSinceReferenceDate];
        if (total > 0) {
            int pct = (int)((received * 100) / total);
            say([NSString stringWithFormat:T(@"catalog.downloading_pct"), pct]);
        }
    } completion:^(BOOL success, NSInteger statusCode, NSError *e) {
        ok = success && (statusCode == 200 || statusCode == 0);
        if (!ok && !e) e = [NSError errorWithDomain:@"LocalCatalog" code:statusCode
                                 userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]}];
        dlErr = e;
        done = YES;
        dispatch_semaphore_signal(sem);
    }];
    // Wait in short slices so that a truly stuck recv() (one that never returns, hence never
    // polls isCancelled) cannot pin us forever. If no progress for the timeout, stop waiting
    // and return an error the UI can retry; a still-running download thread ends on its own
    // socket timeout and its late completion signals a semaphore with no waiter (safe).
    while (!done) {
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC))) == 0) break;
        if ([NSDate timeIntervalSinceReferenceDate] - lastProgress > kCatalogStallTimeout) {
            aborted = YES;   // best-effort: ask the download thread to bail
            if (!dlErr) dlErr = [NSError errorWithDomain:@"LocalCatalog" code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"catalog download stalled"}];
            break;
        }
    }

    if (!ok) {
        [fm removeItemAtPath:gzTmp error:NULL];
        if (errOut) *errOut = dlErr;
        return nil;
    }
    // Record the downloaded .gz size as the freshness baseline (checkForCatalogUpdate
    // re-downloads only when GitHub Pages later reports a different size).
    unsigned long long gzSize = [[fm attributesOfItemAtPath:gzTmp error:NULL] fileSize];
    if (gzSize > 0) [[NSUserDefaults standardUserDefaults] setObject:@(gzSize) forKey:kCatalogGzSizeKey];
    say(T(@"catalog.decompressing"));
    BOOL gunzipped = [self gunzipFile:gzTmp toFile:cached];
    [fm removeItemAtPath:gzTmp error:NULL];
    if (!gunzipped) {
        [fm removeItemAtPath:cached error:NULL];
        if (errOut) *errOut = [NSError errorWithDomain:@"LocalCatalog" code:2
                                   userInfo:@{NSLocalizedDescriptionKey: T(@"catalog.decompress_failed")}];
        return nil;
    }
    return cached;
}

// Streamed gunzip (low memory — works on the 256 MB iPad 1). Returns YES on success.
- (BOOL)gunzipFile:(NSString *)src toFile:(NSString *)dst {
    gzFile in = gzopen([src fileSystemRepresentation], "rb");
    if (!in) return NO;
    NSString *part = [dst stringByAppendingString:@".part"];
    FILE *out = fopen([part fileSystemRepresentation], "wb");
    if (!out) { gzclose(in); return NO; }
    char buf[65536];
    int n;
    BOOL ok = YES;
    while ((n = gzread(in, buf, (unsigned)sizeof(buf))) > 0) {
        if (fwrite(buf, 1, (size_t)n, out) != (size_t)n) { ok = NO; break; }
    }
    if (n < 0) ok = NO;
    gzclose(in);
    fclose(out);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (ok) {
        [fm removeItemAtPath:dst error:NULL];
        ok = [fm moveItemAtPath:part toPath:dst error:NULL];
    }
    if (!ok) [fm removeItemAtPath:part error:NULL];
    return ok;
}

#pragma mark - Background freshness check (v2.0)

// Settings → "Clear catalog cache". Drops the freshness baseline (so the next update check always
// re-downloads), deletes the cached .db (the open SQLite handle keeps the running app working until
// the hot-swap / next launch), then triggers an immediate re-download + hot-swap if online. If
// offline, the deleted cache means the next launch re-downloads from scratch.
+ (void)clearCachedCatalog {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kCatalogGzSizeKey];
    [d synchronize];
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *cached = [caches stringByAppendingPathComponent:@"appdrop_catalog.db"];
    [[NSFileManager defaultManager] removeItemAtPath:cached error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:[cached stringByAppendingString:@".gz"] error:NULL];
    [[self shared] checkForCatalogUpdate];   // re-download now (if online)
}

// Cheap freshness probe — safe to call on every launch / foreground. HEADs the remote
// catalog.db.gz; if its size differs from the one we last downloaded, fetches the new
// catalogue and hot-swaps it in place. No-op until loaded, and never runs two at once.
- (void)checkForCatalogUpdate {
    @synchronized (self) {
        if (!self.loaded || self.updateInFlight) return;
        self.updateInFlight = YES;
    }
    [HTTPSClient probeURL:kCatalogURL completion:^(long long totalSize, BOOL rangeSupported, NSError *err) {
        if (totalSize <= 0) {                       // probe failed → retry next launch
            @synchronized (self) { self.updateInFlight = NO; }
            return;
        }
        long long known = [[[NSUserDefaults standardUserDefaults] objectForKey:kCatalogGzSizeKey] longLongValue];
        if (known == totalSize) {                   // already current → nothing to do
            @synchronized (self) { self.updateInFlight = NO; }
            return;
        }
        // Different size on the server → download + hot-swap on a background queue.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            [self performCatalogUpdateExpectingGzSize:totalSize];
        });
    }];
}

// Background: download the new catalog.db.gz, gunzip it, then hot-swap the open SQLite
// handle on the serial _searchQueue (which also serializes every query → no race). The
// cached DB is only ever replaced via an atomic move of a fully-validated file, so a cold
// start stays correct even if the swap or the app is interrupted mid-way.
- (void)performCatalogUpdateExpectingGzSize:(long long)expectedGzSize {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *cached = [caches stringByAppendingPathComponent:@"appdrop_catalog.db"];
    NSString *gzTmp  = [cached stringByAppendingString:@".upd.gz"];
    NSString *dbTmp  = [cached stringByAppendingString:@".upd.db"];
    [fm removeItemAtPath:gzTmp error:NULL];
    [fm removeItemAtPath:dbTmp error:NULL];

    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [HTTPSClient downloadURL:kCatalogURL toFile:gzTmp
                    progress:^(long long received, long long total) { (void)received; (void)total; }
                  completion:^(BOOL success, NSInteger statusCode, NSError *e) {
        ok = success && (statusCode == 200 || statusCode == 0);
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (!ok) { [fm removeItemAtPath:gzTmp error:NULL]; @synchronized (self) { self.updateInFlight = NO; } return; }

    BOOL gunzipped = [self gunzipFile:gzTmp toFile:dbTmp];
    [fm removeItemAtPath:gzTmp error:NULL];
    unsigned long long dbSize = [[fm attributesOfItemAtPath:dbTmp error:NULL] fileSize];
    if (!gunzipped || dbSize < 1000000) {
        [fm removeItemAtPath:dbTmp error:NULL];
        @synchronized (self) { self.updateInFlight = NO; }
        return;
    }

    dispatch_async(_searchQueue, ^{
        // Validate the new DB opens BEFORE discarding the live one.
        sqlite3 *newdb = NULL;
        if (sqlite3_open_v2([dbTmp UTF8String], &newdb,
                            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
            if (newdb) sqlite3_close(newdb);
            [fm removeItemAtPath:dbTmp error:NULL];
            @synchronized (self) { self.updateInFlight = NO; }
            return;
        }
        // Promote temp → canonical cached path (atomic). The old inode stays alive while
        // self.db still has it open, so in-flight reads on it remain valid.
        [fm removeItemAtPath:cached error:NULL];
        [fm moveItemAtPath:dbTmp toPath:cached error:NULL];

        sqlite3_exec(newdb, "PRAGMA mmap_size = 0", NULL, NULL, NULL);   // #171: no mmap → no 0xdead10cc suspend-kill
        ADApplyAdaptiveCacheSize(newdb);                                 // SQL-08: RAM-adaptive page cache
        sqlite3_exec(newdb, "PRAGMA temp_store = MEMORY",   NULL, NULL, NULL);
        sqlite3_busy_timeout(newdb, 4000);   // v3.2.1 : si une écriture (table downloads / extras) verrouille le
                                             // fichier, les LECTURES (catégories, etc.) ATTENDENT au lieu d'échouer
                                             // (sinon SQLITE_BUSY → requête vide → accueil sans catégories).

        NSMutableDictionary *urls = [NSMutableDictionary dictionaryWithCapacity:30000];
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(newdb, "SELECT idx, url FROM urls", -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                int idx = sqlite3_column_int(st, 0);
                const unsigned char *u = sqlite3_column_text(st, 1);
                if (!u) continue;
                NSString *urlStr = [NSString stringWithUTF8String:(const char *)u];
                if (!urlStr.length) continue;
                urls[@(idx)] = urlStr;   // SQL-07: NSNumber key (matches dictFromRow / urlForBaseIdx)
            }
        }
        sqlite3_finalize(st);

        sqlite3 *old = self.db;
        self.db = newdb;
        self.urls = urls;
        _dbPath = [cached copy];
        _countCacheKey = nil;   // SQL-01: new DB → discard the memoized COUNT (still on _searchQueue)
        if (old) sqlite3_close(old);
        [self applyStoredCategoryOverrides];     // #156: re-apply category corrections to the fresh DB
        [self ensureDownloadsTable];             // v3.2 : recréer la table downloads dans le nouveau fichier
        if (kEnableCatalogExtras) [self applyCatalogExtras];     // v3.2 (deferred): re-merge community apps
        [self applyStoredHiddenApps];            // #37 : reconstruire la de-recommandation sur le nouveau DB

        if (expectedGzSize > 0)
            [[NSUserDefaults standardUserDefaults] setObject:@(expectedGzSize) forKey:kCatalogGzSizeKey];
        @synchronized (self) { self.updateInFlight = NO; }

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:LocalCatalogDidUpdateNotification object:nil];
        });
    });
}

#pragma mark - Load

- (void)loadWithProgress:(void (^)(NSString *))progressBlock
              completion:(void (^)(BOOL, NSError *))completion {
    if (self.loaded) {
        if (completion) completion(YES, nil);
        return;
    }
    dispatch_async(_searchQueue, ^{
        if (self.loaded) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(YES, nil); });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (progressBlock) progressBlock(T(@"catalog.loading"));
        });

        // Resolve the DB path: cached download → bundled (if still shipped) → download.
        NSError *resolveErr = nil;
        NSString *path = [self resolveDatabasePathWithProgress:progressBlock errorOut:&resolveErr];
        if (!path) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, resolveErr ?:
                    [NSError errorWithDomain:@"LocalCatalog" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: T(@"catalog.unavailable")}]);
            });
            return;
        }
        _dbPath = [path copy];
        ADSetNoFileProtection(_dbPath);   // 0xdead10cc: keep the file out of any data-protection class

        // #171: FULLMUTEX (was NOMUTEX). Several read methods (versionsForBundleId, categoryCounts,
        // iconPoolForCategory, uniqueAppCount…) run sqlite3_* on the CALLING thread — often the main
        // thread (e.g. RevivalCatalog.appDicts looks up icons). A NOMUTEX connection used from the
        // main thread WHILE _searchQueue runs a search = concurrent access to a single-thread handle
        // → EXC_BAD_ACCESS inside libsqlite3 (the SIGSEGV auto-crashes #110/#131/#134). FULLMUTEX
        // makes SQLite serialize access with its own per-connection mutex, so it's crash-safe.
        sqlite3 *db = NULL;
        int rc = sqlite3_open_v2([_dbPath UTF8String], &db,
                                   SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                                   NULL);
        if (rc != SQLITE_OK) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO,
                    [NSError errorWithDomain:@"LocalCatalog" code:rc
                                    userInfo:@{NSLocalizedDescriptionKey:
                                               [NSString stringWithFormat:@"sqlite3_open: %s",
                                                  sqlite3_errmsg(db)]}]);
            });
            if (db) sqlite3_close(db);
            return;
        }
        // #171: mmap_size MUST stay 0. A memory-mapped file in Library/Caches held across app
        // SUSPENSION makes iOS kill the app with 0xdead10cc ("was suspended with locked system
        // files: appdrop_catalog.db") — the #1 source of auto crash reports on iOS 5/6/7. A readonly
        // connection holds no lock between queries, so dropping mmap removes the only thing iOS sees
        // held across suspension. Indexed queries stay fast via the page cache below.
        sqlite3_exec(db, "PRAGMA mmap_size = 0", NULL, NULL, NULL);          // no mmap → no 0xdead10cc
        ADApplyAdaptiveCacheSize(db);                                        // SQL-08: RAM-adaptive page cache
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", NULL, NULL, NULL);
        sqlite3_busy_timeout(db, 4000);   // v3.2.1 : lectures attendent les écritures concurrentes (table
                                          // downloads/extras) au lieu d'échouer en SQLITE_BUSY → plus d'accueil vide.

        // Pre-load all urls.
        NSMutableDictionary *urls = [NSMutableDictionary dictionaryWithCapacity:30000];
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT idx, url FROM urls", -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                int idx = sqlite3_column_int(st, 0);
                const unsigned char *u = sqlite3_column_text(st, 1);
                if (!u) continue;
                NSString *urlStr = [NSString stringWithUTF8String:(const char *)u];
                if (!urlStr.length) continue;  // invalid UTF-8 or empty — skip the row
                urls[@(idx)] = urlStr;   // SQL-07: NSNumber key (matches dictFromRow / urlForBaseIdx)
            }
        }
        sqlite3_finalize(st);

        // Count for status reporting
        long long entryCount = 0;
        if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM entries_unique", -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW) entryCount = sqlite3_column_int64(st, 0);
        }
        sqlite3_finalize(st);

        // "0 apps" recovery (feedback #222/#226/#243/#257/#272/#277…): a CACHED catalog that opens
        // but is EMPTY (a truncated/corrupt download that still passed the >1 MB size check) would
        // otherwise leave the user stuck on an empty app forever. If the opened catalog has 0 apps
        // and it's the cached download (not the bundled fallback), drop it + the freshness baseline
        // and re-download — once per session, so a genuinely-empty source can't loop.
        BOOL isCachedDownload = ([_dbPath rangeOfString:@"appdrop_catalog.db"].location != NSNotFound);
        if (entryCount == 0 && isCachedDownload && !_emptyCatalogRetried) {
            _emptyCatalogRetried = YES;
            sqlite3_close(db);
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:_dbPath error:NULL];
            [fm removeItemAtPath:[_dbPath stringByAppendingString:@".gz"] error:NULL];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCatalogGzSizeKey];
            _dbPath = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self loadWithProgress:progressBlock completion:completion];   // loaded is still NO → re-resolves + re-downloads
            });
            return;
        }

        self.db = db;
        self.urls = urls;
        self.loaded = YES;
        [self ensureDownloadsTable];           // v3.2 : table downloads prête pour le tri SQL (rapide, gardée avant l'affichage)

        // A1 (démarrage encore plus rapide + tout en arrière-plan) : on AFFICHE l'accueil dès que le catalogue
        // en cache est ouvert (completion ci-dessous), PUIS on fait l'enrichissement (corrections de catégories
        // + apps contribuées + refreshes réseau) en ARRIÈRE-PLAN. L'enrichissement est mis en file APRÈS la
        // 1re collecte de l'accueil (déclenchée par completion → buildContent → performRead, donc en tête de la
        // file sérielle), puis poste LocalCatalogDidUpdateNotification → l'accueil se reconstruit avec les données
        // fusionnées. Rien ne bloque l'UI ; le catalogue se met à jour tout seul.
        __weak typeof(self) ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (progressBlock) progressBlock([NSString stringWithFormat:@"Catalogue : %lld apps", entryCount]);
            if (completion) completion(YES, nil);   // accueil affiché MAINTENANT (catalogue en cache)
            [ws performRead:^{                       // enrichissement en arrière-plan, APRÈS la 1re collecte
                if (!ws) return;
                // Le catalogue en cache contient déjà la fusion du dernier lancement (lignes base_idx=-1
                // persistées) → le 1er affichage montre déjà les apps contribuées. Ces appels ré-assurent la
                // cohérence (idempotents) — surtout après une re-décompression fraîche du catalogue. Pas de
                // notification de rebuild explicite ici (redondante, éviterait un clignotement) : les refreshes
                // réseau ci-dessous postent LocalCatalogDidUpdateNotification SEULEMENT s'ils apportent du neuf.
                [ws applyStoredCategoryOverrides];                      // #156 : corrections de catégories en cache
                if (kEnableCatalogExtras) [ws applyCatalogExtras];      // v3.2 : fusionne les apps contribuées
                [ws applyStoredHiddenApps];                            // #37 : de-recommandation en cache
                [ws refreshCategoryOverrides];                         // #156 : réseau → applique + notifie si nouveau
                if (kEnableCatalogExtras) [ws refreshCatalogExtras];   // v3.2 : réseau → applique + notifie si nouveau
                [ws refreshHiddenApps];                                // #37 : réseau → applique + notifie si nouveau
            }];
        });
    });
}

// 0xdead10cc fix: close the open catalog handle when the app is backgrounded. Set loaded=NO FIRST
// (on the calling/main thread) so any further read bails on its (loaded && db) guard before we touch
// the handle; then close on _searchQueue so it runs AFTER any in-flight search on that serial queue.
// loadWithProgress: (called on foreground) reopens the cached file — no re-download.
- (void)closeForBackgroundCompletion:(void (^)(void))completion {
    self.loaded = NO;
    dispatch_async(_searchQueue, ^{
        if (self.db) { sqlite3_close(self.db); self.db = NULL; }
        self->_countCacheKey = nil;
        if (completion) completion();
    });
}

#pragma mark - Search

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
                    completion:(void (^)(NSDictionary *))completion {
    dispatch_async(_searchQueue, ^{
        NSDictionary *res = [self searchWithQuery:q minIOS:minIOSStr maxIOS:maxIOSStr
                                            unique:unique sort:sortKey
                                        descending:descending
                                       deviceClass:deviceClass
                                          category:category subgenre:subgenre
                                            offset:offset limit:limit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(res);
        });
    });
}

- (void)performRead:(dispatch_block_t)block {
    if (!block) return;
    dispatch_async(_searchQueue, block);   // serial queue → safe self.db access, off the main thread
}

// v3.2 — SQL predicate matching `category`, treating "Uncategorized" (the « Non triées » bucket)
// as ALSO covering rows whose category is NULL/empty. The catalogue tags some apps with no
// category at all, and contributed apps come in as "Uncategorized"; both must land in the same
// « Non triées » tile/list. Category value is escaped for inline use.
static NSString *ADCategoryPredicate(NSString *category) {
    if ([category isEqualToString:@"Uncategorized"])
        return @"(category IS NULL OR category = '' OR category = 'Uncategorized')";
    NSString *c = [category stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
    return [NSString stringWithFormat:@"category = '%@'", c];
}

- (NSDictionary *)searchWithQuery:(NSString *)q
                            minIOS:(NSString *)minIOSStr
                            maxIOS:(NSString *)maxIOSStr
                             unique:(BOOL)unique
                               sort:(NSString *)sortKey
                        descending:(BOOL)descending
                       deviceClass:(NSString *)deviceClass
                          category:(NSString *)category
                          subgenre:(NSString *)subgenre
                             offset:(NSInteger)offset
                              limit:(NSInteger)limit {
    if (!self.loaded || !self.db) {
        return @{@"error": @"catalog not loaded", @"results": @[], @"total": @0};
    }

    NSString *table = unique ? @"entries_unique" : @"entries";
    NSString *qLower = [[q stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    NSString *qLike = qLower.length ? [NSString stringWithFormat:@"%%%@%%", qLower] : nil;
    NSInteger minMin = [self encodeIOSVersion:minIOSStr];
    NSInteger maxMin = [self encodeIOSVersion:maxIOSStr];

    NSMutableString *whereClause = [NSMutableString string];
    if (qLike) [whereClause appendString:@" AND (title_lower LIKE ?1 OR bid_lower LIKE ?1)"];
    if (minMin >= 0) [whereClause appendString:[NSString stringWithFormat:@" AND minos >= %ld", (long)minMin]];
    if (maxMin >= 0) {
        // In unique (browse) mode an app is "compatible" if it has ANY version whose
        // minimum iOS is <= maxIOS — use the precomputed min_minos so apps with a
        // runnable older version stay visible and pure iOS 11+ apps drop out. In
        // per-version mode (entries) the row's own minos applies.
        NSString *maxCol = unique ? @"min_minos" : @"minos";
        [whereClause appendString:[NSString stringWithFormat:@" AND %@ <= %ld", maxCol, (long)maxMin]];
    }
    // Device class : bitmask plat field. iPhone bit = 2, iPad bit = 4.
    // "iphone" = app supports iPhone (works on iPhone+iPod and on iPad in compat mode).
    // "ipad"   = app supports iPad (works on iPad only).
    if ([deviceClass isEqualToString:@"iphone"]) {
        [whereClause appendString:@" AND (plat & 2) != 0"];
    } else if ([deviceClass isEqualToString:@"ipad"]) {
        [whereClause appendString:@" AND (plat & 4) != 0"];
    }
    // v1.7: category browse filter. Only entries_unique carries the category column,
    // so this applies in unique (browse) mode — which is what the category menu uses.
    if (unique && category.length) {
        [whereClause appendString:[@" AND " stringByAppendingString:ADCategoryPredicate(category)]];
        if (subgenre.length) {
            NSString *s = [subgenre stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
            [whereClause appendString:[NSString stringWithFormat:@" AND subgenre = '%@'", s]];
        }
    }
    // #37 : en NAVIGATION (pas en recherche), retirer les apps de-recommandées de la liste — elles
    // restent trouvables UNIQUEMENT par recherche textuelle.
    if (!qLike) [whereClause appendString:[self hiddenExclusionForBidColumn:@"bid_lower"]];
    // (Suspect-file SQL filter removed in v2.0.8 — too many false positives.
    //  See AppDetailViewController for per-row install-time mismatch alert.)

    // ORDER BY honors the user-selected direction. Column choice depends on `sortKey`.
    NSString *dir = descending ? @"DESC" : @"ASC";
    NSString *orderCol = @"pk";  // default = recent ordering (by primary key)
    if ([sortKey isEqualToString:@"name"]) orderCol = @"title_lower";
    else if ([sortKey isEqualToString:@"size"]) orderCol = @"size_kb";
    else if ([sortKey isEqualToString:@"minos"]) orderCol = @"minos";
    else if ([sortKey isEqualToString:@"downloads"]) {
        // v3.2: tri par nombre de téléchargements (table `downloads` remplie par les stats Cloudflare).
        // Sous-requête corrélée sur bid_lower (présent dans entries ET entries_unique ; downloads.bid_lower
        // est la clé primaire → lookup indexé). Les apps sans compteur (NULL) tombent en bas en DESC.
        // Garde : si la table n'existe pas encore (catalogue read-only / pas de stats), on retombe sur pk
        // pour que la liste ne soit JAMAIS vide.
        if ([self downloadsTableExists]) {
            orderCol = [NSString stringWithFormat:
                @"(SELECT count FROM downloads WHERE downloads.bid_lower = %@.bid_lower)", table];
        }
    }
    NSString *orderBy = [NSString stringWithFormat:@"%@ %@", orderCol, dir];

    // Count + data in two queries — both indexed, so each is sub-millisecond.
    // SQL-01: COUNT(*) depends only on (table, whereClause, qLike) — NOT on offset/limit. When
    // loadMore pages through a constant filter (same key, growing offset), reuse the memoized total
    // and skip prepare+step+finalize of the COUNT entirely. All accesses are on _searchQueue.
    long long total = 0;
    NSString *countKey = [NSString stringWithFormat:@"%@|%@|%@", table, whereClause, qLike ?: @""];
    if (_countCacheKey && [_countCacheKey isEqualToString:countKey]) {
        total = _countCacheTotal;
    } else {
        NSString *countSQL = [NSString stringWithFormat:@"SELECT COUNT(*) FROM %@ WHERE 1=1%@",
                                                           table, whereClause];
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(self.db, [countSQL UTF8String], -1, &st, NULL) == SQLITE_OK) {
            if (qLike) sqlite3_bind_text(st, 1, [qLike UTF8String], -1, SQLITE_TRANSIENT);
            if (sqlite3_step(st) == SQLITE_ROW) total = sqlite3_column_int64(st, 0);
        }
        sqlite3_finalize(st);
        _countCacheKey = countKey;
        _countCacheTotal = total;
    }

    NSString *cols = @"pk, plat, minos, title, bid, version, base_idx, filename, size_kb, img_pk";
    if (unique) cols = [cols stringByAppendingString:@", min_minos"];   // extra col 10
    // SQL-02: LIMIT/OFFSET are bound (?2/?3) instead of interpolated. ?1 is the LIKE param (when qLike);
    // whereClause's category/subgenre stay interpolated as before. Prepare+finalize per page (no shared stmt).
    NSString *dataSQL = [NSString stringWithFormat:
        @"SELECT %@ FROM %@ WHERE 1=1%@ ORDER BY %@ LIMIT ?2 OFFSET ?3",
        cols, table, whereClause, orderBy];

    NSMutableArray *results = [NSMutableArray arrayWithCapacity:limit];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(self.db, [dataSQL UTF8String], -1, &st, NULL) == SQLITE_OK) {
        if (qLike) sqlite3_bind_text(st, 1, [qLike UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 2, (sqlite3_int64)limit);
        sqlite3_bind_int64(st, 3, (sqlite3_int64)offset);
        while (sqlite3_step(st) == SQLITE_ROW) {
            NSMutableDictionary *d = [[self dictFromRow:st] mutableCopy];
            if (unique) {
                // Show the LOWEST iOS the app supports (across all its versions), not
                // the latest version's — so a tile reflects what the device can run.
                NSInteger mm = sqlite3_column_int(st, 10);
                if (mm > 0) d[@"minOS"] = [self decodeIOSVersion:mm];
                d[@"minMinos"] = @(mm);
            }
            [results addObject:d];
        }
    }
    sqlite3_finalize(st);

    return @{
        @"total": @(total),
        @"offset": @(offset),
        @"limit": @(limit),
        @"results": results,
    };
}

#pragma mark - Category browse (v1.7)

// Build the github-pages icon URL for an img_pk (same scheme as dictFromRow).
static NSString *iconURLForImgPk(long imgPk) {
    if (imgPk <= 0) return nil;
    return [NSString stringWithFormat:
            @"https://stuffed18.github.io/ipa-archive-updated/data/%ld/%ld.jpg",
            imgPk / 1000, imgPk];
}

- (NSArray *)categoryCounts {
    if (!self.loaded || !self.db) return @[];
    NSMutableArray *out = [NSMutableArray array];
    // Count only apps that have a version runnable on THIS device (min_minos <= device
    // iOS), so the card counts match the category lists and exclude iOS 11+-only apps.
    // v3.2 : les apps sans catégorie (NULL/vide) sont regroupées sous « Uncategorized » (tuile
    // « Non triées ») au lieu d'être ignorées, pour qu'elles soient triables comme les autres.
    NSString *sqlStr = [NSString stringWithFormat:
        @"SELECT CASE WHEN category IS NULL OR category = '' THEN 'Uncategorized' ELSE category END AS cat, "
        @"COUNT(*) FROM entries_unique "
        @"WHERE min_minos <= %ld%@%@ "
        @"GROUP BY cat ORDER BY COUNT(*) DESC",
        (long)[self deviceMaxMinos], [self deviceIdiomPlatClause],
        [self hiddenExclusionForBidColumn:@"bid_lower"]];   // #37 : exclure les apps de-recommandées des compteurs
    const char *sql = [sqlStr UTF8String];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(self.db, sql, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char *cat = sqlite3_column_text(st, 0);
            NSString *c = cat ? [NSString stringWithUTF8String:(const char *)cat] : nil;
            if (c.length) [out addObject:@{@"category": c, @"count": @(sqlite3_column_int(st, 1))}];
        }
    }
    sqlite3_finalize(st);
    return out;
}

- (NSArray *)subgenreCountsForCategory:(NSString *)category {
    if (!self.loaded || !self.db || !category.length) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSString *sql = [NSString stringWithFormat:
                    @"SELECT subgenre, COUNT(*) FROM entries_unique "
                    @"WHERE category=?1 AND subgenre IS NOT NULL AND subgenre<>'' "
                    @"AND min_minos <= %ld%@%@ "
                    @"GROUP BY subgenre ORDER BY COUNT(*) DESC",
                    (long)[self deviceMaxMinos], [self deviceIdiomPlatClause],
                    [self hiddenExclusionForBidColumn:@"bid_lower"]];   // #37
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(self.db, [sql UTF8String], -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, [category UTF8String], -1, SQLITE_TRANSIENT);
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char *sub = sqlite3_column_text(st, 0);
            NSString *s = sub ? [NSString stringWithUTF8String:(const char *)sub] : nil;
            if (s.length) [out addObject:@{@"subgenre": s, @"count": @(sqlite3_column_int(st, 1))}];
        }
    }
    sqlite3_finalize(st);
    return out;
}

// v1.7: pool of representative icon URLs for a category (the ~16 biggest apps with
// an icon, precomputed in cat_icon_pool at build time). The UI picks one at random
// each time it shows, so the category cards vary. Returns [] if the table is absent.
// Highest min-iOS the running device can handle (encoded). Apps with minos<=this
// are runnable; minos=0 (no minimum declared) always passes.
- (NSInteger)deviceMaxMinos {
    NSInteger m = [self encodeIOSVersion:[[UIDevice currentDevice] systemVersion]];
    return (m < 0) ? 999999 : m;
}

- (BOOL)deviceCanRunMinIOS:(NSString *)minOSStr {
    NSInteger m = [self encodeIOSVersion:minOSStr];
    if (m < 0) return YES;   // unknown min → assume runnable (jailbreak: try it)
    return m <= [self deviceMaxMinos];
}

// SQL fragment that keeps only apps THIS device's idiom can actually run. An iPhone/iPod
// CANNOT run iPad-only apps, so on a phone we require the iPhone plat bit (2). An iPad runs
// iPhone apps in compatibility mode too, so on iPad we don't filter. Returns "" on iPad.
// Used by the Accueil counts + icon mosaics, which otherwise recommended iPad-only apps on iPhone.
// (The catalog/search/category LISTS already filter via CatalogFilter.deviceClass; these home-screen
// summaries are the only surfaces that didn't.) NOTE: `cat_icon_pool` has no plat column, so this
// only applies to entries_unique queries — on iPhone the mosaics source from entries_unique instead.
- (NSString *)deviceIdiomPlatClause {
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) return @"";
    return @" AND (plat & 2) != 0";
}

- (NSArray *)iconPoolForCategory:(NSString *)category {
    if (!self.loaded || !self.db || !category.length) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *platClause = [self deviceIdiomPlatClause];   // "" on iPad, " AND (plat&2)!=0" on iPhone
    // 1. Curated, device-runnable icons (minos <= device iOS), biggest apps first.
    //    cat_icon_pool has NO plat column, so on iPhone (where iPad-only apps must be hidden) we
    //    SKIP it and source from entries_unique below (which has plat). iPad runs everything → use it.
    if (platClause.length == 0) {
        NSString *sqlStr = [NSString stringWithFormat:
            @"SELECT img_pk FROM cat_icon_pool WHERE category=?1 AND minos<=?2%@ "
            @"ORDER BY rn_cat LIMIT 24", [self hiddenExclusionForImgColumn:@"img_pk"]];   // #37
        const char *sql = [sqlStr UTF8String];
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(self.db, sql, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, [category UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(st, 2, [self deviceMaxMinos]);
            while (sqlite3_step(st) == SQLITE_ROW) {
                int pk = sqlite3_column_int(st, 0);
                NSString *u = iconURLForImgPk(pk);
                if (u && ![seen containsObject:@(pk)]) { [seen addObject:@(pk)]; [out addObject:u]; }
            }
        }
        sqlite3_finalize(st);
    }

    // 2. entries_unique source — PRIMARY on iPhone (with the plat filter so no iPad-only icons),
    // and a top-up on iPad when the curated set is THIN (<6). Some categories' biggest apps all
    // need iOS 7+ — e.g. Social Networking has just 1 curated icon this device can run, Finance has
    // 0 — so the card would never reshuffle. entries_unique still has hundreds of smaller
    // device-runnable apps with icons, giving a varied pool of REAL example icons. Deduped by img_pk.
    if (out.count < 6) {
        // v3.2 : ADCategoryPredicate gère « Uncategorized » = catégorie NULL/vide (tuile « Non triées »).
        NSString *fsqlStr = [NSString stringWithFormat:
                           @"SELECT img_pk FROM entries_unique WHERE %@ AND min_minos<=?1 "
                           @"AND img_pk>0%@%@ ORDER BY size_kb DESC LIMIT 24", ADCategoryPredicate(category), platClause,
                           [self hiddenExclusionForBidColumn:@"bid_lower"]];   // #37
        const char *fsql = [fsqlStr UTF8String];
        sqlite3_stmt *f = NULL;
        if (sqlite3_prepare_v2(self.db, fsql, -1, &f, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(f, 1, [self deviceMaxMinos]);
            while (sqlite3_step(f) == SQLITE_ROW) {
                int pk = sqlite3_column_int(f, 0);
                NSString *u = iconURLForImgPk(pk);
                if (u && ![seen containsObject:@(pk)]) { [seen addObject:@(pk)]; [out addObject:u]; }
            }
        }
        sqlite3_finalize(f);
    }
    return out;
}

- (NSArray *)iconPoolForCategory:(NSString *)category subgenre:(NSString *)subgenre {
    if (!self.loaded || !self.db || !category.length || !subgenre.length) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *platClause = [self deviceIdiomPlatClause];   // "" on iPad, " AND (plat&2)!=0" on iPhone
    // cat_icon_pool has no plat column → skip it on iPhone (source from entries_unique below instead).
    if (platClause.length == 0) {
        NSString *sqlStr = [NSString stringWithFormat:
            @"SELECT img_pk FROM cat_icon_pool WHERE category=?1 AND subgenre=?2 "
            @"AND minos<=?3%@ ORDER BY rn_sub LIMIT 24", [self hiddenExclusionForImgColumn:@"img_pk"]];   // #37
        const char *sql = [sqlStr UTF8String];
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(self.db, sql, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, [category UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 2, [subgenre UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(st, 3, [self deviceMaxMinos]);
            while (sqlite3_step(st) == SQLITE_ROW) {
                int pk = sqlite3_column_int(st, 0);
                NSString *u = iconURLForImgPk(pk);
                if (u && ![seen containsObject:@(pk)]) { [seen addObject:@(pk)]; [out addObject:u]; }
            }
        }
        sqlite3_finalize(st);
    }

    // entries_unique source — PRIMARY on iPhone (plat-filtered), top-up on iPad when THIN (<6), so a
    // subgenre whose biggest apps all need a newer iOS still gets a varied set of real example icons.
    if (out.count < 6) {
        NSString *fsqlStr = [NSString stringWithFormat:
                           @"SELECT img_pk FROM entries_unique WHERE category=?1 AND subgenre=?2 "
                           @"AND min_minos<=?3 AND img_pk>0%@%@ ORDER BY size_kb DESC LIMIT 24", platClause,
                           [self hiddenExclusionForBidColumn:@"bid_lower"]];   // #37
        const char *fsql = [fsqlStr UTF8String];
        sqlite3_stmt *f = NULL;
        if (sqlite3_prepare_v2(self.db, fsql, -1, &f, NULL) == SQLITE_OK) {
            sqlite3_bind_text(f, 1, [category UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(f, 2, [subgenre UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(f, 3, [self deviceMaxMinos]);
            while (sqlite3_step(f) == SQLITE_ROW) {
                int pk = sqlite3_column_int(f, 0);
                NSString *u = iconURLForImgPk(pk);
                if (u && ![seen containsObject:@(pk)]) { [seen addObject:@(pk)]; [out addObject:u]; }
            }
        }
        sqlite3_finalize(f);
    }
    return out;
}

- (NSInteger)uniqueAppCount {
    if (!self.loaded || !self.db) return 0;
    NSInteger n = 0;
    NSString *sql = [NSString stringWithFormat:
        @"SELECT COUNT(*) FROM entries_unique WHERE min_minos <= %ld", (long)[self deviceMaxMinos]];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(self.db, [sql UTF8String], -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int(st, 0);
    }
    sqlite3_finalize(st);
    return n;
}

#pragma mark - Téléchargements (v3.2)

// YES si la table `downloads` existe dans la connexion read-only courante (self.db).
- (BOOL)downloadsTableExists {
    if (!self.db) return NO;
    BOOL exists = NO;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(self.db,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='downloads' LIMIT 1",
            -1, &st, NULL) == SQLITE_OK) {
        exists = (sqlite3_step(st) == SQLITE_ROW);
    }
    sqlite3_finalize(st);
    return exists;
}

// Garantit que la table `downloads(bid_lower, count)` existe dans le fichier catalog.db, pour que la
// sous-requête de tri `sort=downloads` puisse toujours préparer (même avant toute fusion de stats).
// Écrit via une 2e connexion read-write (self.db reste read-only). À appeler sur _searchQueue.
- (void)ensureDownloadsTable {
    if (!_dbPath.length) return;
    sqlite3 *wdb = NULL;
    if (sqlite3_open_v2([_dbPath UTF8String], &wdb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (wdb) sqlite3_close(wdb);
        return;   // DB read-only sur disque → tant pis (le tri retombera vide, sans planter)
    }
    sqlite3_busy_timeout(wdb, 4000);   // v3.2.1 : attendre un éventuel verrou plutôt qu'échouer
    sqlite3_exec(wdb, "CREATE TABLE IF NOT EXISTS downloads (bid_lower TEXT PRIMARY KEY, count INTEGER)",
                 NULL, NULL, NULL);
    sqlite3_close(wdb);
}

- (void)mergeDownloadCounts:(NSDictionary *)bidLowerToCount {
    if (![bidLowerToCount isKindOfClass:[NSDictionary class]] || !bidLowerToCount.count) return;
    NSDictionary *snapshot = [bidLowerToCount copy];
    dispatch_async(_searchQueue, ^{
        if (!self->_dbPath.length) return;
        sqlite3 *wdb = NULL;
        if (sqlite3_open_v2([self->_dbPath UTF8String], &wdb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
            if (wdb) sqlite3_close(wdb);
            return;
        }
        sqlite3_busy_timeout(wdb, 4000);   // v3.2.1 : attendre un verrou plutôt qu'échouer (lectures protégées)
        sqlite3_exec(wdb, "CREATE TABLE IF NOT EXISTS downloads (bid_lower TEXT PRIMARY KEY, count INTEGER)", NULL, NULL, NULL);
        sqlite3_exec(wdb, "BEGIN", NULL, NULL, NULL);
        sqlite3_stmt *ins = NULL;
        if (sqlite3_prepare_v2(wdb, "INSERT OR REPLACE INTO downloads (bid_lower, count) VALUES (?,?)", -1, &ins, NULL) == SQLITE_OK) {
            for (NSString *bid in snapshot) {
                if (![bid isKindOfClass:[NSString class]]) continue;
                NSNumber *c = snapshot[bid];
                if (![c isKindOfClass:[NSNumber class]]) continue;
                sqlite3_reset(ins);
                sqlite3_bind_text(ins, 1, [bid UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_int64(ins, 2, (sqlite3_int64)[c longLongValue]);
                sqlite3_step(ins);
            }
        }
        sqlite3_finalize(ins);
        sqlite3_exec(wdb, "COMMIT", NULL, NULL, NULL);
        sqlite3_close(wdb);
    });
}

- (NSArray *)topDownloadedIconURLs:(NSInteger)n {
    if (!self.loaded || !self.db || n <= 0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *platClause = [self deviceIdiomPlatClause];   // "" sur iPad, " AND (plat&2)!=0" sur iPhone
    NSString *sqlStr = [NSString stringWithFormat:
        @"SELECT e.img_pk FROM entries_unique e JOIN downloads d ON d.bid_lower = e.bid_lower "
        @"WHERE d.count > 0 AND e.min_minos <= ?1 AND e.img_pk > 0%@%@ "
        @"ORDER BY d.count DESC LIMIT ?2", platClause,
        [self hiddenExclusionForBidColumn:@"e.bid_lower"]];   // #37
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(self.db, [sqlStr UTF8String], -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(st, 1, [self deviceMaxMinos]);
        sqlite3_bind_int64(st, 2, (sqlite3_int64)n);
        while (sqlite3_step(st) == SQLITE_ROW) {
            int pk = sqlite3_column_int(st, 0);
            NSString *u = iconURLForImgPk(pk);
            if (u && ![seen containsObject:@(pk)]) { [seen addObject:@(pk)]; [out addObject:u]; }
        }
    }
    sqlite3_finalize(st);
    // Early on, few apps have any recorded downloads yet (the stats backend is fresh), so the JOIN
    // above can return fewer than n — the tile would then show a lone icon instead of a full 2×2
    // mosaic. Top up with the biggest device-runnable apps (deduped) so the preview always looks
    // complete. This only affects the tile's PREVIEW icons; the list itself is still sorted by
    // downloads when tapped.
    if ((NSInteger)out.count < n) {
        NSString *fillStr = [NSString stringWithFormat:
            @"SELECT img_pk FROM entries_unique WHERE min_minos <= ?1 AND img_pk > 0%@%@ "
            @"ORDER BY size_kb DESC LIMIT ?2", platClause,
            [self hiddenExclusionForBidColumn:@"bid_lower"]];   // #37
        sqlite3_stmt *f = NULL;
        if (sqlite3_prepare_v2(self.db, [fillStr UTF8String], -1, &f, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(f, 1, [self deviceMaxMinos]);
            sqlite3_bind_int64(f, 2, (sqlite3_int64)(n * 4));   // headroom for dedupe collisions
            while ((NSInteger)out.count < n && sqlite3_step(f) == SQLITE_ROW) {
                int pk = sqlite3_column_int(f, 0);
                NSString *u = iconURLForImgPk(pk);
                if (u && ![seen containsObject:@(pk)]) { [seen addObject:@(pk)]; [out addObject:u]; }
            }
        }
        sqlite3_finalize(f);
    }
    return out;
}

// v1.7: the most recent version of `bundleId` runnable on this device (min iOS <=
// device iOS). versionsForBundleId is ordered version DESC, pk DESC, so the FIRST
// compatible hit is the latest compatible version. Returns nil if none exist.
- (NSDictionary *)latestCompatibleVersionForBundleId:(NSString *)bundleId {
    if (!bundleId.length) return nil;
    NSInteger dev = [self deviceMaxMinos];
    for (NSDictionary *v in [self versionsForBundleId:bundleId]) {
        if ([self encodeIOSVersion:v[@"minOS"]] <= dev) return v;
    }
    return nil;
}

// Convert one sqlite3 row to the NSDictionary shape the UI expects.
- (NSDictionary *)dictFromRow:(sqlite3_stmt *)st {
    NSInteger pk = sqlite3_column_int(st, 0);
    NSInteger plat = sqlite3_column_int(st, 1);
    NSInteger minOS = sqlite3_column_int(st, 2);
    const unsigned char *title = sqlite3_column_text(st, 3);
    const unsigned char *bid = sqlite3_column_text(st, 4);
    const unsigned char *version = sqlite3_column_text(st, 5);
    NSInteger baseIdx = sqlite3_column_int(st, 6);
    const unsigned char *filename = sqlite3_column_text(st, 7);
    long long sizeKB = sqlite3_column_int64(st, 8);
    NSInteger imgPk = sqlite3_column_int(st, 9);

    // stringWithUTF8String returns nil on invalid UTF-8 → would crash on @{...nil...} below.
    // Always coerce to empty string.
    NSString *titleStr = (title ? [NSString stringWithUTF8String:(const char *)title] : nil) ?: @"";
    NSString *bidStr = (bid ? [NSString stringWithUTF8String:(const char *)bid] : nil) ?: @"";
    NSString *versionStr = (version ? [NSString stringWithUTF8String:(const char *)version] : nil) ?: @"";
    NSString *filenameStr = (filename ? [NSString stringWithUTF8String:(const char *)filename] : nil) ?: @"";

    NSString *baseURL = self.urls[@(baseIdx)] ?: @"";   // SQL-07: NSNumber key (matches urls build)
    if (baseURL.length && ![baseURL hasSuffix:@"/"]) baseURL = [baseURL stringByAppendingString:@"/"];
    NSString *ipaURL = (baseURL.length && filenameStr.length)
        ? [baseURL stringByAppendingString:filenameStr] : @"";
    NSString *iconURL = [NSString stringWithFormat:@"https://stuffed18.github.io/ipa-archive-updated/data/%ld/%ld.jpg",
                          (long)(imgPk / 1000), (long)imgPk];

    // v3.1: community apps (catalog-extras) carry no real base_idx/img_pk — resolve their .ipa URL
    // (by bid|version) and icon (by bid) from the in-memory side-maps. Also lets a contributed
    // decrypted build replace the URL of a known-encrypted catalogue version.
    NSDictionary *eu = self.extraURLs, *ei = self.extraIcons;
    if (eu.count && bidStr.length) {
        NSString *u = eu[[NSString stringWithFormat:@"%@|%@", [bidStr lowercaseString], versionStr]];
        if (u.length) ipaURL = u;
    }
    if (ei.count && bidStr.length) {
        NSString *ic = ei[[bidStr lowercaseString]];
        if (ic.length) iconURL = ic;
    }

    return @{
        @"id": @(pk),
        @"title": titleStr,
        @"bundleId": bidStr,
        @"version": versionStr,
        @"minOS": [self decodeIOSVersion:minOS],
        @"platform": @(plat),
        @"size": @(sizeKB * 1024),
        @"url": ipaURL,
        @"fileName": filenameStr,
        @"icon": iconURL,
    };
}

#pragma mark - Category overrides (#156, crowd-sourced + admin-moderated)

- (NSString *)categoryOverridesCachePath {
    NSString *c = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [c stringByAppendingPathComponent:@"appdrop-category-overrides.json"];
}

// Current category/subgenre of an app (read on the search queue → shares self.db safely).
- (NSDictionary *)categorySubgenreForBundleId:(NSString *)bid {
    if (!self.loaded || !self.db || !bid.length) return nil;
    NSString *low = [bid lowercaseString];
    __block NSDictionary *out = nil;
    dispatch_sync(_searchQueue, ^{
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(self.db, "SELECT category, subgenre FROM entries_unique WHERE bid_lower=? LIMIT 1",
                                -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, [low UTF8String], -1, SQLITE_TRANSIENT);
            if (sqlite3_step(st) == SQLITE_ROW) {
                const unsigned char *c = sqlite3_column_text(st, 0);
                const unsigned char *s = sqlite3_column_text(st, 1);
                out = @{ @"category": c ? [NSString stringWithUTF8String:(const char *)c] : @"",
                         @"subgenre": s ? [NSString stringWithUTF8String:(const char *)s] : @"" };
            }
        }
        sqlite3_finalize(st);
    });
    return out;
}

// Apply the cached category-overrides.json to the CACHED catalog.db via a SECOND read-write
// connection (self.db stays read-only). MUST be called on _searchQueue so no query races the write.
// Accepts { "version":N, "overrides": { "<bid>": {"category":...,"subgenre":...} } } or a flat dict.
- (void)applyStoredCategoryOverrides {
    if (!self.loaded || !_dbPath.length) return;
    NSData *data = [NSData dataWithContentsOfFile:[self categoryOverridesCachePath]];
    if (data.length < 2) return;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSDictionary *ov = nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        id inner = [(NSDictionary *)obj objectForKey:@"overrides"];
        ov = [inner isKindOfClass:[NSDictionary class]] ? inner : (NSDictionary *)obj;
    }
    if (![ov isKindOfClass:[NSDictionary class]] || ov.count == 0) return;

    sqlite3 *wdb = NULL;
    if (sqlite3_open_v2([_dbPath UTF8String], &wdb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (wdb) sqlite3_close(wdb);
        return;   // read-only file (e.g. a bundled DB) → can't apply; harmless
    }
    sqlite3_busy_timeout(wdb, 4000);   // v3.2.1 : attendre un verrou plutôt qu'échouer
    sqlite3_exec(wdb, "BEGIN", NULL, NULL, NULL);
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(wdb, "UPDATE entries_unique SET category=?, subgenre=? WHERE bid_lower=?",
                            -1, &st, NULL) == SQLITE_OK) {
        for (NSString *bid in ov) {
            if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
            id e = [ov objectForKey:bid];
            if (![e isKindOfClass:[NSDictionary class]]) continue;
            NSString *cat = [e[@"category"] isKindOfClass:[NSString class]] ? e[@"category"] : nil;
            if (!cat.length) continue;   // category is required; subgenre may be empty
            NSString *sub = [e[@"subgenre"] isKindOfClass:[NSString class]] ? e[@"subgenre"] : @"";
            sqlite3_reset(st);
            sqlite3_bind_text(st, 1, [cat UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 2, [sub UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 3, [[bid lowercaseString] UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_step(st);
        }
    }
    sqlite3_finalize(st);
    sqlite3_exec(wdb, "COMMIT", NULL, NULL, NULL);
    sqlite3_close(wdb);
}

// Download category-overrides.json, cache it, apply it, and refresh the UI. Best-effort.
- (void)refreshCategoryOverrides {
    [HTTPSClient getURL:kCategoryOverridesURL timeout:20 completion:^(NSData *data, NSInteger code, NSError *err) {
        if (err || code < 200 || code >= 300 || data.length < 2) return;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![obj isKindOfClass:[NSDictionary class]]) return;
        // A1 : ne ré-appliquer/notifier QUE si le contenu a changé (évite un rebuild/clignotement inutile).
        NSData *cached = [NSData dataWithContentsOfFile:[self categoryOverridesCachePath]];
        if (cached && [cached isEqualToData:data]) return;   // identique → rien à faire
        [data writeToFile:[self categoryOverridesCachePath] atomically:YES];
        dispatch_async(self->_searchQueue, ^{
            [self applyStoredCategoryOverrides];
            self->_countCacheKey = nil;   // SQL-01: category/subgenre changed → counts may differ
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:LocalCatalogDidUpdateNotification object:nil];
            });
        });
    }];
}

#pragma mark - Hidden apps (#37, de-recommandation des apps pour adultes)

- (NSString *)hiddenAppsCachePath {
    NSString *c = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [c stringByAppendingPathComponent:@"appdrop-hidden.json"];
}

// Fragment SQL " AND <col> NOT IN ('a','b',...)" pour exclure les apps cachées d'une surface de
// recommandation. Vide si aucune liste. `col` = nom (éventuellement préfixé, ex. "e.bid_lower").
- (NSString *)hiddenExclusionForBidColumn:(NSString *)col {
    NSString *list = self.hiddenBidList;   // lecture atomique
    return list.length ? [NSString stringWithFormat:@" AND %@ NOT IN %@", col, list] : @"";
}

// Idem mais par img_pk (pour cat_icon_pool, qui n'a pas de colonne bid).
- (NSString *)hiddenExclusionForImgColumn:(NSString *)col {
    NSString *list = self.hiddenImgList;
    return list.length ? [NSString stringWithFormat:@" AND %@ NOT IN %@", col, list] : @"";
}

// Lit le hidden.json en cache, construit les listes SQL NOT IN (bids + img_pk résolus depuis le
// catalogue) et les publie dans hiddenBidList/hiddenImgList. MUST run on _searchQueue (lit self.db).
- (void)applyStoredHiddenApps {
    NSData *data = [NSData dataWithContentsOfFile:[self hiddenAppsCachePath]];
    NSArray *bids = nil;
    if (data.length > 1) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            id h = [(NSDictionary *)obj objectForKey:@"hidden"];
            bids = [h isKindOfClass:[NSArray class]] ? h : nil;
        } else if ([obj isKindOfClass:[NSArray class]]) {
            bids = obj;
        }
    }
    if (!bids.count) { self.hiddenBidList = nil; self.hiddenImgList = nil; return; }

    // Liste des bids (minuscules, échappés) → "('com.x','com.y',...)".
    NSMutableArray *quoted = [NSMutableArray arrayWithCapacity:bids.count];
    for (id b in bids) {
        if (![b isKindOfClass:[NSString class]] || ![b length]) continue;
        NSString *low = [(NSString *)b lowercaseString];
        NSString *esc = [low stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
        [quoted addObject:[NSString stringWithFormat:@"'%@'", esc]];
    }
    if (!quoted.count) { self.hiddenBidList = nil; self.hiddenImgList = nil; return; }
    self.hiddenBidList = [NSString stringWithFormat:@"(%@)", [quoted componentsJoinedByString:@","]];

    // Résoudre les img_pk de ces bids (pour exclure aussi de cat_icon_pool, qui n'a pas de bid).
    NSMutableArray *imgs = [NSMutableArray array];
    if (self.db) {
        NSString *sql = [NSString stringWithFormat:
            @"SELECT DISTINCT img_pk FROM entries_unique WHERE bid_lower IN %@ AND img_pk>0",
            self.hiddenBidList];
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(self.db, [sql UTF8String], -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW)
                [imgs addObject:[NSString stringWithFormat:@"%d", sqlite3_column_int(st, 0)]];
        }
        sqlite3_finalize(st);
    }
    self.hiddenImgList = imgs.count ? [NSString stringWithFormat:@"(%@)", [imgs componentsJoinedByString:@","]] : nil;
}

// Télécharge hidden.json, le met en cache, reconstruit les listes et rafraîchit l'UI. Best-effort.
- (void)refreshHiddenApps {
    [HTTPSClient getURL:kHiddenAppsURL timeout:20 completion:^(NSData *data, NSInteger code, NSError *err) {
        if (err || code < 200 || code >= 300 || data.length < 2) return;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![obj isKindOfClass:[NSDictionary class]] && ![obj isKindOfClass:[NSArray class]]) return;
        NSData *cached = [NSData dataWithContentsOfFile:[self hiddenAppsCachePath]];
        if (cached && [cached isEqualToData:data]) return;   // identique → rien à faire
        [data writeToFile:[self hiddenAppsCachePath] atomically:YES];
        dispatch_async(self->_searchQueue, ^{
            [self applyStoredHiddenApps];
            self->_countCacheKey = nil;   // SQL-01 : le filtre a changé → les totaux diffèrent
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:LocalCatalogDidUpdateNotification object:nil];
            });
        });
    }];
}

#pragma mark - Catalog extras (v3.1, community apps merged into the catalogue)

- (NSString *)catalogExtrasCachePath {
    NSString *c = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [c stringByAppendingPathComponent:@"appdrop-catalog-extras.json"];
}

// Resolve an existing catalogue row's .ipa URL from its base_idx + filename (same scheme as dictFromRow).
- (NSString *)urlForBaseIdx:(NSInteger)baseIdx filename:(NSString *)filename {
    NSString *baseURL = self.urls[@(baseIdx)] ?: @"";   // SQL-07: NSNumber key (matches urls build)
    if (baseURL.length && ![baseURL hasSuffix:@"/"]) baseURL = [baseURL stringByAppendingString:@"/"];
    return (baseURL.length && filename.length) ? [baseURL stringByAppendingString:filename] : @"";
}

// Merge the cached catalog-extras.json into the CACHED catalog.db via a 2nd read-write connection.
// MUST run on _searchQueue (or the same context as applyStoredCategoryOverrides). Idempotent: it purges
// prior extra rows (base_idx = -1) then re-inserts, so a re-apply or a hot-swapped fresh DB converges.
- (void)applyCatalogExtras {
    if (!self.loaded || !_dbPath.length) { self.extraURLs = nil; self.extraIcons = nil; return; }
    NSData *data = [NSData dataWithContentsOfFile:[self catalogExtrasCachePath]];
    NSArray *apps = nil;
    if (data.length > 1) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            id a = [(NSDictionary *)obj objectForKey:@"apps"];
            apps = [a isKindOfClass:[NSArray class]] ? a : nil;
        } else if ([obj isKindOfClass:[NSArray class]]) {
            apps = obj;
        }
    }

    sqlite3 *wdb = NULL;
    if (sqlite3_open_v2([_dbPath UTF8String], &wdb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (wdb) sqlite3_close(wdb);
        return;   // read-only DB → can't merge; harmless
    }
    sqlite3_busy_timeout(wdb, 4000);   // v3.2.1 : attendre un verrou plutôt qu'échouer
    sqlite3_exec(wdb, "BEGIN", NULL, NULL, NULL);
    sqlite3_exec(wdb, "DELETE FROM entries_unique WHERE base_idx = -1", NULL, NULL, NULL);   // purge prior extras
    sqlite3_exec(wdb, "DELETE FROM entries WHERE base_idx = -1", NULL, NULL, NULL);

    // RÉVERSIBILITÉ des variantes de compatibilité (v3.2.0.3) : une variante au min-iOS abaissé fait un
    // UPDATE sur une VRAIE ligne de base (minos), qui persiste dans le cache. Pour pouvoir « revenir en
    // arrière » si une variante est retirée du catalogue (ex. elle ne marche pas), on mémorise le min-iOS
    // d'ORIGINE de chaque ligne qu'on abaisse dans `extras_minos_restore`. À CHAQUE ré-application on commence
    // par TOUT restaurer (remettre les minos d'origine + recalculer min_minos depuis les vraies lignes), puis
    // on ré-applique seulement les variantes encore présentes. Donc retirer la variante (revert git de
    // catalog-extras.json) rétablit automatiquement le min-iOS d'origine au prochain merge. Coût ~nul (ne
    // touche que la poignée de lignes abaissées). L'IPA original, lui, n'est jamais écrasé sur archive.org
    // (la variante a un nom de fichier distinct côté pipeline).
    sqlite3_exec(wdb, "CREATE TABLE IF NOT EXISTS extras_minos_restore (bid_lower TEXT, version TEXT, orig_minos INTEGER, PRIMARY KEY (bid_lower, version))", NULL, NULL, NULL);
    // 1) restaurer les minos par-version d'origine sur les lignes encore présentes
    sqlite3_exec(wdb, "UPDATE entries SET minos = (SELECT r.orig_minos FROM extras_minos_restore r WHERE r.bid_lower = entries.bid_lower AND r.version = entries.version) "
                      "WHERE EXISTS (SELECT 1 FROM extras_minos_restore r WHERE r.bid_lower = entries.bid_lower AND r.version = entries.version)", NULL, NULL, NULL);
    // 2) recalculer le min-iOS de l'app (min_minos) depuis les vraies lignes restaurées, pour les bids touchés
    sqlite3_exec(wdb, "UPDATE entries_unique SET min_minos = (SELECT MIN(e.minos) FROM entries e WHERE e.bid_lower = entries_unique.bid_lower) "
                      "WHERE bid_lower IN (SELECT DISTINCT bid_lower FROM extras_minos_restore)", NULL, NULL, NULL);
    // 3) repartir d'une mémoire vierge : on ré-enregistrera seulement les variantes encore appliquées
    sqlite3_exec(wdb, "DELETE FROM extras_minos_restore", NULL, NULL, NULL);

    NSMutableDictionary *newURLs = [NSMutableDictionary dictionary];
    NSMutableDictionary *newIcons = [NSMutableDictionary dictionary];

    if (apps.count) {
        long long nextPk = 1;   // both tables share the pk space
        sqlite3_stmt *mx = NULL;
        if (sqlite3_prepare_v2(wdb, "SELECT MAX(m) FROM (SELECT MAX(pk) m FROM entries_unique UNION SELECT MAX(pk) m FROM entries)", -1, &mx, NULL) == SQLITE_OK) {
            if (sqlite3_step(mx) == SQLITE_ROW) nextPk = sqlite3_column_int64(mx, 0) + 1;
        }
        sqlite3_finalize(mx);

        const char *insU = "INSERT INTO entries_unique (pk, plat, minos, title, bid, version, base_idx, filename, size_kb, img_pk, title_lower, bid_lower, category, subgenre, min_minos) VALUES (?,?,?,?,?,?,-1,?,?,0,?,?,?,?,?)";
        const char *insE = "INSERT INTO entries (pk, plat, minos, title, bid, version, base_idx, filename, size_kb, img_pk, title_lower, bid_lower) VALUES (?,?,?,?,?,?,-1,?,?,0,?,?)";

        for (NSDictionary *app in apps) {
            if (![app isKindOfClass:[NSDictionary class]]) continue;
            NSString *bid = [app[@"bid"] isKindOfClass:[NSString class]] ? app[@"bid"] : nil;
            NSString *ipa = [app[@"ipa"] isKindOfClass:[NSString class]] ? app[@"ipa"] : nil;
            if (!bid.length || !ipa.length) continue;
            NSString *bidLow = [bid lowercaseString];
            NSString *name = [app[@"name"] isKindOfClass:[NSString class]] ? app[@"name"] : bid;
            NSString *ver  = [app[@"version"] isKindOfClass:[NSString class]] ? app[@"version"] : @"";
            NSString *minIosStr = [app[@"min_ios"] isKindOfClass:[NSString class]] ? app[@"min_ios"] : @"";
            NSString *cat  = [app[@"category"] isKindOfClass:[NSString class]] ? app[@"category"] : @"";
            NSString *sub  = [app[@"subgenre"] isKindOfClass:[NSString class]] ? app[@"subgenre"] : @"";
            NSString *icon = [app[@"icon"] isKindOfClass:[NSString class]] ? app[@"icon"] : @"";
            NSInteger plat = [app[@"plat"] respondsToSelector:@selector(integerValue)] ? [app[@"plat"] integerValue] : 0;
            if (plat <= 0) plat = 6;   // default: both idioms
            int minos = (int)[self encodeIOSVersion:minIosStr];
            long long sizeBytes = [app[@"size"] respondsToSelector:@selector(longLongValue)] ? [app[@"size"] longLongValue] : 0;
            long long sizeKb = sizeBytes / 1024;
            NSString *fname = [ipa lastPathComponent] ?: @"app.ipa";
            NSString *titleLow = [name lowercaseString];
            NSString *key = [NSString stringWithFormat:@"%@|%@", bidLow, ver];

            // Existing state (only real rows remain — extras were purged above).
            BOOL bidExists = NO;
            sqlite3_stmt *q = NULL;
            if (sqlite3_prepare_v2(wdb, "SELECT 1 FROM entries_unique WHERE bid_lower=? LIMIT 1", -1, &q, NULL) == SQLITE_OK) {
                sqlite3_bind_text(q, 1, [bidLow UTF8String], -1, SQLITE_TRANSIENT);
                bidExists = (sqlite3_step(q) == SQLITE_ROW);
            }
            sqlite3_finalize(q);

            BOOL versionExists = NO; NSString *existingUrl = nil; int existingMinos = 0;
            q = NULL;
            if (sqlite3_prepare_v2(wdb, "SELECT base_idx, filename, minos FROM entries WHERE bid_lower=? AND version=? LIMIT 1", -1, &q, NULL) == SQLITE_OK) {
                sqlite3_bind_text(q, 1, [bidLow UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(q, 2, [ver UTF8String], -1, SQLITE_TRANSIENT);
                if (sqlite3_step(q) == SQLITE_ROW) {
                    versionExists = YES;
                    NSInteger bi = sqlite3_column_int(q, 0);
                    const unsigned char *fn = sqlite3_column_text(q, 1);
                    existingMinos = sqlite3_column_int(q, 2);
                    existingUrl = [self urlForBaseIdx:bi filename:(fn ? [NSString stringWithUTF8String:(const char *)fn] : @"")];
                }
            }
            sqlite3_finalize(q);

            if (versionExists) {
                // Même bid+version déjà au catalogue. On adopte la copie contribuée dans 2 cas :
                //  (a) REPLACE_ENCRYPTED : la copie du catalogue est chiffrée (FairPlay) → on remplace l'URL
                //      par la copie déchiffrée contribuée.
                //  (b) VARIANTE DE COMPATIBILITÉ (v3.2.0.2) : même version mais min-iOS contribué PLUS BAS
                //      (ex. binaire identique avec MinimumOSVersion abaissé pour iOS 6) → on adopte son URL
                //      ET on baisse le min-iOS enregistré (par-version + app) pour que l'app la propose et
                //      l'installe sur les vieux appareils. La modération a vérifié que le binaire est identique
                //      (même exec_sha256) → ce n'est PAS un mod, juste une app rendue installable plus bas.
                BOOL catEncrypted = (existingUrl.length && [MachOInspector cachedResultForURL:existingUrl] == MachOInspectionResultEncrypted);
                BOOL lowerMin = (minos > 0 && (existingMinos == 0 || existingMinos > minos));
                if (catEncrypted || lowerMin) newURLs[key] = ipa;   // adopte l'URL contribuée
                if (lowerMin) {
                    // Mémorise le min-iOS D'ORIGINE de cette version (pristine, car restauré ci-dessus) pour
                    // pouvoir revenir en arrière si la variante est un jour retirée du catalogue.
                    sqlite3_stmt *rs = NULL;
                    if (sqlite3_prepare_v2(wdb, "INSERT OR IGNORE INTO extras_minos_restore (bid_lower, version, orig_minos) VALUES (?,?,?)", -1, &rs, NULL) == SQLITE_OK) {
                        sqlite3_bind_text(rs, 1, [bidLow UTF8String], -1, SQLITE_TRANSIENT);
                        sqlite3_bind_text(rs, 2, [ver UTF8String], -1, SQLITE_TRANSIENT);
                        sqlite3_bind_int(rs, 3, existingMinos);
                        sqlite3_step(rs);
                    }
                    sqlite3_finalize(rs);
                    sqlite3_stmt *uv = NULL;   // baisse le min de CETTE version
                    if (sqlite3_prepare_v2(wdb, "UPDATE entries SET minos=? WHERE bid_lower=? AND version=?", -1, &uv, NULL) == SQLITE_OK) {
                        sqlite3_bind_int(uv, 1, minos);
                        sqlite3_bind_text(uv, 2, [bidLow UTF8String], -1, SQLITE_TRANSIENT);
                        sqlite3_bind_text(uv, 3, [ver UTF8String], -1, SQLITE_TRANSIENT);
                        sqlite3_step(uv);
                    }
                    sqlite3_finalize(uv);
                    sqlite3_stmt *uu = NULL;   // baisse le min de l'APP si c'était le plus haut
                    if (sqlite3_prepare_v2(wdb, "UPDATE entries_unique SET min_minos=? WHERE bid_lower=? AND min_minos>?", -1, &uu, NULL) == SQLITE_OK) {
                        sqlite3_bind_int(uu, 1, minos);
                        sqlite3_bind_text(uu, 2, [bidLow UTF8String], -1, SQLITE_TRANSIENT);
                        sqlite3_bind_int(uu, 3, minos);
                        sqlite3_step(uu);
                    }
                    sqlite3_finalize(uu);
                }
                continue;
            }

            // New app → a browse row (entries_unique) + a version row; existing bid → just a version row.
            if (!bidExists) {
                sqlite3_stmt *iu = NULL;
                if (sqlite3_prepare_v2(wdb, insU, -1, &iu, NULL) == SQLITE_OK) {
                    sqlite3_bind_int64(iu, 1, nextPk);
                    sqlite3_bind_int(iu, 2, (int)plat);
                    sqlite3_bind_int(iu, 3, minos);
                    sqlite3_bind_text(iu, 4, [name UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(iu, 5, [bid UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(iu, 6, [ver UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(iu, 7, [fname UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_int64(iu, 8, sizeKb);
                    sqlite3_bind_text(iu, 9, [titleLow UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(iu, 10, [bidLow UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(iu, 11, [cat UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(iu, 12, [sub UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_int(iu, 13, minos);
                    sqlite3_step(iu);
                }
                sqlite3_finalize(iu);
                nextPk++;
                if (icon.length) newIcons[bidLow] = icon;   // own the icon only for a new app
            }
            sqlite3_stmt *ie = NULL;
            if (sqlite3_prepare_v2(wdb, insE, -1, &ie, NULL) == SQLITE_OK) {
                sqlite3_bind_int64(ie, 1, nextPk);
                sqlite3_bind_int(ie, 2, (int)plat);
                sqlite3_bind_int(ie, 3, minos);
                sqlite3_bind_text(ie, 4, [name UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(ie, 5, [bid UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(ie, 6, [ver UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(ie, 7, [fname UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_int64(ie, 8, sizeKb);
                sqlite3_bind_text(ie, 9, [titleLow UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(ie, 10, [bidLow UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_step(ie);
            }
            sqlite3_finalize(ie);
            nextPk++;
            newURLs[key] = ipa;
        }
    }

    sqlite3_exec(wdb, "COMMIT", NULL, NULL, NULL);
    sqlite3_close(wdb);
    self.extraURLs = newURLs;
    self.extraIcons = newIcons;
}

// Download catalog-extras.json, cache it, merge it, refresh the UI. Best-effort.
- (void)refreshCatalogExtras {
    [HTTPSClient getURL:kCatalogExtrasURL timeout:20 completion:^(NSData *data, NSInteger code, NSError *err) {
        if (err || code < 200 || code >= 300 || data.length < 2) return;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![obj isKindOfClass:[NSDictionary class]] && ![obj isKindOfClass:[NSArray class]]) return;
        // A1 : ne ré-appliquer/notifier QUE si le contenu a changé (sinon : rebuild = clignotement inutile à
        // chaque lancement, puisque le catalogue en cache reflète déjà ces extras).
        NSData *cached = [NSData dataWithContentsOfFile:[self catalogExtrasCachePath]];
        if (cached && [cached isEqualToData:data]) return;   // identique → rien à faire
        [data writeToFile:[self catalogExtrasCachePath] atomically:YES];
        dispatch_async(self->_searchQueue, ^{
            [self applyCatalogExtras];
            self->_countCacheKey = nil;   // SQL-01: extras inserted/removed rows → counts may differ
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:LocalCatalogDidUpdateNotification object:nil];
            });
        });
    }];
}

#pragma mark - versionsForBundleId

// Compare deux versions NUMÉRIQUEMENT, composant par composant : "1.9" < "1.10", "2.0" < "10.0".
// -1 si a<b, 0 si égal, 1 si a>b. integerValue tolère un suffixe non numérique (ex. "3.0.1 (build)").
static int ADCatVerCmp(NSString *a, NSString *b) {
    NSArray *ca = [(a ?: @"") componentsSeparatedByString:@"."];
    NSArray *cb = [(b ?: @"") componentsSeparatedByString:@"."];
    NSUInteger n = MAX(ca.count, cb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger x = (i < ca.count) ? [ca[i] integerValue] : 0;
        NSInteger y = (i < cb.count) ? [cb[i] integerValue] : 0;
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}

- (NSArray *)versionsForBundleId:(NSString *)bundleId {
    if (!self.loaded || !bundleId.length || !self.db) return @[];
    NSMutableArray *out = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    NSString *sql = @"SELECT pk, plat, minos, title, bid, version, base_idx, filename, size_kb, img_pk "
                    @"FROM entries WHERE bid = ?1 ORDER BY version DESC, pk DESC";
    if (sqlite3_prepare_v2(self.db, [sql UTF8String], -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, [bundleId UTF8String], -1, SQLITE_TRANSIENT);
        while (sqlite3_step(st) == SQLITE_ROW) {
            [out addObject:[self dictFromRow:st]];
        }
    }
    sqlite3_finalize(st);
    // Le ORDER BY SQL est LEXICOGRAPHIQUE (texte) → "1.9" passerait AVANT "1.10". On re-trie
    // NUMÉRIQUEMENT (vraie version la plus récente d'abord ; pk décroissant à égalité) pour que la
    // sélection « dernière version compatible » + la liste des versions soient correctes (bug : choisissait
    // parfois une version plus ancienne ; et le repli « version décryptée » cherchait dans le mauvais ordre).
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        int c = ADCatVerCmp(x[@"version"], y[@"version"]);
        if (c != 0) return (c > 0) ? NSOrderedAscending : NSOrderedDescending;
        NSInteger px = [x[@"id"] integerValue], py = [y[@"id"] integerValue];
        if (px != py) return (px > py) ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return out;
}

// #120: lightweight icon lookup. The Works Today / Modded list (RevivalCatalog/ModdedCatalog
// appDicts) only needs ONE icon URL per bundle id — it used versionsForBundleId, which builds a
// full dict for EVERY version (dozens for e.g. com.burbn.instagram = Retrogram), on the MAIN thread
// → the "app freezes momentarily when loading icons" report. This does a single LIMIT-1 query and
// derives the icon URL straight from img_pk (no per-version dict building).
- (NSString *)iconURLForBundleId:(NSString *)bundleId {
    if (!self.loaded || !bundleId.length || !self.db) return nil;
    NSString *icon = nil;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(self.db,
            "SELECT img_pk FROM entries WHERE bid=?1 AND img_pk>0 ORDER BY version DESC, pk DESC LIMIT 1",
            -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, [bundleId UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_ROW) {
            long imgPk = sqlite3_column_int(st, 0);
            if (imgPk > 0)
                icon = [NSString stringWithFormat:@"https://stuffed18.github.io/ipa-archive-updated/data/%ld/%ld.jpg",
                          imgPk / 1000, imgPk];
        }
    }
    sqlite3_finalize(st);
    return icon;
}

// Map the current app language to its stored description column ("fr" -> "desc_fr").
- (NSString *)descColumnForCurrentLang {
    NSString *lang = [Localization currentLanguageCode] ?: @"en";
    NSDictionary *colMap = @{
        @"en": @"desc_en", @"fr": @"desc_fr", @"es": @"desc_es", @"de": @"desc_de",
        @"pt-BR": @"desc_ptBR", @"ja": @"desc_ja", @"zh-Hans": @"desc_zhHans", @"tr": @"desc_tr",
        @"pl": @"desc_pl",
    };
    NSString *col = colMap[lang];
    if (!col) {
        // unknown / base language (e.g. "pt", "zh") → try the base, else English
        col = colMap[[[lang componentsSeparatedByString:@"-"] firstObject]] ?: @"desc_en";
    }
    return col;
}

// Build the description dict from a prepared row whose columns are, in order:
//   0 localized text, 1 desc_en, 2 demand, 3 min_ios, 4 min_ram_mb, 5 ipad_only, 6 known_issues
// Returns nil if there is no usable text.
- (NSDictionary *)extractDescriptionRow:(sqlite3_stmt *)st {
    const unsigned char *locText = sqlite3_column_text(st, 0);
    const unsigned char *enText  = sqlite3_column_text(st, 1);
    const unsigned char *demand  = sqlite3_column_text(st, 2);
    const unsigned char *minIOS  = sqlite3_column_text(st, 3);
    long long minRAM             = sqlite3_column_int64(st, 4);
    int ipadOnly                 = sqlite3_column_int(st, 5);
    const unsigned char *issues  = sqlite3_column_text(st, 6);

    NSString *text = locText ? [NSString stringWithUTF8String:(const char *)locText] : nil;
    if (text.length < 10 && enText) {  // empty/short localized → English fallback
        text = [NSString stringWithUTF8String:(const char *)enText];
    }
    if (!text.length) return nil;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"text"] = text;
    d[@"demand"] = demand ? [NSString stringWithUTF8String:(const char *)demand] : @"";
    d[@"minIOS"] = minIOS ? [NSString stringWithUTF8String:(const char *)minIOS] : @"";
    d[@"minRAMMB"] = @(minRAM);
    d[@"ipadOnly"] = @(ipadOnly != 0);
    d[@"issues"] = issues ? [NSString stringWithUTF8String:(const char *)issues] : @"";
    return d;
}

// v1.6: AI description + compat profile (by pk), in the current app language.
- (NSDictionary *)descriptionForPK:(NSInteger)pk {
    if (!self.loaded || !self.db || pk <= 0) return nil;
    NSString *col = [self descColumnForCurrentLang];
    NSString *sql = [NSString stringWithFormat:
        @"SELECT %@, desc_en, demand, min_ios, min_ram_mb, ipad_only, known_issues "
        @"FROM descriptions WHERE pk = ?1", col];
    sqlite3_stmt *st = NULL;
    NSDictionary *result = nil;
    if (sqlite3_prepare_v2(self.db, [sql UTF8String], -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(st, 1, (sqlite3_int64)pk);
        if (sqlite3_step(st) == SQLITE_ROW) result = [self extractDescriptionRow:st];
    }
    sqlite3_finalize(st);
    return result;
}

// v1.7: resolve the description by bundle id, so it appears on every version of an
// app. Joins through entries_unique (one row per app) using the indexed bid_lower.
- (NSDictionary *)descriptionForBundleId:(NSString *)bundleId {
    if (!self.loaded || !self.db || !bundleId.length) return nil;
    NSString *col = [self descColumnForCurrentLang];
    NSString *sql = [NSString stringWithFormat:
        @"SELECT d.%@, d.desc_en, d.demand, d.min_ios, d.min_ram_mb, d.ipad_only, d.known_issues "
        @"FROM descriptions d JOIN entries_unique e ON e.pk = d.pk "
        @"WHERE e.bid_lower = ?1 LIMIT 1", col];
    sqlite3_stmt *st = NULL;
    NSDictionary *result = nil;
    if (sqlite3_prepare_v2(self.db, [sql UTF8String], -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, [[bundleId lowercaseString] UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_ROW) result = [self extractDescriptionRow:st];
    }
    sqlite3_finalize(st);
    return result;
}

@end
