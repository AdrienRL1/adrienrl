#import "LocalCatalog.h"
#import "Localization.h"
#import "HTTPSClient.h"   // first-launch catalog download (via bundled mbedTLS)
#import <UIKit/UIKit.h>   // UIDevice — for device-iOS icon filtering
#import <sqlite3.h>
#import <zlib.h>          // gunzip the downloaded catalog.db.gz

// The catalog is NO LONGER bundled in the .deb (kept it ~1 MB so it installs on any
// device). It's downloaded once on first launch — gzip'd to ~22 MB — via the app's
// own mbedTLS (which reaches github.io even on old iOS, unlike Cydia/system TLS),
// then cached in Caches/. archive.org/github Pages are both free, no private server.
static NSString *const kCatalogURL = @"https://adrienrl1.github.io/cydia/catalog.db.gz";
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

@interface LocalCatalog ()
@property (nonatomic, assign) sqlite3 *db;
@property (nonatomic, strong) NSDictionary *urls;  // cached at open (only 27k entries, ~2 MB)
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL updateInFlight;   // a background freshness check/update is running
@end

@implementation LocalCatalog {
    dispatch_queue_t _searchQueue;
    NSString *_dbPath;
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

    __block BOOL ok = NO; __block NSError *dlErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [HTTPSClient downloadURL:kCatalogURL
                      toFile:gzTmp
                    progress:^(long long received, long long total) {
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
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

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
                                   userInfo:@{NSLocalizedDescriptionKey: @"décompression échouée"}];
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
                            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
            if (newdb) sqlite3_close(newdb);
            [fm removeItemAtPath:dbTmp error:NULL];
            @synchronized (self) { self.updateInFlight = NO; }
            return;
        }
        // Promote temp → canonical cached path (atomic). The old inode stays alive while
        // self.db still has it open, so in-flight reads on it remain valid.
        [fm removeItemAtPath:cached error:NULL];
        [fm moveItemAtPath:dbTmp toPath:cached error:NULL];

        sqlite3_exec(newdb, "PRAGMA mmap_size = 268435456", NULL, NULL, NULL);
        sqlite3_exec(newdb, "PRAGMA cache_size = -8000",    NULL, NULL, NULL);
        sqlite3_exec(newdb, "PRAGMA temp_store = MEMORY",   NULL, NULL, NULL);

        NSMutableDictionary *urls = [NSMutableDictionary dictionaryWithCapacity:30000];
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(newdb, "SELECT idx, url FROM urls", -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                int idx = sqlite3_column_int(st, 0);
                const unsigned char *u = sqlite3_column_text(st, 1);
                if (!u) continue;
                NSString *urlStr = [NSString stringWithUTF8String:(const char *)u];
                if (!urlStr.length) continue;
                urls[[NSString stringWithFormat:@"%d", idx]] = urlStr;
            }
        }
        sqlite3_finalize(st);

        sqlite3 *old = self.db;
        self.db = newdb;
        self.urls = urls;
        _dbPath = [cached copy];
        if (old) sqlite3_close(old);

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
                                    userInfo:@{NSLocalizedDescriptionKey: @"catalogue indisponible"}]);
            });
            return;
        }
        _dbPath = [path copy];

        sqlite3 *db = NULL;
        int rc = sqlite3_open_v2([_dbPath UTF8String], &db,
                                   SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
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
        // mmap-backed reads for faster random access on large pages
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456", NULL, NULL, NULL);  // 256 MB max mmap window
        sqlite3_exec(db, "PRAGMA cache_size = -8000", NULL, NULL, NULL);     // 8 MB page cache
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", NULL, NULL, NULL);

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
                urls[[NSString stringWithFormat:@"%d", idx]] = urlStr;
            }
        }
        sqlite3_finalize(st);

        // Count for status reporting
        long long entryCount = 0;
        if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM entries_unique", -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW) entryCount = sqlite3_column_int64(st, 0);
        }
        sqlite3_finalize(st);

        self.db = db;
        self.urls = urls;
        self.loaded = YES;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (progressBlock) progressBlock([NSString stringWithFormat:@"Catalogue : %lld apps", entryCount]);
            if (completion) completion(YES, nil);
        });
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
        NSString *c = [category stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
        [whereClause appendString:[NSString stringWithFormat:@" AND category = '%@'", c]];
        if (subgenre.length) {
            NSString *s = [subgenre stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
            [whereClause appendString:[NSString stringWithFormat:@" AND subgenre = '%@'", s]];
        }
    }
    // (Suspect-file SQL filter removed in v2.0.8 — too many false positives.
    //  See AppDetailViewController for per-row install-time mismatch alert.)

    // ORDER BY honors the user-selected direction. Column choice depends on `sortKey`.
    NSString *dir = descending ? @"DESC" : @"ASC";
    NSString *orderCol = @"pk";  // default = recent ordering (by primary key)
    if ([sortKey isEqualToString:@"name"]) orderCol = @"title_lower";
    else if ([sortKey isEqualToString:@"size"]) orderCol = @"size_kb";
    else if ([sortKey isEqualToString:@"minos"]) orderCol = @"minos";
    NSString *orderBy = [NSString stringWithFormat:@"%@ %@", orderCol, dir];

    // Count + data in two queries — both indexed, so each is sub-millisecond.
    long long total = 0;
    NSString *countSQL = [NSString stringWithFormat:@"SELECT COUNT(*) FROM %@ WHERE 1=1%@",
                                                       table, whereClause];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(self.db, [countSQL UTF8String], -1, &st, NULL) == SQLITE_OK) {
        if (qLike) sqlite3_bind_text(st, 1, [qLike UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_ROW) total = sqlite3_column_int64(st, 0);
    }
    sqlite3_finalize(st);

    NSString *cols = @"pk, plat, minos, title, bid, version, base_idx, filename, size_kb, img_pk";
    if (unique) cols = [cols stringByAppendingString:@", min_minos"];   // extra col 10
    NSString *dataSQL = [NSString stringWithFormat:
        @"SELECT %@ FROM %@ WHERE 1=1%@ ORDER BY %@ LIMIT %ld OFFSET %ld",
        cols, table, whereClause, orderBy, (long)limit, (long)offset];

    NSMutableArray *results = [NSMutableArray arrayWithCapacity:limit];
    st = NULL;
    if (sqlite3_prepare_v2(self.db, [dataSQL UTF8String], -1, &st, NULL) == SQLITE_OK) {
        if (qLike) sqlite3_bind_text(st, 1, [qLike UTF8String], -1, SQLITE_TRANSIENT);
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
    NSString *sqlStr = [NSString stringWithFormat:
        @"SELECT category, COUNT(*) FROM entries_unique "
        @"WHERE category IS NOT NULL AND category<>'' AND min_minos <= %ld "
        @"GROUP BY category ORDER BY COUNT(*) DESC", (long)[self deviceMaxMinos]];
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
                    @"AND min_minos <= %ld "
                    @"GROUP BY subgenre ORDER BY COUNT(*) DESC", (long)[self deviceMaxMinos]];
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

- (NSArray *)iconPoolForCategory:(NSString *)category {
    if (!self.loaded || !self.db || !category.length) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    // 1. Curated, device-runnable icons (minos <= device iOS), biggest apps first.
    const char *sql = "SELECT img_pk FROM cat_icon_pool WHERE category=?1 AND minos<=?2 "
                      "ORDER BY rn_cat LIMIT 24";
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

    // 2. Top up from entries_unique when the curated device-runnable set is THIN (<6). Some
    // categories' biggest apps all need iOS 7+ — e.g. Social Networking has just 1 curated icon
    // this device can run, Finance has 0 — so the card would never reshuffle. entries_unique
    // still has hundreds of smaller device-runnable apps with icons (390 for Social Networking),
    // giving a varied pool of REAL, runnable example icons. Deduped by img_pk.
    if (out.count < 6) {
        const char *fsql = "SELECT img_pk FROM entries_unique WHERE category=?1 AND min_minos<=?2 "
                           "AND img_pk>0 ORDER BY size_kb DESC LIMIT 24";
        sqlite3_stmt *f = NULL;
        if (sqlite3_prepare_v2(self.db, fsql, -1, &f, NULL) == SQLITE_OK) {
            sqlite3_bind_text(f, 1, [category UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(f, 2, [self deviceMaxMinos]);
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
    const char *sql = "SELECT img_pk FROM cat_icon_pool WHERE category=?1 AND subgenre=?2 "
                      "AND minos<=?3 ORDER BY rn_sub LIMIT 24";
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

    // Top up from entries_unique when the curated device-runnable set is THIN (<6) — same as
    // the category-level pool, so a subgenre whose biggest apps all need a newer iOS still gets
    // a varied set of real device-runnable example icons instead of a frozen single icon.
    if (out.count < 6) {
        const char *fsql = "SELECT img_pk FROM entries_unique WHERE category=?1 AND subgenre=?2 "
                           "AND min_minos<=?3 AND img_pk>0 ORDER BY size_kb DESC LIMIT 24";
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

    NSString *baseURL = self.urls[[NSString stringWithFormat:@"%ld", (long)baseIdx]] ?: @"";
    if (baseURL.length && ![baseURL hasSuffix:@"/"]) baseURL = [baseURL stringByAppendingString:@"/"];
    NSString *ipaURL = (baseURL.length && filenameStr.length)
        ? [baseURL stringByAppendingString:filenameStr] : @"";
    NSString *iconURL = [NSString stringWithFormat:@"https://stuffed18.github.io/ipa-archive-updated/data/%ld/%ld.jpg",
                          (long)(imgPk / 1000), (long)imgPk];

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

#pragma mark - versionsForBundleId

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
    return out;
}

// Map the current app language to its stored description column ("fr" -> "desc_fr").
- (NSString *)descColumnForCurrentLang {
    NSString *lang = [Localization currentLanguageCode] ?: @"en";
    NSDictionary *colMap = @{
        @"en": @"desc_en", @"fr": @"desc_fr", @"es": @"desc_es", @"de": @"desc_de",
        @"pt-BR": @"desc_ptBR", @"ja": @"desc_ja", @"zh-Hans": @"desc_zhHans", @"tr": @"desc_tr",
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
