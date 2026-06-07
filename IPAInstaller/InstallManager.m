#import "InstallManager.h"
#import "CheckpointLog.h"
#import "HTTPSClient.h"
#import "ParallelDownloader.h"
#import "Localization.h"
#import "MachOInspector.h"
#import "IPAPackage.h"   // #163 — read the .ipa's real bundle id to verify the install on-device
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <sys/mount.h>   // statfs — low-storage guard (#169)
#include <sys/sysctl.h>  // hw.cpu64bit_capable — arm64-only guard (#164)

extern char **environ;

// #164 — YES iff this device's CPU can run 64-bit (arm64) code (Apple A7 and later: iPhone 5s+,
// iPad Air / mini 2+). On every 32-bit device (A4/A5/A5X/A6/A6X — iPhone 4..5c, iPad 1..4, mini 1,
// iPod 3..5) the sysctl is 0 or absent, so we return NO and treat it as 32-bit-only. An arm64-only
// .ipa cannot run there at all (installs but never launches / shows no icon).
static BOOL ADDeviceIs64BitCapable(void) {
    int64_t cap = 0;
    size_t sz = sizeof(cap);
    if (sysctlbyname("hw.cpu64bit_capable", &cap, &sz, NULL, 0) != 0) return NO;
    return cap != 0;
}

// #169 — low-storage install guard. ipainstaller unpacks the .ipa into
// /var/mobile/Applications WHILE the .ipa still occupies tmp, so a download+install
// transiently needs several times the file size on disk. On a nearly-full 8 GB device
// (Reddit: iPhone 3GS) that would fill the disk to 0 bytes mid-install; instead we refuse
// up front with a clear message. NSTemporaryDirectory() and /var/mobile/Applications share
// the /var volume, so its free space governs both the download and the install.
static const double kDLSpaceFactor      = 2.5;  // ~2.5× the file size free to download AND install it
static const double kInstallSpaceFactor = 1.5;  // ~1.5× the .ipa size free for ipainstaller's extraction

// Free bytes available to us on the volume holding tmp + installed apps. -1 = unknown
// (callers then skip the check rather than wrongly block an install).
static long long ADFreeDiskBytes(void) {
    struct statfs s;
    if (statfs([NSTemporaryDirectory() fileSystemRepresentation], &s) == 0)
        return (long long)s.f_bavail * (long long)s.f_bsize;
    return -1;
}

static NSString *ADHumanSize(long long bytes) {
    if (bytes >= 1024LL * 1024 * 1024) return [NSString stringWithFormat:@"%.1f GB", bytes / 1073741824.0];
    return [NSString stringWithFormat:@"%.0f MB", bytes / 1048576.0];
}

NSString *const InstallManagerJobsChangedNotification = @"InstallManagerJobsChangedNotification";
NSString *const InstallManagerJobSavedNotification     = @"InstallManagerJobSavedNotification";
// Legacy keys kept so old preference values are silently ignored (no migration needed):
// IPAInstall.BackendURL, IPAInstall.AutonomousMode — both unused since v1.5.3.

@implementation InstallJob
@end

@interface InstallManager ()
@property (nonatomic, strong) NSMutableDictionary *jobsById;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, copy) NSString *cachedBackendURL;
- (void)attemptDownloadForJob:(InstallJob *)job
                    localPath:(NSString *)localPath
                      attempt:(int)attempt;
- (void)postSavedNotificationForJob:(InstallJob *)job;
- (void)scheduleUICacheRefresh;
- (void)runUICache;
@end

@implementation InstallManager

+ (instancetype)shared {
    static InstallManager *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[InstallManager alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        CPLog(@"  InstallManager.init: jobsById dict");
        _jobsById = [[NSMutableDictionary alloc] init];
        CPLog(@"  InstallManager.init: loadJobsFromDisk");
        @try { [self loadJobsFromDisk]; }
        @catch (NSException *e) { CPLog([NSString stringWithFormat:@"  EXC in loadJobsFromDisk: %@ — %@", e.name, e.reason]); }
        CPLog(@"  InstallManager.init: sweepOrphanTempFiles");
        @try { [self sweepOrphanTempFiles]; }
        @catch (NSException *e) { CPLog([NSString stringWithFormat:@"  EXC in sweepOrphanTempFiles: %@ — %@", e.name, e.reason]); }
        CPLog(@"  InstallManager.init: sweepDocumentsAppDropFolder");
        @try { [self sweepDocumentsAppDropFolder]; }
        @catch (NSException *e) { CPLog([NSString stringWithFormat:@"  EXC in sweepDocumentsAppDropFolder: %@ — %@", e.name, e.reason]); }
        CPLog(@"  InstallManager.init: pollTimer");
        _pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(pollAllActiveJobs)
                                                    userInfo:nil
                                                     repeats:YES];
        CPLog(@"  InstallManager.init: notification observers");
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(saveJobsToDisk)
                                                      name:UIApplicationDidEnterBackgroundNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(saveJobsToDisk)
                                                      name:UIApplicationWillTerminateNotification
                                                    object:nil];
        CPLog(@"  InstallManager.init: DONE");
    }
    return self;
}

// Defensive cleanup on app launch. The happy paths (cancel, error, success) all
// call removeItemAtPath: when the download/install loop finishes. But if the app
// crashes mid-download (v2.0.25/26 hit this), the partial `_inst_<jobid>.ipa` file
// is left behind in NSTemporaryDirectory. Over time this can fill the sandbox.
//
// Each app reinstall via ipainstaller gets a new sandbox UUID, so this isn't a long-term
// hoarder — but better safe than sorry, and it gives us a clean baseline every launch.
// Documents/AppDrop/ collects .ipa files that couldn't be auto-installed (iOS 10+
// where ipainstaller is broken). Cap the directory at 14-day age + 500 MB total
// so a user who downloads dozens of apps doesn't slowly fill up their device.
//   Pass 1: delete anything older than 14 days
//   Pass 2: if still over 500 MB, delete oldest-first until under cap
- (void)sweepDocumentsAppDropFolder {
    NSString *docsRoot = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docsRoot stringByAppendingPathComponent:@"AppDrop"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    if (!names.count) return;

    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-14 * 24 * 3600];
    const long long kSizeCap = 500LL * 1024 * 1024;

    NSMutableArray *items = [NSMutableArray array];
    long long totalSize = 0;
    for (NSString *name in names) {
        if (![name.lowercaseString hasSuffix:@".ipa"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSDate *mtime = attrs[NSFileModificationDate];
        long long size = [attrs[NSFileSize] longLongValue];
        if (!mtime) continue;
        [items addObject:@{ @"path": path, @"mtime": mtime, @"size": @(size) }];
        totalSize += size;
    }

    // Pass 1: age-based
    NSMutableArray *remaining = [NSMutableArray array];
    NSInteger ageDeleted = 0;
    long long ageBytes = 0;
    for (NSDictionary *it in items) {
        if ([it[@"mtime"] compare:cutoff] == NSOrderedAscending) {
            if ([fm removeItemAtPath:it[@"path"] error:nil]) {
                ageDeleted++;
                ageBytes += [it[@"size"] longLongValue];
                totalSize -= [it[@"size"] longLongValue];
            }
        } else {
            [remaining addObject:it];
        }
    }

    // Pass 2: cap-based (oldest first)
    NSArray *sorted = [remaining sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"mtime"] compare:b[@"mtime"]];
    }];
    NSInteger capDeleted = 0;
    long long capBytes = 0;
    for (NSDictionary *it in sorted) {
        if (totalSize <= kSizeCap) break;
        if ([fm removeItemAtPath:it[@"path"] error:nil]) {
            long long s = [it[@"size"] longLongValue];
            totalSize -= s;
            capDeleted++;
            capBytes += s;
        }
    }

    if (ageDeleted + capDeleted > 0) {
        NSLog(@"[InstallManager] Documents/AppDrop sweep: %ld old (%.1f MB) + %ld over-cap (%.1f MB)",
              (long)ageDeleted, ageBytes / 1048576.0,
              (long)capDeleted, capBytes / 1048576.0);
    }
}

