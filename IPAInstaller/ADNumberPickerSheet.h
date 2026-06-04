#import <UIKit/UIKit.h>

// v3.0 — A native iOS 5/6 "spinning wheel" (UIPickerView) presented as a bottom sheet, the way
// the stock Date & Heure / picker rows looked in that era. Used to pick a small integer (e.g. the
// number of apps / tiles per row) instead of a slider. Works identically on iPhone and iPad
// (it covers the host view rather than relying on UIActionSheet's fiddly iPad popover sizing).
@interface ADNumberPickerSheet : UIView

// Slides the wheel up over `host`. `values` = the selectable NSNumber integers; `labels` = the
// matching display strings (same count). `selectedValue` pre-selects its row (falls back to the
// first). `onPick` fires with the chosen integer when the user taps Done; Cancel / tapping the dim
// backdrop dismisses without calling it.
+ (void)presentInView:(UIView *)host
                title:(NSString *)title
               values:(NSArray *)values
               labels:(NSArray *)labels
        selectedValue:(NSInteger)selectedValue
               onPick:(void (^)(NSInteger value))onPick;

@end
