#import "RevivalCatalog.h"
#import "LocalCatalog.h"
#import "HTTPSClient.h"
#import <UIKit/UIKit.h>

@interface RevivalCatalog ()
@property (nonatomic, strong) NSArray *apps;
@end

@implementation RevivalCatalog

+ (instancetype)shared {
    static RevivalCatalog *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[RevivalCatalog alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) { [self load]; [self refreshFromNetwork]; }
    return self;
}

static NSString *const kRevivalURL = @"https://adrienrl1.github.io/cydia/revival.json";

- (NSString *)cachePath {
    NSString *c = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [c stringByAppendingPathComponent:@"appdrop-revival.json"];
}

// Download the latest revival.json (validated) to Caches for the NEXT launch — lets the
// list + versions be updated without republishing the app. Best-effort.
- (void)refreshFromNetwork {
    [HTTPSClient getURL:kRevivalURL timeout:20 completion:^(NSData *data, NSInteger code, NSError *err) {
        if (err || code < 200 || code >= 300 || data.length < 10) return;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]] &&
            [[(NSDictionary *)obj objectForKey:@"apps"] isKindOfClass:[NSArray class]]) {
            [data writeToFile:[self cachePath] atomically:YES];
        }
    }];
}

- (void)load {
    // Parse BOTH the downloaded cache and the bundled fallback, then use whichever has the
    // higher top-level "version". This stops a STALE downloaded cache (an older hosted file)
    // from downgrading a newer bundled list — the exact bug where new bundled apps "disappeared"
    // after a relaunch because refreshFromNetwork had re-cached the old hosted revival.json.
    // Once the hosted file's version >= the bundled one, the download wins again. Bundled wins ties.
    NSDictionary *cached = nil, *bundled = nil;
    NSData *cd = [NSData dataWithContentsOfFile:[self cachePath]];
    if (cd.length) {
        id o = [NSJSONSerialization JSONObjectWithData:cd options:0 error:NULL];
        if ([o isKindOfClass:[NSDictionary class]]) cached = o;
    }
    NSString *bp = [[NSBundle mainBundle] pathForResource:@"revival" ofType:@"json"];
    if (bp.length) {
        NSData *bd = [NSData dataWithContentsOfFile:bp];
        id o = bd.length ? [NSJSONSerialization JSONObjectWithData:bd options:0 error:NULL] : nil;
        if ([o isKindOfClass:[NSDictionary class]]) bundled = o;
    }
    NSInteger cv = [cached[@"version"] integerValue];
    NSInteger bv = [bundled[@"version"] integerValue];
    NSDictionary *chosen = (cached && cv > bv) ? cached : (bundled ?: cached);
    id apps = chosen[@"apps"];
    self.apps = [apps isKindOfClass:[NSArray class]] ? apps : @[];
}

- (NSArray *)allApps { return self.apps ?: @[]; }

// numeric version compare: is a <= b ? ("5.0" <= "6.1.3")
static BOOL RevVersionLTE(NSString *a, NSString *b) {
    NSArray *ca = [(a ?: @"") componentsSeparatedByString:@"."];
    NSArray *cb = [(b ?: @"") componentsSeparatedByString:@"."];
    NSUInteger n = MAX(ca.count, cb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger x = (i < ca.count) ? [ca[i] integerValue] : 0;
        NSInteger y = (i < cb.count) ? [cb[i] integerValue] : 0;
        if (x != y) return (x < y);
    }
    return YES;   // equal
}

- (NSArray *)compatibleApps {
    NSString *dev = [[UIDevice currentDevice] systemVersion] ?: @"99.0";
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *app in self.apps) {
        if (![app isKindOfClass:[NSDictionary class]]) continue;
        NSString *minIOS = app[@"min_ios"];
        if (!minIOS.length || RevVersionLTE(minIOS, dev)) [out addObject:app];
    }
    return out;
}

- (NSDictionary *)revivalForBundleId:(NSString *)bid {
    if (!bid.length) return nil;
    for (NSDictionary *app in self.apps) {
        if ([app isKindOfClass:[NSDictionary class]] &&
            [app[@"replaces_bid"] isKindOfClass:[NSString class]] &&
            [app[@"replaces_bid"] isEqualToString:bid]) {
            return app;
        }
    }
    return nil;
}

- (NSArray *)appDicts {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *e in [self compatibleApps]) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *bid = e[@"bid"] ?: @"";
        // Explicit icon URL wins (for apps NOT in the 2008-2014 catalogue, e.g. ChatGPT);
        // otherwise reuse the REAL app's catalogue icon via bid (e.g. Discord's).
        NSString *icon = [e[@"icon"] isKindOfClass:[NSString class]] ? e[@"icon"] : @"";
        if (!icon.length && bid.length) {
            NSArray *vers = [[LocalCatalog shared] versionsForBundleId:bid];
            for (NSDictionary *v in vers) {
                if ([v isKindOfClass:[NSDictionary class]] && [v[@"icon"] length]) { icon = v[@"icon"]; break; }
            }
        }
        NSString *ipa = e[@"ipa"] ?: @"";
        NSString *link = e[@"link"] ?: @"";
        // "External" revival entry: no direct .ipa, just a project page (a Cydia tweak, a
        // companion-server app, etc. that can't be installed by one in-app tap). The detail
        // screen turns the Install button into "Open project page" for these.
        BOOL external = (ipa.length == 0 && link.length > 0);
        [out addObject:@{
            @"title":        e[@"name"] ?: @"",
            @"icon":         icon,
            @"url":          ipa,                       // direct .ipa → installed in-app
            @"version":      e[@"version"] ?: @"",
            @"minOS":        e[@"min_ios"] ?: @"",
            @"size":         e[@"size"] ?: @0,    // bytes → shown before install
            @"bundleId":     bid,
            @"fileName":     [ipa lastPathComponent] ?: @"",
            @"platform":     @6,                        // iPhone + iPad
            @"isRevival":    @YES,
            @"revivalStatus": e[@"status"] ?: @"active",
            @"revivalNotes":  e[@"notes"] ?: @"",
            @"revivalLink":   link,
            @"revivalExternal": @(external),
        }];
    }
    return out;
}

@end
