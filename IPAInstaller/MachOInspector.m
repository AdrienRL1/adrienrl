#import "MachOInspector.h"
#import "HTTPSClient.h"
#include <stdio.h>
#include <string.h>
#include <zlib.h>

// ---- ZIP constants (little-endian on disk) ----
#define ZIP_EOCDR_SIG       0x06054b50u
#define ZIP_CD_SIG          0x02014b50u
#define ZIP_LFH_SIG         0x04034b50u
#define ZIP_METHOD_STORED   0
#define ZIP_METHOD_DEFLATE  8

// ---- Mach-O constants ----
// Fat binaries are stored big-endian on disk. On our little-endian host,
// reading the magic bytes as a host-endian uint32 yields FAT_CIGAM
// (0xbebafeca). FAT_MAGIC (0xcafebabe) appears when the binary was created
// on a big-endian host (rare).
#define M_FAT_MAGIC         0xcafebabeu
#define M_FAT_CIGAM         0xbebafecau
// Thin Mach-O on iOS is little-endian → MH_MAGIC reads natively.
#define M_MH_MAGIC          0xfeedfaceu
#define M_MH_CIGAM          0xcefaedfeu
#define M_MH_MAGIC_64       0xfeedfacfu
#define M_MH_CIGAM_64       0xcffaedfeu
// Load command numbers (mask out LC_REQ_DYLD = 0x80000000 before comparing)
#define LC_ENC_INFO         0x21u
#define LC_ENC_INFO_64      0x2Cu
#define LC_REQ_DYLD_MASK    0x80000000u
// cputype values (from <mach/machine.h>)
#define CPU_TYPE_ARM        12
#define CPU_TYPE_ARM64      0x0100000c

// Persisted per-URL cache key. A given file's cryptid never changes, so once probed we
// remember it forever (NSUserDefaults dict url -> @(MachOInspectionResult)).
static NSString *const kEncCacheKey = @"MOEncCacheV1";

// A byte source: returns NSData for [off, off+len) or nil/short on failure. Lets the same
// ZIP/Mach-O parser run over a local FILE* or over HTTP Range requests.
typedef NSData *(^MOReader)(off_t off, size_t len);

#pragma mark - Byte readers

static inline uint16_t le16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static inline uint32_t le32(const uint8_t *p) {
    return  (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}
static inline uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24)
         | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8)
         |  (uint32_t)p[3];
}
static inline uint32_t bswap32(uint32_t x) {
    return ((x & 0xFF000000u) >> 24)
         | ((x & 0x00FF0000u) >> 8)
         | ((x & 0x0000FF00u) << 8)
         | ((x & 0x000000FFu) << 24);
}

@implementation MachOInspector

#pragma mark - Public entry points

+ (MachOInspectionResult)inspectIPA:(NSString *)ipaPath {
    if (!ipaPath.length) return MachOInspectionResultUnknown;
    FILE *fp = fopen([ipaPath fileSystemRepresentation], "rb");
    if (!fp) return MachOInspectionResultUnknown;
    if (fseeko(fp, 0, SEEK_END) != 0) { fclose(fp); return MachOInspectionResultUnknown; }
    off_t fileSize = ftello(fp);

    MOReader reader = ^NSData *(off_t off, size_t len) {
        if (off < 0 || len == 0) return nil;
        NSMutableData *d = [NSMutableData dataWithLength:len];
        if (!d) return nil;
        if (fseeko(fp, off, SEEK_SET) != 0) return nil;
        size_t got = fread(d.mutableBytes, 1, len, fp);
        d.length = got;   // may be short — the parser validates lengths
        return d;
    };

    MachOInspectionResult result;
    @try {
        result = [self inspectUsingReader:reader fileSize:fileSize];
    }
    @catch (NSException *e) {
        NSLog(@"[MachOInspector] caught exception: %@", e);
        result = MachOInspectionResultUnknown;
    }
    fclose(fp);
    return result;
}

+ (void)inspectURL:(NSString *)url completion:(void (^)(MachOInspectionResult result))completion {
    NSInteger cached = [self cachedResultForURL:url];
    if (cached >= 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion((MachOInspectionResult)cached); });
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        MachOInspectionResult r = MachOInspectionResultUnknown;
        @try { r = [self probeURLSync:url]; }
        @catch (NSException *e) { NSLog(@"[MachOInspector] inspectURL exception: %@", e); r = MachOInspectionResultUnknown; }
        if (r != MachOInspectionResultUnknown) [self setCachedResult:r forURL:url];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(r); });
    });
}

#pragma mark - Cache

