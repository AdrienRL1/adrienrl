# AppDrop — iOS 3 / armv6 backport (`iOS3iThink`)

This directory backports AppDrop so it builds and runs on **armv6 / iOS 3.1**
(original iPhone, iPhone 3G, iPod touch 1st/2nd gen).

## TL;DR — the approach

"Downgrading from ARC" has two very different halves:

1. **Reference counting** — the `@property (strong/weak/copy)` keywords, retains,
   releases, autoreleases. This part is **cheap to convert**: under
   `-fno-objc-arc`, clang auto-synthesizes correct retaining setters and emits
   plain `retain`/`release` **message sends**, which the iOS 3 runtime has had
   since day one. The only manual work is `weak` → non-zeroing weak.
2. **Blocks and GCD** — these need C runtime functions (`_Block_copy`,
   `dispatch_async`, `dispatch_once`, …) that **do not exist in iOS 3's
   `libSystem`**. iOS 3 has no libdispatch and no blocks runtime at all. This is
   the genuinely hard part, and it is independent of ARC vs MRC.

So this backport **converts the app to MRC** (manual reference counting) and
statically links tiny, self-contained implementations of the **blocks** and
**GCD** runtimes into the binary. The result is a single Mach-O that manages its
own memory with native `retain`/`release`, carries its own blocks/GCD support,
and runs on a stock iOS 3 device — **with no `libarclite` and no ARC runtime
shim**.

### Why MRC instead of an ARC-runtime shim?

An earlier iteration kept the source in ARC and statically linked an ARC runtime
shim (`objc_retain`, `objc_storeStrong`, `objc_retainAutoreleasedReturnValue`,
…) plus an empty `libarclite` stub to satisfy clang's driver. That works on
paper but is fragile on real iOS 3 hardware: ARC's autoreleased-return-value
optimization (`objc_retainAutoreleasedReturnValue` / `objc_autoreleaseReturnValue`)
depends on a cooperating runtime and a specific calling-convention handshake,
and the empty-`libarclite` driver hack fights the toolchain. MRC sidesteps all of
it: the compiler emits ordinary `objc_msgSend(obj, @selector(release))` calls
that the 3.x runtime already implements.

### How small the conversion actually was (measured, not guessed)

The whole codebase is ~16k lines across 42 `.m` files. Switching the compile to
`-fno-objc-arc` produced **zero** ownership errors — every error was the same
single category: `weak`/`__weak` (zeroing weak references need the iOS 5+
runtime). The complete manual change set:

| Change | Sites | Fix |
|---|---|---|
| `__weak Foo *x = self;` local idiom | 24 | `AD_WEAK Foo *x = self;` (macro = `__unsafe_unretained`, i.e. non-zeroing weak) |
| `@property (nonatomic, weak)` | 2 | `@property (nonatomic, assign)` (delegate + transient bar button — both non-owning) |

`AD_WEAK` is defined in `AppDropCompat.h`. Non-zeroing weak matches what the old
ARC `objc_storeWeak` shim did anyway (a plain assignment), so behavior is
unchanged — it's just explicit now and compiles natively.

Everything else below is SDK/runtime backfill, unrelated to ARC vs MRC:

