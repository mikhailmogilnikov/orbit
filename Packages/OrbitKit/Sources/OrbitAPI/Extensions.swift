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

    public init(id: String, name: String, version: String) {
        self.id = id
        self.name = name
        self.version = version
    }

    /// The handful of top-level `key = "value"` / `authors = [...]` lines Orbit needs.
    static func fromZedTOML(_ text: String) -> ExtensionManifest? {
        var values: [String: String] = [:]
        var authors: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let strings = value.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
                .filter { $0.offset % 2 == 1 }.map { String($0.element) }
            if key == "authors" { authors = strings } else if let first = strings.first { values[key] = first }
        }
        guard let id = values["id"], let name = values["name"] else { return nil }
        var manifest = ExtensionManifest(id: id, name: name, version: values["version"] ?? "0.0.0")
        manifest.description = values["description"]
        manifest.repository = values["repository"]
        manifest.authors = authors.isEmpty ? nil : authors
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
    /// Bumped on every reload; views drawing extension files read it to redraw.
    public private(set) var revision = 0

    @ObservationIgnored private var watcher: DirectoryWatcher?

    private init() {
        reload()
        try? FileManager.default.createDirectory(at: Self.userDirectory, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(url: Self.userDirectory) { [weak self] in self?.reload() }
    }

    /// The theme to draw with in light or dark mode: the picked one, else the default.
    public func colorTheme(dark: Bool) -> ColorTheme {
        let preferences = Preferences.shared
        let picked = dark ? preferences.darkThemeID : preferences.lightThemeID
        let fallback = dark ? Self.defaultDarkThemeID : Self.defaultLightThemeID
        return colorThemes.first { $0.id == picked } ?? colorThemes.first { $0.id == fallback } ?? .system(dark: dark)
    }

    /// The icons to draw with in light or dark mode; nil means the built-in SF Symbols.
    public func iconTheme(dark: Bool) -> IconTheme? {
        let preferences = Preferences.shared
        guard let id = dark ? preferences.darkIconThemeID : preferences.lightIconThemeID else { return nil }
        return iconThemes.first { $0.id == id }
    }

    public func reload() {
        var installed: [InstalledExtension] = []
        var colorThemes: [ColorTheme] = []
        var iconThemes: [IconTheme] = []
        var problems: [ExtensionProblem] = []

        let builtin = Bundle.module.url(forResource: "Extensions", withExtension: nil)
        let sources = [(builtin, true), (Self.userDirectory, false)]
        for case let (root?, isBuiltin) in sources {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
            )) ?? []
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                do {
                    guard let manifest = try Self.manifest(in: folder) else { continue }
                    if installed.contains(where: { $0.id == manifest.id }) {
                        throw ExtensionError.invalid("another extension already uses the id “\(manifest.id)”")
                    }
                    var entry = InstalledExtension(manifest: manifest, directory: folder, isBuiltin: isBuiltin)
                    for file in Self.files(manifest.themes, default: "themes", in: folder) {
                        do {
                            let themes = try ThemeFile.colorThemes(from: Data(contentsOf: file), extensionID: manifest.id, extensionName: manifest.name)
                            colorThemes += themes
                            entry.themeCount += themes.count
                        } catch {
                            problems.append(ExtensionProblem(location: file, message: error.localizedDescription))
                        }
                    }
                    for file in Self.files(manifest.iconThemes, default: "icon_themes", in: folder) {
                        do {
                            let themes = try ThemeFile.iconThemes(from: Data(contentsOf: file), root: folder, extensionID: manifest.id, extensionName: manifest.name)
                            iconThemes += themes
                            entry.iconThemeCount += themes.count
                        } catch {
                            problems.append(ExtensionProblem(location: file, message: error.localizedDescription))
                        }
                    }
                    installed.append(entry)
                } catch {
                    problems.append(ExtensionProblem(location: folder, message: error.localizedDescription))
                }
            }
        }

        if installed != self.installed { self.installed = installed }
        if colorThemes != self.colorThemes { self.colorThemes = colorThemes }
        if iconThemes != self.iconThemes { self.iconThemes = iconThemes }
        if problems != self.problems { self.problems = problems }
        // Files can change without changing what parses out of them (an edited icon SVG).
        revision += 1
        NotificationCenter.default.post(name: Self.themeDidChange, object: nil)
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