+ (NSInteger)cachedResultForURL:(NSString *)url {
    if (!url.length) return -1;
    NSDictionary *m = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kEncCacheKey];
    NSNumber *n = [m objectForKey:url];
    return n ? [n integerValue] : -1;
}

+ (void)setCachedResult:(MachOInspectionResult)r forURL:(NSString *)url {
    if (!url.length || r == MachOInspectionResultUnknown) return;  // never cache transient failures
    @synchronized (self) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *m = [[d dictionaryForKey:kEncCacheKey] mutableCopy];
        if (!m) m = [NSMutableDictionary dictionary];
        if (m.count > 3000) [m removeAllObjects];   // crude cap; the status is cheap to re-probe
        [m setObject:[NSNumber numberWithInteger:(NSInteger)r] forKey:url];
        [d setObject:m forKey:kEncCacheKey];
    }
}

#pragma mark - HTTP Range source

// Synchronous probe (runs on a background queue). Discovers size + Range support, then drives
// the shared parser through a Range-backed reader that caches fetched chunks so the tail and the
// binary header are each fetched at most once.
+ (MachOInspectionResult)probeURLSync:(NSString *)url {
    __block long long total = -1;
    __block BOOL rangeOK = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [HTTPSClient probeURL:url completion:^(long long t, BOOL r, NSError *e) {
        total = t; rangeOK = r; dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)));
    if (total < 22 || !rangeOK) return MachOInspectionResultUnknown;  // can't probe cheaply

    NSMutableArray *chunks = [NSMutableArray array];   // each: @{@"off":@(o), @"data":NSData}
    MOReader reader = ^NSData *(off_t off, size_t len) {
        return [self rangeRead:url off:off len:len total:total cache:chunks];
    };
    return [self inspectUsingReader:reader fileSize:(off_t)total];
}

+ (NSData *)rangeRead:(NSString *)url off:(off_t)off len:(size_t)len total:(long long)total cache:(NSMutableArray *)chunks {
    if (off < 0 || len == 0 || off >= total) return nil;
    if (off + (off_t)len > total) len = (size_t)(total - off);
    if (len == 0) return nil;

    // Serve from an already-fetched chunk if one fully covers [off, off+len).
    for (NSDictionary *c in chunks) {
        off_t co = [[c objectForKey:@"off"] longLongValue];
        NSData *cd = [c objectForKey:@"data"];
        if (off >= co && off + (off_t)len <= co + (off_t)cd.length)
            return [cd subdataWithRange:NSMakeRange((NSUInteger)(off - co), len)];
    }
    // Over-fetch to 64 KB so the local-header read and the following binary read coalesce.
    size_t fetchLen = len < 65536 ? 65536 : len;
    if (off + (off_t)fetchLen > total) fetchLen = (size_t)(total - off);
    NSData *got = [self fetchRange:url from:off length:fetchLen];
    if (!got || got.length == 0) return nil;
    [chunks addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                         [NSNumber numberWithLongLong:(long long)off], @"off", got, @"data", nil]];
    if (got.length >= len) return [got subdataWithRange:NSMakeRange(0, len)];
    return got;   // short read — the parser treats a length mismatch as failure
}

// Download one byte range to a temp file via the bundled-TLS chunk downloader, read it back,
// delete the temp. Blocks the calling (background) queue on a semaphore.
+ (NSData *)fetchRange:(NSString *)url from:(off_t)from length:(size_t)len {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"_moprobe_%@.bin",
                          [[NSProcessInfo processInfo] globallyUniqueString]]];
    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [HTTPSClient downloadChunk:url
                      fromByte:(long long)from
                        toByte:(long long)(from + (off_t)len - 1)
                        toFile:tmp
                   isCancelled:^BOOL{ return NO; }
                      progress:^(long long a, long long b) {}
                    completion:^(BOOL success, NSInteger status, NSError *e) {
        ok = success; dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)));
    NSData *d = ok ? [NSData dataWithContentsOfFile:tmp] : nil;
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    return d;
}

#pragma mark - ZIP parsing (reader-driven)