- (void)sweepOrphanTempFiles {
    NSString *tmpDir = NSTemporaryDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:tmpDir error:nil];
    // #93: SPARE the partial .ipa / .partN of jobs we still know about (loadJobsFromDisk ran first).
    // A PAUSED (or interrupted) download whose app then got killed — very common on iOS 6 — must keep
    // its partial so resumeJob can continue via Range instead of restarting from 0. The stem
    // `_inst_<jobId[6:]>.ipa` is a prefix of both the final file and its `.partN` sidecars.
    NSMutableSet *protectedStems = [NSMutableSet set];
    for (NSString *jid in _jobsById) {
        if (jid.length > 6)
            [protectedStems addObject:[NSString stringWithFormat:@"_inst_%@.ipa", [jid substringFromIndex:6]]];
    }
    NSInteger n = 0;
    long long bytes = 0;
    for (NSString *name in entries) {
        if (![name hasPrefix:@"_inst_"]) continue;
        // Match both `_inst_<uuid>.ipa` (legacy + final files) and the
        // `.partN` sidecars created by ParallelDownloader (build 9). Both
        // come from a previous crashed/interrupted install and are unsafe
        // to keep across launches — they belong to job UUIDs we no longer
        // know about and a new install will allocate a fresh UUID anyway.
        BOOL isIPA = [name hasSuffix:@".ipa"];
        BOOL isPart = ([name rangeOfString:@".ipa.part"].location != NSNotFound);
        BOOL isProbe = [name hasPrefix:@"_probe_"];  // shouldn't be _inst_ but defensive
        if (!isIPA && !isPart && !isProbe) continue;
        BOOL keep = NO;
        for (NSString *stem in protectedStems) { if ([name hasPrefix:stem]) { keep = YES; break; } }
        if (keep) continue;   // belongs to a known (paused/active) job — don't delete its partial
        NSString *path = [tmpDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        bytes += [attrs[NSFileSize] longLongValue];
        if ([fm removeItemAtPath:path error:nil]) n++;
    }
    if (n > 0) {
        NSLog(@"[InstallManager] swept %ld orphan _inst_*.{ipa,partN} files (%.1f MB total)",
              (long)n, bytes / 1048576.0);
    }
}

// Delete every chunk sidecar (<localPath>.part0, .part1, …) associated with
// `localPath`. Called from terminal failure / user-cancel paths so partial
// chunks don't pile up in /tmp between abandoned downloads.
- (void)deleteChunkSidecarsFor:(NSString *)localPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [localPath stringByDeletingLastPathComponent];
    NSString *base = [localPath lastPathComponent];
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSString *prefix = [base stringByAppendingString:@".part"];
    for (NSString *name in entries) {
        if ([name hasPrefix:prefix]) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
        }
    }
}

- (NSString *)jobsCachePath {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [dir stringByAppendingPathComponent:@"jobs.plist"];
}

- (void)loadJobsFromDisk {
    NSArray *arr = [NSArray arrayWithContentsOfFile:[self jobsCachePath]];
    if (![arr isKindOfClass:[NSArray class]]) return;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-24*3600]; // expire 24h
    for (NSDictionary *d in arr) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSDate *started = d[@"startedAt"];
        if ([started isKindOfClass:[NSDate class]] && [started compare:cutoff] == NSOrderedAscending) continue;
        InstallJob *j = [[InstallJob alloc] init];
        j.jobId = d[@"jobId"];
        j.name = d[@"name"];
        j.url = d[@"url"];
        j.state = d[@"state"];
        j.message = d[@"message"];
        j.progress = [d[@"progress"] integerValue];
        j.startedAt = started ?: [NSDate date];
        // A job persisted as ACTIVE (downloading/installing/connecting/queued) can't survive the
        // app being killed — its download/install thread is gone. Restoring it as-is leaves a
        // zombie: a stuck progress bar the 2 s poll never advances (poll skips local- jobs), and
        // a misleading "downloading…" forever. Reconcile every non-terminal restored job to a
        // clear "interrupted" failed state so the list is honest and the user just re-downloads.
        // (Feedback #30 reopen / #38 background-stops-download — defensive hardening either way.)
        if (![InstallManager isTerminalState:j.state]) {
            j.state = @"failed";
            j.message = T(@"install.state.interrupted");
            j.progress = 0;
        }
        if (j.jobId) _jobsById[j.jobId] = j;
    }
}

- (void)saveJobsToDisk {
    NSMutableArray *arr = [NSMutableArray array];
    for (InstallJob *j in [_jobsById allValues]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"jobId"] = j.jobId ?: @"";
        d[@"name"] = j.name ?: @"";
        d[@"url"] = j.url ?: @"";
        d[@"state"] = j.state ?: @"unknown";
        d[@"message"] = j.message ?: @"";
        d[@"progress"] = @(j.progress);
        d[@"startedAt"] = j.startedAt ?: [NSDate date];
        [arr addObject:d];
    }
    [arr writeToFile:[self jobsCachePath] atomically:YES];
}

// Backend / autonomousMode are now legacy no-ops — the app is fully autonomous.
// All catalog / install / LLM / TTS calls go direct to GitHub Pages, archive.org, Groq, DeepSeek
// and translate.google.com. No backend at all.
- (NSString *)backendURL {
    return @"";  // Empty → any `[backend stringByAppendingString:...]` produces a path-only URL
                 // that NSURL rejects. Code paths that branch on autonomousMode never hit these.
}

- (void)setBackendURL:(NSString *)backendURL { /* no-op, kept for binary compat */ }

- (BOOL)autonomousMode {
    return YES;  // Hard-coded ON. The app no longer supports a backend.
}

- (void)setAutonomousMode:(BOOL)autonomousMode { /* no-op */ }

- (NSArray *)jobs {
    NSArray *all = [_jobsById allValues];
    return [all sortedArrayUsingComparator:^NSComparisonResult(InstallJob *a, InstallJob *b) {
        return [b.startedAt compare:a.startedAt];
    }];
}

- (NSString *)shortNameFromURL:(NSString *)url {
    NSString *path = [[NSURL URLWithString:url] path];
    NSString *last = [path lastPathComponent];
    NSString *decoded = [last stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    return decoded ?: (last ?: url);
}

- (void)startInstallWithURL:(NSString *)url
                 completion:(void (^)(NSString *, NSError *))completion {
    if (self.autonomousMode) {
        [self startAutonomousInstallWithURL:url completion:completion];
        return;
    }
    NSString *endpoint = [[self backendURL] stringByAppendingString:@"/install"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"url": url};
    NSError *jsonErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr) {
        if (completion) completion(nil, jsonErr);
        return;
    }
    [req setHTTPBody:bodyData];
    [req setTimeoutInterval:30];

    [NSURLConnection sendAsynchronousRequest:req
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
        if (err) { if (completion) completion(nil, err); return; }
        NSError *parseErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (parseErr) { if (completion) completion(nil, parseErr); return; }
        NSString *jobId = json[@"jobId"];
        if (!jobId) {
            NSString *msg = json[@"error"] ?: @"unknown error";
            NSError *e = [NSError errorWithDomain:@"IPAInstall" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
            if (completion) completion(nil, e);
            return;
        }
        InstallJob *job = [[InstallJob alloc] init];
        job.jobId = jobId;
        job.url = url;
        job.name = [self shortNameFromURL:url];
        job.state = @"queued";
        job.message = T(@"install.state.queued");
        job.progress = 0;
        job.startedAt = [NSDate date];
        self.jobsById[jobId] = job;
        [self postChanged];
        if (completion) completion(jobId, nil);
    }];
}

#pragma mark - Autonomous install (HTTPSClient + posix_spawn ipainstaller)

- (void)startAutonomousInstallWithURL:(NSString *)url
                            completion:(void (^)(NSString *, NSError *))completion {
    NSString *jobId = [NSString stringWithFormat:@"local-%@",
                         [[NSUUID UUID] UUIDString] ?: [NSString stringWithFormat:@"%lu", (unsigned long)[NSDate date].timeIntervalSince1970]];

    InstallJob *job = [[InstallJob alloc] init];
    job.jobId = jobId;
    job.url = url;
    job.name = [self shortNameFromURL:url];
    job.state = @"queued";
    job.message = T(@"install.state.queued");   // "Waiting…" — pumpQueue flips it to connecting when a slot frees
    job.progress = 0;
    job.startedAt = [NSDate date];
    self.jobsById[jobId] = job;
    if (completion) completion(jobId, nil);
    // Don't start it directly — pumpQueue (via postChanged) starts it only when a download slot
    // is free (Settings → "Simultaneous downloads", 1–8). Otherwise it waits its turn as queued.
    [self postChanged];
}

