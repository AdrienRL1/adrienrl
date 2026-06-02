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
    NSArray *result = @[];
    NSData *d = [NSData dataWithContentsOfFile:[self cachePath]];   // downloaded (latest), if any
    if (!d.length) {
        NSString *path = [[NSBundle mainBundle] pathForResource:@"revival" ofType:@"json"];
        d = path.length ? [NSData dataWithContentsOfFile:path] : nil;   // bundled fallback
    }
    if (d.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            id apps = [(NSDictionary *)obj objectForKey:@"apps"];
            if ([apps isKindOfClass:[NSArray class]]) result = apps;
        }
    }
    self.apps = result;
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
        NSString *icon = @"";
        if (bid.length) {
            // Reuse the REAL app's catalogue icon (e.g. Discord's, Roblox's).
            NSArray *vers = [[LocalCatalog shared] versionsForBundleId:bid];
            for (NSDictionary *v in vers) {
                if ([v isKindOfClass:[NSDictionary class]] && [v[@"icon"] length]) { icon = v[@"icon"]; break; }
            }
        }
        NSString *ipa = e[@"ipa"] ?: @"";
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
        }];
    }
    return out;
}

@end
