import CoreServices
import Foundation
import Observation

/// `extension.json` at the root of an extension folder (D37). Zed's
/// `extension.toml` is read too, so Zed theme and icon extensions work as is.
public struct ExtensionManifest: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var authors: [String]?
    public var repository: String?
    /// Theme-family files relative to the folder; `themes/*.json` when omitted.
    public var themes: [String]?
    /// Icon-theme files; `icon_themes/*.json` when omitted.
    public var iconThemes: [String]?
    /// Snippet files; everything in `snippets/` when omitted (D195). Zed's
    /// `extension.toml` lists them as `snippets = "./snippets/rust.json"`.
    /// Agents (`agents/*.json`), `language_servers.json` and `tasks.json` are found by name.
    public var snippets: [String]?

    public init(id: String, name: String, version: String) {
        self.id = id
        self.name = name
        self.version = version
    }

    /// The handful of top-level `key = "value"` / `authors = [...]` lines Orbit needs.
    static func fromZedTOML(_ text: String) -> ExtensionManifest? {
        var values: [String: String] = [:]
        var authors: [String] = []
        var snippets: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let strings = value.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
                .filter { $0.offset % 2 == 1 }.map { String($0.element) }
            if key == "authors" {
                authors = strings
            } else if key == "snippets" {
                snippets = strings
            } else if let first = strings.first {
                values[key] = first
            }
        }
        guard let id = values["id"], let name = values["name"] else { return nil }
        var manifest = ExtensionManifest(id: id, name: name, version: values["version"] ?? "0.0.0")
        manifest.description = values["description"]
        manifest.repository = values["repository"]
        manifest.authors = authors.isEmpty ? nil : authors
        manifest.snippets = snippets.isEmpty ? nil : snippets
        return manifest
    }
}

public struct InstalledExtension: Identifiable, Sendable, Hashable {
    public var id: String { manifest.id }
    public var manifest: ExtensionManifest
    public var directory: URL
    public var isBuiltin: Bool
    public var themeCount = 0
    public var iconThemeCount = 0
    public var snippetCount = 0
    public var agentCount = 0
    public var languageServerCount = 0
    public var taskCount = 0

    /// Brings something that runs programs (agents, servers, tasks), not only looks.
    public var runsPrograms: Bool { agentCount + languageServerCount + taskCount > 0 }
}

/// A file an extension brings for a plugin to read (D195): an agent's
/// manifest, its language servers, its tasks.
public struct ExtensionFile: Sendable, Hashable {
    public var extensionID: String
    public var extensionName: String
    public var url: URL
}

/// See `Extensions.preview`. Starts with the theme matching the current mode
/// when the extension ships one.
public struct ExtensionPreview: Sendable, Hashable {
    public var manifest: ExtensionManifest
    public var directory: URL
    public var colorThemes: [ColorTheme]
    public var iconThemes: [IconTheme]
    public var colorThemeID: String?
    public var iconThemeID: String?

    public init(manifest: ExtensionManifest, directory: URL, colorThemes: [ColorTheme], iconThemes: [IconTheme]) {
        self.manifest = manifest
        self.directory = directory
        self.colorThemes = colorThemes
        self.iconThemes = iconThemes
        colorThemeID = colorThemes.first?.id
        iconThemeID = iconThemes.first?.id
    }

    public var colorTheme: ColorTheme? { colorThemes.first { $0.id == colorThemeID } }
    public var iconTheme: IconTheme? { iconThemes.first { $0.id == iconThemeID } }
}

public struct ExtensionProblem: Identifiable, Sendable, Hashable {
    public var id: String { "\(location.path)|\(message)" }
    public var location: URL
    public var message: String
}

enum ExtensionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// Installed extensions and what they contribute. Built-ins ship in the app;
/// user extensions live in `~/.orbit/extensions/<id>/` and reload as their files change.
@MainActor
@Observable
public final class Extensions {
    public static let shared = Extensions()

