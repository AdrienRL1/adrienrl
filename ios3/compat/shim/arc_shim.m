#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
// ARC entry points implemented on top of classic MRC (available since iOS 2).
id objc_retain(id obj){ if(!obj) return obj; return [obj retain]; }
void objc_release(id obj){ if(obj) [obj release]; }
id objc_autorelease(id obj){ if(!obj) return obj; return [obj autorelease]; }
id objc_retainAutorelease(id obj){ return objc_autorelease(objc_retain(obj)); }
id objc_retainAutoreleasedReturnValue(id obj){ return objc_retain(obj); }
id objc_retainAutoreleaseReturnValue(id obj){ return objc_retainAutorelease(obj); }
id objc_autoreleaseReturnValue(id obj){ return objc_autorelease(obj); }
id objc_retainBlock(id b){ return (id)_Block_copy((const void*)b); }
void objc_storeStrong(id *loc, id obj){ id prev=*loc; obj=objc_retain(obj); *loc=obj; objc_release(prev); }
id objc_storeWeak(id *loc, id obj){ *loc=obj; return obj; } // no zeroing weak on ios3 — assign semantics
id objc_loadWeakRetained(id *loc){ return objc_retain(*loc); }
id objc_loadWeak(id *loc){ return objc_autorelease(objc_retain(*loc)); }
void objc_destroyWeak(id *loc){ *loc=nil; }
id objc_initWeak(id *loc, id obj){ *loc=obj; return obj; }
void objc_copyWeak(id *to, id *from){ *to=*from; }
void objc_moveWeak(id *to, id *from){ *to=*from; *from=nil; }
void* _Block_copy(const void*); // from blocks runtime

// @autoreleasepool support for pre-iOS-4 runtimes. Push returns the pool;
// Pop releases it. iOS 3 libobjc lacks objc_autoreleasePoolPush/Pop.
void *objc_autoreleasePoolPush(void){ return [[NSAutoreleasePool alloc] init]; }
void objc_autoreleasePoolPop(void *pool){ [(NSAutoreleasePool *)pool release]; }
