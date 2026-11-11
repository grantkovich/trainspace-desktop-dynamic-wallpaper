# Trainspace — build with the Swift toolchain alone (Xcode not required).
APP_NAME   := Trainspace
BUNDLE_ID  := com.grantkovich.trainspace
VERSION    ?= 1.0.0
BUILD_DIR  := build
APP        := $(BUILD_DIR)/$(APP_NAME).app
CONFIG     ?= release

# Command Line Tools ship Swift Testing outside the default search paths.
DEV_DIR    := $(shell xcode-select -p)
TEST_FW    := $(firstword $(wildcard $(DEV_DIR)/Library/Developer/Frameworks $(DEV_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks))
TEST_LIB   := $(firstword $(wildcard $(DEV_DIR)/Library/Developer/usr/lib $(DEV_DIR)/Platforms/MacOSX.platform/Developer/usr/lib))
TEST_FLAGS := $(if $(TEST_FW),-Xswiftc -F$(TEST_FW) -Xlinker -F$(TEST_FW) -Xlinker -rpath -Xlinker $(TEST_FW)) \
              $(if $(TEST_LIB),-Xlinker -rpath -Xlinker $(TEST_LIB))

# Signing. Everyday builds are ad-hoc ("-"). Releases are signed with the self-signed
# "Grant Kovich Code Signing" certificate in its own keychain (see RELEASING.md): its
# designated requirement stays the same from release to release, so macOS keeps the
# location permission and Keychain access across updates. No paid Apple Developer Program needed.
SIGN_ID    ?= -
SIGN_KEYCHAIN ?=
ENTITLEMENTS := Resources/Trainspace.entitlements
INSTALL_DIR ?= /Applications

# Build number (CFBundleVersion): the commit count, so each release is higher than the last.
BUILD      ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
# Everyday builds target this Mac; `make release` builds Apple Silicon and Intel.
ARCHS      ?= $(shell uname -m)
MIN_OS     := 14.0
triple      = $(1)-apple-macosx$(MIN_OS)
bin_path    = $$(swift build -c $(CONFIG) --triple $(call triple,$(1)) --show-bin-path)
# Releases live on GitHub: each tag v<version> holds the zip, DMG, SHA256SUMS and install.sh.
REPO       := grantkovich/trainspace-desktop-dynamic-wallpaper
DOWNLOAD_URL ?= https://github.com/$(REPO)/releases/download/v$(VERSION)
# Always the newest release's installer.
INSTALLER_URL := https://github.com/$(REPO)/releases/latest/download/install.sh
ZIP        := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).zip
DMG        := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg

.PHONY: build test app run install release publish zip dmg installer clean data snapshots icon

build:
	@for a in $(ARCHS); do swift build -c $(CONFIG) --triple $$a-apple-macosx$(MIN_OS) || exit 1; done

test:
	swift test $(TEST_FLAGS)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	lipo -create $(foreach a,$(ARCHS),"$(call bin_path,$(a))/$(APP_NAME)") -output $(APP)/Contents/MacOS/$(APP_NAME)
	sed -e 's/$$(VERSION)/$(VERSION)/g' -e 's/$$(BUILD)/$(BUILD)/g' -e 's/$$(BUNDLE_ID)/$(BUNDLE_ID)/g' Resources/Info.plist > $(APP)/Contents/Info.plist
	cp Resources/geodata-*.bin Resources/rail-*.bin $(APP)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/ 2>/dev/null || true
	codesign --force --options runtime $(if $(NOTARY_PROFILE),--timestamp,--timestamp=none) \
	  --entitlements $(ENTITLEMENTS) $(if $(SIGN_KEYCHAIN),--keychain "$(SIGN_KEYCHAIN)") --sign "$(SIGN_ID)" $(APP)
	@echo "Built $(APP) ($(VERSION) build $(BUILD), $(ARCHS))"

run: app
	open $(APP)

# Build, then replace the copy in /Applications and relaunch it. Quitting (rather than
# killing) lets Trainspace restore your own system wallpaper before the new copy takes over.
# Quits by name too, so a copy with an older bundle ID also gets the chance to restore it.
install: app
	@if pgrep -x $(APP_NAME) >/dev/null; then \
	  echo "Quitting running $(APP_NAME)…"; \
	  osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true; \
	  osascript -e 'tell application "$(APP_NAME)" to quit' >/dev/null 2>&1 || true; \
	  for i in $$(seq 1 40); do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.25; done; \
	  if pgrep -x $(APP_NAME) >/dev/null; then echo "$(APP_NAME) didn't quit; close it and try again"; exit 1; fi; \
	fi
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	ditto $(APP) "$(INSTALL_DIR)/$(APP_NAME).app"
	codesign --verify --deep --strict "$(INSTALL_DIR)/$(APP_NAME).app"
	open "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed and launched $(INSTALL_DIR)/$(APP_NAME).app"

