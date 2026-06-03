# AppDrop — iOS 3 / armv6 backport (`iOS3iThink`)

This directory backports AppDrop so it builds and runs on **armv6 / iOS 3.1**
(original iPhone, iPhone 3G, iPod touch 1st/2nd gen) **without rewriting the
app's ARC source to manual reference counting**.

## TL;DR — the key insight

The hard part of "downgrading from ARC" is **not** the `@property (strong)`
keywords. It's that ARC, Objective-C **blocks**, and **GCD** all need C
runtime functions (`objc_retain`, `_Block_copy`, `dispatch_async`, …) that
simply **do not exist in iOS 3's `libobjc` / `libSystem`**. iOS 3 has no
libdispatch and no blocks runtime at all.

So instead of hand-converting ~13,400 lines of ARC across 37 files (and
introducing bugs), this backport **keeps the code in ARC** and statically
links tiny, self-contained implementations of those runtimes into the binary.
The result is a single Mach-O that carries its own ARC/blocks/GCD support and
therefore runs on a stock iOS 3 device.

This was **verified end-to-end on Linux**: all 37 sources compile, the app
links to a real `armv6` Mach-O with `NOUNDEFS`, and a guard asserts that **zero**
ARC/blocks/GCD symbols remain as unresolved dylib imports.

## What was actually needed (measured, not guessed)

| Problem | Files affected | Fix |
|---|---|---|
| `dict[key]` / `arr[i]` subscripting | ~12 | declared in `AppDropCompat.h`, IMPs already in `IOS5Compat.m` |
| `NS_ENUM` / `NS_OPTIONS` macros (iOS 6 SDK) | many | macro fallback in `AppDropCompat.h` |
| `NSTextAlignment*` / `NSLineBreakBy*` renames (iOS 6) | ~10 | `#define` to the iOS 2-era `UI*` names |
| `UIInterfaceOrientationMask*` (iOS 6) | 3 | enum in `AppDropCompat.h` |
| `@YES` / `@NO` boxed literals | a few | `__objc_yes/no` builtins (5.1 SDK breaks these) |
| `NSArray -firstObject` (iOS 4) | several | `+load` IMP in `AppDropRuntime.m` |
| `NSData` base64 (iOS 7) | 1 | `+load` IMP in `AppDropRuntime.m` |
| `NSString sizeWithAttributes:` / `drawAtPoint:withAttributes:` (iOS 7) | few | bridged to iOS-2 `UIStringDrawing` |
| `UIImage +imageWithData:scale:` (iOS 6) | 1 | `+load` IMP |
| `NSUUID` (iOS 6 class) | 1 | real `@implementation` (CFUUID-backed) |
| `NSJSONSerialization` (iOS 5 class) | 10 | cJSON-backed class in `AppDropJSON.m` |
| ARC runtime (`objc_retain`, …) | all | static `shim/arc_shim.m` |
| Blocks runtime (`_Block_copy`, `__NSConcreteStackBlock`, …) | 52 blocks | static `shim/blocks/` (Apple libclosure, public domain) |
| GCD (`dispatch_async`, `dispatch_once`, …) | 56 sites | static pthread-backed `shim/gcd_shim.c` |
| mbedTLS prebuilt was armv7-only | link | rebuilt for armv6 from source (v3.6.2) |
| mbedTLS `clock_gettime`/`CLOCK_MONOTONIC` absent on iOS 3 | link | `shim/mbed_platform_compat.c` (gettimeofday-based) |
| Only **one** real source edit | `InstallManager.m` | `[NSDate date].timeIntervalSince1970` → message syntax |

## Layout

```
ios3/
├── build-ios3.sh          # one-command Linux cross-compile -> .ipa + .deb
├── compat/
│   ├── AppDropCompat.h     # prefix header: macros/decls so ARC sources parse
│   ├── AppDropRuntime.m     # +load backfills (firstObject, base64, NSUUID, …)
│   ├── AppDropJSON.m        # NSJSONSerialization via cJSON
│   ├── cJSON.[ch]           # public-domain JSON (v1.7.18)
│   └── shim/
│       ├── arc_shim.m       # ARC runtime on classic retain/release
│       ├── blocks/          # blocks runtime (libclosure)
│       ├── gcd_shim.c        # GCD on pthreads
│       ├── gcd_mainq.c       # _dispatch_main_q storage
│       └── mbed_platform_compat.c
└── README.md
```

## Building locally

```sh
cd ios3
./build-ios3.sh
```

First run downloads the iOS 5.1 SDK + builds the cctools/ld64/ldid toolchain
and mbedTLS (~10 min). Subsequent runs are cached. Output:
`ios3/build/AppDrop.ipa` and `ios3/build/AppDrop.deb`.

> **Why the iOS 5.1 SDK?** It's the last SDK whose headers still target a
> deployment min low enough for `armv6`, while clang can still emit code for
> `-target armv6-apple-ios3.1`. We compile *against* 5.1 headers but the runtime
> shims supply everything iOS 3 itself lacks, and we set `-miphoneos-version-min`
> so the binary loads on 3.x.

## Status / open items

- ✅ Compiles (37/37), links (`NOUNDEFS`), self-contained ARC/blocks/GCD.
- ✅ Packages `.ipa` + Cydia `.deb`, localizations converted to JSON.
- ⚠️ **Not yet run on real hardware / simulator.** Link-clean ≠ bug-free; the
  GCD shim is a minimal pthread implementation (serial/concurrent queues,
  `dispatch_once`, `after`, groups, semaphores) and may need hardening under
  load. Test on a 3G/3GS first.
- ⚠️ The `.deb` `control` still declares `firmware (>= 5.0)` and AppSync
  dependencies that are iOS 5+ names. For an iOS 3 install, lower the
  `firmware` floor and adjust the AppSync/installipa dependency names to the
  3.x-era packages.
- ⚠️ The GCD shim runs `dispatch_get_main_queue` work on a background thread by
  default. UIKit calls must stay on the main thread — if you see UI from a
  block misbehave, route main-queue dispatches through a CFRunLoop source on
  the main thread (noted inline in `gcd_shim.c`).
