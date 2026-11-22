XCODE_DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
PREFIX ?= $(HOME)/Applications
APP := build/Model Switch.app

.PHONY: build test app icon run run-fixture fixture install clean help

build:
	swift build

test:
	DEVELOPER_DIR=$(XCODE_DEVELOPER_DIR) swift test

app:
	./build-app.sh

icon:
	mkdir -p build/AppIcon.iconset Resources
	swift tools/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

run:
	swift run ModelSwitch

run-fixture:
	swift run ModelSwitch --fixture

fixture: app
	open "$(APP)" --args --fixture

install: app
	mkdir -p "$(PREFIX)"
	rm -rf "$(PREFIX)/Model Switch.app"
	cp -R "$(APP)" "$(PREFIX)/Model Switch.app"
	@echo "Installed $(PREFIX)/Model Switch.app"

clean:
	swift package clean
	rm -rf build

help:
	@echo "build        compile (debug)"
	@echo "test         swift test (uses Xcode's XCTest)"
	@echo "app          release build + build/Model Switch.app"
	@echo "icon         render Resources/AppIcon.icns from tools/make-icon.swift"
	@echo "run          run from swift (no bundle)"
	@echo "run-fixture  run with the canned fixture servers"
	@echo "fixture      build .app and open it in fixture mode"
	@echo "install      copy the app to PREFIX (default ~/Applications)"
