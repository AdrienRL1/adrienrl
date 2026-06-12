// AppDropBlockOp.m — NSBlockOperation backport for iOS 3.1.
//
// NSBlockOperation is iOS 4.0+. iOS 3.x ships NSOperation and NSOperationQueue,
// just not the block convenience subclass. AppDrop's IconLoader enqueues every
// network icon fetch as +[NSBlockOperation blockOperationWithBlock:], so on a
// real 3.1 device the first uncached icon throws:
//
//     *** +[NSBlockOperation blockOperationWithBlock:]: unrecognized selector
//
// AppDropCompat.h macro-rewrites `NSBlockOperation` → `ADBlockOperation` (this
// class) so every call site is unchanged. We subclass NSOperation (which DOES
// exist on 3.1) and run the stored blocks in -main. NSOperationQueue drives
// -start/-main and KVO for isExecuting/isFinished natively, so a plain
// non-concurrent NSOperation is all we need.
//
// Blocks are NOT ObjC objects on iOS 3 (see AppDropBlocks.h), so we store and
// release them through the C blocks runtime, never via -copy/-retain messages.
//
// MRC (-fno-objc-arc).

#import <Foundation/Foundation.h>
#import "AppDropBlocks.h"   // _Block_copy / _Block_release

// Keep the real ADBlockOperation name in this file (undo the compat.h rewrite).
#undef NSBlockOperation

@implementation ADBlockOperation {
    NSMutableArray *_blockBoxes;   // ADBlockBox elements (each owns a heap block)
    BOOL _adStarted;               // dedupe guard for the iOS 3.x/4.x queue bug
}

+ (instancetype)blockOperationWithBlock:(void (^)(void))block {
    ADBlockOperation *op = [[[self alloc] init] autorelease];
    if (block) [op addExecutionBlock:block];
    return op;
}

- (id)init {
    if ((self = [super init])) {
        _blockBoxes = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)addExecutionBlock:(void (^)(void))block {
    if (!block) return;
    // ADBlockBox heap-copies via _Block_copy and releases in its -dealloc; the
    // array retains the BOX (a real NSObject), never the block itself.
    [_blockBoxes addObject:[ADBlockBox boxWithBlock:block]];
}

// iOS 3.x/4.x NSOperationQueue has a scheduling race: when the queue runs with
// maxConcurrentOperationCount > 1 AND the queuePriority of already-enqueued
// operations is mutated (IconLoader does this for visible-first icon ordering
// while the catalog scrolls), the scheduler can send -start to the SAME
// operation twice. NSOperation's own -start then throws:
//     *** -[ADBlockOperation start]: receiver has already started or finished
// Apple fixed this in iOS 5; on 3.1 we self-defend. The guard makes a second
// -start a no-op so [super start] (which drives isExecuting/isFinished KVO the
// queue depends on) is only ever invoked once.
- (void)start {
    @synchronized (self) {
        if (_adStarted || self.isExecuting || self.isFinished) return;
        _adStarted = YES;
    }
    [super start];
}

- (void)main {
    // NSOperationQueue has already transitioned us to executing; just run the
    // blocks. (NSBlockOperation runs its execution blocks concurrently, but
    // AppDrop only ever adds one, and serial execution is a safe superset.)
    if (self.isCancelled) return;
    for (ADBlockBox *box in [[_blockBoxes copy] autorelease]) {
        if (self.isCancelled) break;
        [box invoke];
    }
}

- (void)dealloc {
    [_blockBoxes release];
    [super dealloc];
}

@end