| Problem | Files affected | Fix |
|---|---|---|
| `dict[key]` / `arr[i]` subscripting | ~12 | declared in `AppDropCompat.h`, IMPs in `IOS5Compat.m` |
| `NS_ENUM` / `NS_OPTIONS` macros (iOS 6 SDK) | many | macro fallback in `AppDropCompat.h` |
| `NSTextAlignment*` / `NSLineBreakBy*` renames (iOS 6) | ~10 | `#define` to the iOS 2-era `UI*` names |
| `UIInterfaceOrientationMask*` (iOS 6) | 3 | enum in `AppDropCompat.h` |
| `shouldAutorotate` / `supportedInterfaceOrientations` (iOS 6) | 1 | category decl in `AppDropCompat.h` (runtime-guarded in code) |
| `UISwitch`/`UIView -tintColor` (iOS 6/7) | 2 | category decls, runtime-guarded with `respondsToSelector:` |
| `UITableViewHeaderFooterView` (iOS 6 class) | 1 | `NSClassFromString` lookup so it never hard-links on armv6 |
| `@YES` / `@NO` boxed literals | a few | `__objc_yes/no` builtins (5.1 SDK breaks these) |
| `NSArray -firstObject` (iOS 4) | several | `+load` IMP in `AppDropRuntime.m` |
| `NSData` base64 (iOS 7) | 1 | `+load` IMP in `AppDropRuntime.m` |
| `NSString sizeWithAttributes:` / `drawAtPoint:withAttributes:` (iOS 7) | few | bridged to iOS-2 `UIStringDrawing` |
| `UIImage +imageWithData:scale:` (iOS 6) | 1 | `+load` IMP |
| `NSUUID` (iOS 6 class) | 1 | real `@implementation` (CFUUID-backed) |
| `NSJSONSerialization` (iOS 5 class) | 10 | cJSON-backed class in `AppDropJSON.m` |
| `UINavigationItem setRightBarButtonItems:`/`setLeftBarButtonItems:` + getters (iOS 5) | 9 (Search/Catalog/Collection/AppDetail/Root) | `+load` IMP in `AppDropRuntime.m`; >1 item hosted in a transparent `UIToolbar` via the singular setter (right side reversed to match iOS 5 ordering). **iOS 3.1.3:** the wrapper toolbar is given a content-tight explicit width (per-item measurement) instead of `-sizeToFit`, which on 3.1.3 snaps to the full 320 pt bar — that was hiding the title + left/back button and shoving the buttons to the left edge |
| `+[UIView animateWithDuration:…]` block animations (iOS 4.0; all 3 variants) | 10 (NumberPickerSheet/Category*/AppTile/AppDetail) | `+load` IMPs on the UIView metaclass in `AppDropRuntime.m`; bridged to the iOS-2 `beginAnimations:`/`commitAnimations` API, completion delivered via `animationDidStop:finished:context:`, curve unpacked from `UIViewAnimationOptions` bits 16-17 |
| `NSCache` (iOS 4.0 class; weak-imported → `nil` on iOS 3.1.3, so the icon RAM cache was dead) | 1 (`IconLoader`) | `ADCache` in `AppDropCache.m` — a `NSMutableDictionary` + `@synchronized` work-alike with LRU eviction honouring `countLimit` + `totalCostLimit`; `NSCache` token macro-rewritten to `ADCache` (same strategy as `ADBezierPath`) |
| ImageIO thumbnail decode (`CGImageSourceCreateWithData` / `…CreateThumbnailAtIndex`, iOS 4.0; weak-imported) | 1 (`IconLoader`) | every weak symbol guarded with `&sym != NULL`; on iOS 3.1.3 (keys/funcs `NULL`) it falls back to a full `+[UIImage imageWithData:]` decode + downscale, so icons actually appear instead of every decode returning `nil` |
| `+[UIView animateWithDuration:…]` block animations (iOS 4.0; all 3 variants) | 10 (NumberPickerSheet/Category*/AppTile/AppDetail) | `+load` IMPs on the UIView metaclass in `AppDropRuntime.m`; bridged to the iOS-2 `beginAnimations:`/`commitAnimations` API, completion delivered via `animationDidStop:finished:context:`, curve unpacked from `UIViewAnimationOptions` bits 16-17 |
| Blocks runtime (`_Block_copy`, `__NSConcreteStackBlock`, …) | 52 blocks | static `shim/blocks/` (Apple libclosure, public domain) |
| GCD (`dispatch_async`, `dispatch_once`, …) | 56 sites | static pthread-backed `shim/gcd_shim.c` |
| mbedTLS prebuilt was armv7-only | link | rebuilt for armv6 from source (v3.6.2) |
| mbedTLS `clock_gettime`/`CLOCK_MONOTONIC` absent on iOS 3 | link | `shim/mbed_platform_compat.c` (gettimeofday-based) |
| Memory management (`objc_retain`, `objc_storeStrong`, …) | all | **none — MRC emits native `retain`/`release` message sends** |

