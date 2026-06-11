#!/bin/bash
# AppDrop — build depuis Linux (Unraid) avec la toolchain Theos embarquee dans build-toolchain/.
#
# Tout l'environnement de compilation vit dans ce dossier projet (build-toolchain/) :
#   - theos/                  Theos + toolchain clang Linux (armv7) + SDK iPhoneOS10.3 (patche)
#   - bin/plutil              remplacant Linux de l'outil macOS plutil (.strings -> Localizable.json)
# Les paquets systeme (apt) requis sont installes par build-toolchain/setup-system-deps.sh.
#
# Usage :
#   ./build.sh                 # = gmake package FINALPACKAGE=1 -j<nproc>  (produit le .deb signe)
#   ./build.sh clean
#   ./build.sh <cibles/vars gmake...>
set -e

# Chemin reel du projet (peut contenir des espaces : "Projet AppDrop")
PROJECT_REAL="$(cd "$(dirname "$0")" && pwd -P)"

# Theos refuse les espaces dans le chemin du projet -> on l'expose via un symlink sans espaces.
LINK="${APPDROP_LINK:-$HOME/appdrop}"
ln -sfn "$PROJECT_REAL" "$LINK"

export THEOS="$LINK/build-toolchain/theos"
export PATH="$LINK/build-toolchain/bin:$PATH"   # shim plutil en priorite

if [ ! -x "$THEOS/toolchain/linux/iphone/bin/clang" ]; then
    echo "ERREUR : toolchain absente ($THEOS/toolchain). Voir build-toolchain/." >&2
    exit 1
fi

# Auto-reparation : les paquets apt vivent dans la couche overlay (ephemere) du conteneur.
# Un redemarrage serveur les conserve ; une RECREATION du conteneur les perd. Si des
# dependances manquent (ex. libtinfo5 dont depend le clang de la toolchain), on relance
# l'installation automatiquement -> le build fonctionne sans intervention apres recreation.
if ! command -v fakeroot >/dev/null 2>&1 \
   || ! command -v rsync   >/dev/null 2>&1 \
   || ! { [ -e /usr/lib/x86_64-linux-gnu/libtinfo.so.5 ] || [ -e /lib/x86_64-linux-gnu/libtinfo.so.5 ]; }; then
    echo "==> Dependances systeme manquantes (conteneur recree ?) — reinstallation automatique..."
    bash "$PROJECT_REAL/build-toolchain/setup-system-deps.sh"
fi

# deps/mbedtls (headers) n'est PAS commite (.gitignore) — seules les libs statiques
# deps/build/*.a (mbedTLS 3.6.0, armv7) le sont. Sur un runner CI fraichement clone,
# on recupere donc les headers de la MEME version pour que HTTPSClient.m compile.
if [ ! -f "$PROJECT_REAL/deps/mbedtls/include/mbedtls/ssl.h" ]; then
    echo "==> Headers mbedTLS absents — clonage de mbedtls v3.6.0 (headers only)..."
    rm -rf "$PROJECT_REAL/deps/mbedtls"
    git clone -q --depth 1 --branch v3.6.0 https://github.com/Mbed-TLS/mbedtls.git "$PROJECT_REAL/deps/mbedtls"
fi

