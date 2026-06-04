#import <UIKit/UIKit.h>
#import "IOS6Theme.h"

// Scrolling colour picker for the app theme (Settings → Thème). Lists "Défaut" plus every
// curated colour as a swatch; tapping one applies it instantly across the whole app.
@interface ThemePickerViewController : UITableViewController <ADThemable>
@end