    /// Posted on the main thread when the colors to draw with may have changed:
    /// themes reloaded or another theme picked. For AppKit views; SwiftUI views
    /// observe `Extensions` and `Preferences` directly.
    public static let themeDidChange = Notification.Name("OrbitThemeDidChange")

    public static let defaultLightThemeID = "orbit-default/Orbit Light"
    public static let defaultDarkThemeID = "orbit-default/Orbit Dark"

    public static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".orbit/extensions", directoryHint: .isDirectory)
    }

    public private(set) var installed: [InstalledExtension] = []
    public private(set) var colorThemes: [ColorTheme] = []
    public private(set) var iconThemes: [IconTheme] = []
    public private(set) var problems: [ExtensionProblem] = []
    /// What extensions bring besides themes (D195); plugins read their own kind.
    public private(set) var snippets: [CodeSnippet] = []
    public private(set) var agentFiles: [ExtensionFile] = []
    public private(set) var languageServerFiles: [ExtensionFile] = []
    public private(set) var taskFiles: [ExtensionFile] = []
    /// Bumped on every reload; views drawing extension files read it to redraw.
    public private(set) var revision = 0

    @ObservationIgnored private var watcher: DirectoryWatcher?

    private init() {
        reload()
        try? FileManager.default.createDirectory(at: Self.userDirectory, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(url: Self.userDirectory) { [weak self] in self?.reload() }
    }

    /// An extension being tried on: loaded from a cache folder, not installed,
    /// drawn instead of the picked themes until it is installed or dismissed.
    public var preview: ExtensionPreview? {
        didSet {
            guard preview != oldValue else { return }
            revision += 1
            NotificationCenter.default.post(name: Self.themeDidChange, object: nil)
        }
    }

    /// The theme to draw with in light or dark mode: the one being tried on
    /// (for its own mode), the picked one, else the default.
    public func colorTheme(dark: Bool) -> ColorTheme {
        if let theme = preview?.colorTheme, theme.isDark == dark { return theme }
        return pickedColorTheme(dark: dark)
    }

    /// Changes whenever the colors to draw with may have: another theme picked or
    /// tried on, or themes reloaded. For `.task(id:)` of views that bake colors in
    /// (syntax-colored diffs); light/dark switches don't need it, those colors are dynamic.
    public var themeKey: String {
        "\(colorTheme(dark: false).id)|\(colorTheme(dark: true).id)|\(revision)"
    }

    /// The theme picked in Settings, ignoring a preview.
    public func pickedColorTheme(dark: Bool) -> ColorTheme {
        let preferences = Preferences.shared
        let picked = dark ? preferences.darkThemeID : preferences.lightThemeID
        let fallback = dark ? Self.defaultDarkThemeID : Self.defaultLightThemeID
        return colorThemes.first { $0.id == picked } ?? colorThemes.first { $0.id == fallback } ?? .system(dark: dark)
    }

    /// The icons to draw with in light or dark mode; nil means the built-in SF Symbols.
    public func iconTheme(dark: Bool) -> IconTheme? {
        if let theme = preview?.iconTheme { return theme }
        let preferences = Preferences.shared
        guard let id = dark ? preferences.darkIconThemeID : preferences.lightIconThemeID else { return nil }
        return iconThemes.first { $0.id == id }
    }

    /// Picks `theme` for its mode and, when its extension ships themes for the
    /// other mode too, the closest-named one of those ("Catppuccin Mocha" →
    /// "Catppuccin Latte", "One Dark" → "One Light"). A fixed Light/Dark
    /// appearance follows the theme, so the choice shows right away.
    public func choose(_ theme: ColorTheme, from family: [ColorTheme]? = nil) {
        let preferences = Preferences.shared
        let family = family ?? colorThemes.filter { $0.extensionID == theme.extensionID }
        if theme.isDark { preferences.darkThemeID = theme.id } else { preferences.lightThemeID = theme.id }
        let partner = family.filter { $0.isDark != theme.isDark }
            .max { Self.sharedPrefix($0.name, theme.name) < Self.sharedPrefix($1.name, theme.name) }
        if let partner {
            if partner.isDark { preferences.darkThemeID = partner.id } else { preferences.lightThemeID = partner.id }
        }
        if preferences.appearance != .system, preferences.isDark != theme.isDark {
            preferences.appearance = theme.isDark ? .dark : .light
        }
    }

    private static func sharedPrefix(_ a: String, _ b: String) -> Int {
        zip(a.lowercased(), b.lowercased()).prefix { $0 == $1 }.count
    }

    /// Reads an unpacked extension for trying on; throws when it has nothing to show.
    public func makePreview(of folder: URL) throws -> ExtensionPreview {
        guard let loaded = try Self.load(folder, isBuiltin: false) else {
            throw ExtensionError.invalid("the download has no extension manifest")
        }
        if let problem = loaded.problems.first, loaded.colorThemes.isEmpty, loaded.iconThemes.isEmpty {
            throw ExtensionError.invalid(problem.message)
        }
        guard !loaded.colorThemes.isEmpty || !loaded.iconThemes.isEmpty else {
            throw ExtensionError.invalid("it has no themes or icon themes")
        }
        return ExtensionPreview(manifest: loaded.entry.manifest, directory: folder, colorThemes: loaded.colorThemes, iconThemes: loaded.iconThemes)
    }

    public func reload() {
        var installed: [InstalledExtension] = []
        var colorThemes: [ColorTheme] = []
        var iconThemes: [IconTheme] = []
        var problems: [ExtensionProblem] = []
        var snippets: [CodeSnippet] = []
        var agentFiles: [ExtensionFile] = [], languageServerFiles: [ExtensionFile] = [], taskFiles: [ExtensionFile] = []

        let builtin = Bundle.module.url(forResource: "Extensions", withExtension: nil)
        let sources = [(builtin, true), (Self.userDirectory, false)]
        for case let (root?, isBuiltin) in sources {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
            )) ?? []
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                do {
                    guard let loaded = try Self.load(folder, isBuiltin: isBuiltin) else { continue }
                    if installed.contains(where: { $0.id == loaded.entry.id }) {
                        throw ExtensionError.invalid("another extension already uses the id “\(loaded.entry.id)”")
                    }
                    installed.append(loaded.entry)
                    colorThemes += loaded.colorThemes
                    iconThemes += loaded.iconThemes
                    problems += loaded.problems
                    snippets += loaded.snippets
                    agentFiles += loaded.agentFiles
                    languageServerFiles += loaded.languageServerFiles
                    taskFiles += loaded.taskFiles
                } catch {
                    problems.append(ExtensionProblem(location: folder, message: error.localizedDescription))
                }
            }
        }

        if installed != self.installed { self.installed = installed }
        if colorThemes != self.colorThemes { self.colorThemes = colorThemes }
        if iconThemes != self.iconThemes { self.iconThemes = iconThemes }
        if problems != self.problems { self.problems = problems }
        if snippets != self.snippets { self.snippets = snippets }
        if agentFiles != self.agentFiles { self.agentFiles = agentFiles }
        if languageServerFiles != self.languageServerFiles { self.languageServerFiles = languageServerFiles }
        if taskFiles != self.taskFiles { self.taskFiles = taskFiles }
        // Files can change without changing what parses out of them (an edited icon SVG).
        revision += 1
        NotificationCenter.default.post(name: Self.themeDidChange, object: nil)
    }

    struct LoadedExtension {
        var entry: InstalledExtension
        var colorThemes: [ColorTheme] = []
        var iconThemes: [IconTheme] = []
        var problems: [ExtensionProblem] = []
        var snippets: [CodeSnippet] = []
        var agentFiles: [ExtensionFile] = []
        var languageServerFiles: [ExtensionFile] = []
        var taskFiles: [ExtensionFile] = []
    }

    /// One extension folder; nil when it has no manifest. A theme file that
    /// fails to parse is a problem, not a failure of the whole extension.
    static func load(_ folder: URL, isBuiltin: Bool) throws -> LoadedExtension? {
        guard let manifest = try manifest(in: folder) else { return nil }
        var loaded = LoadedExtension(entry: InstalledExtension(manifest: manifest, directory: folder, isBuiltin: isBuiltin))
        for file in files(manifest.themes, default: "themes", in: folder) {
            do {
                let themes = try ThemeFile.colorThemes(from: Data(contentsOf: file), extensionID: manifest.id, extensionName: manifest.name)
                loaded.colorThemes += themes
                loaded.entry.themeCount += themes.count
            } catch {
                loaded.problems.append(ExtensionProblem(location: file, message: error.localizedDescription))
            }
        }
        for file in files(manifest.iconThemes, default: "icon_themes", in: folder) {
            do {
                let themes = try ThemeFile.iconThemes(from: Data(contentsOf: file), root: folder, extensionID: manifest.id, extensionName: manifest.name)
                loaded.iconThemes += themes
                loaded.entry.iconThemeCount += themes.count
            } catch {
                loaded.problems.append(ExtensionProblem(location: file, message: error.localizedDescription))
            }
        }
        let snippets = if let listed = manifest.snippets {
            CodeSnippet.load(files: listed.map { folder.appending(path: $0).standardizedFileURL }, source: manifest.name)
        } else {
            CodeSnippet.load(folder: folder.appending(path: "snippets"), source: manifest.name)
        }
        loaded.snippets = snippets.snippets
        loaded.problems += snippets.problems
        loaded.entry.snippetCount = snippets.snippets.count
        func file(_ url: URL) -> ExtensionFile { ExtensionFile(extensionID: manifest.id, extensionName: manifest.name, url: url) }
        loaded.agentFiles = files(nil, default: "agents", in: folder).map(file)
        loaded.entry.agentCount = loaded.agentFiles.count
        for (name, key) in [("language_servers.json", "servers"), ("tasks.json", "tasks")] {
            let url = folder.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // Counted here for the Extensions page; their plugins read them in full.
            let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.json5Allowed])) as? [String: Any]
            guard let list = object?[key] as? [Any] else {
                loaded.problems.append(ExtensionProblem(location: url, message: "\(name) holds { \"\(key)\": [ … ] }"))
                continue
            }
            if key == "servers" {
                loaded.languageServerFiles = [file(url)]
                loaded.entry.languageServerCount = list.count
            } else {
                loaded.taskFiles = [file(url)]
                loaded.entry.taskCount = list.count
            }
        }
        return loaded
    }

    private static func manifest(in folder: URL) throws -> ExtensionManifest? {
        let json = folder.appending(path: "extension.json")
        if FileManager.default.fileExists(atPath: json.path) {
            do {
                return try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: json))
            } catch let error as DecodingError {
                throw ExtensionError.invalid("extension.json: \(Self.describe(error))")
            }
        }
        let toml = folder.appending(path: "extension.toml")
        guard let text = try? String(contentsOf: toml, encoding: .utf8) else { return nil }
        guard let manifest = ExtensionManifest.fromZedTOML(text) else {
            throw ExtensionError.invalid("extension.toml needs an id and a name")
        }
        return manifest
    }

    private static func files(_ listed: [String]?, default directory: String, in folder: URL) -> [URL] {
        if let listed { return listed.map { folder.appending(path: $0) } }
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder.appending(path: directory), includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): "missing “\(key.stringValue)”"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            "wrong value for “\(context.codingPath.map(\.stringValue).joined(separator: "."))”"
        case .dataCorrupted(let context): context.underlyingError?.localizedDescription ?? context.debugDescription
        @unknown default: error.localizedDescription
        }
    }
}

/// FSEvents on a folder tree, coalesced: fires once per burst of changes.
@MainActor
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated {
                Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
