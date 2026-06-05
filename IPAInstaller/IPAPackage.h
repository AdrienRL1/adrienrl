#import <Foundation/Foundation.h>

// Lightweight reader for a local .ipa (a zip). Pulls metadata + the app icon out WITHOUT fully
// unpacking — it drives MachOInspector's central-directory extractor. Used by the upload flow to
// auto-fill the form (name / bundle id / version / min iOS) and to ship an icon automatically.
@interface IPAPackage : NSObject

// Parsed Info.plist of the top-level Payload/<App>.app (binary or XML), or nil on any failure.
+ (NSDictionary *)infoPlistForIPA:(NSString *)ipaPath;

// Largest app icon, re-encoded as a STANDARD PNG (UIImage decodes Apple's "CgBI" crushed PNGs, so
// the result renders everywhere — moderation page, browsers). nil if no icon is found.
+ (NSData *)iconPNGForIPA:(NSString *)ipaPath;

// Convenience: { name, bid, version, min_ios } pulled from the Info.plist (missing keys omitted).
+ (NSDictionary *)metadataForIPA:(NSString *)ipaPath;

@end
