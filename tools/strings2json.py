#!/usr/bin/env python3
# strings2json.py — Linux replacement for `plutil -convert json` on .strings files.
# Used by IPAInstaller/Makefile (after-stage) when the macOS/`build-toolchain/bin`
# plutil shim is unavailable (e.g. on a fresh CI runner). Same conversion the
# ios3 build (build-ios3.sh) performs inline.
#
# Usage: strings2json.py <Localizable.strings> <Localizable.json>
import sys, re, json

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, "rb").read()
for enc in ("utf-8", "utf-16"):
    try:
        text = raw.decode(enc)
        break
    except UnicodeDecodeError:
        continue
else:
    sys.exit("cannot decode %s" % src)

text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
text = re.sub(r"//[^\n]*", "", text)
pat = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)

def unesc(s):
    return s.encode().decode("unicode_escape") if "\\" in s else s

d = {}
for k, v in pat.findall(text):
    d[unesc(k)] = unesc(v)
json.dump(d, open(dst, "w", encoding="utf-8"), ensure_ascii=False)
print("  %d strings" % len(d))
