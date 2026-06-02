#import <Foundation/Foundation.h>

// Translation helper supporting iOS 5+ with manual language override (no app restart needed).
//
// Usage from any .m file:
//   #import "Localization.h"
//   self.title = T(@"chat.title");
//
// Keys live in Resources/{lang}.lproj/Localizable.strings — see IPAInstall.strings.
//
// Auto-detection picks the user's iOS device language (NSLocale.preferredLanguages),
// falling back to English. Manual override is stored in NSUserDefaults and persists
// across launches.
@interface Localization : NSObject

// Returns the bundle currently in use (one of the .lproj inside the app bundle).
+ (NSBundle *)currentBundle;

// The English (en.lproj) bundle — used as a last-resort fallback so a key missing in
// the active language shows readable English instead of the raw dotted key.
+ (NSBundle *)englishBundle;

// Loads <code>.lproj/Localizable.strings DIRECTLY into a dictionary (cached per code).
// Bypasses NSBundle's localization resolution, which mis-fires when the chosen
// language differs from the device language (that was the "Turkish → English" bug).
+ (NSDictionary *)stringsForCode:(NSString *)code;

// 2-letter code currently active (e.g. "fr", "en", "ja").
+ (NSString *)currentLanguageCode;

// Set a manual override. Pass nil/empty to revert to auto-detection.
// Posts kLocalizationDidChangeNotification — VCs should re-render their UI.
+ (void)setLanguageCode:(NSString *)code;

// All supported language codes in the app bundle (those that have .lproj folders).
+ (NSArray *)availableLanguageCodes;

// Human-readable display name for a language code (e.g. "fr" → "Français").
+ (NSString *)displayNameForLanguageCode:(NSString *)code;

@end

extern NSString *const kLocalizationDidChangeNotification;

// Internal helper. Use the `T()` macro below in code.
//
// Wrapped in a function (rather than a pure macro with `?:`) so that when T() is used
// as a format string in `[NSString stringWithFormat:T(@"key"), arg]`, clang's format
// checker can't peek inside and falsely conclude the format is a constant key string —
// which would trigger -Wformat-extra-args = error against any %@ args we pass.
//
// Returns the localized string, or the key itself if the bundle returns nil (which does
// happen on iOS 5 / iPad 1 if .lproj resolution falls back to mainBundle and the key
// isn't found there — value=nil + key-not-found returns nil on iOS 5, vs. returning
// the key on iOS 6+; nil propagating into an `@{...}` literal then crashes the app).
NSString *AppDropT(NSString *key);

// Shortcut macro
#define T(key) AppDropT(key)
