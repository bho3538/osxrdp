# osxrdp macOS installer package build
#
# Usage:
#   make              # build binaries + signed installer pkg (build_once.sh + packaging.sh)
#   make build        # build & sign osxup dylib, OSXRDP.app, OSXRDPUninstaller.app
#   make pkg          # stage payload, pkgbuild + productbuild (signed)
#   make notarize     # notarize & staple the built pkg
#   make release      # everything including notarization
#   make identities   # show signing identities detected on this machine
#   make clean
#
# Signing identities are auto-selected from the build machine's keychain.
# Override if needed:
#   make APP_SIGN_ID="Developer ID Application: ..." PKG_SIGN_ID="Developer ID Installer: ..."
#
# Unsigned build (no Developer ID required; apps get ad-hoc signatures,
# pkg is left unsigned and cannot be notarized):
#   make SIGN=0       # or: make unsigned
# Unsigned builds use the Debug configuration: the IPC peer code-signature
# check (xipc_is_client_signed_by) is compiled out under #if DEBUG, and an
# unsigned/ad-hoc build can never pass it (no Team ID), which would make the
# RDP session drop immediately after connecting.

SHELL := /bin/bash

VERSION ?= 2.0.5
PKG_ID  := com.byungho.osxrdp.setup
INSTALL_FOLDER_NAME := osxrdp

APP_NAME       := OSXRDP.app
UNINS_APP_NAME := OSXRDPUninstaller.app

REPO_ROOT   := $(abspath $(CURDIR)/..)
SOURCE_DIR  := $(CURDIR)/source
SCRIPTS_DIR := $(CURDIR)/scripts
BUILD_DIR   := $(CURDIR)/build
PAYLOAD_DIR := $(BUILD_DIR)/payload

DIST_XML       := $(CURDIR)/distribution.xml
DIST_XML_BUILD := $(BUILD_DIR)/distribution.xml
COMPONENT_PKG  := $(BUILD_DIR)/osxrdp_component.pkg

# SIGN=0 builds without a Developer ID (ad-hoc codesign, unsigned pkg)
SIGN ?= 1

# Profile created with `xcrun notarytool store-credentials`
NOTARY_PROFILE ?= AC_PASSWORD

ifeq ($(SIGN),0)
CONFIGURATION := Debug
APP_SIGN_ID := -
PKG_SIGN_ID :=
CODESIGN_FLAGS := --force
PRODUCT_SIGN_FLAGS :=
# Disable Xcode's own signing (project is configured with a signing team);
# we ad-hoc sign the outputs ourselves afterwards.
XCODE_SIGN_FLAGS := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
	CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
