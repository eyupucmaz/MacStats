# MacStats — convenience wrappers around SwiftPM and Scripts/build-app.sh.

SWIFT ?= swift
APP_BUNDLE := dist/MacStats.app
# Release version comes from Info.plist so the Makefile never drifts from the bundle.
VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
BUILD_NUMBER ?= 1
DMG := dist/MacStats-$(VERSION)-universal.dmg

.PHONY: all build release app dmg verify-app verify-release icon test run clean help

all: build

help:
	@echo "make build    - debug build (swift build)"
	@echo "make release  - optimised build (swift build -c release)"
	@echo "make app      - assemble and ad-hoc sign $(APP_BUNDLE)"
	@echo "make dmg      - package the verified app as a universal DMG"
	@echo "make verify-release - mount and verify the packaged DMG"
	@echo "make icon     - re-render the app icon into the asset catalog"
	@echo "make test     - run the XCTest suite (swift test)"
	@echo "make run      - assemble the app bundle and launch it"
	@echo "make clean    - remove .build/ and dist/"

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

app:
	APP_VERSION=$(VERSION) BUILD_NUMBER=$(BUILD_NUMBER) RELEASE_STRICT=1 bash Scripts/build-app.sh

dmg: app
	bash Scripts/package-dmg.sh $(VERSION)

verify-app:
	bash Scripts/verify-app.sh dist/MacStats.app $(VERSION) $(BUILD_NUMBER)

verify-release:
	bash Scripts/verify-release.sh $(VERSION) $(BUILD_NUMBER)

icon:
	$(SWIFT) Scripts/make-icon.swift Sources/MacStats/Resources/Assets.xcassets/AppIcon.appiconset

test:
	$(SWIFT) test

run: app
	open $(APP_BUNDLE)

clean:
	-$(SWIFT) package clean
	rm -rf .build dist
