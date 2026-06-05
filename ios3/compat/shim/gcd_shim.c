// gcd_shim.c — minimal libdispatch (GCD) implementation for iOS 3.x, which
// ships no libdispatch at all. Backed by pthreads + a CFRunLoop hop for the
// main queue. Covers exactly the GCD surface AppDrop uses:
//   dispatch_async / dispatch_after
//   dispatch_get_global_queue / dispatch_queue_create / dispatch_get_main_queue
//   dispatch_once
//   dispatch_group_{create,enter,leave,notify,async}
//   dispatch_semaphore_{create,signal,wait}
//   dispatch_time / dispatch_walltime
//
// NOTE: this is intentionally small. Queues created with dispatch_queue_create
// are treated as concurrent (each async spawns a detached pthread). If AppDrop
// relies anywhere on a *serial* queue for ordering, that queue needs a real
// FIFO+worker; see README open items.
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <sys/time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include "blocks/Block.h"

// ---------------------------------------------------------------------------
// Per-thread autorelease pool (iOS 3 / MRC correctness)
// ---------------------------------------------------------------------------
// Every block this shim runs on a *spawned* pthread (the detached trampoline,
// the serial worker, the dispatch_after thread, group async/notify threads)
// executes Objective-C code that autoreleases Foundation objects (NSURL,
// NSData, NSString, file ops, JSON parsing, SQLite row wrappers, …). On iOS 3
// under MRC there is NO implicit per-thread pool: only the main thread's
// CFRunLoop wraps each iteration in one. A worker thread with no
// NSAutoreleasePool floods the log with
//     *** _NSAutoreleaseNoPool(): Object 0x… autoreleased with no pool in place
//         - just leaking
// and, once enough objects pile up / a leaked-then-touched object is messaged,
// faults in objc_msgSend with EXC_BAD_ACCESS (the ~2s-after-launch crash on
// Thread 3). Wrapping each worker block in a real NSAutoreleasePool fixes both
// the leak storm and the crash. This file is C, so the pool is driven through
// the objc runtime C API (NSAutoreleasePool is iOS 2.0, always present).
static void *ad_pool_push(void) {
    Class cls = objc_getClass("NSAutoreleasePool");
    if (!cls) return NULL;
    id (*msg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id pool = msg((id)cls, sel_registerName("alloc"));
    pool = msg(pool, sel_registerName("init"));
    return (void *)pool;
}
static void ad_pool_pop(void *pool) {
    if (!pool) return;
    void (*msg)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    msg((id)pool, sel_registerName("release"));
}

// Run an Objective-C block wrapped in its own NSAutoreleasePool. Used for every
// block executed on a shim-spawned worker thread (which otherwise has no pool).
static void ad_invoke(dispatch_block_t b) {
    void *pool = ad_pool_push();
    b();
    ad_pool_pop(pool);
}

#undef dispatch_once
#undef dispatch_once_f

// ---------------------------------------------------------------------------
// Queues
// ---------------------------------------------------------------------------
// Three kinds of queue exist in this shim:
//   * the main queue        -> work hops onto the main CFRunLoop (UIKit-safe)
//   * the global queue      -> concurrent: every async spawns a detached thread
//   * dispatch_queue_create -> a REAL FIFO serial queue (single worker thread),
//                              unless created DISPATCH_QUEUE_CONCURRENT.
// The serial path matters: LocalCatalog.m relies on its _searchQueue
// serializing every SQLite query on one db handle (no locking otherwise). The
// old shim ran those as concurrent detached threads, which would race the
// single sqlite3* — corrupting results or crashing on a real iOS 3 device.

static char _global_q_storage[64];

#define AD_QUEUE_MAGIC 0x51444551u  // 'QDEQ'

typedef struct ad_node {
    dispatch_block_t b;       // already Block_copy'd
    struct ad_node *next;
} ad_node;

typedef struct {
    unsigned int   magic;     // AD_QUEUE_MAGIC sentinel
    int            concurrent;// 1 = concurrent, 0 = serial FIFO
    pthread_mutex_t m;
    pthread_cond_t  cv;
    ad_node        *head, *tail;
    int            started;   // worker thread launched?
    pthread_t      worker;
} ad_queue;

dispatch_queue_t dispatch_get_global_queue(long pri, unsigned long flags) {
    (void)pri; (void)flags;
    return (dispatch_queue_t)_global_q_storage;
}

dispatch_queue_t dispatch_queue_create(const char *label, dispatch_queue_attr_t attr) {
    (void)label;
    ad_queue *q = (ad_queue *)calloc(1, sizeof(ad_queue));
    q->magic = AD_QUEUE_MAGIC;
    // libdispatch: DISPATCH_QUEUE_SERIAL is NULL; anything else (e.g.
    // DISPATCH_QUEUE_CONCURRENT) means concurrent. AppDrop only asks for SERIAL.
    q->concurrent = (attr != NULL) ? 1 : 0;
    pthread_mutex_init(&q->m, NULL);
    pthread_cond_init(&q->cv, NULL);
    return (dispatch_queue_t)q;
}

static void *trampoline(void *ctx) {
    dispatch_block_t b = (dispatch_block_t)ctx;
    ad_invoke(b);
    Block_release(b);
    return NULL;
}

// run_on_main: schedule `b` (already Block_copy'd; we own it) to run on the
// main thread's run loop. iOS 3.1.3 has NO CFRunLoopPerformBlock (that symbol
// first appears in iOS 4.0 / CoreFoundation 550), so using it makes dyld abort
// the process with "Symbol not found: _CFRunLoopPerformBlock" at first call.
// Instead we use a one-shot CFRunLoopTimer (available since iOS 2.0) with an
// immediate fire date: CF retains the timer while it's scheduled, fires it on
// the next main-loop pass, we run+release the block, then invalidate.
static void ad_main_timer_cb(CFRunLoopTimerRef timer, void *info) {
    dispatch_block_t b = (dispatch_block_t)info;
    if (b) { b(); Block_release(b); }
    CFRunLoopTimerInvalidate(timer);
}

static void run_on_main(dispatch_block_t b) {
    CFRunLoopRef rl = CFRunLoopGetMain();
    CFRunLoopTimerContext ctx = { 0, (void *)b, NULL, NULL, NULL };
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(
        kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent(),  // fire immediately on next loop pass
        0,                            // non-repeating
        0, 0,
        ad_main_timer_cb,
        &ctx);
    if (!t) { if (b) { ad_invoke(b); Block_release(b); } return; }  // fallback: run inline
    CFRunLoopAddTimer(rl, t, kCFRunLoopCommonModes);
    CFRelease(t);                     // run loop keeps it alive until it fires
    CFRunLoopWakeUp(rl);
}

static void run_detached(dispatch_block_t b) {
    pthread_t t;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &at, trampoline, b) != 0) { ad_invoke(b); Block_release(b); }
    pthread_attr_destroy(&at);
}

