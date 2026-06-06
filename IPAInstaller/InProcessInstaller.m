#import "InProcessInstaller.h"
#import <dlfcn.h>

// MobileInstallation private framework path (since iOS 2.0).
static NSString *const kMIPath =
    @"/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation";

// MobileInstallationInstall(CFStringRef path, CFDictionaryRef params,
//                           MobileInstallationCallback callback, CFStringRef backpath) -> int (0 = OK)
// Signature is identical from iOS 2.0 through 7.x. The 3rd arg is a progress
// callback (PercentComplete / Status dict); we pass NULL — we only need the
// blocking result. The 4th arg ("backpath") is the source path again, matching
// what autopear's ipainstaller and AppSync's appinst pass.
typedef void (*MICallback)(CFDictionaryRef information);
typedef int (*MIInstallFn)(CFStringRef path, CFDictionaryRef parameters,
                           MICallback callback, CFStringRef backpath);

// Resolve MobileInstallationInstall once. Returns NULL on iOS 8+ (symbol gone)
// or if the framework can't be loaded.
static MIInstallFn ResolveInstallFn(void) {
    static MIInstallFn fn = NULL;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        void *image = dlopen([kMIPath fileSystemRepresentation], RTLD_LAZY);
        if (image) {
            fn = (MIInstallFn)dlsym(image, "MobileInstallationInstall");
            // Intentionally leak the handle: the framework stays mapped for the
            // process lifetime and we may install more than once.
        }
    }
    return fn;
}

@implementation InProcessInstaller

+ (BOOL)isAvailable {
    return ResolveInstallFn() != NULL;
}

+ (int)installIPAAtPath:(NSString *)ipaPath capturedOutput:(NSString **)outOutput {
    NSString *name = [[ipaPath lastPathComponent] stringByDeletingPathExtension];
    if (!name.length) name = @"app";

    MIInstallFn install = ResolveInstallFn();
    if (!install) {
        if (outOutput)
            *outOutput = @"Install failed: MobileInstallationInstall is unavailable on this iOS version.";
        return -1;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:ipaPath]) {
        if (outOutput)
            *outOutput = [NSString stringWithFormat:@"Install failed: %@ not found.", ipaPath];
        return -1;
    }

    // MobileInstallation extracts (and may move/consume) the source it's handed,
    // so install from a private staging copy. This keeps the caller's original
    // localPath intact for the "Keep IPA after install" / save-to-Documents
    // logic that runs after a successful install in InstallManager.
    NSString *stageDir = [NSTemporaryDirectory()
                            stringByAppendingPathComponent:@"appdrop-inproc-install"];
    [fm removeItemAtPath:stageDir error:nil];
    NSError *mkErr = nil;
    if (![fm createDirectoryAtPath:stageDir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&mkErr]) {
        if (outOutput)
            *outOutput = [NSString stringWithFormat:@"Install failed: could not create staging dir (%@).",
                            mkErr.localizedDescription ?: @"unknown"];
        return -1;
    }

    NSString *stagePath = [stageDir stringByAppendingPathComponent:@"install.ipa"];
    [fm removeItemAtPath:stagePath error:nil];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:ipaPath toPath:stagePath error:&copyErr]) {
        [fm removeItemAtPath:stageDir error:nil];
        if (outOutput)
            *outOutput = [NSString stringWithFormat:@"Install failed: could not stage .ipa (%@).",
                            copyErr.localizedDescription ?: @"unknown"];
        return -1;
    }

    // ApplicationType = User → installs as a normal home-screen app (not a
    // system app). Same parameter dict autopear/appinst use for the C path.
    NSDictionary *params = [NSDictionary dictionaryWithObject:@"User"
                                                       forKey:@"ApplicationType"];

    int rc = -1;
    @try {
        rc = install((__bridge CFStringRef)stagePath,
                     (__bridge CFDictionaryRef)params,
                     NULL,
                     (__bridge CFStringRef)stagePath);
    } @catch (NSException *ex) {
        if (outOutput)
            *outOutput = [NSString stringWithFormat:@"Install failed: %@", [ex reason] ?: [ex name]];
        [fm removeItemAtPath:stageDir error:nil];
        return -1;
    }

    // Clean up staging (MobileInstallation copies what it needs out of it).
    [fm removeItemAtPath:stageDir error:nil];

    if (outOutput) {
        // Shape the message like ipainstaller's stdout so InstallManager's
        // existing success-detection ("successfully" / "Installed (.+?) successfully")
        // and failure formatting keep working without changes.
        *outOutput = (rc == 0)
            ? [NSString stringWithFormat:@"Installed %@ successfully.", name]
            : [NSString stringWithFormat:@"Install failed: MobileInstallationInstall returned %d.", rc];
    }
    return rc;
}

@end
