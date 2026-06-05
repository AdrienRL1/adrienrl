#import <UIKit/UIKit.h>

// "Partager une app" — a user uploads an app THEY HAVE THE RIGHT TO SHARE (their own / homebrew /
// open-source / freeware / public domain). Picks a local .ipa, fills name + their own description +
// category + metadata, confirms the rights checkbox, and POSTs it (base64) to the Worker /upload
// endpoint → moderation queue. NO decryption — a plain .ipa only.
@interface UploadViewController : UITableViewController
// Preselected type the form opens on: @"catalog" (normal app/game absent from the catalogue),
// @"revival" (Fonctionne aujourd'hui) or @"mods" (Apps modifiées). The user can switch in-form.
- (instancetype)initWithTarget:(NSString *)target;
@end
