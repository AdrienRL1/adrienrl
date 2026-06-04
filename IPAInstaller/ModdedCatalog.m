#import "ModdedCatalog.h"
#import "LocalCatalog.h"
#import "HTTPSClient.h"
#import <UIKit/UIKit.h>

@interface ModdedCatalog ()
@property (nonatomic, strong) NSArray *apps;
@end

@implementation ModdedCatalog

+ (instancetype)shared {
    static ModdedCatalog *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ModdedCatalog alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) { [self load]; [self refreshFromNetwork]; }
    return self;
}

// Hosted alongside revival.json on the project's GitHub Pages. Bundled mods.json is the fallback.
static NSString *const kModsURL = @"https://adrienrl1.github.io/cydia/mods.json";

- (NSString *)cachePath {
    NSString *c = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [c stringByAppendingPathComponent:@"appdrop-mods.json"];
}

// Download the latest mods.json (validated) to Caches for the NEXT launch — lets the list be
// updated without republishing the app. Best-effort.
- (void)refreshFromNetwork {
    [HTTPSClient getURL:kModsURL timeout:20 completion:^(NSData *data, NSInteger code, NSError *err) {
        if (err || code < 200 || code >= 300 || data.length < 10) return;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]] &&
            [[(NSDictionary *)obj objectForKey:@"apps"] isKindOfClass:[NSArray class]]) {
            [data writeToFile:[self cachePath] atomically:YES];
        }
    }];
}

- (void)load {
    // Use whichever of the downloaded cache / bundled fallback has the higher top-level "version"
    // (bundled wins ties) so a stale hosted file can't downgrade a newer bundled list. Same logic
    // as RevivalCatalog.
    NSDictionary *cached = nil, *bundled = nil;
    NSData *cd = [NSData dataWithContentsOfFile:[self cachePath]];
    if (cd.length) {
        id o = [NSJSONSerialization JSONObjectWithData:cd options:0 error:NULL];
        if ([o isKindOfClass:[NSDictionary class]]) cached = o;
    }
    NSString *bp = [[NSBundle mainBundle] pathForResource:@"mods" ofType:@"json"];
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
static BOOL ModVersionLTE(NSString *a, NSString *b) {
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
        if (!minIOS.length || ModVersionLTE(minIOS, dev)) [out addObject:app];
    }
    return out;
}

- (NSArray *)appDicts {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *e in [self compatibleApps]) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *bid = e[@"bid"] ?: @"";
        // Explicit icon URL wins; else reuse the original app's catalogue icon via its bundle id.
        NSString *icon = [e[@"icon"] isKindOfClass:[NSString class]] ? e[@"icon"] : @"";
        if (!icon.length && bid.length) {
            NSArray *vers = [[LocalCatalog shared] versionsForBundleId:bid];
            for (NSDictionary *v in vers) {
                if ([v isKindOfClass:[NSDictionary class]] && [v[@"icon"] length]) { icon = v[@"icon"]; break; }
            }
        }
        NSString *ipa = e[@"ipa"] ?: @"";
        NSString *link = e[@"link"] ?: @"";
        BOOL external = (ipa.length == 0 && link.length > 0);   // no direct .ipa → "open page"
        [out addObject:@{
            @"title":        e[@"name"] ?: @"",
            @"icon":         icon,
            @"url":          ipa,
            @"version":      e[@"version"] ?: @"",
            @"minOS":        e[@"min_ios"] ?: @"",
            @"size":         e[@"size"] ?: @0,
            @"bundleId":     bid,
            @"fileName":     [ipa lastPathComponent] ?: @"",
            @"platform":     @6,                         // iPhone + iPad
            @"isModded":     @YES,
            @"modDesc":      e[@"mod"] ?: @"",           // short description of the modification
            @"revivalNotes": e[@"notes"] ?: @"",         // reuse the detail screen's notes line
            @"revivalLink":  link,
            @"revivalExternal": @(external),
        }];
    }
    return out;
}

@end
