#import "StatsClient.h"
#import "HTTPSClient.h"
#import "LocalCatalog.h"

NSString *const StatsActiveUsersChangedNotification = @"StatsActiveUsersChangedNotification";
NSString *const StatsDownloadsChangedNotification   = @"StatsDownloadsChangedNotification";

// Worker Cloudflare déployé (voir mémoire appdrop-v32-plan). HORS du serveur Unraid.
static NSString *const kStatsBase = @"https://appdrop-stats.adrienruestlorquet.workers.dev";

@interface StatsClient ()
@property (nonatomic, retain) NSMutableDictionary *counts;   // bid_lower (NSString) -> NSNumber
@property (nonatomic, assign) NSInteger activeUsers;         // -1 = inconnu
@property (nonatomic, assign) BOOL downloadsInFlight;
@end

@implementation StatsClient

+ (instancetype)shared {
    static StatsClient *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[StatsClient alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _activeUsers = -1;
        NSDictionary *cached = [NSDictionary dictionaryWithContentsOfFile:[self countsCachePath]];
        _counts = cached ? [cached mutableCopy] : [[NSMutableDictionary alloc] init];
        // Re-pousser les compteurs en cache dans la base après chaque hot-swap du catalogue
        // (le fichier catalog.db est remplacé → la table downloads y est recréée vide).
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(catalogDidUpdate)
                name:LocalCatalogDidUpdateNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_counts release];
    [super dealloc];
}

- (NSString *)countsCachePath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:@"appdrop_downloads.plist"];
}

#pragma mark - Identifiant anonyme

- (NSString *)deviceID {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *did = [d stringForKey:@"AppDropDeviceID"];
    if (did.length) return did;
    CFUUIDRef u = CFUUIDCreate(NULL);
    CFStringRef cfDid = CFUUIDCreateString(NULL, u);
    did = [[(NSString *)cfDid retain] autorelease];
    CFRelease(cfDid);
    CFRelease(u);
    [d setObject:did forKey:@"AppDropDeviceID"]; [d synchronize];
    return did;
}

#pragma mark - Utilisateurs actifs

- (NSInteger)cachedActiveUsers { return self.activeUsers; }

- (void)sendHeartbeatWithCompletion:(void (^)(NSInteger active))completion {
    NSData *body = [[NSString stringWithFormat:@"{\"id\":\"%@\"}", [self deviceID]]
                    dataUsingEncoding:NSUTF8StringEncoding];
    AD_WEAK typeof(self) ws = self;
    [HTTPSClient postURL:[kStatsBase stringByAppendingString:@"/heartbeat"]
                 headers:@{ @"Content-Type": @"application/json" }
                    body:body
                 timeout:12
              completion:^(NSData *resp, NSInteger status, NSError *err) {
        __strong typeof(ws) self = ws;
        NSInteger active = -1;
        if (self && status == 200 && resp.length) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:resp options:0 error:NULL];
            if ([j isKindOfClass:[NSDictionary class]] && [j[@"active"] isKindOfClass:[NSNumber class]])
                active = [j[@"active"] integerValue];
        }
        if (self && active >= 0) {
            self.activeUsers = active;
            [[NSNotificationCenter defaultCenter] postNotificationName:StatsActiveUsersChangedNotification
                object:self userInfo:@{ @"active": @(active) }];
        }
        if (completion) completion(active);
    }];
}

#pragma mark - Téléchargements

- (NSInteger)downloadsForBundleId:(NSString *)bid {
    if (![bid isKindOfClass:[NSString class]] || !bid.length) return -1;
    NSNumber *n = self.counts[[bid lowercaseString]];
    return [n isKindOfClass:[NSNumber class]] ? [n integerValue] : -1;
}

- (void)refreshDownloads {
    // Réinjecte d'abord les compteurs en cache dans la base (le tri/top marche même hors-ligne au démarrage).
    if (self.counts.count) [[LocalCatalog shared] mergeDownloadCounts:self.counts];
    @synchronized (self) { if (self.downloadsInFlight) return; self.downloadsInFlight = YES; }
    AD_WEAK typeof(self) ws = self;
    [HTTPSClient getURL:[kStatsBase stringByAppendingString:@"/downloads"]
                timeout:15
             completion:^(NSData *body, NSInteger status, NSError *err) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        @synchronized (self) { self.downloadsInFlight = NO; }
        if (status != 200 || !body.length) return;
        id j = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        if (![j isKindOfClass:[NSDictionary class]]) return;
        NSMutableDictionary *m = [[NSMutableDictionary alloc] initWithCapacity:[(NSDictionary *)j count]];
        for (NSString *bid in (NSDictionary *)j) {
            if (![bid isKindOfClass:[NSString class]]) continue;
            NSNumber *c = ((NSDictionary *)j)[bid];
            if ([c isKindOfClass:[NSNumber class]]) m[[bid lowercaseString]] = c;
        }
        self.counts = m;
        [m release];
        [self.counts writeToFile:[self countsCachePath] atomically:YES];
        [[LocalCatalog shared] mergeDownloadCounts:self.counts];
        [[NSNotificationCenter defaultCenter] postNotificationName:StatsDownloadsChangedNotification object:self];
    }];
}

- (void)recordDownloadForBundleId:(NSString *)bid {
    if (![bid isKindOfClass:[NSString class]] || !bid.length) return;
    NSString *bidLow = [bid lowercaseString];
    // +1 optimiste local (affichage immédiat) — le serveur dédoublonne de toute façon.
    NSInteger cur = [self downloadsForBundleId:bid];
    self.counts[bidLow] = @(cur < 0 ? 1 : cur + 1);
    [self.counts writeToFile:[self countsCachePath] atomically:YES];
    [[LocalCatalog shared] mergeDownloadCounts:@{ bidLow: self.counts[bidLow] }];
    [[NSNotificationCenter defaultCenter] postNotificationName:StatsDownloadsChangedNotification object:self];

    NSString *jb = [NSString stringWithFormat:@"{\"id\":\"%@\",\"bid\":\"%@\"}",
                    [self deviceID], [self jsonEscape:bid]];
    [HTTPSClient postURL:[kStatsBase stringByAppendingString:@"/download"]
                 headers:@{ @"Content-Type": @"application/json" }
                    body:[jb dataUsingEncoding:NSUTF8StringEncoding]
                 timeout:12
              completion:^(NSData *resp, NSInteger status, NSError *err) { (void)resp; (void)status; (void)err; }];
}

- (NSString *)jsonEscape:(NSString *)s {
    NSString *o = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [o stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

- (void)catalogDidUpdate {
    if (self.counts.count) [[LocalCatalog shared] mergeDownloadCounts:self.counts];
}

@end
