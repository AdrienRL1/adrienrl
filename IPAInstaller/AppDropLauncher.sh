#!/bin/sh
# AppDrop launcher: pick the right slice by iOS VERSION only.
#   iOS 3-4  -> AppDrop.armv6
#   iOS 5+   -> AppDrop.armv7
# No external tools (head/awk/defaults/plutil don't exist on stock iOS 3) —
# ProductVersion is parsed from SystemVersion.plist with shell builtins only.
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

SV="/System/Library/CoreServices/SystemVersion.plist"
VERSION=""
found=0
if [ -r "$SV" ]; then
    while IFS= read -r line; do
        if [ "$found" = 1 ]; then
            case "$line" in
                *"<string>"*)
                    VERSION="${line#*<string>}"
                    VERSION="${VERSION%%</string>*}"
                    break
                    ;;
            esac
        fi
        case "$line" in
            *ProductVersion*"<string>"*)
                VERSION="${line#*<string>}"
                VERSION="${VERSION%%</string>*}"
                break
                ;;
            *ProductVersion*) found=1 ;;
        esac
    done < "$SV"
fi

MAJOR="${VERSION%%.*}"
case "$MAJOR" in
    ''|*[!0-9]*) MAJOR=0 ;;
esac

if [ "$MAJOR" -ge 5 ]; then
    [ -x "$DIR/AppDrop.armv7" ] && exec "$DIR/AppDrop.armv7" "$@"
    [ -x "$DIR/AppDrop.armv6" ] && exec "$DIR/AppDrop.armv6" "$@"
    exit 1
fi
# iOS 3-4, or version unknown: armv6 first.
[ -x "$DIR/AppDrop.armv6" ] && exec "$DIR/AppDrop.armv6" "$@"
[ -x "$DIR/AppDrop.armv7" ] && exec "$DIR/AppDrop.armv7" "$@"
exit 1
