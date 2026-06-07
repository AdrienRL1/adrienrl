#import "CheckpointLog.h"
#include <syslog.h>

// Write to several places at once because on iOS 5 a system-installed app
// at /Applications/ has a sandboxed /tmp/ that doesn't match what an SSH
// session sees. By fanning the log through:
//   1) syslog (always reachable via /var/log/syslog over SSH)
//   2) NSLog (also routes to syslog)
//   3) a couple of disk paths
// we're guaranteed at least one will show what happened.

static void cpAppendAtPath(NSString *path, NSString *line) {
    if (!path || !line) return;
    @try {
        NSString *withNewline = [line stringByAppendingString:@"\n"];
        NSData *bytes = [withNewline dataUsingEncoding:NSUTF8StringEncoding];
        if (!bytes.length) return;
        FILE *f = fopen([path fileSystemRepresentation], "a");
        if (!f) return;
        fwrite([bytes bytes], 1, [bytes length], f);
        fflush(f);
        fclose(f);
    } @catch (__unused id e) {}
}

static void cpAppend(NSString *line) {
    if (!line) return;
    @try {
        // 1) syslog — survives any FS sandbox restriction
        syslog(LOG_NOTICE, "AppDrop %s", [line UTF8String]);
        // 2) NSLog — convenient on Mac during dev, also lands in syslog
        NSLog(@"AppDrop %@", line);
        // 3) disk attempts
        cpAppendAtPath(@"/var/mobile/Documents/appdrop-launch.log", line);
    } @catch (__unused id e) {}
}

void CPLog(NSString *label) {
    if (!label) label = @"(nil)";
    // ISO-ish timestamp without bringing in NSDateFormatter (lighter, also
    // safer if NSDateFormatter has issues on iOS 5 with unset locale).
    NSDate *now = [NSDate date];
    NSTimeInterval t = [now timeIntervalSince1970];
    long sec = (long)t;
    int ms = (int)((t - (NSTimeInterval)sec) * 1000);
    NSString *line = [NSString stringWithFormat:@"[%ld.%03d] %@", sec, ms, label];
    cpAppend(line);
}

void CPLogReset(void) {
    @try {
        // Best-effort wipe on each disk path; syslog isn't wipeable but the
        // boundary line below is enough to identify a fresh launch.
        FILE *f2 = fopen("/var/mobile/Documents/appdrop-launch.log", "w");
        if (f2) fclose(f2);
    } @catch (__unused id e) {}
    CPLog(@"=== launch begin ===");
}