// Is this pointer a queue made by dispatch_queue_create (vs main/global storage)?
static ad_queue *as_created_queue(dispatch_queue_t q) {
    if (!q) return NULL;
    if (q == dispatch_get_main_queue()) return NULL;
    if (q == (dispatch_queue_t)_global_q_storage) return NULL;
    ad_queue *aq = (ad_queue *)q;
    return (aq->magic == AD_QUEUE_MAGIC) ? aq : NULL;
}

// Serial worker: drains the FIFO in order, one block at a time, forever.
static void *serial_worker(void *ctx) {
    ad_queue *q = (ad_queue *)ctx;
    for (;;) {
        pthread_mutex_lock(&q->m);
        while (q->head == NULL) pthread_cond_wait(&q->cv, &q->m);
        ad_node *n = q->head;
        q->head = n->next;
        if (q->head == NULL) q->tail = NULL;
        pthread_mutex_unlock(&q->m);

        ad_invoke(n->b);
        Block_release(n->b);
        free(n);
    }
    return NULL;
}

// Enqueue onto a created queue: concurrent -> detached thread; serial -> FIFO.
static void queue_enqueue(ad_queue *q, dispatch_block_t b /* owned */) {
    if (q->concurrent) { run_detached(b); return; }
    ad_node *n = (ad_node *)malloc(sizeof(ad_node));
    n->b = b;
    n->next = NULL;
    pthread_mutex_lock(&q->m);
    if (q->tail) q->tail->next = n; else q->head = n;
    q->tail = n;
    if (!q->started) {
        q->started = 1;
        if (pthread_create(&q->worker, NULL, serial_worker, q) != 0) {
            // Couldn't spawn worker — drain inline as a last resort.
            q->started = 0;
            ad_node *cur = q->head; q->head = q->tail = NULL;
            pthread_mutex_unlock(&q->m);
            while (cur) { ad_node *nx = cur->next; ad_invoke(cur->b); Block_release(cur->b); free(cur); cur = nx; }
            return;
        }
    }
    pthread_cond_signal(&q->cv);
    pthread_mutex_unlock(&q->m);
}

