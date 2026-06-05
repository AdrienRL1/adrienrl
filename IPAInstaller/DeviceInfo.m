#import "DeviceInfo.h"
#import "Localization.h"
#import <sys/sysctl.h>
#import <UIKit/UIKit.h>

@implementation DeviceInfo

// identifier (hw.machine) -> @[ model name, chip, RAM ]
// Covers every device that can plausibly run iOS 6 → iOS 10, including the
// community / unofficially-upgraded ones (iPod touch 3G, iPad 1 …). Many
// identifiers map to the same marketing model (Wi-Fi / cellular / region revs).
+ (NSDictionary *)table {
    static NSDictionary *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = [@{
            // ---- iPod touch ----
            @"iPod1,1": @[@"iPod touch (1st gen)", @"Samsung S5L8900 (ARM11)", @"128 MB"],
            @"iPod2,1": @[@"iPod touch (2nd gen)", @"Samsung S5L8720 (ARM11)", @"128 MB"],
            @"iPod3,1": @[@"iPod touch (3rd gen)", @"Samsung S5L8922 (Cortex-A8)", @"256 MB"],
            @"iPod4,1": @[@"iPod touch (4th gen)", @"Apple A4", @"256 MB"],
            @"iPod5,1": @[@"iPod touch (5th gen)", @"Apple A5", @"512 MB"],
            @"iPod7,1": @[@"iPod touch (6th gen)", @"Apple A8", @"1 GB"],

            // ---- iPhone ----
            @"iPhone1,1": @[@"iPhone (1st gen)", @"Samsung S5L8900 (ARM11)", @"128 MB"],
            @"iPhone1,2": @[@"iPhone 3G", @"Samsung S5L8900 (ARM11)", @"128 MB"],
            @"iPhone2,1": @[@"iPhone 3GS", @"Samsung S5PC100 (Cortex-A8)", @"256 MB"],
            @"iPhone3,1": @[@"iPhone 4 (GSM)", @"Apple A4", @"512 MB"],
            @"iPhone3,2": @[@"iPhone 4 (GSM, rev A)", @"Apple A4", @"512 MB"],
            @"iPhone3,3": @[@"iPhone 4 (CDMA)", @"Apple A4", @"512 MB"],
            @"iPhone4,1": @[@"iPhone 4S", @"Apple A5", @"512 MB"],
            @"iPhone5,1": @[@"iPhone 5 (GSM)", @"Apple A6", @"1 GB"],
            @"iPhone5,2": @[@"iPhone 5 (Global)", @"Apple A6", @"1 GB"],
            @"iPhone5,3": @[@"iPhone 5c (GSM)", @"Apple A6", @"1 GB"],
            @"iPhone5,4": @[@"iPhone 5c (Global)", @"Apple A6", @"1 GB"],
            @"iPhone6,1": @[@"iPhone 5s (GSM)", @"Apple A7", @"1 GB"],
            @"iPhone6,2": @[@"iPhone 5s (Global)", @"Apple A7", @"1 GB"],
            @"iPhone7,2": @[@"iPhone 6", @"Apple A8", @"1 GB"],
            @"iPhone7,1": @[@"iPhone 6 Plus", @"Apple A8", @"1 GB"],
            @"iPhone8,1": @[@"iPhone 6s", @"Apple A9", @"2 GB"],
            @"iPhone8,2": @[@"iPhone 6s Plus", @"Apple A9", @"2 GB"],
            @"iPhone8,4": @[@"iPhone SE (1st gen)", @"Apple A9", @"2 GB"],
            @"iPhone9,1": @[@"iPhone 7", @"Apple A10 Fusion", @"2 GB"],
            @"iPhone9,3": @[@"iPhone 7", @"Apple A10 Fusion", @"2 GB"],
            @"iPhone9,2": @[@"iPhone 7 Plus", @"Apple A10 Fusion", @"3 GB"],
            @"iPhone9,4": @[@"iPhone 7 Plus", @"Apple A10 Fusion", @"3 GB"],

            // ---- iPad ----
            @"iPad1,1": @[@"iPad (1st gen)", @"Apple A4", @"256 MB"],
            @"iPad2,1": @[@"iPad 2 (Wi-Fi)", @"Apple A5", @"512 MB"],
            @"iPad2,2": @[@"iPad 2 (GSM)", @"Apple A5", @"512 MB"],
            @"iPad2,3": @[@"iPad 2 (CDMA)", @"Apple A5", @"512 MB"],
            @"iPad2,4": @[@"iPad 2 (Wi-Fi, 2012)", @"Apple A5", @"512 MB"],
            @"iPad2,5": @[@"iPad mini (1st gen, Wi-Fi)", @"Apple A5", @"512 MB"],
            @"iPad2,6": @[@"iPad mini (1st gen, GSM)", @"Apple A5", @"512 MB"],
            @"iPad2,7": @[@"iPad mini (1st gen, Global)", @"Apple A5", @"512 MB"],
            @"iPad3,1": @[@"iPad (3rd gen, Wi-Fi)", @"Apple A5X", @"1 GB"],
            @"iPad3,2": @[@"iPad (3rd gen, CDMA)", @"Apple A5X", @"1 GB"],
            @"iPad3,3": @[@"iPad (3rd gen, GSM)", @"Apple A5X", @"1 GB"],
            @"iPad3,4": @[@"iPad (4th gen, Wi-Fi)", @"Apple A6X", @"1 GB"],
            @"iPad3,5": @[@"iPad (4th gen, GSM)", @"Apple A6X", @"1 GB"],
            @"iPad3,6": @[@"iPad (4th gen, Global)", @"Apple A6X", @"1 GB"],
            @"iPad4,1": @[@"iPad Air (Wi-Fi)", @"Apple A7", @"1 GB"],
            @"iPad4,2": @[@"iPad Air (Cellular)", @"Apple A7", @"1 GB"],
            @"iPad4,3": @[@"iPad Air (China)", @"Apple A7", @"1 GB"],
            @"iPad4,4": @[@"iPad mini 2", @"Apple A7", @"1 GB"],
            @"iPad4,5": @[@"iPad mini 2 (Cellular)", @"Apple A7", @"1 GB"],
            @"iPad4,6": @[@"iPad mini 2 (China)", @"Apple A7", @"1 GB"],
            @"iPad4,7": @[@"iPad mini 3", @"Apple A7", @"1 GB"],
            @"iPad4,8": @[@"iPad mini 3 (Cellular)", @"Apple A7", @"1 GB"],
            @"iPad4,9": @[@"iPad mini 3 (China)", @"Apple A7", @"1 GB"],
            @"iPad5,1": @[@"iPad mini 4 (Wi-Fi)", @"Apple A8", @"2 GB"],
            @"iPad5,2": @[@"iPad mini 4 (Cellular)", @"Apple A8", @"2 GB"],
            @"iPad5,3": @[@"iPad Air 2 (Wi-Fi)", @"Apple A8X", @"2 GB"],
            @"iPad5,4": @[@"iPad Air 2 (Cellular)", @"Apple A8X", @"2 GB"],
            @"iPad6,11": @[@"iPad (5th gen, Wi-Fi)", @"Apple A9", @"2 GB"],
            @"iPad6,12": @[@"iPad (5th gen, Cellular)", @"Apple A9", @"2 GB"],
        } retain];
    });
    return t;
}

