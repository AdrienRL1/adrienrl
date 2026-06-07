#import <UIKit/UIKit.h>

// Posted (on the main thread) whenever the active theme changes. AppDelegate listens and
// re-applies the theme to every live screen so the change is instant — no app restart.
extern NSString * const AppDropThemeChangedNotification;

// A view or view controller that wants a hook to re-apply theme colors live (e.g. re-set its
// background / reload its table / setNeedsDisplay). The central applier calls -applyTheme on
// anything in the live hierarchy that conforms. Implementing it is OPTIONAL — generic controls
// (tables, switches, search bars, custom drawn views) are re-tinted automatically.
@protocol ADThemable <NSObject>
- (void)applyTheme;
@end

// Centralized iOS 6 skeuomorphic theme — now a LIVE, switchable theme engine.
//
// A theme is just a base "accent" colour. The DEFAULT theme is special: it returns the exact
// original blue iOS-6 PNG chrome + light content, so "Défaut" is pixel-identical to the classic
// look. Any other theme recolours the whole app from its accent colour: nav/tab bars become a
// code-drawn glossy gradient in that hue, buttons / selections / switches / chat bubbles / the
// faint content wash all follow, while the content plane stays LIGHT with DARK text — so the UI
// is guaranteed readable whatever colour is picked. Colours are derived (lighten/darken/contrast)
// and cached per-theme; the cache is cleared on every switch.
@interface IOS6Theme : NSObject

+ (instancetype)shared;

// ---- Live theme selection ----
// All available themes, as an ordered array of @{ @"id": NSString, @"nameKey": NSString,
// @"color": UIColor (swatch), @"isDefault": @(BOOL) }. Drives the in-app theme picker.
+ (NSArray *)availableThemes;
+ (NSString *)currentThemeID;                 // e.g. @"default", @"graphite", @"rouge"…
+ (void)setThemeID:(NSString *)themeID;       // persists, clears caches, posts the notification
+ (NSString *)displayNameForThemeID:(NSString *)themeID;   // localized name for Settings detail
+ (UIColor *)accent;                          // raw accent colour of the current theme (blue by default)
+ (BOOL)isDefaultTheme;                       // YES when the classic light blue look is active
+ (BOOL)isDark;                               // YES when a dark-mode theme is active
+ (BOOL)isLightColored;                       // YES for a light theme with a vivid colour accent (not default, not dark)

// Re-tint a live view subtree in place (tables, switches, search bars, segmented controls, and any
// <ADThemable> subview). Used by the central applier so a theme change propagates without a restart.
+ (void)retintViewTree:(UIView *)view;

// Current theme (legacy): YES when the "graphite" dark variant is selected.
+ (BOOL)isGraphite;

// YES on iOS 7.0+, NO on iOS 6.x. iOS 7 dropped Apple's skeuomorphic chrome
// (gradient nav bars, glossy buttons, shadowed text) in favour of a flat,
// borderless aesthetic — applying our iOS-6 PNG backgrounds on top of that
// system makes the app look dated and out of place on later devices. So
// callers that paint skeuomorphic styling should branch on this value and
// fall back to system defaults / solid colors on iOS 7+. Cheap to call
// (cached on first use; just a Major-Version comparison on Info.plist).
+ (BOOL)useFlatStyle;

// ---- Legacy compat (existing code uses these names) ----
+ (UIImage *)linenBackground;
+ (UIColor *)linenColor;

// ---- Background images (stretchable / tileable) ----
+ (UIImage *)navBarBackground;       // iOS 6 blue glossy gradient, stretchable
+ (UIImage *)tabBarBackground;       // dark metal gradient, stretchable
+ (UIImage *)cellBackground;         // white with 1px bottom hairline
+ (UIImage *)cellSelectedBackground; // blue gradient for selected state
+ (UIImage *)cardBackground;         // rounded white card for app cells in chat
+ (UIImage *)linenPattern;           // tileable cream linen
+ (UIColor *)linenPatternColor;      // shortcut for tile pattern color
+ (UIColor *)chatBackgroundColor;    // Messages-like surface (light grey / dark in dark themes)
+ (UIColor *)contentBackgroundColor; // main content plane (white / dark)
+ (UIColor *)groupedBackgroundColor; // grouped-table backdrop (light grey / darker)
+ (UIColor *)cellColor;              // fill for cells / cards / tiles (white / raised dark)

