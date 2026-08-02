APP        := Tokenmax
BUNDLE_ID  := com.tokenmax.Tokenmax
BUILD_DIR  := .build
CONFIG     := Debug
APP_PATH   := $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP).app
INSTALL_TO := /Applications/$(APP).app

.PHONY: all generate build sign install run stop test clean logs

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
	@codesign --force --deep --sign - "$(APP_PATH)"
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

logs:
	@tail -f "$$HOME/Library/Application Support/Tokenmax/logs/tokenmax.log"

clean:
	@rm -rf $(BUILD_DIR) $(APP).xcodeproj