+ (NSString *)hardwareIdentifier {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char buf[96]; size_t sz = sizeof(buf);
        if (sysctlbyname("hw.machine", buf, &sz, NULL, 0) == 0 && sz > 0) {
            NSString *m = [NSString stringWithUTF8String:buf];
            cached = [(m.length ? m : @"?") retain];
        } else {
            cached = [@"?" retain];
        }
    });
    return cached;
}

+ (NSArray *)entry {
    return [self table][[self hardwareIdentifier]];
}

+ (BOOL)isKnown { return [self entry] != nil; }

+ (NSString *)modelName {
    NSArray *e = [self entry];
    return (e.count >= 1) ? e[0] : [self hardwareIdentifier];
}

+ (NSString *)chip {
    NSArray *e = [self entry];
    return (e.count >= 2) ? e[1] : @"?";
}

+ (NSString *)ram {
    NSArray *e = [self entry];
    return (e.count >= 3) ? e[2] : @"?";
}

+ (NSString *)aiSummaryWithIOSVersion:(NSString *)iosVersion {
    NSString *ios = iosVersion.length ? iosVersion : @"?";
    if ([self isKnown]) {
        // "iPad mini 2 (iPad4,4), Apple A7, 1 GB RAM, iOS 10.3.3"
        return [NSString stringWithFormat:@"%@ (%@), %@, %@ RAM, iOS %@",
                [self modelName], [self hardwareIdentifier], [self chip], [self ram], ios];
    }
    // Unknown identifier: still give the raw id + idiom so the model has something.
    NSString *idiom = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        ? @"iPad" : @"iPhone/iPod touch";
    return [NSString stringWithFormat:@"%@ (%@), iOS %@", [self hardwareIdentifier], idiom, ios];
}