OUTPUT_PKG := $(CURDIR)/osxrdp_installer_v$(VERSION)_unsigned.pkg
else
CONFIGURATION := Release
# Auto-select signing certificates from the build machine's keychain
APP_SIGN_ID ?= $(shell security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ {print $$2; exit}')
PKG_SIGN_ID ?= $(shell security find-identity -v | awk -F '"' '/Developer ID Installer/ {print $$2; exit}')
CODESIGN_FLAGS := --force --timestamp --options runtime
PRODUCT_SIGN_FLAGS := --sign "$(PKG_SIGN_ID)"
OUTPUT_PKG := $(CURDIR)/osxrdp_installer_v$(VERSION).pkg
endif

XCODEBUILD := cd $(REPO_ROOT) && xcodebuild build -configuration $(CONFIGURATION) \
	-destination "generic/platform=macOS" ONLY_ACTIVE_ARCH=NO $(XCODE_SIGN_FLAGS)

.PHONY: all unsigned build pkg notarize release osxup app uninstaller stage \
	identities check-app-identity check-pkg-identity clean

all: build pkg

unsigned:
	$(MAKE) SIGN=0 all

release: all notarize

build: osxup app uninstaller

# ==========================================
# Signing identity checks
# ==========================================
check-app-identity:
ifeq ($(SIGN),0)
	@echo "==> unsigned build: ad-hoc codesign, Debug configuration"
else
	@if [ -z "$(APP_SIGN_ID)" ]; then \
		echo "error: no 'Developer ID Application' identity found in keychain."; \
		echo "       (security find-identity -v -p codesigning)"; \
		echo "       For a build without signing, run: make SIGN=0"; \
		exit 1; \
	fi
	@echo "==> codesign identity: $(APP_SIGN_ID)"
endif

check-pkg-identity:
ifeq ($(SIGN),0)
	@echo "==> unsigned build: pkg will not be signed"
else
	@if [ -z "$(PKG_SIGN_ID)" ]; then \
		echo "error: no 'Developer ID Installer' identity found in keychain."; \
		echo "       (security find-identity -v)"; \
		echo "       For a build without signing, run: make SIGN=0"; \
		exit 1; \
	fi
	@echo "==> pkg sign identity: $(PKG_SIGN_ID)"
endif

identities:
ifeq ($(SIGN),0)
	@echo "SIGN=0: unsigned build (ad-hoc codesign, unsigned pkg, Debug configuration)"
else
	@echo "Developer ID Application : $(if $(APP_SIGN_ID),$(APP_SIGN_ID),(not found))"
	@echo "Developer ID Installer   : $(if $(PKG_SIGN_ID),$(PKG_SIGN_ID),(not found))"
endif

# ==========================================
# osxup universal dylib
# ==========================================
osxup: check-app-identity
	$(XCODEBUILD) -scheme osxup ARCHS=arm64  BUILD_DIR=$(BUILD_DIR)/osxup_arm64
	$(XCODEBUILD) -scheme osxup ARCHS=x86_64 BUILD_DIR=$(BUILD_DIR)/osxup_x86_64
	lipo -create \
		$(BUILD_DIR)/osxup_arm64/$(CONFIGURATION)/libosxup.dylib \
		$(BUILD_DIR)/osxup_x86_64/$(CONFIGURATION)/libosxup.dylib \
		-output $(BUILD_DIR)/libosxup.dylib
	codesign $(CODESIGN_FLAGS) --sign "$(APP_SIGN_ID)" $(BUILD_DIR)/libosxup.dylib
	lipo -archs $(BUILD_DIR)/libosxup.dylib
	codesign -dv --verbose=4 $(BUILD_DIR)/libosxup.dylib
	mkdir -p $(SOURCE_DIR)/module
	rm -f $(SOURCE_DIR)/module/libosxup.dylib
	mv $(BUILD_DIR)/libosxup.dylib $(SOURCE_DIR)/module/libosxup.dylib
	rm -rf $(BUILD_DIR)/osxup_arm64 $(BUILD_DIR)/osxup_x86_64

# ==========================================
# OSXRDP main app
# ==========================================
app: check-app-identity
	# The OSXRDP scheme's copy script needs osxrdp_sessionmanager in BUILT_PRODUCTS_DIR,
	# but the scheme has no target dependency guaranteeing build order — build it first.
	$(XCODEBUILD) -scheme "osxrdp_sessionmanager" ARCHS="arm64 x86_64" BUILD_DIR=$(BUILD_DIR)/OSXRDP
	$(XCODEBUILD) -scheme "OSXRDP" ARCHS="arm64 x86_64" BUILD_DIR=$(BUILD_DIR)/OSXRDP
	codesign $(CODESIGN_FLAGS) --deep --sign "$(APP_SIGN_ID)" \
		$(BUILD_DIR)/OSXRDP/$(CONFIGURATION)/$(APP_NAME)
	rm -rf $(SOURCE_DIR)/$(APP_NAME)
	mv $(BUILD_DIR)/OSXRDP/$(CONFIGURATION)/$(APP_NAME) $(SOURCE_DIR)/$(APP_NAME)
	rm -rf $(BUILD_DIR)/OSXRDP

# ==========================================
# OSXRDP uninstaller app
# ==========================================
uninstaller: check-app-identity
	$(XCODEBUILD) -scheme "OSXRDPUninstaller" ARCHS="arm64 x86_64" BUILD_DIR=$(BUILD_DIR)/OSXRDPUninstaller
	codesign $(CODESIGN_FLAGS) --deep --sign "$(APP_SIGN_ID)" \
		$(BUILD_DIR)/OSXRDPUninstaller/$(CONFIGURATION)/$(UNINS_APP_NAME)
	rm -rf $(SOURCE_DIR)/$(UNINS_APP_NAME)
	mv $(BUILD_DIR)/OSXRDPUninstaller/$(CONFIGURATION)/$(UNINS_APP_NAME) $(SOURCE_DIR)/$(UNINS_APP_NAME)
	rm -rf $(BUILD_DIR)/OSXRDPUninstaller

# ==========================================
# Payload staging (apps are assumed to be already signed)
# ==========================================
stage:
	@test -d "$(SOURCE_DIR)/$(APP_NAME)" || { echo "error: $(APP_NAME) not found in source dir. Run 'make build' first."; exit 1; }
	@test -d "$(SOURCE_DIR)/$(UNINS_APP_NAME)" || { echo "error: $(UNINS_APP_NAME) not found in source dir. Run 'make build' first."; exit 1; }
	@test -f "$(SOURCE_DIR)/module/libosxup.dylib" || { echo "error: module/libosxup.dylib not found. Run 'make build' first."; exit 1; }
	rm -rf $(PAYLOAD_DIR)
	mkdir -p $(PAYLOAD_DIR)/Applications/$(INSTALL_FOLDER_NAME)
	mkdir -p $(PAYLOAD_DIR)/Library/LaunchDaemons
	mkdir -p $(PAYLOAD_DIR)/Library/LaunchAgents
	mkdir -p $(PAYLOAD_DIR)/etc/xrdp
	mkdir -p $(PAYLOAD_DIR)/etc/osxrdp
	mkdir -p $(PAYLOAD_DIR)/usr/local/lib/xrdp
	mkdir -p $(PAYLOAD_DIR)/usr/local/share/xrdp
	cp -R "$(SOURCE_DIR)/$(APP_NAME)" $(PAYLOAD_DIR)/Applications/$(INSTALL_FOLDER_NAME)/
	cp -R "$(SOURCE_DIR)/$(UNINS_APP_NAME)" $(PAYLOAD_DIR)/Applications/$(INSTALL_FOLDER_NAME)/
	cp $(SOURCE_DIR)/com.byungho.osxrdp.plist $(PAYLOAD_DIR)/Library/LaunchDaemons/
	cp $(SOURCE_DIR)/com.byungho.osxrdp.sessionmanager.plist $(PAYLOAD_DIR)/Library/LaunchDaemons/
	cp $(SOURCE_DIR)/com.byungho.osxrdp.lockscreen.plist $(PAYLOAD_DIR)/Library/LaunchAgents/
	if [ -d $(SOURCE_DIR)/config ]; then cp -R $(SOURCE_DIR)/config/* $(PAYLOAD_DIR)/etc/xrdp/; fi
	if [ -d $(SOURCE_DIR)/log ]; then cp -R $(SOURCE_DIR)/log/* $(PAYLOAD_DIR)/etc/osxrdp/; fi
	cp $(SOURCE_DIR)/module/libosxup.dylib $(PAYLOAD_DIR)/usr/local/lib/xrdp/
	cp $(SOURCE_DIR)/resources/* $(PAYLOAD_DIR)/usr/local/share/xrdp/
	chmod 755 $(PAYLOAD_DIR)/Applications/$(INSTALL_FOLDER_NAME)
	chmod 755 $(PAYLOAD_DIR)/usr/local/lib/xrdp
	chmod 755 $(PAYLOAD_DIR)/usr/local/share/xrdp
	chmod 755 $(SCRIPTS_DIR)/postinstall

# ==========================================
# Component + product pkg (signed)
# ==========================================
pkg: check-pkg-identity stage
	pkgbuild --root $(PAYLOAD_DIR) \
		--install-location "/" \
		--scripts $(SCRIPTS_DIR) \
		--identifier $(PKG_ID) \
		--version $(VERSION) \
		--ownership recommended \
		$(COMPONENT_PKG)
	sed -E 's/(pkg-ref id="$(PKG_ID)" version=")[0-9.]+(")/\1$(VERSION)\2/' \
		$(DIST_XML) > $(DIST_XML_BUILD)
	productbuild --distribution $(DIST_XML_BUILD) \
		--package-path $(BUILD_DIR) \
		$(PRODUCT_SIGN_FLAGS) \
		$(OUTPUT_PKG)
	@echo "==> Built: $(OUTPUT_PKG)"

# ==========================================
# Notarization & stapling
# ==========================================
notarize:
ifeq ($(SIGN),0)
	@echo "error: an unsigned pkg cannot be notarized."; exit 1
endif
	@test -f "$(OUTPUT_PKG)" || { echo "error: $(OUTPUT_PKG) not found. Run 'make pkg' first."; exit 1; }
	xcrun notarytool submit "$(OUTPUT_PKG)" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	xcrun stapler staple "$(OUTPUT_PKG)"
	@echo "==> Notarized & stapled: $(OUTPUT_PKG)"

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(CURDIR)/osxrdp_installer_v*.pkg