+ (MachOInspectionResult)inspectUsingReader:(MOReader)readBytes fileSize:(off_t)fileSize {
    if (fileSize < 22) return MachOInspectionResultUnknown;

    // Read the last ~64 KB to locate the End-Of-Central-Directory Record. EOCDR sits at the
    // very end, possibly followed by a comment (max 65535). 65557 = 22 + 65535.
    off_t searchStart = fileSize > (off_t)65557 ? fileSize - 65557 : 0;
    size_t searchLen = (size_t)(fileSize - searchStart);
    NSData *tail = readBytes(searchStart, searchLen);
    if (!tail || tail.length != searchLen) return MachOInspectionResultUnknown;

    const uint8_t *tb = tail.bytes;
    NSInteger eocdr = -1;
    for (NSInteger i = (NSInteger)searchLen - 22; i >= 0; i--) {
        if (tb[i] == 0x50 && tb[i+1] == 0x4b && tb[i+2] == 0x05 && tb[i+3] == 0x06) { eocdr = i; break; }
    }
    if (eocdr < 0) return MachOInspectionResultUnknown;

    uint32_t cdSize = le32(tb + eocdr + 12);
    uint32_t cdOff  = le32(tb + eocdr + 16);
    if (cdOff == 0xFFFFFFFFu || cdSize == 0xFFFFFFFFu) return MachOInspectionResultUnknown;  // ZIP64
    if ((off_t)cdOff + (off_t)cdSize > fileSize) return MachOInspectionResultUnknown;
    if (cdSize > 16 * 1024 * 1024) return MachOInspectionResultUnknown;

    NSData *cd = readBytes(cdOff, cdSize);
    if (!cd || cd.length != cdSize) return MachOInspectionResultUnknown;

    const uint8_t *cdp = cd.bytes;
    const uint8_t *cdEnd = cdp + cd.length;
    while (cdp + 46 <= cdEnd) {
        if (le32(cdp) != ZIP_CD_SIG) break;
        uint16_t method   = le16(cdp + 10);
        uint32_t compSize = le32(cdp + 20);
        uint16_t fnLen    = le16(cdp + 28);
        uint16_t exLen    = le16(cdp + 30);
        uint16_t cmLen    = le16(cdp + 32);
        uint32_t lhOff    = le32(cdp + 42);

        if (cdp + 46 + (size_t)fnLen + exLen + cmLen > cdEnd) break;
        const uint8_t *fn = cdp + 46;

        if ([self filenameLooksLikeMainBinary:fn length:fnLen]) {
            MachOInspectionResult r = [self peekEntryWithReader:readBytes
                                                      lfhOffset:lhOff
                                                     compMethod:method
                                                       compSize:compSize];
            if (r != MachOInspectionResultUnknown) return r;
        }
        cdp += 46 + fnLen + exLen + cmLen;
    }
    return MachOInspectionResultUnknown;
}

+ (BOOL)filenameLooksLikeMainBinary:(const uint8_t *)fn length:(uint16_t)len {
    if (len < 10) return NO;
    if (memcmp(fn, "Payload/", 8) != 0) return NO;
    NSInteger lastSlash = -1, appSlash = -1, slashCount = 0;
    for (NSInteger i = 0; i < (NSInteger)len; i++) {
        if (fn[i] == '/') {
            slashCount++;
            if (i >= 4 && fn[i-4] == '.' && fn[i-3] == 'a' && fn[i-2] == 'p' && fn[i-1] == 'p') appSlash = i;
            lastSlash = i;
        }
    }
    if (slashCount != 2 || appSlash < 0 || appSlash != lastSlash) return NO;
    if (lastSlash + 1 >= (NSInteger)len) return NO;
    for (NSInteger i = lastSlash + 1; i < (NSInteger)len; i++) if (fn[i] == '.') return NO;
    return YES;
}

+ (MachOInspectionResult)peekEntryWithReader:(MOReader)readBytes
                                   lfhOffset:(uint32_t)lhOff
                                  compMethod:(uint16_t)method
                                    compSize:(uint32_t)compSize {
    NSData *lfhData = readBytes((off_t)lhOff, 30);
    if (!lfhData || lfhData.length != 30) return MachOInspectionResultUnknown;
    const uint8_t *lfh = lfhData.bytes;
    if (le32(lfh) != ZIP_LFH_SIG) return MachOInspectionResultUnknown;
    uint16_t lfnLen = le16(lfh + 26);
    uint16_t lexLen = le16(lfh + 28);
    off_t dataOff = (off_t)lhOff + 30 + lfnLen + lexLen;

    size_t maxRead = MIN((size_t)compSize, (size_t)32768);
    if (maxRead < 28) return MachOInspectionResultUnknown;
    NSData *raw = readBytes(dataOff, maxRead);
    if (!raw || raw.length == 0) return MachOInspectionResultUnknown;

    NSData *binData = nil;
    if (method == ZIP_METHOD_STORED) {
        binData = raw;
    } else if (method == ZIP_METHOD_DEFLATE) {
        binData = [self inflateRaw:raw maxOutput:32768];
        if (!binData) return MachOInspectionResultUnknown;
    } else {
        return MachOInspectionResultUnknown;
    }

    if (binData.length < 28) return MachOInspectionResultUnknown;
    uint32_t magic = le32(binData.bytes);
    if (magic != M_FAT_MAGIC && magic != M_FAT_CIGAM
        && magic != M_MH_MAGIC && magic != M_MH_CIGAM
        && magic != M_MH_MAGIC_64 && magic != M_MH_CIGAM_64) {
        return MachOInspectionResultUnknown;
    }
    return [self inspectMachOBytes:binData];
}