// Max simultaneous autonomous app downloads. Settings-configurable (1–8); default 2.
+ (NSInteger)maxConcurrentDownloads {
    NSInteger n = [[NSUserDefaults standardUserDefaults] integerForKey:@"IPAInstall.MaxConcurrentDownloads"];
    if (n < 1) n = 2;   // unset (0) or invalid → default 2
    if (n > 8) n = 8;
    return n;
}

// Start queued installs up to the concurrency limit. Idempotent + reentrancy-safe: it claims a
// slot by flipping the job to "downloading" synchronously (so a re-entrant pump counts it) and
// never posts a change itself. Called from -postChanged (which fires on every state change,
// including job completion → the next queued job starts) and when the limit changes in Settings.
- (void)pumpQueue {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self pumpQueue]; }); return; }
    NSInteger maxC = [InstallManager maxConcurrentDownloads];
    NSInteger active = 0;
    NSMutableArray *waiting = [NSMutableArray array];
    for (InstallJob *j in [self.jobsById allValues]) {
        if (![j.jobId hasPrefix:@"local-"]) continue;   // autonomous jobs only
        if ([j.state isEqualToString:@"downloading"] || [j.state isEqualToString:@"installing"]) active++;
        else if ([j.state isEqualToString:@"queued"]) [waiting addObject:j];
    }
    if (active >= maxC || waiting.count == 0) return;
    [waiting sortUsingComparator:^NSComparisonResult(InstallJob *a, InstallJob *b) {
        return [(a.startedAt ?: [NSDate distantPast]) compare:(b.startedAt ?: [NSDate distantPast])];
    }];
    for (InstallJob *j in waiting) {
        if (active >= maxC) break;
        active++;
        j.state = @"downloading";                       // claim the slot before the async hop
        j.message = T(@"install.state.connecting");
        InstallJob *jb = j;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self runAutonomousJob:jb];
        });
    }
}

// Returns the user-configured download folder (Settings → Download → Save
// folder), or the default Documents/AppDrop/ if unset. Always returns an
// absolute path. Directory is created lazily on first save.
+ (NSString *)configuredDownloadFolder {
    NSString *custom = [[NSUserDefaults standardUserDefaults] stringForKey:@"IPAInstall.DownloadFolder"];
    if (custom.length) return custom;
    NSString *docsRoot = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docsRoot stringByAppendingPathComponent:@"AppDrop"];
}

// Returns the default download folder (sandbox Documents/AppDrop/) regardless
// of the user's override. Used by Settings UI to display "Default (xyz)".
+ (NSString *)defaultDownloadFolder {
    NSString *docsRoot = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docsRoot stringByAppendingPathComponent:@"AppDrop"];
}

// Find a destination path that doesn't clash with an existing file at
// preferredPath. Returns preferredPath if no file exists there, otherwise
// "Name (2).ext" / "Name (3).ext" / ... up to (999). Reported by a Reddit
// user archiving multiple downloads on iOS 10.3.3.
+ (NSString *)nonClashingPathFor:(NSString *)preferredPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:preferredPath]) return preferredPath;
    NSString *dir = [preferredPath stringByDeletingLastPathComponent];
    NSString *base = [[preferredPath lastPathComponent] stringByDeletingPathExtension];
    NSString *ext = [preferredPath pathExtension];
    for (NSInteger n = 2; n < 1000; n++) {
        NSString *candidate = ext.length
            ? [dir stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"%@ (%ld).%@", base, (long)n, ext]]
            : [dir stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"%@ (%ld)", base, (long)n]];
        if (![fm fileExistsAtPath:candidate]) return candidate;
    }
    return nil;  // give up after 999 dupes — extremely unlikely
}

// Save a downloaded .ipa into the user's configured download folder so they
// can recover it (open in Filza/iFile) when auto-install can't run, or
// archive a personal collection of installed apps. Used in three cases now:
// (1) iOS 10+ where ipainstaller is broken (mandatory), (2) iOS 6-9 success
// when the "Keep IPA after install" toggle is on, (3) install failure on
// any iOS so the .ipa isn't lost (also gated by toggle).
//
// Conflict policy: appends " (2)", " (3)", … instead of overwriting. The
// previous behaviour silently overwrote, which made batch-archiving useless.
//
// `sourcePath` is moved (or copied, if cross-volume) — caller doesn't need
// to clean it up afterward. Returns the actual destination path (which may
// differ from the requested name due to conflict resolution), or nil on
// failure.
+ (NSString *)saveIPAToDocuments:(NSString *)sourcePath originalURL:(NSString *)url {
    NSString *destDir = [self configuredDownloadFolder];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES
                    attributes:nil error:nil];
    // v1.3 fix: [NSURL URLWithString:url] returns nil for URLs with unencoded
    // spaces (very common on archive.org: "iOS 5/App With Spaces.ipa"), which
    // collapsed every such file to "app.ipa" and overwrote previous downloads.
    // Use NSString's lastPathComponent (a path-style split on '/', does not
    // validate the URL) then percent-decode whatever escapes are in there.
    NSString *lastComp = [url lastPathComponent];
    NSString *decoded = [lastComp stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSString *filename = decoded.length ? decoded : (lastComp.length ? lastComp : @"app.ipa");
    NSString *preferredPath = [destDir stringByAppendingPathComponent:filename];
    NSString *destPath = [self nonClashingPathFor:preferredPath];
    if (!destPath) {
        NSLog(@"[InstallManager] saveIPAToDocuments: 999 name conflicts at %@", destDir);
        return nil;
    }
    NSError *moveErr = nil;
    if (![fm moveItemAtPath:sourcePath toPath:destPath error:&moveErr]) {
        // Move failed (e.g. cross-volume, custom folder is /var/mobile/...).
        // Fall back to copy + delete the source.
        if (![fm copyItemAtPath:sourcePath toPath:destPath error:&moveErr]) {
            NSLog(@"[InstallManager] saveIPAToDocuments failed: %@", moveErr);
            return nil;
        }
        [fm removeItemAtPath:sourcePath error:nil];
    }
    return destPath;
}

// Major iOS version on the running device (e.g. 6 for iOS 6.1.3, 10 for 10.3.4).
// Used to skip ipainstaller on iOS 10+ where it's broken.
+ (NSInteger)iosMajorVersion {
    NSString *v = [[UIDevice currentDevice] systemVersion];
    NSString *firstPart = [[v componentsSeparatedByString:@"."] firstObject];
    return [firstPart integerValue];
}

- (void)runAutonomousJob:(InstallJob *)job {
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *localPath = [tmpDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"_inst_%@.ipa",
                             [job.jobId substringFromIndex:6]]];

    // Phase 1: download with progress + slow-mirror retry.
    dispatch_async(dispatch_get_main_queue(), ^{
        job.state = @"downloading";
        job.message = T(@"install.state.connecting");
        // Don't reset progress here: on resume the job already holds its paused % and the
        // partial .ipa is on disk (Range resume), so keep it rather than flashing 0% → 73%.
        // A fresh job is already at 0, so nothing changes for the normal path.
        [self postChanged];
    });

    [self attemptDownloadForJob:job localPath:localPath attempt:0];
}

