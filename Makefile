DERIVED := .build/xcode
CONFIG ?= Debug
APP := $(DERIVED)/Build/Products/$(CONFIG)/Orbit.app

.PHONY: project build run test release clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -skipPackagePluginValidation -quiet build

run: build
	-pkill -x Orbit
	open $(APP)

test:
	cd Packages/OrbitKit && swift test

release:
	$(MAKE) build CONFIG=Release

clean:
	rm -rf $(DERIVED) Orbit.xcodeproj
