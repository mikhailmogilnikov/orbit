DERIVED := .build/xcode
CONFIG ?= Debug
APP := $(DERIVED)/Build/Products/$(CONFIG)/Orbit.app

.PHONY: project build run test test-languages test-language-installs import-lspconfig import-grammars release clean

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

release:
	$(MAKE) build CONFIG=Release

# Also the package's own build: it can keep a stale file list after new
# source files arrive (types in new files "not found" by swift test).
clean:
	rm -rf $(DERIVED) Orbit.xcodeproj Packages/OrbitKit/.build/out
