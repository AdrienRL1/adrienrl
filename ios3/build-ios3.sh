#!/bin/sh
# build-ios3.sh — Cross-compile AppDrop for armv6 / iOS 3.1 on Linux.
#
# AppDrop is written in ARC against the iOS 7 SDK + Theos. iOS 3/4 devices have
# neither ARC, blocks, nor GCD in their system libraries, and the iOS 5.1 SDK
# (the last SDK with armv6 library slices) predates many APIs the app uses.
#
# This script makes the *unmodified ARC source* run on iOS 3 by:
#   1. Compiling against the iOS 5.1 SDK (armv6 slices) with a compat prefix
#      header (AppDropCompat.h) that backfills missing iOS 6/7 SDK declarations.
#   2. Statically linking tiny runtime shims so the binary carries its own
#      ARC runtime, blocks runtime and libdispatch (GCD) — none of which exist
#      on an iOS 3 device. They are no-ops / native pass-throughs on iOS 5+.
#   3. Backfilling NSJSONSerialization (cJSON), NSUUID, NSData base64, and
#      NSString drawing/sizing at runtime (AppDropRuntime.m / AppDropJSON.m).
#   4. Building mbedTLS for armv6.
#
# Produces: build/AppDrop.ipa  (and a Cydia .deb if dpkg-deb is available)
#
# Env knobs (all optional):
#   DEPLOY_TARGET  - min iOS version (default 3.1)
#   CLANG / AR / RANLIB / LLVM_CONFIG - toolchain binaries
#   SDK_URL        - override iOS 5.1 SDK source
set -e

scriptroot="$(cd "$(dirname "$0")" && pwd)"
cd "$scriptroot"

APP_NAME="AppDrop"          # binary + .app name (user-facing brand)
ARCH="armv6"
DEPLOY_TARGET="${DEPLOY_TARGET:-3.1}"
TRIPLE="${ARCH}-apple-ios${DEPLOY_TARGET}"

SRC="$scriptroot/../IPAInstaller"          # AppDrop ObjC sources
COMPAT="$scriptroot/compat"             # this backport's compat layer
work="$scriptroot/build/work"
sdk="$work/sdks/iPhoneOS5.1.sdk"
out="$scriptroot/build"
obj="$out/obj"
mkdir -p "$work/sdks" "$out" "$obj"

CLANG="${CLANG:-clang}"
AR="${AR:-llvm-ar}"
RANLIB="${RANLIB:-llvm-ranlib}"
LLVM_CONFIG="${LLVM_CONFIG:-llvm-config}"

# ---------------------------------------------------------------------------
# 1. iOS 5.1 SDK (last SDK with armv6 library slices)
# ---------------------------------------------------------------------------
if [ ! -d "$sdk" ]; then
    printf '\n==> Fetching iOS 5.1 SDK...\n'
    rm -rf "$work/sdks/_dl"; mkdir -p "$work/sdks/_dl"; cd "$work/sdks/_dl"
    git init -q
    git remote add origin "${SDK_URL:-https://github.com/EachAndOther/Legacy-iOS-SDKs.git}"
    git config core.sparseCheckout true
    echo "iPhoneOS5.1.sdk/*" > .git/info/sparse-checkout
    git pull -q --depth 1 origin master
    mv iPhoneOS5.1.sdk "$sdk"
    cd "$scriptroot"; rm -rf "$work/sdks/_dl"
