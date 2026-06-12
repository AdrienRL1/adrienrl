#!/bin/bash
# setup-system-deps.sh — installs the apt packages required by the AppDrop
# Linux build environment (Theos toolchain + packaging).
#
# Safe to re-run: apt-get install is idempotent. Works on Debian/Ubuntu,
# including GitHub Actions ubuntu-24.04 runners (where libtinfo5 is gone
# from the archive — we fall back to a compat symlink onto libtinfo6).
set -e

SUDO=""
if [ "$(id -u)" != "0" ]; then
    SUDO="sudo"
fi

export DEBIAN_FRONTEND=noninteractive

$SUDO apt-get update

$SUDO apt-get install --no-install-recommends -y \
    build-essential clang lld llvm llvm-dev \
    make git wget curl zip unzip rsync fakeroot dpkg perl \
    libplist-dev libplist-utils libssl-dev python3 || true

# Theos prefers gmake; on Debian/Ubuntu plain `make` is GNU make already.
if ! command -v gmake >/dev/null 2>&1; then
    if command -v make >/dev/null 2>&1; then
        $SUDO ln -sf "$(command -v make)" /usr/local/bin/gmake
    fi
fi

# libtinfo5: the prebuilt Theos clang toolchain links against libtinfo.so.5.
# Ubuntu 24.04 / Debian 13 dropped the package, so try apt first and fall
# back to symlinking the ABI-compatible libtinfo.so.6.
has_tinfo5() {
    [ -e /usr/lib/x86_64-linux-gnu/libtinfo.so.5 ] || [ -e /lib/x86_64-linux-gnu/libtinfo.so.5 ]
}
if ! has_tinfo5; then
    $SUDO apt-get install --no-install-recommends -y libtinfo5 2>/dev/null || true
fi
if ! has_tinfo5; then
    for d in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu; do
        if [ -e "$d/libtinfo.so.6" ]; then
            $SUDO ln -sf "$d/libtinfo.so.6" "$d/libtinfo.so.5"
            echo "==> libtinfo5 absent from apt — symlinked $d/libtinfo.so.6 -> libtinfo.so.5"
            break
        fi
    done
fi
if ! has_tinfo5; then
    echo "WARN: libtinfo.so.5 still missing — the Theos toolchain clang may fail to start." >&2
fi

echo "==> System dependencies OK."