// One download attempt against archive.org. On slow-mirror abort, recursively retries
// (up to kMaxMirrorAttempts total). HTTPSClient preserves the partial .ipa between
// attempts and sends Range: bytes=N- so we resume rather than restart — the retry's
// real benefit is that archive.org's load-balancer typically routes the new TCP
// connection to a different CDN node, hopefully a faster one.
- (void)attemptDownloadForJob:(InstallJob *)job
                    localPath:(NSString *)localPath
                      attempt:(int)attempt {
    // 3 attempts total: original + 2 retries. Each retry is ~30s+ apart (the time it
    // takes to detect the stall), so worst case the user waits ~90s before we give up.
    static const int kMaxMirrorAttempts = 3;
    static const double kSlowThresholdBytesPerSec = 100.0 * 1024.0;  // 100 KB/s
    static const NSTimeInterval kSlowCheckWindow = 30.0;             // observe over 30s
    // #171 (AndryTheBeast): past this fraction, leave a slow-but-still-MOVING mirror alone to finish
    // the last few % — switching near the end re-probes/re-splits and threw away progress ("at 97%
    // it jumps to another mirror and I lose half the download"). A truly STALLED mirror (< kStall)
    // is still abandoned, so a dead connection can't hang at 99% forever.
    static const double kNoSwitchPastFraction = 0.90;
    static const double kStallBytesPerSec     = 2.0 * 1024.0;        // < 2 KB/s ≈ dead connection

    __block long long lastReceived = 0;
    __block long long lastTotal = 0;   // #171: latest known total size, for the near-done guard below
    __block NSDate *lastTick = [NSDate date];
    // Slow-mirror detection state. We sample the byte counter every kSlowCheckWindow
    // seconds; if avg throughput in that window is under the threshold AND we have
    // retry budget, we trip slowAbort which the isCancelled block returns YES for.
    __block NSDate *windowStart = [NSDate date];
    __block long long windowStartBytes = 0;
    __block BOOL slowAbort = NO;
    // #169: tripped on the first progress tick if free disk < kDLSpaceFactor × file size.
    __block BOOL spaceAbort = NO;
    __block BOOL spaceChecked = NO;
    __block long long spaceNeedBytes = 0;

    // Stream count from Settings (default 4). 1 disables parallelism and
    // ParallelDownloader transparently falls back to the legacy single-stream
    // path. Anything else triggers probe → chunk split → concurrent downloads.
    NSInteger streams = [[NSUserDefaults standardUserDefaults] integerForKey:@"IPAInstall.ParallelStreams"];
    if (streams <= 0) streams = 4;
    if (streams > 8) streams = 8;

    // #171 (AndryTheBeast, level 2): let the user turn OFF the automatic slow-mirror switching
    // entirely (default ON). When OFF, AppDrop stays on the current mirror no matter how slow; the
    // user switches manually by pausing + resuming (resume re-requests the URL → a fresh node).
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    BOOL autoSwitchMirror = ([prefs objectForKey:@"IPAInstall.AutoSwitchMirror"] == nil)
                            ? YES : [prefs boolForKey:@"IPAInstall.AutoSwitchMirror"];

    __weak InstallJob *weakJob = job;
    [ParallelDownloader downloadURL:job.url
                              toFile:localPath
                         streamCount:streams
                         isCancelled:^BOOL{
        InstallJob *j = weakJob;
        // Abort on cancel OR pause. Pause keeps the partial .ipa + chunks on disk (handled in
        // the completion's pause branch); without this the downloader runs on and the progress
        // ticks below keep overwriting the "paused" UI, so the user sees the download "restart".
        if (!j || j.cancelRequested || j.pauseRequested) return YES;
        if (spaceAbort) return YES;   // #169: not enough free disk to download + install
        // Only consider slow-mirror abort if the user left auto-switch ON (#171 level 2) AND we
        // still have retry budget — otherwise there's no point dropping the connection.
        if (autoSwitchMirror && attempt < kMaxMirrorAttempts - 1) {
            NSTimeInterval elapsed = -[windowStart timeIntervalSinceNow];
            if (elapsed >= kSlowCheckWindow) {
                long long delta = lastReceived - windowStartBytes;
                double bps = elapsed > 0 ? delta / elapsed : 0;
                // #171: near the end, keep a slow-but-still-MOVING mirror (let it finish the last
                // few %); only abandon it if it's effectively dead (< kStallBytesPerSec).
                BOOL nearEnd = (lastTotal > 0 &&
                                lastReceived >= (long long)((double)lastTotal * kNoSwitchPastFraction));
                BOOL keepSlowMirror = nearEnd && (bps >= kStallBytesPerSec);
                if (bps < kSlowThresholdBytesPerSec && !keepSlowMirror) {
                    NSLog(@"[InstallManager] Mirror slow (%.1f KB/s avg over %.0fs) — abort to retry (attempt %d/%d)",
                          bps / 1024.0, elapsed, attempt + 1, kMaxMirrorAttempts);
                    slowAbort = YES;
                    return YES;
                }
                // Healthy speed (or a near-done mirror we're letting finish) — reset the window.
                windowStart = [NSDate date];
                windowStartBytes = lastReceived;
            }
        }
        return NO;
    }
                     progress:^(long long received, long long total) {
        // #169: as soon as the real size is known, make sure there's room to download AND
        // install (ipainstaller extracts while the .ipa is still on disk). If not, trip
        // spaceAbort so isCancelled stops the download now — far better than filling the disk
        // to 0 bytes. Checked once (free space only shrinks as we download).
        if (!spaceChecked && total > 0) {
            spaceChecked = YES;
            long long freeB = ADFreeDiskBytes();
            long long need  = (long long)(total * kDLSpaceFactor);
            // Count bytes already on disk (`received` is large on a resume — the partial .ipa
            // already occupies space) so we don't falsely abort a nearly-finished resume.
            if (freeB >= 0 && (freeB + received) < need) { spaceNeedBytes = need; spaceAbort = YES; }
        }
        NSDate *now = [NSDate date];
        NSTimeInterval dt = [now timeIntervalSinceDate:lastTick];
        double bps = dt > 0 ? (received - lastReceived) / dt : 0;
        lastReceived = received;
        lastTotal = total;
        lastTick = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            InstallJob *j = weakJob;
            if (!j) return;
            // A tick can still arrive between the user pausing and the downloader actually
            // aborting. Don't let it overwrite the "paused" message/progress (would flicker
            // back to "downloading…" and look like the pause failed).
            if (j.pauseRequested || [j.state isEqualToString:@"paused"]) return;
            j.currentBytes = received;
            j.totalBytes = total;
            if (bps > 0) j.bytesPerSec = j.bytesPerSec * 0.5 + bps * 0.5;
            NSInteger pct = total > 0 ? (NSInteger)(received * 100 / total) : 0;
            j.progress = pct;
            j.message = total > 0
                ? [NSString stringWithFormat:T(@"install.state.downloading_full"),
                     received/1048576.0, total/1048576.0, (long)pct]
                : [NSString stringWithFormat:T(@"install.state.downloading_partial"),
                     received/1048576.0];
            [self postChanged];
        });
    }
                   completion:^(BOOL ok, NSInteger status, NSError *err) {
        if (!ok) {
            // #169: aborted because there isn't enough free storage to download + install.
            // Report it clearly and clean up the partial — checked first so the generic
            // network-error path below never masks it.
            if (spaceAbort) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    InstallJob *j = weakJob;
                    if (j) {
                        j.state = @"failed";
                        j.message = [NSString stringWithFormat:T(@"install.error.no_space"),
                                       ADHumanSize(spaceNeedBytes)];
                    }
                    [self postChanged];
                    [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                    [self deleteChunkSidecarsFor:localPath];
                });
                return;
            }
            // Slow-mirror retry: don't surface the failure, just kick off a new attempt.
            // The partial .ipa stays on disk; HTTPSClient will send Range: bytes=N-.
            if (slowAbort && !job.cancelRequested && !job.pauseRequested && attempt < kMaxMirrorAttempts - 1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    InstallJob *j = weakJob;
                    if (!j || j.cancelRequested) return;
                    j.message = [NSString stringWithFormat:T(@"install.state.retrying_mirror"),
                                   attempt + 2, kMaxMirrorAttempts];
                    [self postChanged];
                });
                // Tiny delay before the retry so the progress message is visible and so
                // we don't hammer archive.org if something is very wrong server-side.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self attemptDownloadForJob:job localPath:localPath attempt:attempt + 1];
                });
                return;
            }
            // PAUSE: the loop aborted because the user paused. Keep the partial .ipa + chunks on disk
            // so resumeJob: (which re-queues → attemptDownloadForJob) continues via Range. Free the slot.
            if (job.pauseRequested) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    job.pauseRequested = NO;
                    job.state = @"paused";
                    job.message = T(@"install.state.paused");
                    [self postChanged];
                    [self pumpQueue];   // a paused job no longer holds a download slot
                });
                return;
            }
            BOOL wasCancelled = job.cancelRequested || err.code == 99;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (wasCancelled) {
                    job.state = @"cancelled";
                    job.message = T(@"install.state.cancelled_user");
                } else {
                    job.state = @"failed";
                    NSString *humanReason;
                    if (status == 404) {
                        humanReason = T(@"install.error.404");
                    } else if (status == 403) {
                        humanReason = T(@"install.error.403");
                    } else if (status == 503 || status == 502 || status == 504) {
                        humanReason = [NSString stringWithFormat:T(@"install.error.5xx_archive"), (long)status];
                    } else if (status >= 500) {
                        humanReason = [NSString stringWithFormat:T(@"install.error.5xx_generic"), (long)status];
                    } else if (status > 0) {
                        humanReason = [NSString stringWithFormat:T(@"install.error.http_generic"), (long)status];
                    } else {
                        humanReason = err.localizedDescription ?: T(@"install.error.network");
                    }
                    job.message = [NSString stringWithFormat:T(@"install.error.failed_prefix"), humanReason];
                }
                [self postChanged];
                [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                [self deleteChunkSidecarsFor:localPath];
            });
            return;
        }
        // Last-chance cancellation check: download finished but user clicked Annuler in
        // the brief moment between download-done and install-spawn.
        if (job.cancelRequested) {
            dispatch_async(dispatch_get_main_queue(), ^{
                job.state = @"cancelled";
                job.message = T(@"install.state.cancelled_user");
                [self postChanged];
                [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                [self deleteChunkSidecarsFor:localPath];
            });
            return;
        }

        // FairPlay encryption check (v1.2 build 8).
        // archive.org hosts a mix of cracked .ipas (cryptid=0, runs on any
        // jailbreak) and raw iTunes-purchase dumps that someone forgot to
        // crack (cryptid=1, only runs on the original buyer's Apple ID).
        // Calling ipainstaller on the latter wastes time and slot — the
        // app either silently refuses to launch or crashes on dyld load.
        // We peek the Mach-O header here, before any iOS-version branching,
        // and fail-fast with a clear message so the user can try another
        // mirror. Inspector returns Unknown on any parse / read error,
        // which we treat as "proceed" (false-negative ≪ false-positive).
        MachOInspectionResult enc = [MachOInspector inspectIPA:localPath];
        // The user can opt into installing FairPlay-encrypted IPAs anyway (Settings →
        // "Allow encrypted IPAs"). They won't launch on a different Apple ID, but power users
        // with an on-device decryptor want them installed regardless (Reddit + feedback #47).
        // Default OFF → we still fail-fast with a clear message.
        BOOL allowEncrypted = [[NSUserDefaults standardUserDefaults] boolForKey:@"IPAInstall.AllowEncrypted"];
        if (enc == MachOInspectionResultEncrypted && !allowEncrypted) {
            NSLog(@"[InstallManager] FairPlay-encrypted .ipa detected: %@", job.url);
            dispatch_async(dispatch_get_main_queue(), ^{
                job.state = @"failed";
                job.message = T(@"install.error.fairplay");
                [self postChanged];
                [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
            });
            return;
        }

        // #164: arm64-only guard. A 64-bit-only build (no armv7 slice) installs "successfully"
        // on a 32-bit device but never launches and shows no icon — the user just wasted a
        // (sometimes ~1 GB) download. We read the Mach-O arch set from the downloaded file and
        // fail-fast with a clear message. Only block when we POSITIVELY parsed an arch set, it
        // has NO 32-bit ARM slice, AND this device can't run 64-bit — so a fat (armv7+arm64)
        // build, a 64-bit-capable device, or any parse failure all proceed (false-negative safe).
        {
            MachOArch arch = [MachOInspector architecturesOfIPA:localPath];
            BOOL hasArm32 = (arch & MachOArchARM32) != 0;
            if (arch != MachOArchNone && !hasArm32 && !ADDeviceIs64BitCapable()) {
                NSLog(@"[InstallManager] #164 arm64-only .ipa on a 32-bit device (arch=%lu): %@",
                      (unsigned long)arch, job.url);
                dispatch_async(dispatch_get_main_queue(), ^{
                    job.state = @"failed";
                    job.message = T(@"install.error.arch64");
                    [self postChanged];
                    [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                });
                return;
            }
        }

        // iOS 10+ branch: ipainstaller is broken on iOS 10 (silent failures with
        // "Installed successfully" stdout but no actual app appearing on the home
        // screen). Skip it entirely and save the .ipa to our Documents folder so
        // the user can install it manually via Filza or iFile.
        if ([InstallManager iosMajorVersion] >= 10) {
            NSString *saved = [InstallManager saveIPAToDocuments:localPath
                                                       originalURL:job.url];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (saved) {
                    job.state = @"completed";  // really "saved" but using completed for UI parity
                    job.progress = 100;
                    job.message = [NSString stringWithFormat:T(@"install.modern_ios_msg"), saved];
                    job.savedPath = saved;
                    [self postSavedNotificationForJob:job];
                } else {
                    job.state = @"failed";
                    job.message = [NSString stringWithFormat:T(@"install.error.failed_prefix"),
                                     @"Could not save .ipa to Documents"];
                }
                [self postChanged];
            });
            return;
        }

        // #169: pre-install free-space guard. ipainstaller unpacks the .ipa into
        // /var/mobile/Applications WHILE the .ipa still occupies tmp; on a nearly-full
        // low-storage device (Reddit: iPhone 3GS, 8 GB) that fills the disk to 0 bytes
        // mid-install. Refuse up front with a clear message rather than letting it happen
        // (ipainstaller is a separate process — we can't catch its write failures, only
        // prevent them). The .ipa is downloaded already, so this is the precise moment.
        {
            long long ipaSize = (long long)[[[NSFileManager defaultManager]
                                  attributesOfItemAtPath:localPath error:nil] fileSize];
            long long freeNow = ADFreeDiskBytes();
            long long needNow = (long long)(ipaSize * kInstallSpaceFactor);
            if (ipaSize > 0 && freeNow >= 0 && freeNow < needNow) {
                NSLog(@"[InstallManager] #169 insufficient space to install: free=%lld need=%lld (.ipa=%lld)",
                      freeNow, needNow, ipaSize);
                dispatch_async(dispatch_get_main_queue(), ^{
                    job.state = @"failed";
                    job.message = [NSString stringWithFormat:T(@"install.error.no_space"),
                                     ADHumanSize(needNow)];
                    [self postChanged];
                    [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                });
                return;
            }
        }

        // Phase 2: invoke ipainstaller via posix_spawn
        dispatch_async(dispatch_get_main_queue(), ^{
            job.state = @"installing";
            job.progress = 100;
            job.message = T(@"install.state.installing");
            [self postChanged];
        });
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *out = nil;
            int exitCode = [self runIpainstallerOnFile:localPath capturedOutput:&out];
            BOOL claimed = (exitCode == 0) || (out && [out.lowercaseString rangeOfString:@"successfully"].location != NSNotFound);
            BOOL success = claimed;
            // ipainstaller's exit code is UNRELIABLE on several jailbreaks. The feedback screenshots
            // show two opposite failure modes, both fixed by trusting the DEVICE over the exit code:
            //   • #163/#120/#121: it exits 1 (output stuck at "Analyzing…/Installing…") yet the app
            //     actually installed and appears on the home screen → false "Install failed".
            //   • #150 (iOS 9): it prints "…successfully" / exits 0 yet the app isn't registered.
            // So read the app's REAL bundle id from the downloaded .ipa's Info.plist (most reliable;
            // fall back to parsing stdout) and ask the device whether it's actually installed.
            NSString *vbid = [[IPAPackage metadataForIPA:localPath] objectForKey:@"bid"];
            if (!vbid.length) vbid = [self bundleIdFromInstallerOutput:out];
            if (vbid.length) {
                if (!claimed) {
                    // RESCUE (#163/#120/#121): only when POSITIVELY confirmed installed — a "couldn't
                    // check" must NOT turn a real failure into a false success, so use the strict probe.
                    if ([self isBundleIdDefinitelyInstalled:vbid]) success = YES;
                } else if ([InstallManager iosMajorVersion] >= 9) {
                    // DOWNGRADE (#150): claimed success but not registered. Gate to iOS 9 (where the
                    // silent-fail exists); the tolerant verify returns YES when it can't list, so a
                    // genuinely-working install (e.g. iPad 4 / iOS 6) is never false-failed.
                    if (![self verifyInstalledBundleId:vbid]) {
                        success = NO;
                        out = [(out ?: @"") stringByAppendingString:
                            @"\n[AppDrop] post-install check: app not registered — the install did not take."];
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    job.state = @"completed";
                    [self scheduleUICacheRefresh];   // rebuild the SpringBoard icon cache so the new app appears (feedback #26/#36)
                    NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:
                        @"Installed (.+?) successfully" options:0 error:nil];
                    NSTextCheckingResult *m = r ? [r firstMatchInString:out
                                                                  options:0
                                                                    range:NSMakeRange(0, out.length)] : nil;
                    NSString *name = (m && m.numberOfRanges >= 2)
                        ? [out substringWithRange:[m rangeAtIndex:1]]
                        : @"app";
                    job.message = [NSString stringWithFormat:T(@"install.state.installed_prefix"), name];
                    // v1.3.1: optionally archive the .ipa to the configured download
                    // folder when the user has flipped "Keep IPA after install" in
                    // Settings. Lets users build a personal collection on iOS 6-9
                    // (the iOS 10+ branch saves unconditionally because ipainstaller
                    // is broken there). Default is OFF — we delete the temp file to
                    // avoid surprising the sandbox with multi-GB Documents/ growth.
                    BOOL keepIpa = [[NSUserDefaults standardUserDefaults]
                                     boolForKey:@"IPAInstall.KeepIPAAfterInstall"];
                    if (keepIpa) {
                        NSString *saved = [InstallManager saveIPAToDocuments:localPath
                                                                  originalURL:job.url];
                        // saveIPAToDocuments moves the source on success (consumes
                        // localPath). On failure (nil) the temp may still be around,
                        // so clear it explicitly — we don't want garbage in tmp.
                        if (saved) {
                            job.message = [NSString stringWithFormat:@"%@ — %@",
                                            job.message,
                                            [NSString stringWithFormat:
                                                T(@"install.saved_at_suffix"), saved]];
                            job.savedPath = saved;
                            [self postSavedNotificationForJob:job];
                        } else {
                            [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                        }
                    } else {
                        // Success: delete the temp .ipa, we no longer need it.
                        [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                    }
                } else {
                    // Install failure: delete the .ipa (user feedback v1.2 — they don't
                    // want failed-install .ipas accumulating in Documents/). Users on
                    // iOS 10+ get their .ipa saved automatically via the early-return
                    // branch above, so they're covered. iOS 6-9 users typically just
                    // need to retry, no point keeping garbage around.
                    job.state = @"failed";
                    // #121 ("I don't understand this error"): show a plain, actionable message
                    // instead of the raw "(exit 1): Analyzing _inst_….ipa" jargon. The technical
                    // output still goes to the device console for debugging.
                    NSLog(@"[InstallManager] install failed (exit %d): %@", exitCode, out);
                    job.message = T(@"install.error.install_failed");
                    [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                }
                [self postChanged];
            });
        });
    }];
}

