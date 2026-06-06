//
//  CrashReporter.m
//  AppDrop
//

#import "CrashReporter.h"
#import <UIKit/UIKit.h>
#import "Localization.h"
#import "DeviceInfo.h"
#import "HTTPSClient.h"
#import "CheckpointLog.h"

// Same anonymous endpoint as FeedbackViewController (keep in sync). The Worker turns
// a POST into a GitHub issue; it caps `text` at 8000 chars, so we trim the report
// to the essential header + crashed-thread backtrace + the AppDrop binary-image line
// (everything needed to symbolicate) which stays well under that.
static NSString *const kCRFeedbackURL = @"https://appdrop-feedback.adrienruestlorquet.workers.dev";

// On-device crash report directory (jailbreak). Same place we pulled the iPad 4 log from.
static NSString *const kCRCrashDir = @"/var/mobile/Library/Logs/CrashReporter";

// NSUserDefaults: identity (name|mtime) of the last crash we already prompted about.
static NSString *const kCRSeenKey = @"AppDropLastCrashSeen";

static CrashReporter *gCrashReporter = nil;   // strong ref kept alive across the async alert

@interface CrashReporter () <UIAlertViewDelegate>
@property (nonatomic, copy) NSString *pendingReport;   // full crash text, ready to send
@end

@implementation CrashReporter

+ (void)checkAndOfferReport {
    // Always on the main thread (UIAlertView + UIKit). Defensive: a fault in the crash
    // reporter must never crash the app, so the whole thing is wrapped.
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!gCrashReporter) gCrashReporter = [[CrashReporter alloc] init];
            [gCrashReporter run];
        } @catch (NSException *e) {
            // swallow — best-effort diagnostics only
        }
    });
}

- (void)run {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kCRCrashDir]) return;

    NSString *newestName = nil;
    NSTimeInterval newestMtime = 0;
    [self findNewestCrashName:&newestName mtime:&newestMtime usingFM:fm];

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *seen = [d objectForKey:kCRSeenKey];

    // No AppDrop crash log present.
    if (newestName == nil) {
        if (seen == nil) { [d setObject:@"" forKey:kCRSeenKey]; [d synchronize]; }  // baseline
        CPLog(@"CrashReporter: no AppDrop crash log");
        return;
    }

    NSString *key = [NSString stringWithFormat:@"%@|%ld", newestName, (long)newestMtime];

    // First run with this feature: record a baseline so we never prompt about a crash
    // that happened BEFORE the reporter existed.
    if (seen == nil) {
        [d setObject:key forKey:kCRSeenKey]; [d synchronize];
        CPLog([NSString stringWithFormat:@"CrashReporter: baseline set (%@)", newestName]);
        return;
    }

    // Already prompted about this exact crash.
    if ([seen isEqualToString:key]) { CPLog(@"CrashReporter: no new crash"); return; }

    // A NEW crash log appeared. Read it now, then offer (one prompt per crash).
    NSString *path = [kCRCrashDir stringByAppendingPathComponent:newestName];
    NSString *full = [self readCrashTextAtPath:path];
    if (full.length < 20) {   // unreadable/empty → just baseline so we don't re-try forever
        [d setObject:key forKey:kCRSeenKey]; [d synchronize];
        return;
    }
    self.pendingReport = full;

    // Mark seen NOW so we show exactly one prompt for this crash, even if the user
    // dismisses the app while the prompt is up.
    [d setObject:key forKey:kCRSeenKey]; [d synchronize];
    CPLog([NSString stringWithFormat:@"CrashReporter: NEW crash %@ (%lu chars) -> prompt",
           newestName, (unsigned long)full.length]);

    UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"crash.prompt_title")
                                                message:T(@"crash.prompt_msg")
                                               delegate:self
                                      cancelButtonTitle:T(@"crash.decline")
                                      otherButtonTitles:T(@"crash.send"), nil];
    [a show];
}

#pragma mark - Find newest

- (void)findNewestCrashName:(NSString **)outName mtime:(NSTimeInterval *)outMtime usingFM:(NSFileManager *)fm {
    NSArray *names = [fm contentsOfDirectoryAtPath:kCRCrashDir error:NULL];
    if (names.count == 0) return;

    // Prefer real timestamped "AppDrop_…" reports; fall back to the "LatestCrash-AppDrop"
    // duplicate only if that's all there is (its name is constant, so we key it by mtime).
    NSString *bestName = nil; NSTimeInterval bestMtime = 0;
    NSString *fbName = nil;   NSTimeInterval fbMtime = 0;   // latestcrash fallback

    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *name = [names objectAtIndex:i];
        NSString *lower = [name lowercaseString];
        if ([lower rangeOfString:@"appdrop"].location == NSNotFound) continue;  // iOS5-safe (no containsString:)

        NSString *p = [kCRCrashDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:p error:NULL];
        if (!attrs) continue;
        NSDate *md = [attrs objectForKey:NSFileModificationDate];
        NSTimeInterval mt = md ? [md timeIntervalSince1970] : 0;

        BOOL isLatest = ([lower rangeOfString:@"latestcrash"].location != NSNotFound);
        if (isLatest) {
            if (mt >= fbMtime) { fbMtime = mt; fbName = name; }
        } else {
            if (mt >= bestMtime) { bestMtime = mt; bestName = name; }
        }
    }

    if (bestName) { *outName = bestName; *outMtime = bestMtime; }
    else if (fbName) { *outName = fbName; *outMtime = fbMtime; }
}

