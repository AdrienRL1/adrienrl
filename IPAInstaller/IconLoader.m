#import "IconLoader.h"
#import "HTTPSClient.h"
#import "IOS5Compat.h"
#import <ImageIO/ImageIO.h>

// One pending icon request. Returned to the caller (AppTileView) as an opaque cancel token so a
// reused cell can drop the icon it no longer needs. Several requests can share one URL key (dedup):
// each carries its own completion + cancelled flag. An op whose key has NO live (non-cancelled)
// request short-circuits instead of decoding — this is what drains the stale backlog during a
// fast fling so the currently-visible tiles' icons resolve immediately.
@interface ADIconReq : NSObject
@property (nonatomic, copy)   void (^completion)(UIImage *);
@property (nonatomic, copy)   NSString *key;
@property (nonatomic, assign) BOOL cancelled;
@end
@implementation ADIconReq @end

@interface IconLoader ()
@property (nonatomic, strong) NSCache *cache;            // decoded UIImages (RAM)
@property (nonatomic, strong) NSMutableDictionary *pending;
@property (nonatomic, strong) NSMutableDictionary *failedAt;
@property (nonatomic, strong) NSOperationQueue *downloadQueue;
@property (nonatomic, strong) NSOperationQueue *diskDecodeQueue;  // disk read+decode (separate from network; NOT suspended on scroll)
@property (nonatomic, strong) NSMutableArray *queuedOps;  // pending fetch ops → visible-first reordering
@property (nonatomic, strong) NSString *diskDir;         // persistent thumbnail cache
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, assign) CGFloat screenScale;       // cached [UIScreen mainScreen].scale (read once on main)
// Declared up front because it's called (returning BOOL, used in an if) before its definition; without
// this the compiler would assume an id return and the short-circuit guard would always be truthy.
- (BOOL)keyAbandoned:(NSString *)key;
@end

static const NSTimeInterval kFailureCooldown = 300;  // 5 minutes

// Tiny stable hash → disk filename (djb2). Collisions are astronomically unlikely and
// at worst show one wrong (already-valid) icon, so no crypto hash needed.
static NSString *IconDiskName(NSString *key) {
    const char *s = [key UTF8String];
    unsigned long h = 5381; int c;
    while ((c = (unsigned char)*s++)) h = ((h << 5) + h) + (unsigned long)c;
    return [NSString stringWithFormat:@"%lx_%lu.png", h, (unsigned long)key.length];
}

// Force-decode a (lazily-decoded) UIImage into a raw RGBA bitmap on the CURRENT (background)
// thread. `+[UIImage imageWithData:]` defers the PNG decode until the image is first drawn —
// which happens ON THE MAIN THREAD during scrolling → the #1 cause of icon scroll-jank for
// disk-cached icons. Pre-decoding here means the main thread only blits ready pixels.
static UIImage *IconForceDecode(UIImage *image) {
    if (!image) return nil;
    CGImageRef cg = image.CGImage;
    if (!cg) return image;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return image;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return image;
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);   // <- the actual decode, off-main
    CGImageRef decoded = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!decoded) return image;
    UIImage *out = [UIImage imageWithCGImage:decoded scale:image.scale orientation:UIImageOrientationUp];
    CGImageRelease(decoded);
    return out;
}

@implementation IconLoader

