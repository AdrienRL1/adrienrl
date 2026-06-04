#import <Foundation/Foundation.h>

// Persists the user's custom Accueil layout: which tiles are PINNED (top zone) vs not, the order
// within each zone, and each tile's SPAN ("1x1" / "2x1" / "2x2"). Tiny (three NSUserDefaults
// entries). The view controller owns the per-item DEFAULTS (default-pinned set + default order);
// this only remembers what the user changed via drag / pin / resize.
@interface HomeLayoutStore : NSObject

+ (instancetype)shared;

// Split the current items into ordered PINNED + UNPINNED id lists, merging saved state:
//   • items still present keep their saved zone + order,
//   • brand-new items (categories/folders that appeared since) land in their DEFAULT zone, appended.
// `items` is an array of @{ @"id": NSString, @"defaultPinned": @(BOOL) }.
- (void)resolveItems:(NSArray *)items
          intoPinned:(NSMutableArray *)pinnedIds
            unpinned:(NSMutableArray *)unpinnedIds;

// Persist the full pinned + unpinned id lists (called after a drag / pin / unpin / reorder).
- (void)savePinned:(NSArray *)pinnedIds unpinned:(NSArray *)unpinnedIds;

// Span as "WxH" (e.g. "2x1"); nil when the user hasn't resized this tile (caller applies a default).
- (NSString *)spanForItem:(NSString *)itemId;
- (void)setSpan:(NSString *)span forItem:(NSString *)itemId;

// YES once the user has pinned/reordered/resized anything → the VC shows a "Reset layout" button.
- (BOOL)hasCustomLayout;
- (void)reset;   // forget all layout → back to the automatic defaults

@end