#pragma mark - Read + parse

// iOS 5/6 write a .plist whose "description" string holds the human-readable report;
// iOS 7-10 write a text/.ips file directly. Handle both.
- (NSString *)readCrashTextAtPath:(NSString *)path {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    if ([plist isKindOfClass:[NSDictionary class]]) {
        id desc = [plist objectForKey:@"description"];
        if ([desc isKindOfClass:[NSString class]] && [desc length] > 20) return desc;
    }
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (s.length == 0) s = [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:NULL];
    return s ?: @"";
}

// First line → becomes the GitHub issue title (Worker uses text.split("\n")[0]).
- (NSString *)summaryLineFor:(NSString *)full {
    NSString *exc = [self valueForLogKey:@"Exception Type:" in:full];
    NSString *os  = [self valueForLogKey:@"OS Version:" in:full];
    NSMutableString *s = [NSMutableString stringWithString:@"AppDrop crash (auto)"];
    if (exc.length) [s appendFormat:@" — %@", exc];
    if (os.length)  [s appendFormat:@" — %@", os];
    return s;
}

- (NSString *)valueForLogKey:(NSString *)key in:(NSString *)full {
    NSRange r = [full rangeOfString:key];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = r.location + r.length;
    NSRange nl = [full rangeOfString:@"\n" options:0 range:NSMakeRange(start, full.length - start)];
    NSUInteger end = (nl.location != NSNotFound) ? nl.location : full.length;
    NSString *v = [full substringWithRange:NSMakeRange(start, end - start)];
    return [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

// Keep the report small enough for the Worker's 8000-char cap while preserving what
// we need to symbolicate: the header + crashed-thread backtrace are at the TOP; the
// AppDrop binary-image line (load address + UUID) is at the BOTTOM — keep both ends.
- (NSString *)trimmedReport:(NSString *)full {
    if (full.length == 0) return @"";
    NSUInteger headLen = 6000;
    NSString *head = (full.length > headLen) ? [full substringToIndex:headLen] : full;

    NSString *binLine = nil;
    NSRange bi = [full rangeOfString:@"Binary Images:"];
    NSString *tail = (bi.location != NSNotFound) ? [full substringFromIndex:bi.location] : full;
    NSArray *lines = [tail componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *ln = [lines objectAtIndex:i];
        if ([ln rangeOfString:@"AppDrop"].location != NSNotFound &&
            [ln rangeOfString:@"/Applications/"].location != NSNotFound) { binLine = ln; break; }
    }

    NSMutableString *out = [NSMutableString stringWithString:head];
    if (full.length > headLen) {
        [out appendString:@"\n…[truncated]…"];
        // The Binary Images section lives at the very bottom (cut off above) — re-attach just
        // the AppDrop line so the load address + UUID survive for symbolication. When the log
        // wasn't truncated the head already contains it, so don't duplicate.
        if (binLine.length) { [out appendString:@"\n\nBinary Images:\n"]; [out appendString:binLine]; }
    }
    return out;
}

#pragma mark - Send

- (void)sendReport:(NSString *)full {
    NSString *summary = [self summaryLineFor:full];
    NSString *trimmed = [self trimmedReport:full];
    // First line = summary (→ issue title). Body = fenced report.
    NSString *text = [NSString stringWithFormat:@"%@\n\n```\n%@\n```", summary, trimmed];

    NSBundle *b = [NSBundle mainBundle];
    NSDictionary *payload = @{
        @"text":    text,
        @"kind":    @"crash",                                    // documents intent; Worker ignores unknown keys
        @"device":  [DeviceInfo aiSummary] ?: @"",
        @"version": [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
        @"build":   [b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?",
        @"lang":    [Localization currentLanguageCode] ?: @"en",
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];

    [HTTPSClient postURL:kCRFeedbackURL
                 headers:@{@"Content-Type": @"application/json"}
                    body:body timeout:60
              completion:^(NSData *resp, NSInteger code, NSError *err) {
        if (!err && code >= 200 && code < 300) {
            UIAlertView *t = [[UIAlertView alloc] initWithTitle:T(@"crash.thanks_title")
                                                        message:T(@"crash.thanks_msg")
                                                       delegate:nil
                                              cancelButtonTitle:T(@"common.ok")
                                              otherButtonTitles:nil];
            [t show];
        }
        // On failure stay silent — best-effort, already marked seen so we won't nag.
    }];
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    @try {
        if (buttonIndex != alertView.cancelButtonIndex && self.pendingReport.length) {
            [self sendReport:self.pendingReport];
        }
    } @catch (NSException *e) { /* swallow */ }
    self.pendingReport = nil;
}

@end
