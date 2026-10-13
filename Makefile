DERIVED := .build/xcode
CONFIG ?= Debug
APP := $(DERIVED)/Build/Products/$(CONFIG)/Orbit.app

.PHONY: project build run test test-languages test-language-installs release clean

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

# Each language against its real server (D55). Also runs on Linux
# (scripts/linux-swift.sh), where SwiftPM drops the macOS-only pins.
test-languages:
	cd Packages/OrbitKit && PATH="/opt/swift/usr/bin:$$PATH" swift test --filter "LanguageServer|Completion"; \
		status=$$?; [ "$$(uname)" = Linux ] && git checkout -q -- Package.resolved; exit $$status

# Installs every server Orbit offers from the Mason registry and runs each on a
# file with a problem (D57). Downloads a lot once; cached in the temp folder.
test-language-installs:
	cd Packages/OrbitKit && ORBIT_INSTALL_TESTS=1 PATH="/opt/swift/usr/bin:$$PATH" swift test --filter "LanguageInstall|Grammar"; \
		status=$$?; [ "$$(uname)" = Linux ] && git checkout -q -- Package.resolved; exit $$status

release:
	$(MAKE) build CONFIG=Release

# Also the package's own build: it can keep a stale file list after new
# source files arrive (types in new files "not found" by swift test).
clean:
	rm -rf $(DERIVED) Orbit.xcodeproj Packages/OrbitKit/.build/out
