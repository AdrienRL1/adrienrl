# Compiler AppDrop sur Linux (Unraid)

Tout l'environnement de compilation est embarque dans **`build-toolchain/`** (dans ce dossier
projet, pour qu'il persiste et reste portable). Le binaire produit est **identique** a celui
qui etait compile sur le Mac : `armv7`, version min **iOS 5.0**, entree `LC_UNIXTHREAD`,
memes dylibs liees (il demarre donc sur iPad 1 / iOS 5.1.1 comme avant).

## Compiler

```bash
./build.sh            # -> packages/ca.adrien.appdrop_<ver>_iphoneos-arm.deb (signe)
./build.sh clean
```

Le `.deb` (et le `.ipa` si besoin) sort dans `IPAInstaller/packages/`.

## Contenu de build-toolchain/

| Element | Role |
|---|---|
| `theos/` | Theos + toolchain clang 11 Linux (cross armv7) + `sdks/iPhoneOS10.3.sdk` |
| `bin/plutil` | Remplacant Linux de l'outil macOS `plutil` (convertit les `.strings` en `Localizable.json`, etape `after-stage` du Makefile) |
| `setup-system-deps.sh` | Installe les paquets `apt` requis (non embarquables) |

## Ce qui a du etre adapte pour Linux (et pourquoi le binaire reste identique)

1. **Chemin avec espaces** — Theos refuse « Projet AppDrop ». `build.sh` cree un symlink
   sans espaces (`~/appdrop`) et compile a travers lui. N'affecte pas le binaire.
2. **SDK** — le Makefile demande le SDK 7.0 (absent ; sur Mac il y avait un fallback
   silencieux). On vise le SDK **iPhoneOS10.3** installe, deploiement **min iOS 5.0** inchange.
3. **`GO_EASY_ON_ME=1`** — Theos active `-Werror` par defaut ; on le desactive comme le
   faisait le build macOS. N'change pas le code genere (que des warnings benins :
   `supportedInterfaceOrientations`, `nonnull`).
4. **`crt1.3.1.o` (armv7/armv7s)** — recupere depuis le SDK iPhoneOS9.3 d'Apple et place dans
   `iPhoneOS10.3.sdk/usr/lib/`. Sans lui, ld releve la cible a iOS 7.0 (`LC_MAIN`) et l'app
   **ne demarrerait pas** sur iPad 1. Avec lui : `LC_UNIXTHREAD`, min 5.0, comme le Mac.
5. **`.tbd` completes** — le SDK theos est allege ; on a rajoute a `libSystem.tbd` les builtins
   armv7 (`___udivsi3`, `___divdi3`, `___fixdfdi`, ... + `__Unwind_SjLj_*`) et a `libobjc.A.tbd`
   le symbole `_objc_msgSend_stret`. Ces symboles existent reellement sur l'appareil (le binaire
   Mac de reference les lie de la meme facon). Resultat : liaison identique, sans dependance
   ajoutee (pas de `libgcc_s`).

## Persistance (redemarrage serveur / recreation du conteneur)

`/home/adrien` et `/mnt/user` sont des montages **fuse.shfs** (array Unraid) -> **persistants**, avec
permissions preservees. Survivent donc tout seuls a un redemarrage ET a une recreation du conteneur :
- cles SSH (`~/.ssh/`) et identite Git (`~/.gitconfig`) ;
- `build-toolchain/` (toolchain + SDK) et tout le code.

Seuls les **paquets apt** vivent dans la couche overlay (ephemere) du conteneur :
- **Redemarrage du serveur** (docker stop/start) : conserves (l'overlay upperdir est preserve).
- **Recreation du conteneur** (maj d'image, modif du template) : perdus -> mais `build.sh` les
  **reinstalle automatiquement** au prochain build (il detecte `fakeroot`/`rsync`/`libtinfo.so.5`
  manquants et lance `setup-system-deps.sh`). Aucune intervention requise.

Pre-requis cote template Docker : garder le mapping de volume qui expose `/home/adrien` (et
`/mnt/user/...`) ; c'est lui qui rend le home persistant. Tant qu'il est present, tout fonctionne
au redemarrage comme a la recreation.

## Recreer l'environnement de zero (si build-toolchain/ est perdu)

`build-toolchain/` n'est PAS dans git (trop gros). Pour le reconstruire :

```bash
./build-toolchain/setup-system-deps.sh        # paquets apt

export THEOS="$PWD/build-toolchain/theos"
git clone --recursive https://github.com/theos/theos.git "$THEOS"
# Toolchain clang Linux (source officielle Theos) :
curl -sL https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-x86_64.tar.xz \
  | tar -xJf - -C "$THEOS/toolchain/"
# SDK iPhoneOS10.3 (avec tranche armv7) :
git clone --no-checkout --depth 1 --filter=blob:none https://github.com/theos/sdks.git /tmp/sdks
( cd /tmp/sdks && git sparse-checkout set iPhoneOS10.3.sdk && git checkout )
mkdir -p "$THEOS/sdks" && mv /tmp/sdks/iPhoneOS10.3.sdk "$THEOS/sdks/"
# crt1 armv7 (depuis le SDK 9.3) + patch des .tbd : voir les points 4 et 5 ci-dessus.
```