// Run the detected ipainstaller binary with the given string args (@[path] to install,
// or @[@"-i", bid] to query an installed app), capturing stdout+stderr. Returns the process
// exit code, or -1 if no installer binary is found (outOutput then holds a friendly message).
// Synchronous (spawns + waits) — call OFF the main thread.
- (int)runIpainstallerArgs:(NSArray *)args capturedOutput:(NSString **)outOutput {
    // Candidate installer paths, in priority order:
    //   - /usr/bin/ipainstaller        (legacy / iOS 5-9 jailbreaks: autopear's package)
    //   - /usr/bin/appinst             (newer alias used by some repos)
    //   - /var/jb/usr/bin/ipainstaller (rootless jailbreaks: Dopamine, palera1n)
    //   - /var/jb/usr/bin/appinst
    //   - /opt/procursus/bin/ipainstaller (Procursus bootstrap)
    static const char *kInstallerCandidates[] = {
        "/usr/bin/ipainstaller",
        "/usr/bin/appinst",
        "/var/jb/usr/bin/ipainstaller",
        "/var/jb/usr/bin/appinst",
        "/opt/procursus/bin/ipainstaller",
        NULL
    };
    const char *exec = NULL;
    for (int i = 0; kInstallerCandidates[i]; i++) {
        if (access(kInstallerCandidates[i], X_OK) == 0) {
            exec = kInstallerCandidates[i];
            break;
        }
    }
    if (!exec) {
        if (outOutput) {
            *outOutput = T(@"install.error.no_ipainstaller");
        }
        return -1;
    }
    return [self spawnInstaller:exec args:args capturedOutput:outOutput];
}