+ (NSString *)aiSummary {
    return [self aiSummaryWithIOSVersion:[[UIDevice currentDevice] systemVersion]];
}

#pragma mark - v1.6 compatibility verdict

+ (NSInteger)ramMB {
    NSString *r = [self ram];           // "256 MB", "1 GB", "2 GB", "?"
    if (![r isKindOfClass:[NSString class]] || r.length < 2) return 0;
    NSScanner *sc = [NSScanner scannerWithString:r];
    double n = 0;
    if (![sc scanDouble:&n]) return 0;
    if ([r rangeOfString:@"GB"].location != NSNotFound) return (NSInteger)(n * 1024.0);
    if ([r rangeOfString:@"MB"].location != NSNotFound) return (NSInteger)n;
    return 0;
}

// numeric compare of dotted versions: returns YES if a < b. Missing parts = 0.
static BOOL versionLess(NSString *a, NSString *b) {
    NSArray *pa = [a componentsSeparatedByString:@"."];
    NSArray *pb = [b componentsSeparatedByString:@"."];
    NSUInteger n = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger va = (i < pa.count) ? [pa[i] integerValue] : 0;
        NSInteger vb = (i < pb.count) ? [pb[i] integerValue] : 0;
        if (va < vb) return YES;
        if (va > vb) return NO;
    }
    return NO;
}

// "6.0.0" -> "6.0", "4.0.0" -> "4.0", "5.1.1" -> "5.1.1" (drop a trailing .0 patch).
static NSString *prettyVersion(NSString *v) {
    if (!v.length) return @"";
    NSArray *p = [v componentsSeparatedByString:@"."];
    if (p.count == 3 && [p[2] integerValue] == 0)
        return [NSString stringWithFormat:@"%@.%@", p[0], p[1]];
    return v;
}

// STRICT verdict: only what the EXACT IPA's real metadata can prove.
//   • real minimum iOS (extracted from the binary) vs the device's running iOS
//   • real platform bitmask (iPad-only binaries can't install on an iPhone/iPod)
// No AI-derived RAM / "demand" guesses, no invented "known issues".
+ (NSDictionary *)compatibilityVerdictForAppMinIOS:(NSString *)appMinIOS
                                          platform:(NSInteger)platform {
    NSString *dev    = [self modelName];
    NSString *iosNow = [[UIDevice currentDevice] systemVersion] ?: @"";
    BOOL deviceIsPad = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);

    // Real platform bitmask straight from the IPA: bit1 (2) = iPhone/iPod, bit2 (4) = iPad.
    BOOL appOnIPhone = (platform & 2) != 0;
    BOOL appOnIPad   = (platform & 4) != 0;

    // 1) iPad-only binary on an iPhone/iPod -> cannot install -> red.
    //    (iPhone apps DO run on iPad in compatibility mode, so that case stays green.)
    if (appOnIPad && !appOnIPhone && !deviceIsPad) {
        return @{@"level": @2,
                 @"message": [NSString stringWithFormat:T(@"app.verdict.ipad_only"), dev]};
    }

    // 2) Real minimum iOS of THIS exact version. "0.0.0"/empty = unspecified in the IPA.
    NSInteger major = [appMinIOS integerValue];   // "6.0.0" -> 6, "0.0.0" -> 0
    if (major >= 1) {
        if (versionLess(iosNow, appMinIOS)) {
            return @{@"level": @2,
                     @"message": [NSString stringWithFormat:T(@"app.verdict.ios"),
                                  prettyVersion(appMinIOS), iosNow]};
        }
        return @{@"level": @0,
                 @"message": [NSString stringWithFormat:T(@"app.verdict.perfect"), dev]};
    }

    // 3) No real iOS data and no platform conflict -> make no claim (no banner).
    return nil;
}

@end