# ---------------------------------------------------------------------------
# Patch du SDK iPhoneOS10.3 (theos/sdks) pour qu'il soit IDENTIQUE au SDK local
# decrit dans BUILD-LINUX.md (points 4 et 5). Le SDK distribue par theos/sdks
# est allege : il lui manque le crt1 armv7 et certains symboles dans les .tbd.
# Sans ce patch, le link armv7 echoue (Undefined symbols : ___udivsi3, ___divdi3,
# __Unwind_SjLj_*, _objc_msgSend_stret, ...). Ces symboles existent reellement sur
# l'appareil (le binaire Mac de reference les lie de la meme facon) : on se contente
# de les declarer dans les .tbd pour que ld64 accepte de les marquer comme imports.
#
# Idempotent : si le SDK est deja patche (cas du build local Unraid ou la toolchain
# persiste), rien n'est refait. C'est donc surtout utile sur un runner CI fraichement
# clone, ou le SDK vient brut de theos/sdks.
patch_legacy_sdk() {
    local sdk_dir="$THEOS/sdks/iPhoneOS10.3.sdk"
    [ -d "$sdk_dir" ] || return 0

    # 4. crt1.3.1.o (armv7/armv7s) — absent du SDK10.3 allege, present dans le SDK9.3.
    #    Sans lui, ld releve la cible a iOS 7.0 (LC_MAIN) et l'app ne demarre pas sur iPad 1.
    #    Avec lui : LC_UNIXTHREAD, min 5.0, comme le binaire Mac.
    if [ ! -f "$sdk_dir/usr/lib/crt1.3.1.o" ]; then
        echo "==> iPhoneOS10.3.sdk : crt1.3.1.o absent — recuperation depuis iPhoneOS9.3.sdk..."
        local tmpdir
        tmpdir="$(mktemp -d)"
        git clone -q --no-checkout --depth 1 --filter=blob:none https://github.com/theos/sdks.git "$tmpdir/sdks"
        (
            cd "$tmpdir/sdks"
            git sparse-checkout set iPhoneOS9.3.sdk/usr/lib/crt1.3.1.o >/dev/null 2>&1 || true
            git checkout -q
        )
        if [ -f "$tmpdir/sdks/iPhoneOS9.3.sdk/usr/lib/crt1.3.1.o" ]; then
            mkdir -p "$sdk_dir/usr/lib"
            cp "$tmpdir/sdks/iPhoneOS9.3.sdk/usr/lib/crt1.3.1.o" "$sdk_dir/usr/lib/crt1.3.1.o"
            echo "    crt1.3.1.o installe."
        else
            echo "    WARN: crt1.3.1.o introuvable dans iPhoneOS9.3.sdk (ld retombera sur iOS 7.0)." >&2
        fi
        rm -rf "$tmpdir"
    fi

    # 5. .tbd completes — ajoute les symboles manquants a la PREMIERE liste 'symbols: [...]'
    #    de chaque .tbd (celle de la tranche armv7). Idempotent : un symbole deja present
    #    n'est pas redouble.
    patch_tbd_symbols() {
        local tbd="$1"
        shift
        [ -f "$tbd" ] || { echo "    WARN: $tbd absent — patch ignore." >&2; return 0; }
        TBD_SYMS="$*" python3 - "$tbd" <<'PYEOF'
import os, re, sys
from pathlib import Path

path = Path(sys.argv[1])
required = os.environ["TBD_SYMS"].split()
text = path.read_text()

# Premiere liste "symbols: [ ... ]" du fichier (tranche armv7). Les noms de symboles
# ne contiennent jamais ']', donc le premier ']' rencontre ferme bien la liste.
m = re.search(r'(symbols:\s*\[)(.*?)(\])', text, re.S)
if not m:
    raise SystemExit(f'Could not find a symbols list in {path}')

block = m.group(2)
existing = [s.strip() for s in re.split(r',\s*', block) if s.strip()]
missing = [s for s in required if s not in existing]
if not missing:
    sys.exit(0)

merged = existing + missing
# Reformatage simple, indentation alignee comme le reste du .tbd (26 espaces).
indent = ' ' * 28
wrapped = (',\n' + indent).join(merged)
replacement = m.group(1) + ' ' + wrapped + ' ' + m.group(3)
path.write_text(text[:m.start()] + replacement + text[m.end():])
print(f'    {path.name}: +{len(missing)} symbole(s) ({", ".join(missing)})')
PYEOF
    }

    patch_tbd_symbols "$sdk_dir/usr/lib/libSystem.tbd" \
        ___udivsi3 ___udivdi3 ___divsi3 ___divdi3 ___umodsi3 ___fixdfdi ___floatdidf \
        __Unwind_SjLj_Register __Unwind_SjLj_Unregister __Unwind_SjLj_Resume
    patch_tbd_symbols "$sdk_dir/usr/lib/libobjc.A.tbd" _objc_msgSend_stret
}

patch_legacy_sdk

# Cible : SDK iPhoneOS10.3 installe (le Makefile demande 7.0, absent ici), deploiement min iOS 5.0.
# GO_EASY_ON_ME=1 : ne pas transformer les warnings en erreurs (-Werror), comme le build macOS.
TARGET_TRIPLE="iphone:clang:10.3:5.0"

cd "$LINK/IPAInstaller"

if [ $# -eq 0 ]; then
    set -- package FINALPACKAGE=1 -j"$(nproc)"
fi

exec gmake "$@" \
    THEOS_PROJECT_DIR="$LINK/IPAInstaller" \
    TARGET="$TARGET_TRIPLE" \
    GO_EASY_ON_ME=1