// ---- Buttons ----
+ (UIImage *)blueButtonNormal;       // stretchable glossy primary button (blue default / accent)
+ (UIImage *)blueButtonPressed;
+ (UIImage *)grayButtonNormal;
+ (UIImage *)grayButtonPressed;
// Fill colour of the primary call-to-action button (Install). Vivid accent on light themes; a
// deeper, less-glaring accent on dark themes so the big button sits within the dark palette.
+ (UIColor *)primaryButtonColor;

// Title text attributes for the nav bar under the current theme (auto-contrasting colour + shadow).
+ (NSDictionary *)navBarTitleTextAttributes;
// Text colour for the user's chat bubble (white on the classic blue / dark themes, dark on light ones).
+ (UIColor *)bubbleUserTextColor;

// ---- Style helpers (call once per element after creation) ----
+ (void)applyToNavigationBar:(UINavigationBar *)nav;
+ (void)applyToTabBar:(UITabBar *)tab;
+ (void)styleButton:(UIButton *)button;            // primary blue
+ (void)styleGrayButton:(UIButton *)button;        // secondary
+ (void)styleSmallInstallButton:(UIButton *)button; // App Store "+" pill style
+ (void)styleSearchBar:(UISearchBar *)searchBar;
+ (void)styleTextField:(UITextField *)textField;  // system rounded field (default) / dark field (dark themes)
// Grouped-table section header/footer view: clear its (else black/textured) background and recolour
// its label. Call from BOTH tableView:willDisplayHeaderView: and …willDisplayFooterView:.
+ (void)styleGroupedHeaderFooter:(UIView *)headerFooterView;

// iOS 5 has no willDisplayHeaderView:/willDisplayFooterView: hook, so grouped section header/footer
// titles keep iOS 5's dark default colour — unreadable on dark themes. On iOS 5 the grouped table
// VCs build their own readable views via these; on iOS 6+ the helpers aren't used (the willDisplay
// re-tint above handles it, leaving the iPad 4 / iPhone look untouched).
+ (BOOL)needsManualGroupedHeaderFooter;
+ (UIView *)manualGroupedHeaderViewForTitle:(NSString *)title width:(CGFloat)width;
+ (CGFloat)manualGroupedHeaderHeightForTitle:(NSString *)title;
+ (UIView *)manualGroupedFooterViewForText:(NSString *)text width:(CGFloat)width;
+ (CGFloat)manualGroupedFooterHeightForText:(NSString *)text width:(CGFloat)width;

// ---- Color palette (iOS 6 system) ----
+ (UIColor *)primaryBlue;            // ~#1E6FE6 (theme accent on light content)
+ (UIColor *)barTintColor;           // tab-bar selected glyph tint (bright accent on dark themes)
+ (UIColor *)navBarButtonTint;       // nav-bar bordered button tint (dark glossy pills on dark themes)
+ (UIColor *)separatorColor;         // table separators (light / dark)
+ (UIColor *)labelDark;              // primary body text (near-black / near-white)
+ (UIColor *)labelGray;              // secondary text
+ (UIColor *)titleColor;             // emphasis / list-item titles (navy / near-white)
+ (UIColor *)placeholderColor;       // placeholder / hint text
+ (UIColor *)embossShadowColor;      // iOS-6 emboss shadow (light) / clear on dark themes
+ (UIColor *)bubbleBlueColor;        // user bubble base color
+ (UIColor *)bubbleGrayColor;        // assistant bubble base color

// ---- Font helpers ----
+ (UIFont *)bodyFont;
+ (UIFont *)bodyBoldFont;
+ (UIFont *)titleFont;
+ (UIFont *)caption;

// ---- Bubble drawing (drawRect helper for chat cells) ----
// Renders an iOS 6 Messages-style chat bubble with tail into the current graphics context.
// rect: full bubble bounds. isUser: YES = right-aligned blue; NO = left-aligned gray.
+ (void)drawChatBubbleInRect:(CGRect)rect isUser:(BOOL)isUser;

// ---- Memory management ----
// Drops every cached bar/button/card bitmap. Safe to call anytime: the next
// access regenerates each image identically (same mechanism used when the
// theme changes). Called by the app's memory-warning handler.
+ (void)purgeImageCache;

@end
