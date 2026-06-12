// AppDropBlocks.m — ADBlockBox implementation. See AppDropBlocks.h for why.
// MRC (-fno-objc-arc).

#import "AppDropBlocks.h"

@implementation ADBlockBox

+ (instancetype)boxWithBlock:(void (^)(void))block {
    ADBlockBox *b = [[[self alloc] init] autorelease];
    if (block) {
        // Heap-copy via the C runtime (never message the block).
        b->_block = (void (^)(void))_Block_copy((const void *)block);
    }
    return b;
}

+ (instancetype)boxWithImageBlock:(void (^)(id))block {
    ADBlockBox *b = [[[self alloc] init] autorelease];
    if (block) {
        b->_block = (void (^)(void))_Block_copy((const void *)block);
    }
    return b;
}

- (void (^)(void))block { return _block; }

- (void)invoke { if (_block) _block(); }

- (void)dealloc {
    if (_block) _Block_release((const void *)_block);
    [super dealloc];
}

@end
