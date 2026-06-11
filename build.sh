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
