#import <Foundation/Foundation.h>

// In-process IPA installer.
//
// Installs an .ipa by calling the private C function -MobileInstallationInstall-
// directly inside AppDrop, with no external helper binary. This is exactly what
// the «IPA Installer Console» (autopear) and AppSync's «appinst» do under the
// hood — they dlopen MobileInstallation.framework and call the same symbol. The
// difference is that those *packages* declare a firmware (>= 4.0) dependency, so
// Cydia refuses to install them on iOS 3.1.3, leaving the device with no
// /usr/bin/ipainstaller at all (the "ipainstaller not found" failure).
//
// MobileInstallationInstall itself ships in
//   /System/Library/PrivateFrameworks/MobileInstallation.framework
// since iOS 2.0, with an unchanged signature, so calling it in-process works on
// iOS 3.1.3 the same way it does on iOS 5-7. On iOS 8+ this private C entry point
// is gone (replaced by LSApplicationWorkspace); we never reach this path there
// because an external installer is used / the modern-iOS branch saves the .ipa.
//
// Compiles under both ARC (Theos build) and MRC (-fno-objc-arc, the iOS 3
// armv6 backport): it touches Foundation objects only through ordinary message
// sends and uses __bridge casts, which are valid (and no-ops) in both modes.
@interface InProcessInstaller : NSObject

// YES if MobileInstallationInstall can be resolved on this device (iOS 2.0-7.x).
// On iOS 8+ the symbol is absent and this returns NO.
+ (BOOL)isAvailable;

// Install the .ipa at -ipaPath-. Returns 0 on success, non-zero on failure.
// -outOutput- (optional) receives a human-readable status/error line shaped like
// ipainstaller's stdout ("Installed <name> successfully." / "Install failed: …")
// so the existing success/Failed parsing in InstallManager keeps working
// unchanged. Synchronous — call OFF the main thread.
+ (int)installIPAAtPath:(NSString *)ipaPath capturedOutput:(NSString **)outOutput;

@end