+ (instancetype)shared {
    static IconLoader *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[IconLoader alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache = [[NSCache alloc] init];
        // Disk now backs the cache, so keep the RAM cache modest — much kinder to the
        // iPad 1 (256 MB). Anything evicted is re-loaded from disk in ~ms, not re-downloaded.
        // Scale the RAM cache to the device: A4 256 MB devices get a tiny cap, 512 MB the
        // (unchanged) 240/28 MB, newer devices a larger one. Eviction just re-reads disk.
        NSUInteger ram = (NSUInteger)[[NSProcessInfo processInfo] physicalMemory];
        if (ram <= 300 * 1024 * 1024) {
            _cache.countLimit = 120;
            _cache.totalCostLimit = 14 * 1024 * 1024;
        } else if (ram <= 640 * 1024 * 1024) {
            _cache.countLimit = 240;
            _cache.totalCostLimit = 28 * 1024 * 1024;   // ~2-3 extra screens → fewer disk reloads
        } else {
            _cache.countLimit = 480;
            _cache.totalCostLimit = 64 * 1024 * 1024;
        }
        // Cache the screen scale once on the main thread → background decode paths read the
        // ivar instead of touching UIScreen off-main (same value, just thread-safe).
        CGFloat s = [UIScreen mainScreen].scale;
        _screenScale = s > 0 ? s : 1.0;
        _pending = [NSMutableDictionary dictionary];
        _failedAt = [NSMutableDictionary dictionary];

        _downloadQueue = [[NSOperationQueue alloc] init];
        _downloadQueue.name = @"icon-download";
        // Bounded concurrency now ACTUALLY applies to the HTTPS path (icons run as
        // operations here). 8 fills the visible page a bit faster without the old
        // "90 simultaneous TLS handshakes" thrash that spiked CPU+RAM on old devices.
        // Single-core A4 (iPad 1 / iPhone 4) → only 2: more TLS handshakes than that just
        // thrash the one core. >=2 cores keeps the unchanged 8.
        NSUInteger cores = ADRecommendedConcurrency();
        _downloadQueue.maxConcurrentOperationCount = (cores <= 1) ? 2 : MIN((NSUInteger)8, cores * 4);
        _queuedOps = [NSMutableArray array];

        // Separate queue for disk read+decode. Kept apart from the network queue so that
        // suspend/resume (scroll gating) only pauses NETWORK fetches — already-cached icons
        // keep decoding off disk during a scroll. Tiny concurrency to avoid disk thrash.
        _diskDecodeQueue = [[NSOperationQueue alloc] init];
        _diskDecodeQueue.name = @"icon-disk";
        // Disk read + decode runs on a LOW-priority background queue (never starves the UI thread).
        // Mono-core A4 → 2: while one op blocks on a slow cold NAND read, the other decodes an
        // already-read icon (real overlap on slow storage, negligible context-switch vs NAND latency).
        // Multi-core → cores*2 (cap 6) so iPad 4 / iPhone 5 fill a screen of icons much faster.
        _diskDecodeQueue.maxConcurrentOperationCount = (cores <= 1) ? 2 : MIN((NSUInteger)6, cores * 2);

        // Persistent on-disk thumbnail cache (survives eviction AND app relaunch → an
        // icon downloaded once is instant forever; the #1 real-world speedup).
        NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        _diskDir = [caches stringByAppendingPathComponent:@"appdrop-icons"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_diskDir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        [self pruneDiskCacheAsync];

        // Drop the RAM cache (and failure cooldowns) under memory pressure. Disk + pending
        // are untouched, so in-flight requests still complete and icons re-load from disk.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}

- (void)onMemoryWarning {
    [self.cache removeAllObjects];
    @synchronized (self.failedAt) { [self.failedAt removeAllObjects]; }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)keyForURL:(NSString *)url size:(CGSize)size {
    return [NSString stringWithFormat:@"%@@%dx%d", url, (int)size.width, (int)size.height];
}

- (NSString *)diskPathForKey:(NSString *)key {
    return [self.diskDir stringByAppendingPathComponent:IconDiskName(key)];
}

// Synchronous, RAM-ONLY lookup (called from cellForRow on the main thread — must never
// touch disk or network). A miss returns nil; the async loader then checks disk/network.
- (UIImage *)cachedImageForURL:(NSString *)url targetSize:(CGSize)size {
    if (!url.length) return nil;
    return [_cache objectForKey:[self keyForURL:url size:size]];
}

- (id)loadImageForURL:(NSString *)url
              targetSize:(CGSize)size
                via:(NSString *)proxyURL
              completion:(void (^)(UIImage *))completion {
    if (!url.length || !completion) return nil;
    NSString *key = [self keyForURL:url size:size];

    UIImage *cached = [_cache objectForKey:key];
    if (cached) { dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); }); return nil; }

    // One request token (returned as an opaque cancel handle). Dedup: if a request for this key is
    // already in flight, attach this token to the existing waiter list; otherwise start a new op.
    ADIconReq *req = [[ADIconReq alloc] init];
    req.completion = completion;
    req.key = key;
    @synchronized (self.pending) {
        NSMutableArray *waiters = self.pending[key];
        if (waiters) { [waiters addObject:req]; return req; }
        self.pending[key] = [NSMutableArray arrayWithObject:req];
    }

    NSString *finalURL = proxyURL.length ? proxyURL : url;
    CGFloat screenScale = self.screenScale;

    // Step 1: try the disk cache on a background queue (fast, no network). Only if that
    // misses do we go to the network — and that part is gated by suspend + bounded.
    // NOTE: this runs on _diskDecodeQueue, which is INDEPENDENT of the network queue's
    // suspend — so disk-cached icons keep resolving while the user scrolls.
    [self.diskDecodeQueue addOperationWithBlock:^{
        if ([self keyAbandoned:key]) return;   // every requester scrolled away → skip the decode
        NSString *diskPath = [self diskPathForKey:key];
        NSData *diskData = [NSData dataWithContentsOfFile:diskPath options:NSDataReadingMappedIfSafe error:NULL];
        if (diskData.length > 0) {
            UIImage *img = IconForceDecode([UIImage imageWithData:diskData scale:screenScale]);
            if (img) {
                NSUInteger cost = (NSUInteger)(img.size.width * screenScale * img.size.height * screenScale * 4);
                [self.cache setObject:img forKey:key cost:cost];
                [self fireWaiters:key withImage:img];
                return;
            }
        }

        // Cooldown: skip the network if this URL failed recently.
        @synchronized (self.failedAt) {
            NSDate *failedAt = self.failedAt[key];
            if (failedAt && -[failedAt timeIntervalSinceNow] < kFailureCooldown) {
                [self fireWaiters:key withImage:nil];
                return;
            }
        }

        [self enqueueNetworkFetch:finalURL key:key size:size];
    }];
    return req;
}