void dispatch_async(dispatch_queue_t q, dispatch_block_t block) {
    dispatch_block_t b = Block_copy(block);
    if (q == dispatch_get_main_queue()) { run_on_main(b); return; }
    ad_queue *aq = as_created_queue(q);
    if (aq) { queue_enqueue(aq, b); return; }
    run_detached(b);  // global / unknown -> concurrent
}

void dispatch_sync(dispatch_queue_t q, dispatch_block_t block) {
    (void)q;
    block();  // executes inline on the calling thread (FIFO ordering preserved
              // because the caller blocks; AppDrop does not use dispatch_sync)
}

// ---------------------------------------------------------------------------
// dispatch_once
// ---------------------------------------------------------------------------
void dispatch_once(dispatch_once_t *pred, dispatch_block_t block) {
    static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&m);
    if (*pred != ~0l) { block(); *pred = ~0l; }
    pthread_mutex_unlock(&m);
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------
dispatch_time_t dispatch_time(dispatch_time_t when, int64_t delta) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    uint64_t now = (uint64_t)tv.tv_sec * 1000000000ull + (uint64_t)tv.tv_usec * 1000ull;
    if (when == DISPATCH_TIME_NOW) when = now;
    int64_t r = (int64_t)when + delta;
    return (dispatch_time_t)(r < 0 ? 0 : r);
}

dispatch_time_t dispatch_walltime(const struct timespec *w, int64_t delta) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    uint64_t base = w ? ((uint64_t)w->tv_sec * 1000000000ull + (uint64_t)w->tv_nsec)
                      : ((uint64_t)tv.tv_sec * 1000000000ull + (uint64_t)tv.tv_usec * 1000ull);
    int64_t r = (int64_t)base + delta;
    return (dispatch_time_t)(r < 0 ? 0 : r);
}

typedef struct { dispatch_time_t when; dispatch_block_t b; int is_main; } after_ctx;
static void *after_thread(void *p) {
    after_ctx *c = (after_ctx *)p;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    uint64_t now = (uint64_t)tv.tv_sec * 1000000000ull + (uint64_t)tv.tv_usec * 1000ull;
    if (c->when > now) {
        uint64_t ns = c->when - now;
        struct timespec ts;
        ts.tv_sec = (time_t)(ns / 1000000000ull);
        ts.tv_nsec = (long)(ns % 1000000000ull);
        nanosleep(&ts, NULL);
    }
    if (c->is_main) {
        // Hop the final call onto the main run loop. run_on_main takes ownership
        // of the block (it releases it after the one-shot timer fires), so we do
        // NOT release it here.
        run_on_main(c->b);
    } else {
        ad_invoke(c->b);
        Block_release(c->b);
    }
    free(c);
    return NULL;
}

void dispatch_after(dispatch_time_t when, dispatch_queue_t q, dispatch_block_t block) {
    dispatch_block_t b = Block_copy(block);
    after_ctx *c = (after_ctx *)malloc(sizeof(after_ctx));
    c->when = when;
    c->b = b;                               // we hand this single ref off to after_thread
    c->is_main = (q == dispatch_get_main_queue());
    pthread_t t; pthread_attr_t at; pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &at, after_thread, c) != 0) {
        if (c->is_main) run_on_main(c->b); else { ad_invoke(c->b); Block_release(c->b); }
        free(c);
    }
    pthread_attr_destroy(&at);
}

// ---------------------------------------------------------------------------
// Groups (counter + condvar)
// ---------------------------------------------------------------------------
typedef struct {
    pthread_mutex_t m;
    pthread_cond_t  cv;
    long count;
} grp_t;

dispatch_group_t dispatch_group_create(void) {
    grp_t *g = (grp_t *)calloc(1, sizeof(grp_t));
    pthread_mutex_init(&g->m, NULL);
    pthread_cond_init(&g->cv, NULL);
    g->count = 0;
    return (dispatch_group_t)g;
}

void dispatch_group_enter(dispatch_group_t group) {
    grp_t *g = (grp_t *)group;
    pthread_mutex_lock(&g->m);
    g->count++;
    pthread_mutex_unlock(&g->m);
}

void dispatch_group_leave(dispatch_group_t group) {
    grp_t *g = (grp_t *)group;
    pthread_mutex_lock(&g->m);
    if (--g->count <= 0) pthread_cond_broadcast(&g->cv);
    pthread_mutex_unlock(&g->m);
}