This is verified end-to-end on Linux: all 42 sources compile under
`-fno-objc-arc`, the app links to a real `armv6` Mach-O with `NOUNDEFS`, and a
guard asserts that **zero** ARC C-functions and **zero** unresolved blocks/GCD
imports remain.

## Layout

```
ios3/
├── build-ios3.sh          # one-command Linux cross-compile -> .ipa + .deb
├── compat/
│   ├── AppDropCompat.h     # prefix header: macros/decls + AD_WEAK so sources parse
│   ├── AppDropRuntime.m     # +load backfills (firstObject, base64, NSUUID, …)
│   ├── AppDropJSON.m        # NSJSONSerialization via cJSON
│   ├── cJSON.[ch]           # public-domain JSON (v1.7.18)
│   ├── AppDropBezier.m      # self-contained ADBezierPath (UIBezierPath is iOS 3.2+)
│   ├── AppDropGestures.m    # self-contained AD*GestureRecognizer + dispatch engine (gestures are iOS 3.2+)
│   └── shim/
│       ├── blocks/          # blocks runtime (libclosure)
│       ├── gcd_shim.c        # GCD on pthreads
│       ├── gcd_mainq.c       # _dispatch_main_q storage
│       └── mbed_platform_compat.c
└── README.md
```

> Note: there is no `arc_shim.m` — the ARC runtime shim was removed when the app
> was converted to MRC. Only the blocks and GCD shims remain, because iOS 3
> lacks those runtimes regardless of ARC/MRC.

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

- ✅ Converted to **MRC** (42/42 compile under `-fno-objc-arc`), links
  (`NOUNDEFS`), self-contained blocks/GCD, native `retain`/`release`, no
  `libarclite`.
- ✅ Packages `.ipa` + Cydia `.deb`, localizations converted to JSON.
- ✅ **Info.plist lowered for iOS 3.** `MinimumOSVersion` is now `3.0` (was
  `5.0`) and the `UIRequiredDeviceCapabilities` `armv7` entry was removed, so an
  armv6 / iOS 3 device no longer rejects the bundle at install time.
- ✅ **GCD serial queues are real now.** `dispatch_queue_create` returns a true
  FIFO serial queue (single worker thread draining an in-order list); only the
  global queue and `DISPATCH_QUEUE_CONCURRENT` stay concurrent. This is what
  `LocalCatalog`'s `_searchQueue` needs — every SQLite query runs in order on
  one `sqlite3*` handle, so there is no race on the shared db handle. The main
  queue already hops onto the main `CFRunLoop` (`CFRunLoopPerformBlock` +
  `CFRunLoopWakeUp`), so UIKit work from `dispatch_get_main_queue` stays on the
  main thread.
- ✅ **Launch crash fixed (`Symbol not found: _imp_implementationWithBlock`).**
  `AppDropRuntime.m` used to install its backfilled IMPs via
  `imp_implementationWithBlock()`, which only exists in iOS 4.3+ `libobjc`; on
  iOS 3.1.3 dyld aborted the process at launch. Every IMP is now a plain static
  C function `(id self, SEL _cmd, …)` passed straight to `class_addMethod()`
  with the same type encodings — no block trampoline, no missing runtime
  symbol. `build-ios3.sh`'s leaked-symbol guard now also fails the build if
  `imp_implementationWithBlock` / `imp_removeBlock` ever reappear.