// Network fetch as a bounded, suspendable operation. Using the SYNC client inside the
// operation means the operation holds its slot for the whole fetch → real concurrency
// limiting AND real suspend (queued ops pause while scrolling).
- (void)enqueueNetworkFetch:(NSString *)finalURL key:(NSString *)key size:(CGSize)size {
    BOOL isHTTPS = [[finalURL lowercaseString] hasPrefix:@"https://"];
    NSTimeInterval timeout = 30;  // mbedTLS handshake on iPad 1 can take several seconds.

    __weak typeof(self) ws = self;
    NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        __strong typeof(ws) self = ws; if (!self) return;
        if ([self keyAbandoned:key]) return;   // every requester scrolled away → skip the network fetch
        NSData *d = nil;
        if (isHTTPS) {
            NSInteger code = 0;
            d = [HTTPSClient getSyncURL:finalURL timeout:timeout statusCode:&code error:NULL];
            if (code != 0 && (code < 200 || code >= 300)) d = nil;   // 404/503 → not an image
        } else {
            NSURL *u = [NSURL URLWithString:finalURL];
            if (u) d = [NSData dataWithContentsOfURL:u];
        }
        [self handleFetched:d key:key size:size];
    }];
    // Visible-first ordering: the LATEST request is what's on screen now, so it jumps ahead of
    // the stale requests piled up while scrolling past. Demote everything still waiting to Low,
    // mark this one High → the queue's free slots always grab the currently-visible icons next.
    @synchronized (self) {
        for (NSInteger i = (NSInteger)self.queuedOps.count - 1; i >= 0; i--) {
            NSOperation *o = self.queuedOps[i];
            if (o.isFinished) { [self.queuedOps removeObjectAtIndex:i]; continue; }
            if (!o.isExecuting) o.queuePriority = NSOperationQueuePriorityLow;
        }
        op.queuePriority = NSOperationQueuePriorityHigh;
        [self.queuedOps addObject:op];
    }
    [self.downloadQueue addOperation:op];
}

// Decode + bake corners (synchronously, on the bounded operation thread → also caps the
// decode CPU/RAM), then persist to disk + RAM and notify waiters.
- (void)handleFetched:(NSData *)d key:(NSString *)key size:(CGSize)size {
    if (!d || d.length < 100) {
        @synchronized (self.failedAt) { self.failedAt[key] = [NSDate date]; }
        [self fireWaiters:key withImage:nil];
        return;
    }
    UIImage *img = [self decodeAndResize:d targetSize:size];
    if (img) {
        CGFloat sc = self.screenScale;
        NSUInteger cost = (NSUInteger)(size.width * sc * size.height * sc * 4);
        [self.cache setObject:img forKey:key cost:cost];
        @synchronized (self.failedAt) { [self.failedAt removeObjectForKey:key]; }
        // Persist (PNG keeps the baked transparent rounded corners). Best-effort.
        NSData *png = UIImagePNGRepresentation(img);
        if (png.length) [png writeToFile:[self diskPathForKey:key] atomically:YES];
    } else {
        @synchronized (self.failedAt) { self.failedAt[key] = [NSDate date]; }
    }
    [self fireWaiters:key withImage:img];
}

