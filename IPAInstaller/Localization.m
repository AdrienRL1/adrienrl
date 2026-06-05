#import "Localization.h"

NSString *AppDropT(NSString *key) {
    if (!key) return @"";
    // Look the key up in the ACTIVE language's strings dictionary, loaded DIRECTLY
    // from the file (NOT via NSBundle, whose localization resolution returned the
    // wrong language when the chosen language differed from the device language --
    // that was the "Turkish shows English" bug). Fall back to English, then raw key.
    NSString *code = [Localization currentLanguageCode];
    id v = [[Localization stringsForCode:code] objectForKey:key];
    if ([v isKindOfClass:[NSString class]]) return v;
    if (![code isEqualToString:@"en"]) {
        id ev = [[Localization stringsForCode:@"en"] objectForKey:key];
        if ([ev isKindOfClass:[NSString class]]) return ev;
    }
    return key;
}

// Hand-rolled .strings parser. iOS 6's Foundation parsers (propertyListFromStringsFileFormat
// AND dictionaryWithContentsOfFile, in BOTH text and binary form) return an EMPTY dict for
// some perfectly-valid files — notably Turkish — which caused "Turkish shows English"
// (macOS parses the exact same files to 296 keys). This scanner reads the UTF-8 text
// OURSELVES (consecutive quoted tokens = key, value), so Foundation's quirks can't break it.
// Handles // and /* */ comments and \n \t \r \" \\ escapes.
static NSDictionary *AppDropParseStrings(NSString *text) {
    NSUInteger n = text.length;
    if (!n) return nil;
    unichar *c = (unichar *)malloc(sizeof(unichar) * n);
    unichar *tmp = (unichar *)malloc(sizeof(unichar) * n);
    if (!c || !tmp) { free(c); free(tmp); return nil; }
    [text getCharacters:c range:NSMakeRange(0, n)];
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:320];
    NSString *pendingKey = nil;
    NSUInteger i = 0;
    while (i < n) {
        unichar ch = c[i];
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') { i++; continue; }
        if (ch == '/' && i + 1 < n && c[i+1] == '/') { i += 2; while (i < n && c[i] != '\n') i++; continue; }
        if (ch == '/' && i + 1 < n && c[i+1] == '*') { i += 2; while (i + 1 < n && !(c[i]=='*' && c[i+1]=='/')) i++; i = (i + 1 < n) ? i + 2 : n; continue; }
        if (ch != '"') { i++; continue; }   // '=', ';' or stray → skip
        i++;
        NSUInteger len = 0;
        while (i < n && c[i] != '"') {
            if (c[i] == '\\' && i + 1 < n) {
                i++; unichar e = c[i];
                if (e == 'n') tmp[len++] = '\n';
                else if (e == 't') tmp[len++] = '\t';
                else if (e == 'r') tmp[len++] = '\r';
                else tmp[len++] = e;            // \" \\ etc. → literal char
                i++;
            } else {
                tmp[len++] = c[i++];
            }
        }
        if (i < n) i++;   // skip closing quote
        NSString *tok = [NSString stringWithCharacters:tmp length:len];
        if (pendingKey == nil) {
            pendingKey = tok;
        } else {
            if (pendingKey.length) [out setObject:tok forKey:pendingKey];
            pendingKey = nil;
        }
    }
    free(c); free(tmp);
    return out;
}

NSString *const kLocalizationDidChangeNotification = @"LocalizationDidChange";

static NSString *const kUserDefaultsKey = @"IPAInstall.Language";
static NSBundle *_cachedBundle = nil;
static NSString *_cachedCode = nil;
static NSBundle *_enBundle = nil;

@implementation Localization

+ (NSString *)currentLanguageCode {
    if (_cachedCode) return _cachedCode;

    // 1. Manual override (Settings → Language)
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:kUserDefaultsKey];
    if (override.length) {
        _cachedCode = [override copy];
        return _cachedCode;
    }

    // 2. iOS device preferred language. Match case-insensitively and on the base
    //    language so region variants resolve correctly: "tr-TR" → tr, "fr-CA" → fr,
    //    "pt" → pt-BR, "zh-Hans-CN" → zh-Hans. iOS only lists a language here if it
    //    is declared in CFBundleLocalizations (Info.plist) — all 8 are.
    NSArray *preferred = [NSLocale preferredLanguages];
    NSArray *supported = [self availableLanguageCodes];
    for (NSString *pref in preferred) {
        NSString *p = [pref lowercaseString];
        // exact (case-insensitive) match first
        for (NSString *sup in supported) {
            if ([p isEqualToString:[sup lowercaseString]]) { _cachedCode = [sup copy]; return _cachedCode; }
        }
        // then base-language match ("tr-TR" → "tr", "pt" → "pt-BR")
        NSString *pBase = [[[p componentsSeparatedByString:@"-"] firstObject]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!pBase.length) continue;
        for (NSString *sup in supported) {
            NSString *sBase = [[[sup lowercaseString] componentsSeparatedByString:@"-"] firstObject];
            if ([pBase isEqualToString:sBase]) { _cachedCode = [sup copy]; return _cachedCode; }
        }
    }

    // 3. Default to English
    _cachedCode = @"en";
    return _cachedCode;
}

