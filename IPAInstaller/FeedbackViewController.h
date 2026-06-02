#import <UIKit/UIKit.h>

// Lets users send a bug report / improvement idea (optionally with a photo) that
// lands as a GitHub issue, via a free Cloudflare Worker proxy (holds the GitHub
// token server-side; the app just POSTs JSON through its bundled mbedTLS so it
// works even on old iOS where Cydia/Safari can't reach github.com).
@interface FeedbackViewController : UIViewController
@end

// Drop-in helper: gives any nav-bar-hosted screen a persistent "Feedback" button.
// Call from a ROOT view controller's viewDidLoad (roots have no Back button, so the
// left slot is free). Tapping it pushes the Feedback screen.
@interface UIViewController (AppDropFeedback)
- (void)installFeedbackBarButton;
@end