- ✅ **Binary + `.app` are named `AppDrop`.** `APP_NAME="AppDrop"` in
  `build-ios3.sh`, matching `CFBundleExecutable=AppDrop` in `Info.plist`, so
  SpringBoard finds the executable inside `AppDrop.app` (an earlier mismatch —
  exec `IPAInstaller` vs plist `AppDrop` — caused a "does not have an executable
  path" launch rejection). The source folder stays `IPAInstaller/`.
- ✅ **Launch crash fixed (`-[UILongPressGestureRecognizer setMinimumPressDuration:]:
  unrecognized selector`).** The entire `UIGestureRecognizer` family —
  `UITap`/`UILongPress`/`UIPanGestureRecognizer`, their property setters, and
  `-[UIView addGestureRecognizer:]` — is **iOS 3.2+**. On 3.1.3 the class symbols
  exist enough to `alloc`/`init` (so the object is live), but the methods are dead
  stubs, so the first setter call (`setMinimumPressDuration:` in
  `CategoryViewController`) threw `NSInvalidArgumentException` → `SIGABRT` right
  after `makeKeyAndVisible`. Fixed the same way as `UIBezierPath`: a
  self-contained backport in `compat/AppDropGestures.m` — real
  `AD{,Tap,LongPress,Pan}GestureRecognizer` classes plus a tiny dispatch engine
  (a `UIWindow -sendEvent:` swizzle that walks the hit-view superview chain and
  feeds touches to the attached recognizers) — macro-rewritten over the UIKit
  class names in `AppDropCompat.h`. This both removes the crash **and** keeps the
  app usable: every tile tap, banner tap, edit-mode long-press and resize-pan
  rides on these recognizers, so a bare guard would have stopped the crash but
  frozen the UI. Uses only iOS-2.0-era primitives (`locationInView:`,
  `CACurrentMediaTime`, associated objects — already proven at launch by the
  rootVC backfill).
- ✅ **Launch crash fixed (`dyld: Symbol not found: _CFRunLoopPerformBlock`).**
  The GCD shim's `run_on_main()` (in `compat/shim/gcd_shim.c`) hopped main-queue
  work onto the main run loop via `CFRunLoopPerformBlock`, which **first ships in
  iOS 4.0** (CoreFoundation 550). On 3.1.3 dyld's lazy bind couldn't resolve it
  and aborted with `SIGTRAP` right after `makeKeyAndVisible` (the first
  `dispatch_async(dispatch_get_main_queue(), …)` triggers it). Replaced with a
  one-shot `CFRunLoopTimer` (available since iOS 2.0) fired immediately on the
  main run loop in `kCFRunLoopCommonModes`: the copied block rides in the timer
  context, the callback runs + `Block_release`es it, then invalidates the timer.
  `build-ios3.sh` gained a second symbol guard that fails the build if any
  iOS-4.0+ CoreFoundation symbol (`CFRunLoopPerformBlock`, `CFRunLoopWakeUpV2`,
  …) appears as an undefined import, so this can't silently regress (the older
  guard only catches *unresolved* imports, but CF 4.0 symbols resolve against
  the 5.1 SDK at build time and only fail at runtime on 3.x).
- ✅ **Launch crash fixed (`EXC_BAD_ACCESS` on a GCD worker thread ~2s after
  launch).** The app starts, then `LocalCatalog` kicks catalog-DB work onto its
  serial `_searchQueue` and the global background queue (`dispatch_async`).
  Those queues are backed by the `gcd_shim.c` pthread workers, which ran the
  Objective-C blocks **with no `NSAutoreleasePool` on the thread**. On iOS 3
  under MRC there is no implicit per-thread pool (only the main thread's
  `CFRunLoop` provides one), so every autoreleased Foundation object (NSURL,
  NSData, NSString, file ops, JSON, SQLite row wrappers) leaked — the device
  log fills with `*** _NSAutoreleaseNoPool(): … just leaking` — and once enough
  piled up the runtime faulted in `objc_msgSend` (`EXC_BAD_ACCESS at 0xe`,
  crashed Thread 3). Fixed by wrapping **every** block executed on a
  shim-spawned thread in its own `NSAutoreleasePool` (`ad_invoke()` in
  `gcd_shim.c`: the detached trampoline, the serial worker, `dispatch_after`,
  and group async/notify threads, plus their inline fallbacks). The pool is
  driven through the objc runtime C API since the shim is C; `NSAutoreleasePool`
  is iOS 2.0 and always present.
