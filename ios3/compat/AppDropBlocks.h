// AppDropBlocks.h — safe block storage on iOS 3.x (blocks are NOT ObjC objects).
//
// THE PROBLEM
// -----------
// The Objective-C `NSBlock` class hierarchy first ships in iOS 4. On iOS 3.x the
// compiler still stamps every block's `isa` with one of the `_NSConcrete*Block`
// symbols, but nothing back-fills those symbols with a real class — in this
// project's bundled blocks runtime they are literally `void *[32] = {0}` (32 zero
// words; see ios3/compat/shim/blocks/data.c). Therefore sending a block ANY
// Objective-C message dereferences a garbage Class and crashes:
//
//     EXC_BAD_ACCESS (SIGBUS) at 0x0 in objc_msgSend
//
// The compiler/runtime sends a block an ObjC message in three common situations:
//   1. `@property(copy)` block setter  → objc_setProperty → -copyWithZone:
//   2. an explicit `[someBlock copy]`  → -copy
//   3. storing a block in an NSArray/NSDictionary → the collection -retains it
//
// All three are landmines on iOS 3. The BUNDLED C blocks runtime, in contrast,
// copies/releases a block WITHOUT messaging it, via the C functions _Block_copy
// and _Block_release. This header routes every block lifetime op through those.
//
// USAGE
// -----
//   * Replace a synthesized `@property(copy)` block setter/getter with a manual
//     pair backed by an ivar, using AD_BLOCK_ACCESSORS (declare the ivar +
//     `@dynamic name;` in the @implementation).
//   * To stash a block in a collection, box it with ADBlockBox (it retains the
//     block with _Block_copy and releases it with _Block_release in -dealloc),
//     then call -invoke / -block as needed.
//
// MRC throughout (-fno-objc-arc), matching the rest of the iOS 3 compat layer.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// From the bundled C blocks runtime (ios3/compat/shim/blocks). These copy a
// stack block to the heap / bump-or-free a heap block's refcount WITHOUT ever
// sending the block an Objective-C message.
extern void *_Block_copy(const void *aBlock);
extern void  _Block_release(const void *aBlock);

#ifdef __cplusplus
}
#endif

// Generate a manual getter/setter pair for a copy-semantics block @property,
// backed by `ivar`. Heap-copies the incoming block with _Block_copy and frees
// the previous one with _Block_release — never messages a block. Use inside an
// @implementation together with the matching ivar and `@dynamic <getter>;`.
//
//   @implementation Foo {
//       void (^_onTap)(void);
//   }
//   @dynamic onTap;
//   AD_BLOCK_ACCESSORS(onTap, setOnTap, _onTap, void(^)(void))
//
#define AD_BLOCK_ACCESSORS(GETTER, SETTER, IVAR, BLOCKTYPE)                    \
    - (BLOCKTYPE)GETTER { return IVAR; }                                      \
    - (void)SETTER:(BLOCKTYPE)blk {                                           \
        if (blk == IVAR) return;                                             \
        if (blk) blk = (BLOCKTYPE)_Block_copy((const void *)blk);            \
        if (IVAR) _Block_release((const void *)IVAR);                        \
        IVAR = blk;                                                          \
    }

// A retain-counted ObjC wrapper that owns a block via the C runtime, so blocks
// can live inside NSArray/NSDictionary (the collection retains the BOX, never
// the block). -invoke runs a zero-argument block; for other shapes, read -block
// and cast.
@interface ADBlockBox : NSObject {
    void (^_block)(void);
}
+ (instancetype)boxWithBlock:(void (^)(void))block;          // copies a void(^)(void) block
+ (instancetype)boxWithImageBlock:(void (^)(id image))block; // copies a void(^)(id) block (e.g. UIImage *)
- (void (^)(void))block;                              // the heap block (not copied); cast as needed
- (void)invoke;                                       // calls the block if present (zero-arg shape)
@end