#pragma mark - zlib inflate (raw deflate, no zlib header)

+ (NSData *)inflateRaw:(NSData *)compressed maxOutput:(size_t)maxLen {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:maxLen];
    if (!out) { inflateEnd(&strm); return nil; }
    strm.next_in = (Bytef *)compressed.bytes;
    strm.avail_in = (uInt)compressed.length;
    strm.next_out = out.mutableBytes;
    strm.avail_out = (uInt)maxLen;
    int ret = inflate(&strm, Z_NO_FLUSH);
    inflateEnd(&strm);
    if (ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR) return nil;
    out.length = maxLen - strm.avail_out;
    if (out.length < 28) return nil;
    return out;
}

#pragma mark - Mach-O parsing

+ (MachOInspectionResult)inspectMachOBytes:(NSData *)binData {
    if (binData.length < 28) return MachOInspectionResultUnknown;
    const uint8_t *bytes = binData.bytes;
    size_t len = binData.length;

    uint32_t magic = le32(bytes);
    size_t sliceOff = 0;

    if (magic == M_FAT_MAGIC || magic == M_FAT_CIGAM) {
        if (len < 8) return MachOInspectionResultUnknown;
        uint32_t nfat = be32(bytes + 4);
        if (nfat == 0 || nfat > 16) return MachOInspectionResultUnknown;
        size_t armSlice = 0;
        BOOL haveArm = NO;
        for (uint32_t i = 0; i < nfat; i++) {
            size_t archOff = 8 + (size_t)i * 20;
            if (archOff + 20 > len) return MachOInspectionResultUnknown;
            uint32_t cputype = be32(bytes + archOff);
            uint32_t sliceFileOff = be32(bytes + archOff + 8);
            if (cputype == CPU_TYPE_ARM) { armSlice = sliceFileOff; haveArm = YES; break; }
        }
        if (!haveArm) return MachOInspectionResultUnknown;
        if (armSlice >= len || armSlice + 4 > len) return MachOInspectionResultUnknown;
        sliceOff = armSlice;
        magic = le32(bytes + sliceOff);
    }

    BOOL is64 = NO, swap = NO;
    if (magic == M_MH_MAGIC)        { is64 = NO;  swap = NO;  }
    else if (magic == M_MH_CIGAM)   { is64 = NO;  swap = YES; }
    else if (magic == M_MH_MAGIC_64){ is64 = YES; swap = NO;  }
    else if (magic == M_MH_CIGAM_64){ is64 = YES; swap = YES; }
    else return MachOInspectionResultUnknown;

    size_t headerSize = is64 ? 32 : 28;
    if (sliceOff + headerSize > len) return MachOInspectionResultUnknown;

    uint32_t ncmds = le32(bytes + sliceOff + 16);
    if (swap) ncmds = bswap32(ncmds);
    if (ncmds == 0 || ncmds > 1024) return MachOInspectionResultUnknown;

    size_t cmdOff = sliceOff + headerSize;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (cmdOff + 8 > len) return MachOInspectionResultUnknown;
        uint32_t cmd = le32(bytes + cmdOff);
        uint32_t cmdsize = le32(bytes + cmdOff + 4);
        if (swap) { cmd = bswap32(cmd); cmdsize = bswap32(cmdsize); }
        if (cmdsize < 8 || cmdOff + cmdsize > len) return MachOInspectionResultUnknown;

        uint32_t cmdMasked = cmd & ~LC_REQ_DYLD_MASK;
        if (cmdMasked == LC_ENC_INFO || cmdMasked == LC_ENC_INFO_64) {
            if (cmdOff + 20 > len) return MachOInspectionResultUnknown;
            uint32_t cryptid = le32(bytes + cmdOff + 16);
            if (swap) cryptid = bswap32(cryptid);
            return cryptid == 0 ? MachOInspectionResultDecrypted : MachOInspectionResultEncrypted;
        }
        cmdOff += cmdsize;
    }
    return MachOInspectionResultDecrypted;   // no LC_ENCRYPTION_INFO → homebrew/adhoc, never DRM'd
}

@end