fi
file "$sdk/usr/lib/libobjc.A.dylib" | grep -q armv6 || { echo "ERROR: SDK has no armv6 slice" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. cctools-port (ld64, lipo, strip) + ldid  (cached)
# ---------------------------------------------------------------------------
tcbin="$work/toolchain/bin"; export PATH="$tcbin:$PATH"; mkdir -p "$tcbin"
if [ ! -x "$tcbin/ld64.ld64" ] || [ ! -x "$tcbin/lipo" ]; then
    printf '\n==> Building cctools-port (ld64, lipo, strip)...\n'
    ncpus="$(nproc 2>/dev/null || echo 2)"
    c=fee8115127bb849d7481ea0015f181d3ebbd33cf
    cd "$work"; rm -rf "cctools-port-$c"
    wget -qO- "https://github.com/Un1q32/cctools-port/archive/$c.tar.gz" | tar -xz
    cd "cctools-port-$c/cctools"
    ./configure --enable-silent-rules --with-llvm-config="$LLVM_CONFIG" CC="$CLANG" CXX="${CLANG}++"
    make -C libstuff -j"$ncpus"; make -C libmacho -j"$ncpus"
    make -C ld64 -j"$ncpus"; make -C misc strip lipo -j"$ncpus"
    cp ld64/src/ld/ld "$tcbin/ld64.ld64"; cp misc/lipo "$tcbin/lipo"; cp misc/strip "$tcbin/cctools-strip"
    cd "$scriptroot"
fi
if ! command -v ldid >/dev/null && [ ! -x "$tcbin/ldid" ]; then
    printf '\n==> Building ldid...\n'
    c=ef330422ef001ef2aa5792f4c6970d69f3c1f478
    cd "$work"; rm -rf "ldid-$c"
    wget -qO- "https://github.com/ProcursusTeam/ldid/archive/$c.tar.gz" | tar -xz
    cd "ldid-$c"; make CXX="${CLANG}++" LDFLAGS="-lplist-2.0"; cp ldid "$tcbin/ldid"; cd "$scriptroot"
fi
LDID="$(command -v ldid || echo "$tcbin/ldid")"

# ---------------------------------------------------------------------------
# 3. mbedTLS for armv6
# ---------------------------------------------------------------------------
mbeddir="$work/mbedtls-src"
mbedlib="$work/libmbedtls_all.a"
if [ ! -f "$mbedlib" ]; then
    printf '\n==> Building mbedTLS (armv6)...\n'
    [ -d "$mbeddir" ] || git clone --depth 1 --branch v3.6.2 https://github.com/Mbed-TLS/mbedtls.git "$mbeddir"
    MF="-target $TRIPLE -arch $ARCH -isysroot $sdk -miphoneos-version-min=$DEPLOY_TARGET -Os \
        -fno-modules -Wno-everything -I$mbeddir/include -I$mbeddir/library \
        -DMBEDTLS_HAVE_TIME -DMBEDTLS_HAVE_TIME_DATE"
    mo="$work/mbedobj"; rm -rf "$mo"; mkdir -p "$mo"
    for s in "$mbeddir"/library/*.c; do
        b="$(basename "$s" .c)"
        # platform_util.c uses clock_gettime/CLOCK_MONOTONIC (absent on iOS 3) —
        # replaced by compat/mbed_platform_compat.c below.
        [ "$b" = "platform_util.c" ] && continue
        [ "$b" = "platform_util" ] && continue
        "$CLANG" $MF -c "$s" -o "$mo/$b.o" 2>/dev/null || true
    done
    "$CLANG" $MF -c "$COMPAT/mbed_platform_compat.c" -o "$mo/_platform_compat.o"
    "$AR" rcs "$mbedlib" "$mo"/*.o; "$RANLIB" "$mbedlib"
fi

# ---------------------------------------------------------------------------
# 4. Compile AppDrop (MRC) + compat layer (MRC) + blocks/GCD runtime shims
# ---------------------------------------------------------------------------
printf '\n==> Compiling AppDrop for %s...\n' "$TRIPLE"
rm -f "$obj"/*.o

# AppDrop sources, compiled under Manual Reference Counting (-fno-objc-arc).
# iOS 3/4's libobjc has no ARC runtime (objc_retain/release/storeStrong, zeroing
# __weak), so the app was historically compiled ARC + a fake ARC runtime shim.
# Under MRC, clang emits ordinary -retain/-release/-autorelease *message sends*
# that the iOS 3 runtime implements natively — no ARC shim, no libarclite. Every
# .m EXCEPT the iOS-5 subscript shim (superseded by AppDropRuntime.m).
MRCAPP="-target $TRIPLE -isysroot $sdk -fno-objc-arc -fobjc-abi-version=2 \
     -include $COMPAT/AppDropCompat.h -I$mbeddir/include \
     -Wno-deprecated-declarations -Wno-unused-command-line-argument -Os"
for s in "$SRC"/*.m; do
    b="$(basename "$s" .m)"
    [ "$b" = "IOS5Compat" ] && continue   # replaced by AppDropRuntime.m
    "$CLANG" $MRCAPP -c "$s" -o "$obj/app_$b.o"
done

# MRC compat (runtime plumbing must not be ARC-managed)
MRC="-target $TRIPLE -isysroot $sdk -fno-objc-arc -fobjc-abi-version=2 -Wno-everything -Os"
"$CLANG" $MRC -include "$COMPAT/AppDropCompat.h" -c "$COMPAT/AppDropRuntime.m" -o "$obj/compat_runtime.o"
"$CLANG" $MRC -include "$COMPAT/AppDropCompat.h" -I"$COMPAT" -c "$COMPAT/AppDropJSON.m" -o "$obj/compat_json.o"
"$CLANG" $MRC -include "$COMPAT/AppDropCompat.h" -c "$COMPAT/AppDropBezier.m" -o "$obj/compat_bezier.o"
"$CLANG" $MRC -include "$COMPAT/AppDropCompat.h" -c "$COMPAT/AppDropGestures.m" -o "$obj/compat_gestures.o"
"$CLANG" $MRC -I"$COMPAT" -c "$COMPAT/cJSON.c" -o "$obj/compat_cjson.o"

# Runtime shims: blocks + GCD only. iOS 3 has no blocks runtime and no
# libdispatch regardless of ARC/MRC, so the binary still carries its own.
# (The former arc_shim.m is gone — MRC needs no ARC runtime.)
"$CLANG" $MRC -I"$COMPAT/shim/blocks" -DHAVE_OBJC=1 \
    -DHAVE_SYNC_BOOL_COMPARE_AND_SWAP_INT=1 -DHAVE_SYNC_BOOL_COMPARE_AND_SWAP_LONG=1 \
    -c "$COMPAT/shim/blocks/runtime.c" -o "$obj/shim_blocks_rt.o"
"$CLANG" $MRC -I"$COMPAT/shim/blocks" -c "$COMPAT/shim/blocks/data.c" -o "$obj/shim_blocks_data.o"
"$CLANG" $MRC -c "$COMPAT/shim/gcd_shim.c" -o "$obj/shim_gcd.o"
"$CLANG" $MRC -c "$COMPAT/shim/gcd_mainq.c" -o "$obj/shim_gcd_mainq.o"

# ---------------------------------------------------------------------------
# 5. Link
# ---------------------------------------------------------------------------
printf '\n==> Linking...\n'
# MRC: no -fobjc-arc, no libarclite. The objc runtime calls are plain message
# sends resolved by libobjc on the device.
"$CLANG" -target "$TRIPLE" -isysroot "$sdk" \
    -fuse-ld=ld64 -mlinker-version=762 \
    -framework UIKit -framework Foundation -framework CoreGraphics \
    -framework QuartzCore -framework ImageIO -framework CFNetwork -framework SystemConfiguration \
    -lsqlite3 -lz \
    "$obj"/*.o "$mbedlib" \
    -o "$out/$APP_NAME" 2> "$work/link.err" || { cat "$work/link.err" >&2; exit 1; }
file "$out/$APP_NAME"

# Fail loudly if any ARC/blocks/GCD symbol leaked in as an unresolved import
# (would crash on a real iOS 3 device). ARC C-functions must NOT appear at all
# now that the app is MRC — if they do, something is still compiled ARC.
leaked="$(llvm-nm -mu "$out/$APP_NAME" 2>/dev/null | grep -iE '(_objc_(retain|release|storeStrong|storeWeak|loadWeak|autorelease)|dispatch_async|dispatch_once|Block_copy|retainBlock|imp_implementationWithBlock|imp_removeBlock)' || true)"
if [ -n "$leaked" ]; then
    echo "ERROR: unresolved ARC/blocks/GCD/objc-runtime imports remain (would crash on real iOS 3):" >&2; echo "$leaked" >&2; exit 1
fi
echo "OK: blocks/GCD resolved internally, MRC retain/release native — binary is iOS 3 self-contained."

# Second guard: symbols that DO resolve against the 5.1 SDK at build time but do
# NOT exist on iOS 3.1.3 CoreFoundation (149/4xx), so dyld aborts at launch with
# "Symbol not found". CFRunLoopPerformBlock is iOS 4.0. Keep this list growing as
# we discover more 4.0+ APIs that slip through.
toonew="$(llvm-nm -u "$out/$APP_NAME" 2>/dev/null | grep -oE '_(CFRunLoopPerformBlock)' | sort -u || true)"
if [ -n "$toonew" ]; then
    echo "ERROR: iOS 4.0+ symbols present as imports (resolve vs 5.1 SDK but missing on iOS 3.1.3 — dyld will abort at launch):" >&2; echo "$toonew" >&2; exit 1
fi
echo "OK: no known iOS 4.0+ CoreFoundation symbols imported."

# ---------------------------------------------------------------------------
# 6. Bundle .app, fake-sign, package .ipa  (+ Cydia .deb when possible)
# ---------------------------------------------------------------------------
printf '\n==> Packaging...\n'
app="$out/Payload/$APP_NAME.app"
rm -rf "$out/Payload"; mkdir -p "$app"
cp "$out/$APP_NAME" "$app/$APP_NAME"
cp "$SRC/Info.plist" "$app/Info.plist" 2>/dev/null || true
# bundle resources (icons, launch images, localizations)
[ -d "$SRC/Resources" ] && cp -R "$SRC/Resources/"* "$app/" 2>/dev/null || true
# compile each .lproj/Localizable.strings -> Localizable.json (iOS-6 binary-plist
# bug workaround the project relies on). The project's Localization.m prefers
# Localizable.json (parsed via NSJSONSerialization, which our shim backfills on
# iOS 3/4). We convert .strings -> .json with python3 (plutil is macOS-only;
# plistutil cannot parse .strings).
for d in "$app"/*.lproj; do
    [ -d "$d" ] || continue
    lang="$(basename "$d" .lproj)"
    src="$SRC/Resources/$lang.lproj/Localizable.strings"
    [ -f "$src" ] || continue
    python3 - "$src" "$d/Localizable.json" <<'PYEOF' || echo "  WARN: $lang localization not converted"
import sys, re, json
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
# strip /* */ and // comments
text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
text = re.sub(r"//[^\n]*", "", text)
pat = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)
def unesc(s):
    return s.encode().decode("unicode_escape") if "\\" in s else s
