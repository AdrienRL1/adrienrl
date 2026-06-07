// IOS5Compat.h
//
// Companion header for IOS5Compat.m. Besides the runtime subscript shims
// (installed via +load, no declaration needed), this exposes small shared
// helpers used across the app.
//
// Adaptive concurrency helpers
// ----------------------------
// AppDrop targets devices from a single-core 800 MHz–1 GHz A4 (iPad 1,
// iPhone 4, 256–512 MB) up to multi-core A6X and beyond. Background work
// (icon decode, disk reads, probes) should use ALL cores when present, but
// MUST NOT over-subscribe a single slow core — more threads than cores on an
// A4 only adds context-switch overhead and thrash.
//
// -[NSProcessInfo activeProcessorCount] exists since iOS 2, so no runtime
// guard is needed.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Number of active CPU cores, clamped to >= 1.
//   iPad 1 / iPhone 4 / 3GS (single core)  -> 1
//   A5 / A6 / A6X (dual core)               -> 2
//   newer                                   -> 2..N
NSUInteger ADRecommendedConcurrency(void);

// ADRecommendedConcurrency() clamped to at most maxCap (pass 0 for no cap).
NSUInteger ADRecommendedConcurrencyCapped(NSUInteger maxCap);

#ifdef __cplusplus
}
#endif
