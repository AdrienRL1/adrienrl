#!/bin/sh
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VERSION=""
for CMD in \
    'defaults read /System/Library/CoreServices/SystemVersion ProductVersion' \
    '/usr/libexec/PlistBuddy -c "Print :ProductVersion" /System/Library/CoreServices/SystemVersion.plist' \
    'plutil -p /System/Library/CoreServices/SystemVersion.plist | awk -F" => " "/ProductVersion/ {gsub(/\"/, \"\", $2); print $2; exit}"'
do
    VERSION="$(sh -c "$CMD" 2>/dev/null | head -n 1)"
    [ -n "$VERSION" ] && break
done
MAJOR="${VERSION%%.*}"
case "$MAJOR" in
    ''|*[!0-9]*) MAJOR=5 ;;
esac
if [ "$MAJOR" -le 4 ] && [ -x "$DIR/AppDrop.armv6" ]; then
    exec "$DIR/AppDrop.armv6" "$@"
fi
if [ -x "$DIR/AppDrop.armv7" ]; then
    exec "$DIR/AppDrop.armv7" "$@"
fi
if [ -x "$DIR/AppDrop.armv6" ]; then
    exec "$DIR/AppDrop.armv6" "$@"
fi
exit 1
