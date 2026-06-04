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
- ⚠️ **Not yet run on real hardware / simulator.** Link-clean ≠ bug-free.
  Memory management is now native MRC, but the conversion was mechanical — watch
  for over-/under-release on the `weak`→`assign` delegate (`FilterViewController`)
  and bar-button (`CollectionViewController`) if those ever outlive their owner.
  Test on a 3G/3GS first.
- ⚠️ The GCD shim is a minimal pthread implementation (serial/concurrent queues,
  `dispatch_once`, `after`, groups, semaphores) and may need hardening under
  load.
- ⚠️ The `.deb` `control` still declares `firmware (>= 5.0)` and AppSync
  dependencies that are iOS 5+ names. For an iOS 3 install, lower the
  `firmware` floor and adjust the AppSync/installipa dependency names to the
  3.x-era packages.
- ⚠️ The GCD shim runs `dispatch_get_main_queue` work on a background thread by
  default. UIKit calls must stay on the main thread — if you see UI from a
  block misbehave, route main-queue dispatches through a CFRunLoop source on
  the main thread (noted inline in `gcd_shim.c`).
