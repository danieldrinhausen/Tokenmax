APP        := Tokenmax
BUNDLE_ID  := com.tokenmax.Tokenmax
BUILD_DIR  := .build
CONFIG     ?= Debug
APP_PATH   := $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP).app
INSTALL_TO := /Applications/$(APP).app
VERSION    := $(shell sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' project.yml)
DIST_DIR   := dist
DMG        := $(DIST_DIR)/$(APP)-$(VERSION).dmg

# A stable signing identity when one exists, ad-hoc otherwise.
#
# Ad-hoc means no certificate, so the bundle has no stable designated
# requirement and both the keychain ACL and the app's TCC grants fall back to
# the raw cdhash — which changes on every rebuild. macOS then treats each build
# as a different program: "Always Allow" never sticks for the Claude
# credentials, and file-access grants are thrown away, which makes an
# unattended run block on a consent dialog nobody is there to answer.
#
# Detected rather than left as a variable you must remember to pass. One
# forgotten `SIGN_ID=` silently reinstates the whole problem, which is exactly
# how a certificate created on 3 Aug went unused. A clone with no certificate
# still builds ad-hoc, so setup remains optional. Override explicitly with
# `make install SIGN_ID=-` to test the ad-hoc path.
#
# Create the certificate once: Keychain Access → Certificate Assistant →
# Create a Certificate…, named "Tokenmax Dev", Self Signed Root, Code Signing.
# See README → Building a release.
#
# Note the absent `-v`. Certificate Assistant leaves a self-signed root
# untrusted, so `-v` reports "0 valid identities found" and this fell back to
# ad-hoc on a machine where the certificate had just been created as documented
# — losing the file-access grants the certificate is bought for. Trust governs
# Gatekeeper, not whether codesign can use the identity.
SIGN_ID ?= $(shell security find-identity -p codesigning 2>/dev/null \
	| grep -q '"Tokenmax Dev"' && echo "Tokenmax Dev" || echo "-")

.PHONY: all generate build sign install run stop test doctor dmg dmg-image clean logs

all: install

# Checks the surfaces this app does not own — CLI flags, the keychain blob,
# the usage endpoints, the statusline payload. Run it after every Claude Code
# update; it is the cheapest way to find drift before a queued run does.
doctor:
	@./Tools/doctor.sh

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
# Always Release, never whatever `CONFIG` happens to be. 0.1.0 shipped a Debug
# image because the default was Debug and nothing here disagreed — unoptimised,
# with assertions live, handed to users. Leaving this to a `CONFIG=Release` you
# have to remember is the same trap `SIGN_ID` was, so it is not a flag.
dmg:
	@$(MAKE) --no-print-directory dmg-image CONFIG=Release

dmg-image: sign
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
