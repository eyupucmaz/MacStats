# MacStats — convenience wrappers around SwiftPM and Scripts/build-app.sh.

SWIFT ?= swift
APP_BUNDLE := dist/MacStats.app

.PHONY: all build release app icon test run clean help

all: build

help:
	@echo "make build    - debug build (swift build)"
	@echo "make release  - optimised build (swift build -c release)"
	@echo "make app      - assemble and ad-hoc sign $(APP_BUNDLE)"
	@echo "make icon     - re-render the app icon into the asset catalog"
	@echo "make test     - run the XCTest suite (swift test)"
	@echo "make run      - assemble the app bundle and launch it"
	@echo "make clean    - remove .build/ and dist/"

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

app:
	bash Scripts/build-app.sh

icon:
	$(SWIFT) Scripts/make-icon.swift Sources/MacStats/Resources/Assets.xcassets/AppIcon.appiconset

test:
	$(SWIFT) test

run: app
	open $(APP_BUNDLE)

clean:
	-$(SWIFT) package clean
	rm -rf .build dist