// Extracted from runIpainstallerArgs: — spawn the installer binary `exec` with [argv0, args…],
// capture stdout+stderr (≤30 KB), and return the child's exit code (-1 on a spawn/pipe error).
// Kept as its own method so the #120/#121 alternate-installer retry can target a specific binary.
// Synchronous (spawns + waits) — call OFF the main thread.
- (int)spawnInstaller:(const char *)exec args:(NSArray *)args capturedOutput:(NSString **)outOutput {
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        if (outOutput) *outOutput = @"pipe() failed";
        return -1;
    }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addclose(&fa, pipefd[0]);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 2);
    posix_spawn_file_actions_addclose(&fa, pipefd[1]);

    // Build argv = [ argv0, args..., NULL ]. argv[0] is the basename matching the chosen exec
    // so the binary's own usage/log lines stay coherent. The fileSystemRepresentation buffers
    // stay valid for this synchronous call because `args` is retained throughout it.
    const char *base = strrchr(exec, '/');
    NSUInteger argc = args.count;
    const char **argv = (const char **)malloc(sizeof(char *) * (argc + 2));
    argv[0] = base ? base + 1 : exec;
    for (NSUInteger i = 0; i < argc; i++) {
        argv[i + 1] = [[args[i] description] fileSystemRepresentation];
    }
    argv[argc + 1] = NULL;
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exec, &fa, NULL, (char *const *)argv, environ);
    free(argv);
    posix_spawn_file_actions_destroy(&fa);
    close(pipefd[1]);

    if (rc != 0) {
        close(pipefd[0]);
        // posix_spawn returns the errno value directly (NOT via the global errno).
        if (outOutput) *outOutput = [NSString stringWithFormat:T(@"install.error.spawn_failed"),
                                         exec, strerror(rc)];
        return -1;
    }

    // Read output (up to ~30 KB; ipainstaller is concise)
    NSMutableData *buf = [NSMutableData data];
    char chunk[1024];
    while (1) {
        ssize_t n = read(pipefd[0], chunk, sizeof(chunk));
        if (n <= 0) break;
        [buf appendBytes:chunk length:n];
        if (buf.length > 30000) break;  // cap
    }
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -2;

    if (outOutput) {
        *outOutput = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
    }
    return exitCode;
}

// Install an .ipa file, with a one-shot ALTERNATE-installer retry (#120/#121).
// ipainstaller and appinst are two different tools; some IPAs / jailbreaks install with one but
// not the other. So: run the primary tool (ipainstaller-family if present); if it reports failure
// AND a *different* tool (appinst-family) exists, retry once with it and keep whichever succeeded.
// (`-l` / `-i` queries still go through runIpainstallerArgs:, which just uses the first installer.)
- (int)runIpainstallerOnFile:(NSString *)path capturedOutput:(NSString **)outOutput {
    NSArray *args = (path.length ? @[path] : @[]);
    static const char *kIpaFamily[] = { "/usr/bin/ipainstaller", "/var/jb/usr/bin/ipainstaller", "/opt/procursus/bin/ipainstaller", NULL };
    static const char *kAppFamily[] = { "/usr/bin/appinst", "/var/jb/usr/bin/appinst", NULL };
    const char *primary = NULL, *alternate = NULL;
    for (int i = 0; kIpaFamily[i]; i++) if (access(kIpaFamily[i], X_OK) == 0) { primary = kIpaFamily[i]; break; }
    for (int i = 0; kAppFamily[i]; i++) if (access(kAppFamily[i], X_OK) == 0) { alternate = kAppFamily[i]; break; }
    if (!primary) { primary = alternate; alternate = NULL; }   // appinst-only device: it's the primary
    if (!primary) {
        if (outOutput) *outOutput = T(@"install.error.no_ipainstaller");
        return -1;
    }

    int rc = [self spawnInstaller:primary args:args capturedOutput:outOutput];
    BOOL ok = (rc == 0) || (outOutput && *outOutput
                            && [(*outOutput).lowercaseString rangeOfString:@"successfully"].location != NSNotFound);
    if (ok || !alternate) return rc;

    // Primary failed and a different installer tool exists — retry once with it.
    NSString *altOut = nil;
    int altRc = [self spawnInstaller:alternate args:args capturedOutput:&altOut];
    BOOL altOk = (altRc == 0) || (altOut
                                  && [altOut.lowercaseString rangeOfString:@"successfully"].location != NSNotFound);
    if (altOk) {
        if (outOutput) *outOutput = altOut;
        return altRc;
    }
    return rc;   // both tools failed → keep the primary tool's output for the error message
}

