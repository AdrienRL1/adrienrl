//
//  CrashReporter.h
//  AppDrop
//
//  Captures the latest on-device crash log and offers (one prompt per crash) to
//  send it through the existing anonymous feedback channel. This is how we get the
//  real backtraces of crashes on iOS versions / devices we can't reproduce
//  (e.g. #167 rotation crash on iPhone 4S / iOS 9.3.6, #143 iOS 7/8 launch crash).
//
//  Privacy: opt-in (a prompt). The sent text is the crash report only (process,
//  OS version, exception type, the crashed thread's backtrace) — no contacts,
//  files, or personal data. Same anonymous endpoint as the Feedback screen.
//

#import <Foundation/Foundation.h>

@interface CrashReporter : NSObject

// Call once, shortly after launch (deferred, off the critical path). On the FIRST
// run with this feature it silently records a baseline (so it never prompts about a
// crash that happened before the reporter existed). On later runs, if a NEW crash
// log appeared since last time, it shows a one-time prompt offering to send it.
// Fully wrapped in @try/@catch — a fault here can never crash the app.
+ (void)checkAndOfferReport;

@end