- (void)fireWaiters:(NSString *)key withImage:(UIImage *)img {
    NSArray *waiters = nil;
    @synchronized (self.pending) {
        waiters = self.pending[key];
        [self.pending removeObjectForKey:key];
    }
    for (ADIconReq *r in waiters) {
        if (r.cancelled) continue;            // requester scrolled away → don't deliver
        void (^cb)(UIImage *) = r.completion;
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(img); });
    }
}

// A request is "abandoned" once every waiter sharing its URL key has been cancelled (the cells that
// wanted it all scrolled away / got reused). The decode/network op calls this at its start and skips
// the work — this is what lets a fast fling's stale backlog drain instantly so the currently-visible
// tiles' icons resolve first. Returns YES (and drops the key) when nothing live remains.
- (BOOL)keyAbandoned:(NSString *)key {
    @synchronized (self.pending) {
        NSMutableArray *reqs = self.pending[key];
        for (ADIconReq *r in reqs) if (!r.cancelled) return NO;
        if (reqs) [self.pending removeObjectForKey:key];
        return YES;
    }
}

// Cancel token returned by loadImageForURL:. Called by a reused cell that no longer needs the icon.
- (void)cancelRequest:(id)token {
    if (![token isKindOfClass:[ADIconReq class]]) return;
    @synchronized (self.pending) { ((ADIconReq *)token).cancelled = YES; }
}

// ImageIO thumbnail decode: decodes STRAIGHT to ~target pixels instead of fully decoding
// a large source JPEG into RAM and then downscaling — a big memory/CPU cut on old devices.
// Corners are baked into the pixels (no runtime cornerRadius → no offscreen render).
- (UIImage *)decodeAndResize:(NSData *)data targetSize:(CGSize)targetSize {
    CGFloat scale = self.screenScale;
    CGSize px = CGSizeMake(targetSize.width * scale, targetSize.height * scale);

    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    NSDictionary *opts = @{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: (__bridge id)kCFBooleanTrue,
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform:   (__bridge id)kCFBooleanTrue,
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @((int)MAX(px.width, px.height)),
    };
    CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!thumb) return nil;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)px.width, (size_t)px.height,
                                              8, (size_t)px.width * 4, colorSpace,
                                              kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!ctx) { CGColorSpaceRelease(colorSpace); CGImageRelease(thumb); return nil; }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);

    CGFloat radius = targetSize.width * 0.21 * scale;
    CGRect rect = CGRectMake(0, 0, px.width, px.height);
    UIBezierPath *roundPath = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
    CGContextAddPath(ctx, roundPath.CGPath);
    CGContextClip(ctx);
    CGContextDrawImage(ctx, rect, thumb);

    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    UIImage *out = [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    CGImageRelease(thumb);
    CGContextRelease(ctx);
    CGColorSpaceRelease(colorSpace);
    return out;
}

- (void)suspend {
    self.suspended = YES;
    self.downloadQueue.suspended = YES;   // now genuinely pauses queued icon fetches
}

- (void)resume {
    self.suspended = NO;
    self.downloadQueue.suspended = NO;
}

- (void)clearCache {
    [self.cache removeAllObjects];
    @synchronized (self.failedAt) { [self.failedAt removeAllObjects]; }
}

// Keep the on-disk cache bounded. Caches/ is purgeable by iOS under disk pressure, but we
// also cap it ourselves: if it grows past ~6000 files, drop the oldest ~2000.
- (void)pruneDiskCacheAsync {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *names = [fm contentsOfDirectoryAtPath:self.diskDir error:NULL];
        if (names.count <= 6000) return;
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *n in names) {
            NSString *p = [self.diskDir stringByAppendingPathComponent:n];
            NSDictionary *a = [fm attributesOfItemAtPath:p error:NULL];
            NSDate *m = a[NSFileModificationDate];
            if (m) [items addObject:@{@"p": p, @"m": m}];
        }
        [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"m"] compare:b[@"m"]];   // oldest first
        }];
        NSUInteger toRemove = items.count > 2000 ? 2000 : items.count;
        for (NSUInteger i = 0; i < toRemove; i++) [fm removeItemAtPath:items[i][@"p"] error:NULL];
    });
}

@end