// #150: pull a reverse-DNS bundle id (e.g. com.foo.bar) out of ipainstaller's output so we can
// confirm the install really registered. Returns nil if none is found (→ skip verification).
- (NSString *)bundleIdFromInstallerOutput:(NSString *)out {
    if (!out.length) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"[A-Za-z][A-Za-z0-9_-]*(\\.[A-Za-z0-9_-]+){2,}" options:0 error:NULL];
    NSTextCheckingResult *m = re ? [re firstMatchInString:out options:0
                                                    range:NSMakeRange(0, out.length)] : nil;
    return (m && m.range.location != NSNotFound) ? [out substringWithRange:m.range] : nil;
}

// #150: YES if the bundle id is confirmed installed (it appears in `ipainstaller -l`). If we
// can't list (no installer, or -l failed), returns YES — we never downgrade a success we
// can't actually disprove. Synchronous (spawns + waits) — call OFF the main thread.
- (BOOL)verifyInstalledBundleId:(NSString *)bid {
    if (!bid.length) return YES;
    NSString *out = nil;
    int rc = [self runIpainstallerArgs:@[@"-l"] capturedOutput:&out];
    if (rc != 0 || !out.length) return YES;            // can't list → assume OK
    if ([out rangeOfString:bid].location != NSNotFound) return YES;   // listed → installed
    // #163: `ipainstaller -l`'s output format varies by build (some print display names, not
    // bundle ids), so its silence isn't proof of absence — it false-failed good installs.
    // Cross-check with `-i <bid>`, which returns the app's info iff it's actually registered.
    // Only when BOTH `-l` and `-i` say "absent" do we treat the install as failed.
    return ([self installedVersionForBundleId:bid] != nil);
}

// #163 — STRICT installed-check for the rescue path. Unlike verifyInstalledBundleId: (which
// returns YES when it can't list, so it never false-FAILS a claimed success), this returns YES
// ONLY on a POSITIVE confirmation (`-l` lists the bid, or `-i <bid>` returns its info). A
// "couldn't check" returns NO — we must not turn a genuine install failure into a false success.
// Synchronous (spawns + waits) — call OFF the main thread.
- (BOOL)isBundleIdDefinitelyInstalled:(NSString *)bid {
    if (!bid.length) return NO;
    NSString *out = nil;
    int rc = [self runIpainstallerArgs:@[@"-l"] capturedOutput:&out];
    if (rc == 0 && out.length && [out rangeOfString:bid].location != NSNotFound) return YES;
    return ([self installedVersionForBundleId:bid] != nil);
}

// After a successful install the new icon often won't appear on SpringBoard until the icon
// cache is rebuilt — ipainstaller doesn't reliably trigger it on every jailbreak (feedback
// #26/#36: "I download it but it doesn't show on my home screen"). uicache rebuilds it.
// It's expensive, so coalesce a burst of installs (multi-select) into a single run.
static NSInteger gUICacheToken = 0;

- (void)scheduleUICacheRefresh {
    NSInteger token = ++gUICacheToken;
    // Run soon, at DEFAULT priority (was 2.5 s / LOW) so the icon actually appears before the
    // user leaves the app — the single most common confusion ("installed but not on my home
    // screen": feedback #24/#40/#50/#74 + Reddit). Still coalesces a burst of multi-select installs.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (token != gUICacheToken) return;   // a newer install rescheduled — let that later one run uicache
        [self runUICache];
    });
}

+ (BOOL)respring {
    // sbreload re-execs SpringBoard gracefully; killall SpringBoard is the harder fallback. Either
    // rebuilds the home screen so a freshly-installed app's icon appears. We spawn and return — the
    // respring tears down SpringBoard (and usually this app with it), so there's nothing to wait for.
    static const char *kSbreload[] = {
        "/usr/bin/sbreload", "/var/jb/usr/bin/sbreload", "/opt/procursus/bin/sbreload", NULL };
    for (int i = 0; kSbreload[i]; i++) {
        if (access(kSbreload[i], X_OK) == 0) {
            const char *slash = strrchr(kSbreload[i], '/');
            char *const argv[] = { (char *)(slash ? slash + 1 : kSbreload[i]), NULL };
            pid_t pid = 0;
            if (posix_spawn(&pid, kSbreload[i], NULL, NULL, argv, environ) == 0) return YES;
        }
    }
    static const char *kKillall[] = { "/usr/bin/killall", "/bin/killall", "/var/jb/usr/bin/killall", NULL };
    for (int i = 0; kKillall[i]; i++) {
        if (access(kKillall[i], X_OK) == 0) {
            char *const argv[] = { (char *)"killall", (char *)"SpringBoard", NULL };
            pid_t pid = 0;
            if (posix_spawn(&pid, kKillall[i], NULL, NULL, argv, environ) == 0) return YES;
        }
    }
    return NO;   // no sbreload / killall found on this device
}

- (void)runUICache {
    static const char *kUICacheCandidates[] = {
        "/usr/bin/uicache",            // legacy / iOS 5-10 jailbreaks (our audience)
        "/var/jb/usr/bin/uicache",     // rootless jailbreaks
        "/opt/procursus/bin/uicache",  // Procursus bootstrap
        NULL
    };
    const char *exec = NULL;
    for (int i = 0; kUICacheCandidates[i]; i++) {
        if (access(kUICacheCandidates[i], X_OK) == 0) { exec = kUICacheCandidates[i]; break; }
    }
    if (!exec) return;   // no uicache on this device — nothing we can do
    const char *slash = strrchr(exec, '/');
    char *const argv[] = { (char *)(slash ? slash + 1 : exec), NULL };  // bare `uicache` = rebuild all (legacy)
    pid_t pid = 0;
    if (posix_spawn(&pid, exec, NULL, NULL, argv, environ) == 0) {
        int status = 0;
        waitpid(pid, &status, 0);
    }
}

// Installed version of an app AppDrop installed via ipainstaller, parsed from the
// "Version:" line of `ipainstaller -i <bid>`. nil if not installed / no installer.
// ipainstaller -i only knows apps IT installed — system/dpkg apps return nil, which the
// caller treats as "not installed" (button stays "Install"). Call OFF the main thread.
- (NSString *)installedVersionForBundleId:(NSString *)bid {
    if (!bid.length) return nil;
    NSString *out = nil;
    int rc = [self runIpainstallerArgs:@[@"-i", bid] capturedOutput:&out];
    if (rc != 0 || !out.length) return nil;
    for (NSString *raw in [out componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line rangeOfString:@"Version:"].location == 0) {
            NSString *v = [[line substringFromIndex:[@"Version:" length]]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (v.length) return v;
        }
    }
    return nil;
}

- (void)pollAllActiveJobs {
    for (InstallJob *job in [self.jobsById allValues]) {
        if ([InstallManager isTerminalState:job.state]) continue;
        // Local autonomous jobs update themselves via callbacks — no backend to poll
        if ([job.jobId hasPrefix:@"local-"]) continue;
        [self pollJob:job.jobId];
    }
}