long dispatch_group_wait(dispatch_group_t group, dispatch_time_t timeout) {
    grp_t *g = (grp_t *)group;
    pthread_mutex_lock(&g->m);
    while (g->count > 0) {
        if (timeout == DISPATCH_TIME_FOREVER) {
            pthread_cond_wait(&g->cv, &g->m);
        } else {
            struct timespec ts;
            ts.tv_sec = (time_t)(timeout / 1000000000ull);
            ts.tv_nsec = (long)(timeout % 1000000000ull);
            if (pthread_cond_timedwait(&g->cv, &g->m, &ts) != 0) break;
        }
    }
    long r = g->count;
    pthread_mutex_unlock(&g->m);
    return r;  // 0 = all done, non-zero = timed out
}

typedef struct { grp_t *g; dispatch_queue_t q; dispatch_block_t b; int is_main; } gasync_ctx;
static void *group_async_thread(void *p) {
    gasync_ctx *c = (gasync_ctx *)p;
    ad_invoke(c->b);
    Block_release(c->b);
    dispatch_group_leave((dispatch_group_t)c->g);
    free(c);
    return NULL;
}

void dispatch_group_async(dispatch_group_t group, dispatch_queue_t q, dispatch_block_t block) {
    dispatch_group_enter(group);
    gasync_ctx *c = (gasync_ctx *)malloc(sizeof(gasync_ctx));
    c->g = (grp_t *)group; c->q = q; c->b = Block_copy(block);
    pthread_t t; pthread_attr_t at; pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &at, group_async_thread, c) != 0) {
        ad_invoke(c->b); Block_release(c->b); dispatch_group_leave(group); free(c);
    }
    pthread_attr_destroy(&at);
}

typedef struct { grp_t *g; dispatch_block_t b; int is_main; } gnotify_ctx;
static void *group_notify_thread(void *p) {
    gnotify_ctx *c = (gnotify_ctx *)p;
    dispatch_group_wait((dispatch_group_t)c->g, DISPATCH_TIME_FOREVER);
    if (c->is_main) run_on_main(c->b);
    else { ad_invoke(c->b); Block_release(c->b); }
    free(c);
    return NULL;
}

void dispatch_group_notify(dispatch_group_t group, dispatch_queue_t q, dispatch_block_t block) {
    gnotify_ctx *c = (gnotify_ctx *)malloc(sizeof(gnotify_ctx));
    c->g = (grp_t *)group; c->b = Block_copy(block);
    c->is_main = (q == dispatch_get_main_queue());
    pthread_t t; pthread_attr_t at; pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &at, group_notify_thread, c) != 0) {
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        ad_invoke(c->b); Block_release(c->b); free(c);
    }
    pthread_attr_destroy(&at);
}

// ---------------------------------------------------------------------------
// Semaphores
// ---------------------------------------------------------------------------
typedef struct {
    pthread_mutex_t m;
    pthread_cond_t  cv;
    long value;
} sem_t_shim;

dispatch_semaphore_t dispatch_semaphore_create(long value) {
    sem_t_shim *s = (sem_t_shim *)calloc(1, sizeof(sem_t_shim));
    pthread_mutex_init(&s->m, NULL);
    pthread_cond_init(&s->cv, NULL);
    s->value = value;
    return (dispatch_semaphore_t)s;
}

long dispatch_semaphore_signal(dispatch_semaphore_t dsema) {
    sem_t_shim *s = (sem_t_shim *)dsema;
    pthread_mutex_lock(&s->m);
    s->value++;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->m);
    return 0;
}

long dispatch_semaphore_wait(dispatch_semaphore_t dsema, dispatch_time_t timeout) {
    sem_t_shim *s = (sem_t_shim *)dsema;
    pthread_mutex_lock(&s->m);
    while (s->value <= 0) {
        if (timeout == DISPATCH_TIME_FOREVER) {
            pthread_cond_wait(&s->cv, &s->m);
        } else {
            struct timespec ts;
            ts.tv_sec  = (time_t)(timeout / 1000000000ull);
            ts.tv_nsec = (long)(timeout % 1000000000ull);
            if (pthread_cond_timedwait(&s->cv, &s->m, &ts) != 0) {
                pthread_mutex_unlock(&s->m);
                return ~0l;  // timed out
            }
        }
    }
    s->value--;
    pthread_mutex_unlock(&s->m);
    return 0;
}
