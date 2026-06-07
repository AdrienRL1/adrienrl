#import "ParallelDownloader.h"
#import "HTTPSClient.h"
#import "Localization.h"
#import <CoreFoundation/CoreFoundation.h>

@implementation ParallelDownloader

+ (void)downloadURL:(NSString *)url
              toFile:(NSString *)finalPath
         streamCount:(NSInteger)streamCount
         isCancelled:(BOOL (^)(void))isCancelled
            progress:(void (^)(long long, long long))progressBlock
          completion:(void (^)(BOOL, NSInteger, NSError *))completion {
    if (streamCount < 1) streamCount = 1;
    if (streamCount > 16) streamCount = 16;  // sanity cap

    // streamCount=1: skip the probe + chunk machinery entirely and fall back
    // to the legacy single-stream path. This mirrors build 8 exactly so a
    // user who turned parallel off in Settings sees zero behavior change.
    if (streamCount == 1) {
        [HTTPSClient downloadURL:url toFile:finalPath
                     isCancelled:isCancelled progress:progressBlock
                      completion:completion];
        return;
    }

    [HTTPSClient probeURL:url completion:^(long long totalSize, BOOL rangeSupported, NSError *probeErr) {
        // Fall back to single-stream when:
        //   - Probe failed entirely (DNS / connect error)
        //   - Server doesn't support Range (200 instead of 206 on bytes=0-0)
        //   - File too small to benefit from chunking (<4 MB ÷ N streams = tiny
        //     chunks; the per-chunk setup overhead outweighs the bandwidth gain)
        if (probeErr || !rangeSupported || totalSize <= 0) {
            NSLog(@"[ParallelDownloader] probe failed (size=%lld range=%@) — falling back to single-stream",
                  totalSize, rangeSupported ? @"YES" : @"NO");
            [HTTPSClient downloadURL:url toFile:finalPath
                         isCancelled:isCancelled progress:progressBlock
                          completion:completion];
            return;
        }
        long long minChunkSize = 1LL * 1024 * 1024;  // 1 MB
        if (totalSize / streamCount < minChunkSize) {
            // Tiny file — single stream is fine.
            NSLog(@"[ParallelDownloader] file too small (%lld bytes) for %ld chunks — single stream",
                  totalSize, (long)streamCount);
            [HTTPSClient downloadURL:url toFile:finalPath
                         isCancelled:isCancelled progress:progressBlock
                          completion:completion];
            return;
        }
        [self runChunkedDownload:url
                          toFile:finalPath
                       totalSize:totalSize
                     streamCount:streamCount
                     isCancelled:isCancelled
                        progress:progressBlock
                      completion:completion];
    }];
}