- (void)pollJob:(NSString *)jobId {
    NSString *endpoint = [NSString stringWithFormat:@"%@/install/status?id=%@",
                          [self backendURL], jobId];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:endpoint]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:10];
    [NSURLConnection sendAsynchronousRequest:req
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
        InstallJob *job = self.jobsById[jobId];
        if (!job) return;
        // Detect HTTP error (e.g. 404 job not found = backend restart)
        NSInteger statusCode = 200;
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            statusCode = [(NSHTTPURLResponse *)resp statusCode];
        }
        if (err || !data) {
            if (![job.state isEqualToString:@"completed"] &&
                ![job.state isEqualToString:@"failed"]) {
                job.state = @"failed";
                job.message = [NSString stringWithFormat:@"Reseau : %@",
                                 err.localizedDescription ?: @"timeout"];
                [self postChanged];
            }
            return;
        }
        if (statusCode == 404) {
            job.state = @"failed";
            job.message = @"Job perdu (backend redemarre?)";
            [self postChanged];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) return;
        NSString *state = json[@"status"] ?: json[@"state"];
        if (state) job.state = state;
        NSNumber *prog = json[@"progress"];
        if (prog) job.progress = [prog integerValue];
        NSString *msg = json[@"message"];
        if (msg) job.message = msg;

        // Parse bytes from messages like "Telechargement: 25.3 MB / 349.0 MB (7%)"
        if (msg.length) {
            NSError *re_err = nil;
            NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:
                @"([0-9.]+)\\s*MB\\s*/\\s*([0-9.]+)\\s*MB"
                options:0 error:&re_err];
            if (r) {
                NSTextCheckingResult *m = [r firstMatchInString:msg
                                                          options:0
                                                            range:NSMakeRange(0, msg.length)];
                if (m && m.numberOfRanges >= 3) {
                    NSString *curStr = [msg substringWithRange:[m rangeAtIndex:1]];
                    NSString *totStr = [msg substringWithRange:[m rangeAtIndex:2]];
                    long long cur = (long long)([curStr doubleValue] * 1024 * 1024);
                    long long tot = (long long)([totStr doubleValue] * 1024 * 1024);
                    job.totalBytes = tot;
                    // Compute speed
                    NSDate *now = [NSDate date];
                    if (job.lastBytesAt && cur > job.lastBytes) {
                        NSTimeInterval dt = [now timeIntervalSinceDate:job.lastBytesAt];
                        if (dt > 0.5) {
                            double bps = (double)(cur - job.lastBytes) / dt;
                            job.bytesPerSec = job.bytesPerSec > 0
                                ? (job.bytesPerSec * 0.6 + bps * 0.4)  // EMA
                                : bps;
                            job.lastBytes = cur;
                            job.lastBytesAt = now;
                        }
                    } else {
                        job.lastBytes = cur;
                        job.lastBytesAt = now;
                    }
                    job.currentBytes = cur;
                }
            }
        }
        [self postChanged];
    }];
}

- (void)removeJob:(NSString *)jobId {
    [self.jobsById removeObjectForKey:jobId];
    [self postChanged];
}

- (void)clearCompletedJobs {
    NSMutableArray *toRemove = [NSMutableArray array];
    for (InstallJob *j in [self.jobsById allValues]) {
        if ([j.state isEqualToString:@"completed"]
            || [j.state isEqualToString:@"failed"]
            || [j.state isEqualToString:@"cancelled"]) {
            [toRemove addObject:j.jobId];
        }
    }
    for (NSString *jid in toRemove) [self.jobsById removeObjectForKey:jid];
    [self postChanged];
}

// Job is terminal if no more work will happen against it.
+ (BOOL)isTerminalState:(NSString *)state {
    return [state isEqualToString:@"completed"]
        || [state isEqualToString:@"failed"]
        || [state isEqualToString:@"cancelled"];
}

- (void)cancelJob:(NSString *)jobId {
    InstallJob *job = self.jobsById[jobId];
    if (!job) return;
    if ([InstallManager isTerminalState:job.state]) return;
    job.cancelRequested = YES;
    // Reflect intent immediately in the UI; the actual download loop will exit on its
    // next iteration and we'll get the final state update from the completion block.
    // We still set state=cancelled here so the UI doesn't show "downloading..." while
    // we wait for the loop to notice. The completion block will overwrite with the
    // same value if it runs first.
    job.state = @"cancelled";
    job.message = T(@"install.state.cancelling");
    [self postChanged];
}

- (NSInteger)cancelAllActiveJobs {
    NSInteger count = 0;
    for (InstallJob *j in [self.jobsById allValues]) {
        if (![InstallManager isTerminalState:j.state]) {
            j.cancelRequested = YES;
            j.state = @"cancelled";
            j.message = T(@"install.state.cancelling");
            count++;
        }
    }
    if (count > 0) [self postChanged];
    return count;
}

#pragma mark - Pause / Resume

// Pausable = queued or downloading (NOT installing — ipainstaller can't be paused — nor terminal/paused).
- (BOOL)isPausableState:(NSString *)state {
    return [state isEqualToString:@"queued"] || [state isEqualToString:@"downloading"];
}

- (void)pauseJob:(NSString *)jobId {
    InstallJob *job = self.jobsById[jobId];
    if (!job || ![self isPausableState:job.state]) return;
    BOOL wasDownloading = [job.state isEqualToString:@"downloading"];
    job.state = @"paused";
    job.message = T(@"install.state.paused");
    if (wasDownloading) {
        job.pauseRequested = YES;   // the running loop polls this, aborts, and KEEPS the partial
    } else {
        [self pumpQueue];           // it was only queued — nothing to abort; free nothing, just refresh queue
    }
    [self postChanged];
}

- (void)resumeJob:(NSString *)jobId {
    InstallJob *job = self.jobsById[jobId];
    if (!job || ![job.state isEqualToString:@"paused"]) return;
    job.pauseRequested = NO;
    job.state = @"queued";          // pumpQueue restarts it; the partial .ipa resumes via HTTP Range
    job.message = T(@"install.state.queued");
    [self postChanged];
    [self pumpQueue];
}

- (NSInteger)pauseAllActiveJobs {
    NSInteger count = 0;
    for (InstallJob *j in [[self.jobsById allValues] copy])
        if ([self isPausableState:j.state]) { [self pauseJob:j.jobId]; count++; }
    return count;
}

- (NSInteger)resumeAllPausedJobs {
    NSInteger count = 0;
    for (InstallJob *j in [[self.jobsById allValues] copy])
        if ([j.state isEqualToString:@"paused"]) { [self resumeJob:j.jobId]; count++; }
    return count;
}

- (BOOL)hasPausedJobs {
    for (InstallJob *j in [self.jobsById allValues])
        if ([j.state isEqualToString:@"paused"]) return YES;
    return NO;
}

- (BOOL)hasActiveJobs {
    for (InstallJob *j in [self.jobsById allValues]) {
        if (![InstallManager isTerminalState:j.state]) return YES;
    }
    return NO;
}

- (BOOL)hasActiveJobForURL:(NSString *)url {
    if (!url.length) return NO;
    for (InstallJob *j in [self.jobsById allValues]) {
        if (![j.url isEqualToString:url]) continue;
        if ([InstallManager isTerminalState:j.state]) continue;
        return YES;
    }
    return NO;
}

- (void)postChanged {
    [self updateIdleTimer];   // keep the screen awake while a download/install is in progress
    [[NSNotificationCenter defaultCenter] postNotificationName:InstallManagerJobsChangedNotification
                                                        object:self];
    [self pumpQueue];   // start the next queued install when a slot frees (or a new one is added)
}

// Prevent the auto-lock from interrupting an active download/install — a common complaint was the
// screen turning off mid-download. Stay awake while ANY job is downloading/installing/queued; return
// to normal once everything is done/paused. (idleTimerDisabled is per-process, so it also auto-resets
// when the app quits to hand off to ipainstaller.) Applied on the main thread (UIApplication).
- (void)updateIdleTimer {
    BOOL active = NO;
    for (InstallJob *j in [self.jobsById allValues]) {
        if ([j.state isEqualToString:@"downloading"] ||
            [j.state isEqualToString:@"installing"] ||
            [j.state isEqualToString:@"queued"]) { active = YES; break; }
    }
    dispatch_block_t apply = ^{ [UIApplication sharedApplication].idleTimerDisabled = active; };
    if ([NSThread isMainThread]) apply(); else dispatch_async(dispatch_get_main_queue(), apply);
}

// v1.3.1: fired once per save. AppDelegate observes globally and pops a
// "Open in Filza" prompt. Posted on the main queue (callers above are already
// on main via dispatch_async).
- (void)postSavedNotificationForJob:(InstallJob *)job {
    if (!job.savedPath.length) return;
    NSDictionary *info = @{ @"savedPath": job.savedPath,
                            @"jobId":     job.jobId ?: @"" };
    [[NSNotificationCenter defaultCenter] postNotificationName:InstallManagerJobSavedNotification
                                                        object:self
                                                      userInfo:info];
}

@end
