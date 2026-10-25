DERIVED := .build/xcode
CONFIG ?= Debug
APP := $(DERIVED)/Build/Products/$(CONFIG)/Orbit.app
# The everyday Debug build is the one the app is used in: optimized like
# Release (unoptimized Swift scrolled the editor and long chats at a crawl,
# D165), still with DEBUG and its debug commands. Xcode's own builds stay
# -Onone for previews and the debugger.
OPTIMIZE := SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s

.PHONY: project build run test test-languages test-language-installs stress stress-vm stress-full import-lspconfig import-grammars acknowledgements release release-setup release-publish clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -skipPackagePluginValidation -quiet $(OPTIMIZE) build

run: build
	-pkill -x Orbit
	open $(APP)

test:
	cd Packages/OrbitKit && swift test

# Every feature of the debug build, from the plugins' steps and checks, in
# order and at random, in 4 copies and modes in the background (D243-D245).
# STEPS=, SEED=, JOBS= to vary; STEPS=0 the fixed part and coverage only;
# REPLAY=<log> MODE=<n> a failed copy again; FOREGROUND=1 adds full screen.
stress: build
	scripts/stress.sh

# The same on macOS 26, the minimum, in the Tart VM (D235, D246).
stress-vm: build
	scripts/stress-vm.sh

# Before a release (D246): longer, with leaks, and on macOS 26; stamps the
# commit, which make release asks for. SHRINK=<log> make stress shrinks a failure.
stress-full: build
	scripts/stress-full.sh

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

# Rewrites App/Acknowledgements.txt, the licenses shown in About Orbit (D207),
# from the checked-out packages. Run it after a dependency changes.
acknowledgements: build
	python3 -I scripts/acknowledgements.py

# Regenerates OrbitLanguages/Resources/Servers.json from nvim-lspconfig,
# Neovim's and Linguist's file types and Mason's registry (D65). Bump the pins
# to pick up new servers; read the diff before committing it.
LSPCONFIG_COMMIT := 6d27c288ff951e1e94cb5f91c800adeddf0dc0c2
NEOVIM_TAG := v0.11.4
LINGUIST_TAG := v9.4.0
import-lspconfig:
	@tmp=$$(mktemp -d) && \
	git init -q $$tmp/lspconfig && \
	git -C $$tmp/lspconfig fetch -q --depth 1 https://github.com/neovim/nvim-lspconfig.git $(LSPCONFIG_COMMIT) && \
	git -C $$tmp/lspconfig checkout -q FETCH_HEAD && \
	curl -sSfL -o $$tmp/filetype.lua https://raw.githubusercontent.com/neovim/neovim/$(NEOVIM_TAG)/runtime/lua/vim/filetype.lua && \
	curl -sSfL -o $$tmp/languages.yml https://raw.githubusercontent.com/github-linguist/linguist/$(LINGUIST_TAG)/lib/linguist/languages.yml && \
	curl -sSfL -o $$tmp/registry.zip https://github.com/mason-org/mason-registry/releases/latest/download/registry.json.zip && \
	unzip -q -o $$tmp/registry.zip -d $$tmp && \
	python3 -I scripts/import-lspconfig.py $$tmp/lspconfig $$tmp/filetype.lua $$tmp/languages.yml $$tmp/registry.json \
		$(LSPCONFIG_COMMIT) Packages/OrbitKit/Sources/OrbitLanguages/Resources/Servers.json; \
	status=$$?; rm -rf $$tmp; exit $$status

# Regenerates OrbitAPI/Resources/Grammars.json from Zed's own languages and
# its extension catalog (D71). Bump the pins to pick up new languages; read the
# diff before committing it.
ZED_COMMIT := 36682547bea1c3d4fa60c08d341cf60081853941
ZED_EXTENSIONS_COMMIT := c63c15ce892e8ea02d0be53ae5d2526105e03519
import-grammars:
	@tmp=$$(mktemp -d) && \
	git init -q $$tmp/zed && \
	git -C $$tmp/zed sparse-checkout set --no-cone /Cargo.toml /Cargo.lock /crates/grammars/ && \
	git -C $$tmp/zed fetch -q --depth 1 --filter=blob:none https://github.com/zed-industries/zed.git $(ZED_COMMIT) && \
	git -C $$tmp/zed checkout -q FETCH_HEAD && \
	git init -q $$tmp/catalog && \
	git -C $$tmp/catalog fetch -q --depth 1 --filter=blob:none https://github.com/zed-industries/extensions.git $(ZED_EXTENSIONS_COMMIT) && \
	git -C $$tmp/catalog checkout -q FETCH_HEAD && \
	python3 -I scripts/import-grammars.py $$tmp/zed $(ZED_COMMIT) $$tmp/catalog $(ZED_EXTENSIONS_COMMIT) $$tmp/work \
		Packages/OrbitKit/Sources/OrbitAPI/Resources/Grammars.json; \
	status=$$?; rm -rf $$tmp; exit $$status

# Releases with Sparkle updates (D129); see scripts/release.sh.
release-setup:
	scripts/release.sh setup

release:
	scripts/release.sh build $(VERSION)

release-publish:
	scripts/release.sh publish $(VERSION)

# Also the package's own build: it can keep a stale file list after new
# source files arrive (types in new files "not found" by swift test).
clean:
	rm -rf $(DERIVED) Orbit.xcodeproj Packages/OrbitKit/.build/out
