import Foundation
import Testing
@testable import OrbitAPI

@Suite struct ExtensionTests {
    @Test func parsesHexColors() {
        #expect(ThemeColor(hex: "#ff0000") == ThemeColor(red: 1, green: 0, blue: 0))
        #expect(ThemeColor(hex: "#00ff0080")?.alpha == Double(0x80) / 255)
        #expect(ThemeColor(hex: "#fff") == ThemeColor(red: 1, green: 1, blue: 1))
        #expect(ThemeColor(hex: "nope") == nil)
        #expect(ThemeColor(hex: "#12345") == nil)
    }

    @Test func readsZedThemeFamily() throws {
        let json = """
        {
          "name": "Sample",
          "themes": [
            {
              "name": "Sample Dark",
              "appearance": "dark",
              "style": {
                "editor.background": "#101010",
                "editor.foreground": "#eeeeee",
                "created": "#00ff00",
                "version_control.modified": "#ffaa00",
                "terminal.ansi.red": "#ff0000",
                "terminal.ansi.bright_white": "#ffffff",
                "players": [{ "cursor": "#ff00ff", "selection": "#ff00ff33" }],
                "syntax": {
                  "keyword": { "color": "#c678dd", "font_weight": 700 },
                  "comment": { "color": "#5c6370", "font_style": "italic" },
                  "function": { "color": "#61afef" }
                }
              }
            },
            { "name": "Sample Light", "appearance": "light", "style": {} }
          ]
        }
        """
        let themes = try ThemeFile.colorThemes(from: Data(json.utf8), extensionID: "sample", extensionName: "Sample")
        #expect(themes.map(\.id) == ["sample/Sample Dark", "sample/Sample Light"])
        let dark = themes[0]
        #expect(dark.isDark)
        #expect(!themes[1].isDark)
        #expect(dark.editorBackground == ThemeColor(hex: "#101010"))
        #expect(dark.added == ThemeColor(hex: "#00ff00"))
        #expect(dark.modified == ThemeColor(hex: "#ffaa00"))
        #expect(dark.cursor == ThemeColor(hex: "#ff00ff"))
        #expect(dark.terminalANSI[1] == ThemeColor(hex: "#ff0000"))
        #expect(dark.terminalANSI[15] == ThemeColor(hex: "#ffffff"))
        #expect(dark.terminalANSI[0] == nil)
        #expect(dark.syntax["keyword"]?.weight == 700)
        #expect(dark.syntax["comment"]?.isItalic == true)
    }

    @Test func capturesFallBackToZedNames() {
        var theme = ColorTheme(id: "t", name: "t", isDark: true, extensionName: "t")
        theme.syntax = [
            "keyword": SyntaxStyle(color: ThemeColor(hex: "#111111")),
            "function": SyntaxStyle(color: ThemeColor(hex: "#222222")),
            "function.method": SyntaxStyle(color: ThemeColor(hex: "#333333")),
            "string": SyntaxStyle(color: ThemeColor(hex: "#444444")),
        ]
        #expect(theme.style(forCapture: "keyword.return")?.color == ThemeColor(hex: "#111111"))
        #expect(theme.style(forCapture: "include")?.color == ThemeColor(hex: "#111111"))
        #expect(theme.style(forCapture: "function.call")?.color == ThemeColor(hex: "#222222"))
        #expect(theme.style(forCapture: "method")?.color == ThemeColor(hex: "#333333"))
        #expect(theme.style(forCapture: "string.regex")?.color == ThemeColor(hex: "#444444"))
        #expect(theme.style(forCapture: "variable") == nil)
    }

    @Test func matchesIconsByNameAndSuffix() throws {
        let json = """
        {
          "name": "Icons",
          "themes": [{
            "name": "Icons",
            "directory_icons": { "collapsed": "./icons/folder.svg", "expanded": "./icons/folder-open.svg" },
            "named_directory_icons": { "src": { "collapsed": "./icons/src.svg" } },
            "file_stems": { "Makefile": "make", "Dockerfile": "docker" },
            "file_suffixes": { "ts": "typescript", "d.ts": "types", "JSON": "json" },
            "file_icons": {
              "make": { "path": "./icons/make.svg" },
              "docker": { "path": "./icons/docker.svg" },
              "typescript": { "path": "./icons/ts.svg" },
              "types": { "path": "./icons/dts.svg" },
              "json": { "path": "./icons/json.svg" },
              "default": { "path": "./icons/file.svg" }
            }
          }]
        }
        """
        let root = URL(fileURLWithPath: "/ext")
        let theme = try #require(ThemeFile.iconThemes(from: Data(json.utf8), root: root, extensionID: "icons", extensionName: "Icons").first)
        #expect(theme.icon(forFileNamed: "Makefile")?.lastPathComponent == "make.svg")
        #expect(theme.icon(forFileNamed: "Dockerfile.dev")?.lastPathComponent == "docker.svg")
        #expect(theme.icon(forFileNamed: "index.d.ts")?.lastPathComponent == "dts.svg")
        #expect(theme.icon(forFileNamed: "main.ts")?.lastPathComponent == "ts.svg")
        #expect(theme.icon(forFileNamed: "Package.JSON")?.lastPathComponent == "json.svg")
        #expect(theme.icon(forFileNamed: "notes.xyz")?.lastPathComponent == "file.svg")
        #expect(theme.icon(forFolderNamed: "src", expanded: true)?.lastPathComponent == "src.svg")
        #expect(theme.icon(forFolderNamed: "docs", expanded: true)?.path == "/ext/icons/folder-open.svg")
    }