- ✅ **Launch crash fixed (`EXC_BAD_ACCESS` in `objc_msgSend` on the main
  thread / Thread 0, fault address `0xb`).** The static blocks runtime
  (`compat/shim/blocks/runtime.c`) shipped its default object-retain/-release
  callouts (`_Block_retain_object_default` / `_Block_release_object_default`) as
  **no-ops**. On a stock iOS, libSystem's objc runtime calls `_Block_use_RR(objc_retain,
  objc_release)` during startup to wire those callouts to real retain/release,
  but this self-contained shim is **never handed those callbacks** (nothing calls
  `_Block_use_RR`). The result: `Block_copy` ran `_Block_object_assign` →
  `_Block_retain_object()` → *nothing*, so an Objective-C object captured by a
  block was **not retained on copy**. The capturing autorelease scope then drained
  and freed it, and by the time the copied block ran — e.g. a
  `dispatch_async(dispatch_get_main_queue(), ^{ … })` body fired off the main
  `CFRunLoopTimer` hop — it messaged a dangling pointer, faulting in `objc_msgSend`
  on Thread 0 (matching the crash: main thread, `libobjc` top frame, stack through
  `CoreFoundation` run loop → AppDrop → the GCD main-queue shim). Fixed by making
  the two default callouts actually send `-retain` / `-release` via the objc C API
  (`objc_msgSend` + `sel_registerName`, both iOS 2.0), exactly as the real
  `_Block_use_RR` would. This is the block-capture analogue of the worker-thread
  pool fix above and uses the same primitives already proven at launch.
- ✅ **Launch crash fixed for real (`EXC_BAD_ACCESS` in `objc_msgSend` on the
  main thread / Thread 0, fault address `0x12`, ~0.6 s after `makeKeyAndVisible`).**
  The retain fix above was necessary but not the trigger; the actual fault was a
  **double-release of the deferred block** in `dispatch_after`'s main-queue path
  (`compat/shim/gcd_shim.c`). The old code wrapped the user block `mb` in a
  trampoline `^{ run_on_main(Block_copy(mb)); Block_release(mb); }`. The blocks
  runtime already retains a block captured by another block on `Block_copy` and
  releases it when the wrapper is destroyed (its dispose helper), so the extra
  manual `Block_release(mb)` over-released `mb`: it was freed early, which in turn
  disposed *its* captured objects (the `AppDelegate` `self`, the alert strings)
  ahead of time. When the main `CFRunLoopTimer` finally fired ~0.6 s later (the
  deferred "catalog quality" alert), it messaged those dangling objects →
  `objc_msgSend` fault on Thread 0, stack through `CoreFoundation` run loop →
  AppDrop → the GCD shim. This recurred verbatim across rebuilds (only the binary
  addresses shifted) because the retain change didn't touch this path. Fixed by
  dropping the wrapper entirely: `dispatch_after` now stores the single
  `Block_copy`'d block plus an `is_main` flag, and `after_thread` hands that one
  reference to `run_on_main` (which owns and releases it after its one-shot timer
  fires) for the main queue, or runs+releases it inline for other queues — no
  second copy, no manual over-release.
- ⚠️ The GCD shim is a small pthread implementation (serial **and** concurrent
  queues, `dispatch_once`, `after`, groups, semaphores). The serial path is now
  correct, but the whole thing may still need hardening under heavy load.
- ⚠️ The `.deb` `control` still declares `firmware (>= 5.0)` and AppSync
  dependencies that are iOS 5+ names. For an iOS 3 install, lower the
  `firmware` floor and adjust the AppSync/installipa dependency names to the
  3.x-era packages.
