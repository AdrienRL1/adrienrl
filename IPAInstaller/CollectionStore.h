#import <Foundation/Foundation.h>

// Posted (on the main thread) whenever any collection changes — membership, order, name, or the
// pinned preview app. The Accueil tiles + open collection screens listen to refresh live.
extern NSString * const CollectionStoreDidChangeNotification;

// The built-in Favoris collection id. Always present, can't be deleted or renamed.
extern NSString * const CollectionFavoritesId;
// The built-in "Télécharger plus tard" queue id. Always present; behaves like a collection but apps
// leave it once their download starts.
extern NSString * const CollectionLaterId;

// Stores the user's app COLLECTIONS, persisted to a plist so they survive relaunches:
//   • the built-in "Favoris" collection (id == CollectionFavoritesId), and
//   • user-created folders (Phase 4) — same shape, same behaviour.
// Each collection holds the FULL catalog app dictionaries the user added, so a favourite still
// works (and shows its icon) even offline or if the catalogue later changes.
@interface CollectionStore : NSObject

+ (instancetype)shared;

// A stable key for an app dict (bundleId → url → title). Used for membership + de-dup.
+ (NSString *)keyForApp:(NSDictionary *)app;

#pragma mark Collections

// Ordered: Favoris first, then folders in creation order. Each entry is a dict with keys
// @"id", @"name", @"builtin"(NSNumber bool), @"apps"(NSArray of app dicts), and optionally @"pinned"(key).
- (NSArray *)collections;
- (NSDictionary *)collectionForId:(NSString *)cid;
- (NSArray *)folders;                       // user collections only (builtin == NO)

- (NSString *)nameForCollection:(NSString *)cid;       // localized "Favoris" for the built-in one
- (NSArray *)appsInCollection:(NSString *)cid;          // app dicts
- (NSInteger)countInCollection:(NSString *)cid;
- (BOOL)collection:(NSString *)cid containsApp:(NSString *)appKey;

- (void)addApp:(NSDictionary *)app toCollection:(NSString *)cid;
- (void)removeAppKey:(NSString *)appKey fromCollection:(NSString *)cid;

#pragma mark Favoris convenience

- (BOOL)isFavorite:(NSString *)appKey;
- (void)toggleFavorite:(NSDictionary *)app;             // add if absent, remove if present

#pragma mark Télécharger plus tard convenience

- (BOOL)isInLater:(NSString *)appKey;
- (void)toggleLater:(NSDictionary *)app;                // add if absent, remove if present

#pragma mark Folders (Phase 4)

- (NSString *)createFolderNamed:(NSString *)name;       // returns the new collection id
- (void)renameCollection:(NSString *)cid to:(NSString *)name;
- (void)deleteCollection:(NSString *)cid;               // no-op on the built-in Favoris

#pragma mark Pinned preview app

// nil = automatic (rotating mosaic). Otherwise the app key that's always shown as the tile image.
- (NSString *)pinnedKeyForCollection:(NSString *)cid;
- (void)setPinnedKey:(NSString *)appKey forCollection:(NSString *)cid;   // nil resets to auto

// Icon URLs of the apps in a collection (for the tile mosaic). When an app is pinned, that app's
// icon is returned first so it can be shown as the fixed image.
- (NSArray *)iconPoolForCollection:(NSString *)cid;

@end