    @Test func readsZedExtensionTOML() throws {
        let toml = """
        id = "one-dark"
        name = "One Dark"
        version = "1.2.0"
        schema_version = 1
        authors = ["Jane <jane@example.com>", "Joe"]
        description = "A theme"
        repository = "https://github.com/example/one-dark"

        [grammars.foo]
        id = "ignored"
        """
        let manifest = try #require(ExtensionManifest.fromZedTOML(toml))
        #expect(manifest.id == "one-dark")
        #expect(manifest.version == "1.2.0")
        #expect(manifest.authors == ["Jane <jane@example.com>", "Joe"])
        #expect(manifest.repository == "https://github.com/example/one-dark")
    }

    @Test @MainActor func builtinThemesLoad() {
        let extensions = Extensions.shared
        #expect(extensions.installed.contains { $0.id == "orbit-default" && $0.isBuiltin })
        #expect(extensions.colorThemes.contains { $0.id == Extensions.defaultLightThemeID && !$0.isDark })
        #expect(extensions.colorThemes.contains { $0.id == Extensions.defaultDarkThemeID && $0.isDark })
    }

    /// The extensions in `examples/` stay valid as the format evolves.
    @Test func examplesParse() throws {
        let examples = URL(fileURLWithPath: #filePath).appending(path: "../../../../../examples/extensions").standardizedFileURL
        for file in ["nord/themes/nord.json", "github-theme/themes/github.json"] {
            let themes = try ThemeFile.colorThemes(from: Data(contentsOf: examples.appending(path: file)), extensionID: "x", extensionName: "x")
            #expect(themes.count == 2)
            #expect(Set(themes.map(\.isDark)) == [true, false])
            #expect(themes.allSatisfy { $0.editorBackground != nil && !$0.syntax.isEmpty })
        }
        let iconsRoot = examples.appending(path: "simple-icons")
        let icons = try ThemeFile.iconThemes(
            from: Data(contentsOf: iconsRoot.appending(path: "icon_themes/simple-icons.json")),
            root: iconsRoot, extensionID: "simple-icons", extensionName: "Simple Icons"
        )
        let theme = try #require(icons.first)
        for url in theme.fileIcons.values + [theme.folder, theme.folderExpanded].compactMap({ $0 }) {
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
        }
    }

    @Test func decodesZedCatalogEntries() throws {
        let json = """
        {"data": [{
          "id": "catppuccin", "name": "Catppuccin", "version": "0.2.1",
          "description": "Soothing pastel theme", "authors": ["Someone <a@b.c>"],
          "repository": "https://github.com/catppuccin/zed", "schema_version": 1,
          "wasm_api_version": null, "provides": ["themes", "icon-themes"],
          "published_at": "2025-01-01T00:00:00Z", "download_count": 123456
        }, {"id": "bare"}]}
        """
        struct Response: Decodable { var data: [CatalogEntry] }
        let entries = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).data
        #expect(entries[0].downloadCount == 123456)
        #expect(entries[0].provides == ["themes", "icon-themes"])
        #expect(entries[1].name == "bare")
        #expect(entries[1].version == "0.0.0")
    }

    @MainActor @Test func loadsAFolderForTryingOn() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "orbit-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "themes"), withIntermediateDirectories: true)
        try Data("id = \"try\"\nname = \"Try\"\nversion = \"1.2.3\"\n".utf8).write(to: folder.appending(path: "extension.toml"))
        let family = #"{"themes": [{"name": "Try Light", "appearance": "light", "style": {}}, {"name": "Try Dark", "appearance": "dark", "style": {}}]}"#
        try Data(family.utf8).write(to: folder.appending(path: "themes/try.json"))
        let loaded = try #require(try Extensions.load(folder, isBuiltin: false))
        #expect(loaded.entry.manifest.version == "1.2.3")
        #expect(loaded.colorThemes.map(\.id) == ["try/Try Light", "try/Try Dark"])
        let preview = ExtensionPreview(manifest: loaded.entry.manifest, directory: folder, colorThemes: loaded.colorThemes, iconThemes: [])
        #expect(preview.colorTheme?.name == "Try Light")
        #expect(preview.iconTheme == nil)
    }
}
