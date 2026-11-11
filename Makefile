# Trainspace — build with the Swift toolchain alone (Xcode not required).
APP_NAME   := Trainspace
BUNDLE_ID  := com.trainspace.wallpaper
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

SIGN_ID    ?= -
ENTITLEMENTS := Resources/Trainspace.entitlements

.PHONY: build test app run install release dmg clean data snapshots icon

build:
	swift build -c $(CONFIG)

test:
	swift test $(TEST_FLAGS)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" $(APP)/Contents/MacOS/$(APP_NAME)
	sed -e 's/$$(VERSION)/$(VERSION)/g' -e 's/$$(BUNDLE_ID)/$(BUNDLE_ID)/g' Resources/Info.plist > $(APP)/Contents/Info.plist
	cp Resources/geodata-*.bin Resources/rail-*.bin $(APP)/Contents/Resources/
	mkdir -p $(APP)/Contents/Resources/Fonts && cp Resources/Fonts/* $(APP)/Contents/Resources/Fonts/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/ 2>/dev/null || true
	codesign --force --options runtime --timestamp=none --entitlements $(ENTITLEMENTS) --sign "$(SIGN_ID)" $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

# Build and copy into /Applications (quits a running copy first).
install: app
	-osascript -e 'tell application "$(APP_NAME)" to quit' 2>/dev/null
	rm -rf /Applications/$(APP_NAME).app
	ditto $(APP) /Applications/$(APP_NAME).app
	@echo "Installed /Applications/$(APP_NAME).app"

# Developer ID build + notarization:
#   make release SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=trainspace
# where NOTARY_PROFILE was stored with `xcrun notarytool store-credentials`.
release: app
	@test "$(SIGN_ID)" != "-" || (echo "Set SIGN_ID to a Developer ID Application identity"; exit 1)
	codesign --force --options runtime --timestamp --entitlements $(ENTITLEMENTS) --sign "$(SIGN_ID)" $(APP)
	$(MAKE) dmg
	@if [ -n "$(NOTARY_PROFILE)" ]; then \
	  xcrun notarytool submit $(BUILD_DIR)/$(APP_NAME).dmg --keychain-profile "$(NOTARY_PROFILE)" --wait && \
	  xcrun stapler staple $(BUILD_DIR)/$(APP_NAME).dmg; \
	else echo "NOTARY_PROFILE not set; skipping notarization"; fi

dmg:
	rm -rf $(BUILD_DIR)/dmg $(BUILD_DIR)/$(APP_NAME).dmg
	mkdir -p $(BUILD_DIR)/dmg && cp -R $(APP) $(BUILD_DIR)/dmg/ && ln -s /Applications $(BUILD_DIR)/dmg/Applications
	hdiutil create -volname $(APP_NAME) -srcfolder $(BUILD_DIR)/dmg -ov -format UDZO $(BUILD_DIR)/$(APP_NAME).dmg

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
