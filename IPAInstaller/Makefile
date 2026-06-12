TARGET = iphone:clang:7.0:5.0
ARCHS = armv7
INSTALL_TARGET_PROCESSES = AppDrop

MBEDTLS_DIR = $(PWD)/../deps/mbedtls
MBEDTLS_LIB = $(PWD)/../deps/build
# iOS 5 support (CFSHIM note): on iOS 5.x the Obj-C root class symbols
# (_OBJC_CLASS_$_NSObject / _OBJC_METACLASS_$_NSObject) are exported by CoreFoundation, NOT
# libobjc — they only moved into libobjc with the iOS 7 SDK's unified runtime. Building against
# the 10.3 SDK makes ld attribute them to libobjc → dyld "Symbol not found … Expected in
# libobjc" → instant launch crash on iOS 5.1.1 (every build since the toolchain moved to the
# 10.3 SDK). ld can't be steered here (it coalesces any CoreFoundation-install-name stub with
# the real CF and uses the real export list), so the fix is a deterministic POST-LINK patch in
# build.sh (tools/ios5_rebind.py) that rewrites those two symbols' bind ordinal from libobjc to
# CoreFoundation — exactly the layout the old SDK-5.0 build produced. The 3 genuine libobjc
# runtime symbols (objc_personality, OBJC_EHTYPE_id, objc_empty_cache) stay on libobjc. No API
# loss: still compiled against the full 10.3 SDK; verified working on iOS 5.1.1 and 6-10.

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = AppDrop

AppDrop_FILES = main.m AppDelegate.m RootViewController.m InstallManager.m CatalogViewController.m CatalogFilter.m FilterViewController.m AppDetailViewController.m IconLoader.m JobCell.m AppTileView.m AppRowCell.m VersionsViewController.m IOS6Theme.m SettingsViewController.m HTTPSClient.m LocalCatalog.m Localization.m CatalogAppCell.m SearchViewController.m CategoryViewController.m CategoryTileView.m FeedbackViewController.m MachOInspector.m ParallelDownloader.m UpdateChecker.m UpdateNotesViewController.m DeviceInfo.m IOS5Compat.m CheckpointLog.m RevivalCatalog.m RevivalListViewController.m ThemePickerViewController.m CollectionStore.m CollectionViewController.m HomeLayoutStore.m FolderPicker.m ModdedCatalog.m FilePickerViewController.m UploadViewController.m ADNumberPickerSheet.m CategorySuggestViewController.m IPAPackage.m CrashReporter.m StatsClient.m
# CoreFoundation is listed explicitly so it always has a stable LC_LOAD_DYLIB ordinal — the
# post-link iOS-5 fix (build.sh) rebinds NSObject's class/metaclass symbols to it. See CFSHIM note above.
AppDrop_FRAMEWORKS = UIKit CoreGraphics Foundation CoreFoundation QuartzCore ImageIO CFNetwork
# Perf build (test): -fvisibility=hidden shrinks the dynamic symbol table (faster
# dyld link at launch; Obj-C metadata is unaffected so reflection/+load still work);
# -Wl,-dead_strip drops unreachable code/data (smaller binary -> fewer NAND pages to
# fault in on a cold start). AppDrop_STRIP_FLAGS=-x -S strips locals + residual debug
# symbols while KEEPING global symbols so the on-device crash reporter still resolves
# backtraces. -Os is already applied by Theos for FINALPACKAGE builds.
AppDrop_CFLAGS = -fobjc-arc -Wall -fvisibility=hidden -fvisibility-inlines-hidden -I$(MBEDTLS_DIR)/include
AppDrop_LDFLAGS = -L$(MBEDTLS_LIB) -lmbedtls -lmbedx509 -lmbedcrypto -lsqlite3 -lz -Wl,-dead_strip
AppDrop_STRIP_FLAGS = -x -S
AppDrop_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

# Inject Cydia maintainer scripts (postinst/postrm) into the .deb so that
# SpringBoard re-registers /Applications/AppDrop.app after install
# (otherwise the icon appears square with no iOS 6 gloss).
after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/DEBIAN
	cp -f Layout/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/postinst
	cp -f Layout/DEBIAN/postrm   $(THEOS_STAGING_DIR)/DEBIAN/postrm
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/postrm
	@echo "Generating Localizable.json per language (Theos compiles .strings to binary plist, which iOS 6 mis-parses for some Unicode e.g. Turkish; JSON + NSJSONSerialization is bulletproof)…"
	@for d in $(THEOS_STAGING_DIR)/Applications/AppDrop.app/*.lproj; do \
		lang=`basename "$$d" .lproj`; \
		src="Resources/$$lang.lproj/Localizable.strings"; \
		if [ -f "$$src" ]; then plutil -convert json -o "$$d/Localizable.json" "$$src" && echo "  $$lang ok" || echo "  $$lang FAILED"; fi; \
	done
	@echo "iOS 5 fix: rebinding NSObject (libobjc -> CoreFoundation) so the app launches on iOS 5.x, then re-signing…"
	@python3 "$(PWD)/../tools/ios5_rebind.py" "$(THEOS_STAGING_DIR)/Applications/AppDrop.app/AppDrop"
	@"$(THEOS)/toolchain/linux/iphone/bin/ldid" -Sentitlements.plist "$(THEOS_STAGING_DIR)/Applications/AppDrop.app/AppDrop" && echo "  re-signed ok"