+ (void)runChunkedDownload:(NSString *)url
                    toFile:(NSString *)finalPath
                 totalSize:(long long)totalSize
               streamCount:(NSInteger)streamCount
               isCancelled:(BOOL (^)(void))isCancelled
                  progress:(void (^)(long long, long long))progressBlock
                completion:(void (^)(BOOL, NSInteger, NSError *))completion {

    // Split [0, totalSize) into `streamCount` contiguous chunks. The last
    // chunk absorbs the rounding remainder so the sum is exactly totalSize.
    NSMutableArray *ranges = [NSMutableArray arrayWithCapacity:streamCount];
    NSMutableArray *chunkPaths = [NSMutableArray arrayWithCapacity:streamCount];
    long long base = totalSize / streamCount;
    long long acc = 0;
    for (NSInteger i = 0; i < streamCount; i++) {
        long long start = acc;
        long long size = (i == streamCount - 1) ? (totalSize - acc) : base;
        long long end = start + size - 1;
        acc = end + 1;
        NSRange r = NSMakeRange((NSUInteger)start, (NSUInteger)size);
        [ranges addObject:[NSValue valueWithRange:r]];
        NSString *cp = [NSString stringWithFormat:@"%@.part%ld", finalPath, (long)i];
        [chunkPaths addObject:cp];
    }
    NSLog(@"[ParallelDownloader] splitting %lld bytes into %ld chunks (~%lld bytes each)",
          totalSize, (long)streamCount, base);

    // Shared state across chunk callbacks. NSLock protects mutation of these.
    NSMutableArray *chunkBytesArr = [NSMutableArray arrayWithCapacity:streamCount];
    NSMutableArray *chunkOkArr = [NSMutableArray arrayWithCapacity:streamCount];
    NSMutableArray *chunkErrArr = [NSMutableArray arrayWithCapacity:streamCount];
    NSMutableArray *chunkCodeArr = [NSMutableArray arrayWithCapacity:streamCount];
    for (NSInteger i = 0; i < streamCount; i++) {
        // Pre-populate per-chunk slot with bytes already on disk so the very
        // first aggregate progress fires the correct resumed value, not 0.
        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:chunkPaths[i] error:nil];
        long long existing = attrs ? [attrs[NSFileSize] longLongValue] : 0;
        [chunkBytesArr addObject:@(existing)];
        [chunkOkArr addObject:@NO];
        [chunkErrArr addObject:[NSNull null]];
        [chunkCodeArr addObject:@0];
    }
    __block CFAbsoluteTime lastAggregateFire = 0;  // 0 = "never fired"; first tick always passes the 0.3s gate
    NSLock *lock = [[NSLock alloc] init];
    __block BOOL anyChunkFailed = NO;

    // Composite isCancelled: aborts when the user cancels OR any chunk has
    // failed permanently (then the others stop quickly to avoid wasting bw).
    BOOL (^chunkIsCancelled)(void) = ^BOOL {
        if (isCancelled && isCancelled()) return YES;
        [lock lock]; BOOL fail = anyChunkFailed; [lock unlock];
        return fail;
    };

    dispatch_group_t group = dispatch_group_create();
    for (NSInteger i = 0; i < streamCount; i++) {
        dispatch_group_enter(group);
        NSRange r = [ranges[i] rangeValue];
        long long start = (long long)r.location;
        long long end = start + (long long)r.length - 1;
        NSString *cp = chunkPaths[i];
        NSInteger idx = i;
        [HTTPSClient downloadChunk:url
                          fromByte:start
                            toByte:end
                            toFile:cp
                       isCancelled:chunkIsCancelled
                          progress:^(long long chunkReceived, long long chunkTotal) {
            // Update this chunk's byte count and possibly fire an aggregate
            // progress callback (throttled to ~3 times/sec to avoid burning
            // CPU on tiny updates).
            BOOL shouldFire = NO;
            long long aggregateReceived = 0;
            [lock lock];
            chunkBytesArr[idx] = @(chunkReceived);
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastAggregateFire > 0.3) {
                shouldFire = YES;
                lastAggregateFire = now;
                for (NSInteger j = 0; j < streamCount; j++) {
                    aggregateReceived += [chunkBytesArr[j] longLongValue];
                }
            }
            [lock unlock];
            if (shouldFire && progressBlock) {
                progressBlock(aggregateReceived, totalSize);
            }
        }
                        completion:^(BOOL ok, NSInteger code, NSError *err) {
            [lock lock];
            chunkOkArr[idx] = @(ok);
            chunkCodeArr[idx] = @(code);
            chunkErrArr[idx] = err ?: (NSError *)[NSNull null];
            if (!ok && err.code != 99) {  // non-cancel failure
                anyChunkFailed = YES;
                NSLog(@"[ParallelDownloader] chunk %ld failed: status=%ld err=%@",
                      (long)idx, (long)code, err.localizedDescription);
            }
            [lock unlock];
            dispatch_group_leave(group);
        }];
    }

    // When all chunks are done, decide success/failure and concatenate.
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL allOk = YES;
        NSError *firstErr = nil;
        NSInteger firstFailCode = 0;
        for (NSInteger i = 0; i < streamCount; i++) {
            if (![chunkOkArr[i] boolValue]) {
                allOk = NO;
                if (!firstErr) {
                    id e = chunkErrArr[i];
                    firstErr = (e == [NSNull null]) ? nil : (NSError *)e;
                    firstFailCode = [chunkCodeArr[i] integerValue];
                }
            }
        }
        if (!allOk) {
            // Leave partial chunk files on disk — InstallManager's slow-
            // mirror retry will pick up where we left off via Range resume.
            // Only the cancellation path / terminal failure path (in
            // InstallManager) will sweep them.
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, firstFailCode, firstErr);
            });
            return;
        }
        // All chunks succeeded — concatenate into finalPath.
        NSError *concatErr = nil;
        BOOL concatOk = [self concatenateChunks:chunkPaths
                                       intoFile:finalPath
                                          error:&concatErr];
        // Always cleanup the part files, even on concat failure (they're
        // garbage at this point — either fully consumed or we'll restart).
        for (NSString *cp in chunkPaths) {
            [[NSFileManager defaultManager] removeItemAtPath:cp error:nil];
        }
        if (!concatOk) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, 0, concatErr);
            });
            return;
        }
        // Fire one final progress callback at 100% so the UI doesn't sit at
        // 99.7%-or-whatever because the throttle ate the last update.
        if (progressBlock) progressBlock(totalSize, totalSize);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES, 200, nil);
        });
    });
}

// Concatenate `chunkPaths` in order into `finalPath`. 64 KB buffer keeps
// memory bounded (concatenating a 100 MB IPA only ever holds 64 KB resident).
+ (BOOL)concatenateChunks:(NSArray *)chunkPaths
                 intoFile:(NSString *)finalPath
                    error:(NSError **)outError {
    FILE *out = fopen([finalPath fileSystemRepresentation], "wb");
    if (!out) {
        if (outError) *outError = [NSError errorWithDomain:@"ParallelDownloader"
                                                       code:1
                                                   userInfo:@{NSLocalizedDescriptionKey:
                                                                T(@"install.error.open_final")}];
        return NO;
    }
    uint8_t buf[65536];
    for (NSString *path in chunkPaths) {
        FILE *in = fopen([path fileSystemRepresentation], "rb");
        if (!in) {
            fclose(out);
            [[NSFileManager defaultManager] removeItemAtPath:finalPath error:nil];
            if (outError) *outError = [NSError errorWithDomain:@"ParallelDownloader"
                                                           code:2
                                                       userInfo:@{NSLocalizedDescriptionKey:
                                                                    [NSString stringWithFormat:
                                                                       T(@"install.error.open_chunk"),
                                                                       [path lastPathComponent]]}];
            return NO;
        }
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
            if (fwrite(buf, 1, n, out) != n) {
                fclose(in);
                fclose(out);
                [[NSFileManager defaultManager] removeItemAtPath:finalPath error:nil];
                if (outError) *outError = [NSError errorWithDomain:@"ParallelDownloader"
                                                               code:3
                                                           userInfo:@{NSLocalizedDescriptionKey:
                                                                        T(@"install.error.concat_write")}];
                return NO;
            }
        }
        fclose(in);
        // #169: free each chunk the moment it's been copied, so the peak disk use during
        // assembly is ~1× the final size instead of 2× (all parts + the growing final at
        // once). Critical on low-storage devices (Reddit: iPhone 3GS, 8 GB). The caller's
        // post-concat cleanup loop then just no-ops on the already-deleted parts.
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    fclose(out);
    return YES;
}

@end