# Release: a universal app signed with SIGN_ID, as a zip (for install.sh and updates) and a
# DMG, with SHA-256 checksums. Run `make data` first so the timetables are current.
# See RELEASING.md.
#   make release SIGN_ID="Grant Kovich Code Signing" SIGN_KEYCHAIN=~/Library/Keychains/wallpaper-signing.keychain-db
# With a paid Developer ID, add NOTARY_PROFILE (stored with `xcrun notarytool store-credentials`)
# and the DMG is notarized and stapled too.
release:
	@test "$(SIGN_ID)" != "-" || (echo "Set SIGN_ID to the release signing identity (see RELEASING.md)"; exit 1)
	$(MAKE) app ARCHS="arm64 x86_64"
	codesign --verify --deep --strict $(APP)
	codesign -d -r- $(APP) 2>&1 | grep designated
	$(MAKE) zip dmg
	@if [ -n "$(NOTARY_PROFILE)" ]; then \
	  xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait && \
	  xcrun stapler staple $(DMG); \
	fi
	cd $(BUILD_DIR) && shasum -a 256 $(notdir $(ZIP)) $(notdir $(DMG)) | tee SHA256SUMS
	$(MAKE) installer

# build/install.sh: the one-line Terminal installer, for this version and DOWNLOAD_URL.
installer:
	sed -e 's#@APP@#$(APP_NAME)#g' -e 's#@VERSION@#$(VERSION)#g' -e 's#@BUNDLE_ID@#$(BUNDLE_ID)#g' \
	  -e 's#@DOWNLOAD_URL@#$(DOWNLOAD_URL)#g' -e 's#@INSTALLER_URL@#$(INSTALLER_URL)#g' Tools/install.sh.in > $(BUILD_DIR)/install.sh
	chmod +x $(BUILD_DIR)/install.sh
	sh -n $(BUILD_DIR)/install.sh

# Publish the release built by `make release` as GitHub release v$(VERSION) (tags HEAD).
# The repo must be public for the downloads to work without a GitHub login.
publish:
	@test -f $(ZIP) -a -f $(DMG) -a -f $(BUILD_DIR)/SHA256SUMS -a -f $(BUILD_DIR)/install.sh || (echo "Run make release first"; exit 1)
	@test -z "$$(git status --porcelain)" || (echo "Commit your changes first"; exit 1)
	gh release create v$(VERSION) $(ZIP) $(DMG) $(BUILD_DIR)/SHA256SUMS $(BUILD_DIR)/install.sh \
	  --repo $(REPO) --target "$$(git rev-parse HEAD)" --title "$(APP_NAME) $(VERSION)" --generate-notes
	@echo "Installer: curl -fsSL $(INSTALLER_URL) | sh"

zip:
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)

dmg:
	rm -rf $(BUILD_DIR)/dmg $(DMG)
	mkdir -p $(BUILD_DIR)/dmg && cp -R $(APP) $(BUILD_DIR)/dmg/ && ln -s /Applications $(BUILD_DIR)/dmg/Applications
	hdiutil create -volname $(APP_NAME) -srcfolder $(BUILD_DIR)/dmg -ov -format UDZO $(DMG)

# Re-render Resources/AppIcon.icns from the AppIcon SwiftUI view.
icon:
	swift run -c $(CONFIG) $(APP_NAME) --icon $(BUILD_DIR)/AppIcon.iconset
	iconutil -c icns $(BUILD_DIR)/AppIcon.iconset -o Resources/AppIcon.icns

# Regenerate each region's base map (Resources/geodata-<region>.bin) and network (track,
# stations, timetables: Resources/rail-<region>.bin) from Natural Earth and each agency's static
# GTFS. Run before each release so the bundled timetables are current.
REGIONS = dcbal nyc phl bos
data:
	./Tools/fetch_data.sh $(BUILD_DIR)/data-src
	for r in $(REGIONS); do \
	  python3 -I Tools/build_geodata.py $(BUILD_DIR)/data-src Resources/geodata-$$r.bin $$r && \
	  python3 -I Tools/build_rail.py $(BUILD_DIR)/data-src Resources/rail-$$r.bin $$r || exit 1; \
	done

# Render headless previews of every style/appearance into build/snapshots.
snapshots:
	swift run -c $(CONFIG) $(APP_NAME) --snapshots $(BUILD_DIR)/snapshots

clean:
	rm -rf .build $(BUILD_DIR)
