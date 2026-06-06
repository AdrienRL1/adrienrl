#import "ModdedCatalog.h"
#import "LocalCatalog.h"
#import "HTTPSClient.h"
#import "Localization.h"
#import <UIKit/UIKit.h>

NSString *const ModdedCatalogDidChangeNotification = @"ModdedCatalogDidChangeNotification";

@interface ModdedCatalog ()
@property (nonatomic, strong) NSArray *apps;
@property (nonatomic, assign) NSInteger loadedVersion;   // top-level "version" of self.apps (#142)
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
        if (![obj isKindOfClass:[NSDictionary class]]) return;
        if (![[(NSDictionary *)obj objectForKey:@"apps"] isKindOfClass:[NSArray class]]) return;
        NSInteger newVer = [[(NSDictionary *)obj objectForKey:@"version"] integerValue];
        [data writeToFile:[self cachePath] atomically:YES];
        // #142: refresh the Modded list IN-SESSION when the hosted file is newer.
        if (newVer > self.loadedVersion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self load];
                [[NSNotificationCenter defaultCenter] postNotificationName:ModdedCatalogDidChangeNotification object:nil];
            });
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
    self.loadedVersion = [chosen[@"version"] integerValue];   // #142
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

// #147: notes in the user's language — notes_i18n[lang] → notes_i18n["en"] → notes (FR default).
static NSString *ADLocalizedModNotes(NSDictionary *e) {
    id i18n = e[@"notes_i18n"];
    if ([i18n isKindOfClass:[NSDictionary class]]) {
        NSString *lang = [Localization currentLanguageCode];
        id s = (lang.length ? [i18n objectForKey:lang] : nil);
        if ([s isKindOfClass:[NSString class]] && [s length]) return s;
        id en = [i18n objectForKey:@"en"];
        if ([en isKindOfClass:[NSString class]] && [en length]) return en;
    }
    id n = e[@"notes"];
    return [n isKindOfClass:[NSString class]] ? n : @"";
}

// Normalize a display name to a grouping key: lowercase, keep only a–z / 0–9.
static NSString *ADModdedNameKey(NSString *name) {
    NSString *s = [name lowercaseString] ?: @"";
    NSMutableString *m = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [m appendFormat:@"%C", c];
    }
    return m;
}

// #171 Bug 3: collapse same-name Modded entries (different versions) into ONE row, newest first,
// with the full list under "revivalVersions". Exact-version duplicates inside a group are dropped.
static NSArray *ADModdedGroupByName(NSArray *flat) {
    NSMutableArray *order = [NSMutableArray array];
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *d in flat) {
        NSString *key = ADModdedNameKey(d[@"title"]);
        if (!key.length) key = [(d[@"url"] ?: @"") lowercaseString];
        NSMutableArray *g = [groups objectForKey:key];
        if (!g) { g = [NSMutableArray array]; [groups setObject:g forKey:key]; [order addObject:key]; }
        NSString *nv = d[@"version"] ?: @"";
        BOOL dup = NO;
        for (NSDictionary *x in g) { if ([(x[@"version"] ?: @"") isEqualToString:nv]) { dup = YES; break; } }
        if (!dup) [g addObject:d];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in order) {
        NSMutableArray *g = [groups objectForKey:key];
        [g sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL aLEb = ModVersionLTE(a[@"version"], b[@"version"]);
            BOOL bLEa = ModVersionLTE(b[@"version"], a[@"version"]);
            if (aLEb && bLEa) return NSOrderedSame;
            return aLEb ? NSOrderedDescending : NSOrderedAscending;   // newest first
        }];
        if (g.count <= 1) { [out addObject:[g objectAtIndex:0]]; continue; }
        NSMutableDictionary *rep = [[g objectAtIndex:0] mutableCopy];
        [rep setObject:[g copy] forKey:@"revivalVersions"];
        [out addObject:rep];
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
            icon = [[LocalCatalog shared] iconURLForBundleId:bid] ?: @"";   // #120: O(1) icon, not every version
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
            @"revivalNotes": ADLocalizedModNotes(e),     // reuse the detail screen's notes line
            @"revivalLink":  link,
            @"revivalExternal": @(external),
        }];
    }
    return ADModdedGroupByName(out);   // #171 Bug 3: one row per app, versions grouped
}

@end
