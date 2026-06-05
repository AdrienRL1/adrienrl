#import "IPAPackage.h"
#import "MachOInspector.h"
#import <UIKit/UIKit.h>

// Count '/' in a zip entry path — used to require an entry sit DIRECTLY in Payload/<App>.app/
// (exactly 2 slashes), so we don't grab a nested .appex / .bundle / Frameworks Info.plist or icon.
static NSInteger ipaSlashCount(NSString *s) {
    NSInteger n = 0;
    for (NSUInteger i = 0; i < s.length; i++) if ([s characterAtIndex:i] == '/') n++;
    return n;
}

@implementation IPAPackage

+ (NSDictionary *)infoPlistForIPA:(NSString *)ipaPath {
    NSData *d = [MachOInspector extractLargestEntryFromIPA:ipaPath matching:^BOOL(NSString *name) {
        return [name hasPrefix:@"Payload/"]
            && [name hasSuffix:@".app/Info.plist"]
            && ipaSlashCount(name) == 2;
    } maxBytes:4 * 1024 * 1024];
    if (!d.length) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:d
                                                         options:NSPropertyListImmutable
                                                          format:NULL error:NULL];
    return [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
}

+ (NSDictionary *)metadataForIPA:(NSString *)ipaPath {
    NSDictionary *info = [self infoPlistForIPA:ipaPath];
    if (!info) return nil;
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    NSString *name = info[@"CFBundleDisplayName"];
    if (![name isKindOfClass:[NSString class]] || !name.length) name = info[@"CFBundleName"];
    if ([name isKindOfClass:[NSString class]] && name.length) m[@"name"] = name;
    NSString *bid = info[@"CFBundleIdentifier"];
    if ([bid isKindOfClass:[NSString class]] && bid.length) m[@"bid"] = bid;
    NSString *ver = info[@"CFBundleShortVersionString"];
    if (![ver isKindOfClass:[NSString class]] || !ver.length) ver = info[@"CFBundleVersion"];
    if ([ver isKindOfClass:[NSString class]] && ver.length) m[@"version"] = ver;
    NSString *minos = info[@"MinimumOSVersion"];
    if ([minos isKindOfClass:[NSString class]] && minos.length) m[@"min_ios"] = minos;
    return m;
}

// Collect candidate icon base names (lowercased, .png stripped) from the Info.plist, with sensible
// fallbacks. We then match any file directly inside the .app whose stem equals a base or starts with
// "base@" (Retina) or "base~" (idiom), and keep the largest — i.e. the highest-resolution variant.
+ (NSData *)iconPNGForIPA:(NSString *)ipaPath {
    NSDictionary *info = [self infoPlistForIPA:ipaPath];
    NSMutableArray *bases = [NSMutableArray array];

    void (^harvest)(NSDictionary *) = ^(NSDictionary *iconsDict) {
        if (![iconsDict isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *prim = iconsDict[@"CFBundlePrimaryIcon"];
        NSArray *files = [prim isKindOfClass:[NSDictionary class]] ? prim[@"CFBundleIconFiles"] : nil;
        if ([files isKindOfClass:[NSArray class]]) [bases addObjectsFromArray:files];
    };
    harvest(info[@"CFBundleIcons"]);
    harvest(info[@"CFBundleIcons~ipad"]);
    NSArray *topFiles = info[@"CFBundleIconFiles"];
    if ([topFiles isKindOfClass:[NSArray class]]) [bases addObjectsFromArray:topFiles];
    id single = info[@"CFBundleIconFile"];
    if ([single isKindOfClass:[NSString class]] && [single length]) [bases addObject:single];
    // Common defaults when an app declares nothing.
    [bases addObjectsFromArray:@[ @"AppIcon60x60", @"AppIcon", @"Icon", @"Icon-60", @"icon" ]];

    NSMutableArray *norm = [NSMutableArray array];
    for (id b in bases) {
        if (![b isKindOfClass:[NSString class]] || ![b length]) continue;
        NSString *x = [b lowercaseString];
        if ([x hasSuffix:@".png"]) x = [x substringToIndex:x.length - 4];
        if (x.length && ![norm containsObject:x]) [norm addObject:x];
    }
    if (!norm.count) return nil;

    NSData *raw = [MachOInspector extractLargestEntryFromIPA:ipaPath matching:^BOOL(NSString *name) {
        if (![name hasPrefix:@"Payload/"] || ipaSlashCount(name) != 2) return NO;
        NSString *file = [[name lastPathComponent] lowercaseString];
        if (![file hasSuffix:@".png"]) return NO;
        NSString *stem = [file substringToIndex:file.length - 4];
        for (NSString *base in norm) {
            if ([stem isEqualToString:base]) return YES;
            if ([stem hasPrefix:[base stringByAppendingString:@"@"]]) return YES;   // base@2x / base@3x
            if ([stem hasPrefix:[base stringByAppendingString:@"~"]]) return YES;   // base~ipad
        }
        return NO;
    } maxBytes:3 * 1024 * 1024];
    if (!raw.length) return nil;

    UIImage *img = [UIImage imageWithData:raw];
    if (!img) return raw;                                  // undecodable → ship raw bytes as-is
    NSData *png = UIImagePNGRepresentation(img);           // standard PNG (un-crushes CgBI)
    return png.length ? png : raw;
}

@end
