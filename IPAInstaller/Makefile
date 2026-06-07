TARGET = iphone:clang:7.0:5.0
ARCHS = armv7
INSTALL_TARGET_PROCESSES = AppDrop

MBEDTLS_DIR = $(PWD)/../deps/mbedtls
MBEDTLS_LIB = $(PWD)/../deps/build

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = AppDrop

AppDrop_FILES = main.m AppDelegate.m RootViewController.m InstallManager.m CatalogViewController.m CatalogFilter.m FilterViewController.m AppDetailViewController.m IconLoader.m JobCell.m AppTileView.m AppRowCell.m VersionsViewController.m IOS6Theme.m SettingsViewController.m HTTPSClient.m LocalCatalog.m Localization.m CatalogAppCell.m SearchViewController.m CategoryViewController.m CategoryTileView.m FeedbackViewController.m MachOInspector.m ParallelDownloader.m UpdateChecker.m UpdateNotesViewController.m DeviceInfo.m IOS5Compat.m CheckpointLog.m RevivalCatalog.m RevivalListViewController.m ThemePickerViewController.m CollectionStore.m CollectionViewController.m HomeLayoutStore.m FolderPicker.m ModdedCatalog.m FilePickerViewController.m UploadViewController.m ADNumberPickerSheet.m CategorySuggestViewController.m IPAPackage.m CrashReporter.m
AppDrop_FRAMEWORKS = UIKit CoreGraphics Foundation QuartzCore ImageIO CFNetwork
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
