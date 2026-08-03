APP        := Tokenmax
BUNDLE_ID  := com.tokenmax.Tokenmax
BUILD_DIR  := .build
CONFIG     := Debug
APP_PATH   := $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP).app
INSTALL_TO := /Applications/$(APP).app
VERSION    := $(shell sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' project.yml)
DIST_DIR   := dist
DMG        := $(DIST_DIR)/$(APP)-$(VERSION).dmg

# Ad-hoc by default, so a fresh clone builds with no setup at all.
#
# Ad-hoc means no certificate, so the bundle has no stable designated
# requirement and the keychain ACL falls back to the raw cdhash — which changes
# on every rebuild, so macOS re-asks for access to the Claude credentials every
# time and "Always Allow" never sticks. Signing with a self-signed code-signing
# certificate fixes that: `make sign SIGN_ID="Tokenmax Dev"`. See README →
# Building a release.
SIGN_ID ?= -

.PHONY: all generate build sign install run stop test dmg clean logs

all: install

generate:
	@xcodegen generate --quiet

build: generate
	@xcodebuild \
		-project $(APP).xcodeproj \
		-scheme $(APP) \
		-configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		-quiet \
		build

sign: build
	@codesign --force --deep --sign "$(SIGN_ID)" "$(APP_PATH)"
	@codesign --verify --verbose=1 "$(APP_PATH)" 2>&1 | tail -2

install: stop sign
	@rm -rf "$(INSTALL_TO)"
	@cp -R "$(APP_PATH)" "$(INSTALL_TO)"
	@# Nudge Launch Services so the bundle ID is registered for notifications.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$(INSTALL_TO)" 2>/dev/null || true
	@echo "installed -> $(INSTALL_TO)"

run:
	@open "$(INSTALL_TO)"

stop:
	@pkill -x $(APP) 2>/dev/null || true
	@sleep 0.3

test: generate
	@xcodebuild \
		-project $(APP).xcodeproj \
		-scheme $(APP) \
		-configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		-quiet \
		test

# A drag-to-Applications disk image. `hdiutil` ships with macOS, so this needs
# nothing installed and no Apple Developer account. The image is not notarised,
# so Gatekeeper will ask the recipient to confirm the first launch — README →
# Installing a release covers what they see.
dmg: sign
	@rm -rf "$(DIST_DIR)/root" "$(DMG)"
	@mkdir -p "$(DIST_DIR)/root"
	@cp -R "$(APP_PATH)" "$(DIST_DIR)/root/"
	@ln -s /Applications "$(DIST_DIR)/root/Applications"
	@hdiutil create \
		-volname "$(APP) $(VERSION)" \
		-srcfolder "$(DIST_DIR)/root" \
		-ov -format UDZO -quiet \
		"$(DMG)"
	@rm -rf "$(DIST_DIR)/root"
	@echo "built -> $(DMG)  (signed with: $(SIGN_ID))"

logs:
	@tail -f "$$HOME/Library/Application Support/Tokenmax/logs/tokenmax.log"

clean:
	@rm -rf $(BUILD_DIR) $(DIST_DIR) $(APP).xcodeproj