d = {}
for k, v in pat.findall(text):
    d[unesc(k)] = unesc(v)
json.dump(d, open(dst, "w", encoding="utf-8"), ensure_ascii=False)
print("  %s: %d strings" % (dst.split("/")[-2], len(d)))
PYEOF
done

"$LDID" -S"$SRC/entitlements.plist" "$app/$APP_NAME"

cd "$out"; rm -f "$APP_NAME.ipa"; zip -qr "AppDrop.ipa" Payload; cd "$scriptroot"

# Cydia .deb (Architecture: iphoneos-arm) if dpkg-deb present
if command -v dpkg-deb >/dev/null; then
    deb="$out/deb"; rm -rf "$deb"
    mkdir -p "$deb/Applications" "$deb/DEBIAN"
    cp -R "$app" "$deb/Applications/"
    cp "$SRC/control" "$deb/DEBIAN/control" 2>/dev/null || true
    if [ -d "$SRC/Layout/DEBIAN" ]; then
        cp -f "$SRC/Layout/DEBIAN/postinst" "$deb/DEBIAN/" 2>/dev/null || true
        cp -f "$SRC/Layout/DEBIAN/postrm"   "$deb/DEBIAN/" 2>/dev/null || true
        chmod 0755 "$deb/DEBIAN/postinst" "$deb/DEBIAN/postrm" 2>/dev/null || true
    fi
    dpkg-deb -Zgzip -b "$deb" "$out/AppDrop.deb" >/dev/null 2>&1 && \
        printf 'DEB: %s\n' "$out/AppDrop.deb" || true
fi

printf '\nDone.\n  IPA: %s\n' "$out/AppDrop.ipa"
