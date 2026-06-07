#import <Foundation/Foundation.h>

extern NSString *const InstallManagerJobsChangedNotification;

// v1.3.1: fired once when a job's .ipa lands in the configured download folder
// (iOS 10+ fallback, or iOS 6-9 with "Keep IPA after install" enabled).
// userInfo: { @"savedPath": NSString *, @"jobId": NSString * }.
// Used by the global Filza-launcher prompt in AppDelegate.
extern NSString *const InstallManagerJobSavedNotification;

@interface InstallJob : NSObject
@property (nonatomic, copy) NSString *jobId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *state;     // queued, downloading, installing, completed, failed, cancelled
@property (nonatomic, copy) NSString *message;
@property (nonatomic, assign) NSInteger progress;
@property (nonatomic, strong) NSDate *startedAt;
// For ETA: track byte progress
@property (nonatomic, assign) long long lastBytes;
@property (nonatomic, strong) NSDate *lastBytesAt;
@property (nonatomic, assign) double bytesPerSec;   // computed
@property (nonatomic, assign) long long totalBytes; // parsed from message if available
@property (nonatomic, assign) long long currentBytes;
// Cancellation: written from main thread, polled by the background download loop.
// Atomic for memory ordering (BOOL writes are word-aligned so already atomic on ARMv7,
// but the keyword documents intent and adds a barrier).
@property (atomic, assign) BOOL cancelRequested;
// Pause: like cancel, the download loop polls this and aborts — but the partial .ipa + chunks are
// KEPT (state → "paused") so resumeJob: continues via HTTP Range instead of restarting.
@property (atomic, assign) BOOL pauseRequested;
// v1.3.1: set when the .ipa was archived to the download folder (either iOS 10+
// fallback or the iOS 6-9 "Keep IPA" toggle). Lets observers offer a Filza
// quick-open without re-deriving the path.
@property (nonatomic, copy) NSString *savedPath;
@end

@interface InstallManager : NSObject

+ (instancetype)shared;

// Restart SpringBoard (graceful sbreload, else killall SpringBoard). Refreshes the home screen /
// icon cache — used by the Settings "Respring" row + when an installed app's icon doesn't appear.
+ (BOOL)respring;
- (void)setBackendURL:(NSString *)backendURL;
- (NSString *)backendURL;
@property (nonatomic, assign) BOOL autonomousMode;  // YES = local download via mbedTLS + ipainstaller
- (NSArray *)jobs;
- (void)startInstallWithURL:(NSString *)url
                 completion:(void (^)(NSString *jobId, NSError *error))completion;
- (void)removeJob:(NSString *)jobId;
- (void)clearCompletedJobs;

// Cancel a single job. Idempotent. No-op if the job is already terminal (completed/failed/cancelled).
- (void)cancelJob:(NSString *)jobId;

// Cancel every job that's still active (queued/downloading/installing).
// Returns the number of jobs that were actually cancelled.
- (NSInteger)cancelAllActiveJobs;

// Pause a downloading/queued job (keeps the partial → resumable). No-op on installing/terminal jobs.
- (void)pauseJob:(NSString *)jobId;
// Resume a paused job (re-queues it; the download continues via HTTP Range).
- (void)resumeJob:(NSString *)jobId;
// Pause every paused-able job; resume every paused job. Return how many were affected.
- (NSInteger)pauseAllActiveJobs;
- (NSInteger)resumeAllPausedJobs;
// YES if at least one job is currently paused (for the Install menu's Pause/Resume-all toggle).
- (BOOL)hasPausedJobs;

// Convenience: YES if at least one job is in a non-terminal state.
- (BOOL)hasActiveJobs;

// v2.0.27: dedup helper. Returns YES if there's a job for this URL currently in
// queued/downloading/installing state. Caller uses this to skip re-launching
// installs the user fat-fingered on the install button.
- (BOOL)hasActiveJobForURL:(NSString *)url;

// v1.3.1: where saved .ipas land. Returns user override from NSUserDefaults
// (Settings → Download → Save folder) when set, else +defaultDownloadFolder.
+ (NSString *)configuredDownloadFolder;
+ (NSString *)defaultDownloadFolder;

// v1.6: installed version of an app AppDrop installed via ipainstaller (parsed from
// `ipainstaller -i <bid>` → the "Version:" line), or nil if not installed / unavailable.
// Used by the "Works today" detail screen to offer "Update to vX" when the curated build
// is newer. Spawns a process + waits — call OFF the main thread.
- (NSString *)installedVersionForBundleId:(NSString *)bid;

// v2.0: max simultaneous autonomous app downloads (Settings, 1–8; default 2).
+ (NSInteger)maxConcurrentDownloads;
// Start queued installs up to that limit. Call after the limit changes in Settings.
- (void)pumpQueue;

@end