+ (NSBundle *)currentBundle {
    if (_cachedBundle) return _cachedBundle;
    NSString *code = [self currentLanguageCode];
    NSString *path = [[NSBundle mainBundle] pathForResource:code ofType:@"lproj"];
    if (!path) {
        // "pt-BR" → try base "pt"
        NSString *base = [[code componentsSeparatedByString:@"-"] firstObject];
        path = [[NSBundle mainBundle] pathForResource:base ofType:@"lproj"];
    }
    if (!path) path = [[NSBundle mainBundle] pathForResource:@"en" ofType:@"lproj"];
    _cachedBundle = [([NSBundle bundleWithPath:path] ?: [NSBundle mainBundle]) retain];
    return _cachedBundle;
}

+ (NSBundle *)englishBundle {
    if (_enBundle) return _enBundle;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"en" ofType:@"lproj"];
    _enBundle = [((path ? [NSBundle bundleWithPath:path] : nil) ?: [NSBundle mainBundle]) retain];
    return _enBundle;
}

+ (NSDictionary *)stringsForCode:(NSString *)code {
    if (!code.length) code = @"en";
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [[NSMutableDictionary dictionary] retain];
    NSDictionary *cached = cache[code];
    if (cached) return cached;   // per-code, immutable → safe to keep across switches
    NSString *lproj = [[NSBundle mainBundle] pathForResource:code ofType:@"lproj"];
    if (!lproj) {
        NSString *base = [[code componentsSeparatedByString:@"-"] firstObject];
        if (base.length) lproj = [[NSBundle mainBundle] pathForResource:base ofType:@"lproj"];
    }
    NSDictionary *loaded = nil;
    if (lproj) {
        // PRIMARY: Localizable.json (generated at build from the .strings). iOS 6's
        // NSJSONSerialization is rock-solid for all Unicode, unlike its .strings/plist
        // parser — which returns 0 keys for some valid files (Turkish), even Theos's
        // binary-compiled .strings. THIS is the real "Turkish shows English" fix.
        NSData *jd = [NSData dataWithContentsOfFile:[lproj stringByAppendingPathComponent:@"Localizable.json"]];
        if (jd.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) loaded = obj;
        }
        // Fallbacks: our hand-rolled UTF-8 .strings scanner, then Foundation's reader.
        if (![loaded isKindOfClass:[NSDictionary class]] || loaded.count == 0) {
            NSString *file = [lproj stringByAppendingPathComponent:@"Localizable.strings"];
            NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];
            if (text.length) loaded = AppDropParseStrings(text);
            if (![loaded isKindOfClass:[NSDictionary class]] || loaded.count == 0)
                loaded = [NSDictionary dictionaryWithContentsOfFile:file];
        }
    }
    if (![loaded isKindOfClass:[NSDictionary class]]) loaded = [NSDictionary dictionary];
    cache[code] = loaded;
    return loaded;
}

+ (void)setLanguageCode:(NSString *)code {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (code.length) {
        [d setObject:code forKey:kUserDefaultsKey];
    } else {
        [d removeObjectForKey:kUserDefaultsKey];
    }
    [d synchronize];
    _cachedBundle = nil;
    _cachedCode = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:kLocalizationDidChangeNotification
                                                         object:nil];
}

+ (NSArray *)availableLanguageCodes {
    // Scan .lproj folders directly. [[NSBundle mainBundle] localizations] returns BOTH
    // the .lproj folders AND any CFBundleLocalizations declared in Info.plist, causing
    // duplicates ("en" + "en" etc.). Direct scan is the source of truth.
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *file in contents) {
        if (![file hasSuffix:@".lproj"]) continue;
        NSString *code = [file stringByDeletingPathExtension];
        if ([code isEqualToString:@"Base"]) continue;
        if ([seen containsObject:code]) continue;
        [seen addObject:code];
        [out addObject:code];
    }
    // Stable order: en first, then alpha
    [out sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if ([a isEqualToString:@"en"]) return NSOrderedAscending;
        if ([b isEqualToString:@"en"]) return NSOrderedDescending;
        return [a compare:b];
    }];
    return out;
}

+ (NSString *)displayNameForLanguageCode:(NSString *)code {
    static NSDictionary *names = nil;
    if (!names) {
        names = [@{
            @"en":      @"English",
            @"fr":      @"Français",
            @"es":      @"Español",
            @"de":      @"Deutsch",
            @"pt-BR":   @"Português (BR)",
            @"pt":      @"Português",
            @"ja":      @"日本語",
            @"zh-Hans": @"简体中文",
            @"zh":      @"中文",
            @"zh-Hant": @"繁體中文",
            @"tr":      @"Türkçe",
            @"it":      @"Italiano",
            @"ko":      @"한국어",
            @"ru":      @"Русский",
        } retain];
    }
    return names[code] ?: code;
}

@end
