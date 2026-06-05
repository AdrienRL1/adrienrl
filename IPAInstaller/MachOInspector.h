#import <Foundation/Foundation.h>

// FairPlay-encryption inspection result for an .ipa's main executable.
//
// Background: every App Store binary contains a Mach-O load command
// (LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64) with a `cryptid` field. Apple's
// FairPlay DRM sets cryptid=1 at purchase time, tied to the buyer's Apple ID
// keybag. dyld checks this on launch; if cryptid != 0 and the device doesn't
// have the matching keybag entry, the binary is unrunnable.
//
// "Cracked" .ipas (Clutch, CrackerXI, etc.) dump the decrypted binary from
// a purchaser's device and set cryptid back to 0 — those work on any
// jailbreak. archive.org's collection is ~95% cracked, ~5% raw iTunes dumps
// that still have cryptid=1 and only run on the original buyer.
typedef NS_ENUM(NSInteger, MachOInspectionResult) {
    // Could not determine (read error, unsupported ZIP feature, deflate
    // failed, no recognizable Mach-O magic, etc.). Caller should treat
    // this the same as Decrypted — we'd rather false-negative the check
    // than block a legitimate install.
    MachOInspectionResultUnknown = 0,
    // Binary is positively decrypted: either cryptid == 0, or there's no
    // LC_ENCRYPTION_INFO command at all (homebrew app never DRM-protected).
    MachOInspectionResultDecrypted,
    // Binary has LC_ENCRYPTION_INFO with cryptid != 0 — it's still FairPlay-
    // protected. Will not run on this device's jailbreak (Apple ID mismatch).
    MachOInspectionResultEncrypted,
};

@interface MachOInspector : NSObject

// Inspect the main executable Mach-O inside an .ipa. The .ipa is treated as
// a standard zip — we read the End-Of-Central-Directory record, walk the
// central directory looking for entries shaped like `Payload/*.app/<name>`
// where <name> has no extension, peek the data, and verify each candidate
// starts with a Mach-O magic. Then parse fat header (if any) → pick the
// ARM slice → mach_header → load commands → LC_ENCRYPTION_INFO → cryptid.
//
// Reads at most ~32 KB from the binary — enough for header + all load
// commands. Safe to call from any thread; doesn't retain the file.
+ (MachOInspectionResult)inspectIPA:(NSString *)ipaPath;

// Probe a REMOTE .ipa over HTTP **without downloading it** — uses Range requests to read only
// the ZIP tail + the main binary's first ~32 KB (a few tens of KB total). Lets the catalog warn
// "this version is FairPlay-encrypted (won't run)" and recommend a decrypted version, before any
// full download. Requires the server to support Range (archive.org does); returns Unknown if not.
// The result is cached per-URL (persisted) — a given file's cryptid never changes.
// `completion` is called on the MAIN queue.
+ (void)inspectURL:(NSString *)url completion:(void (^)(MachOInspectionResult result))completion;

// Synchronous, no-network cache lookup. Returns the cached MachOInspectionResult, or -1 if this
// URL hasn't been probed yet (so a caller can show a cached badge instantly, then probe if absent).
+ (NSInteger)cachedResultForURL:(NSString *)url;

// Generic single-file extractor that reuses the same ZIP plumbing. Walks the central directory and,
// among entries whose full path passes `match` (STORED or DEFLATE only), inflates the one with the
// LARGEST uncompressed size — so an icon lookup grabs the highest-resolution variant. Output capped
// at `maxBytes`. Returns the file bytes, or nil if nothing matches / on any parse error. Any thread.
+ (NSData *)extractLargestEntryFromIPA:(NSString *)ipaPath
                              matching:(BOOL (^)(NSString *entryName))match
                              maxBytes:(NSUInteger)maxBytes;

@end
