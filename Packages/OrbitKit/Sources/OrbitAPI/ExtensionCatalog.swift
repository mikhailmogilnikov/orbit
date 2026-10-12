import Foundation
import Observation

/// An extension listed in Zed's public catalog (D48).
public struct CatalogEntry: Decodable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var authors: [String]
    public var repository: String?
    public var downloadCount: Int
    /// Zed's contribution kinds: `themes`, `icon-themes`, `languages`, …
    public var provides: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, authors, repository, provides
        case downloadCount = "download_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        authors = try container.decodeIfPresent([String].self, forKey: .authors) ?? []
        repository = try container.decodeIfPresent(String.self, forKey: .repository)
        downloadCount = try container.decodeIfPresent(Int.self, forKey: .downloadCount) ?? 0
        provides = try container.decodeIfPresent([String].self, forKey: .provides) ?? []
    }
}

/// Browses Zed's extension catalog and installs the themes and icon themes
/// from it (D48). Only those parts are kept: Orbit runs no Zed code.
@MainActor
@Observable
public final class ExtensionCatalog {
    public static let shared = ExtensionCatalog()

    public enum Kind: String, CaseIterable, Sendable {
        case themes, iconThemes

        var zedName: String { self == .themes ? "themes" : "icon-themes" }
    }

    public private(set) var entries: [CatalogEntry] = []
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    /// Extension ids being downloaded (try on, install or update).
    public private(set) var busy: Set<String> = []
    /// Install / try-on failures by extension id, shown on the row.
    public private(set) var failures: [String: String] = [:]
    /// The catalog entry of `Extensions.shared.preview`, for its Install button.
    public private(set) var previewEntry: CatalogEntry?

    /// Zed's API (what Zed itself uses); one place to change if it moves.
    nonisolated static let apiBase = URL(string: "https://api.zed.dev")!

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    private init() {}

    private var extensions: Extensions { .shared }

    // MARK: Listing

    /// Replaces `entries`; a newer search cancels an older one.
    public func search(_ query: String, kind: Kind) {
        searchTask?.cancel()
        isLoading = true
        loadError = nil
        searchTask = Task {
            do {
                let found = try await Self.fetch(query: query.trimmingCharacters(in: .whitespaces), kind: kind)
                guard !Task.isCancelled else { return }
                entries = found
            } catch {
                guard !Task.isCancelled else { return }
                entries = []
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    public func installed(_ entry: CatalogEntry) -> InstalledExtension? {
        extensions.installed.first { $0.id == entry.id && !$0.isBuiltin }
    }

    public func hasUpdate(_ entry: CatalogEntry) -> Bool {
        guard let installed = installed(entry) else { return false }
        return installed.manifest.version != entry.version
    }

    nonisolated static func fetch(query: String, kind: Kind) async throws -> [CatalogEntry] {
        var components = URLComponents(url: apiBase.appending(path: "extensions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "max_schema_version", value: "1"),
            URLQueryItem(name: "provides", value: kind.zedName),
        ]
        if !query.isEmpty { components.queryItems?.append(URLQueryItem(name: "filter", value: query)) }
        let data = try await download(components.url!)
        struct Response: Decodable { var data: [CatalogEntry] }
        let entries = try JSONDecoder().decode(Response.self, from: data).data
        return entries.sorted { $0.downloadCount > $1.downloadCount }
    }

    // MARK: Try on, install, uninstall

    /// Downloads the extension into the cache and draws with it until
    /// `install` or `endPreview`.
    public func tryOn(_ entry: CatalogEntry) async {
        guard !busy.contains(entry.id) else { return }
        busy.insert(entry.id)
        failures[entry.id] = nil
        defer { busy.remove(entry.id) }
        do {
            let folder = Self.previewDirectory.appending(path: entry.id, directoryHint: .isDirectory)
            if (try? extensions.makePreview(of: folder))?.manifest.version != entry.version {
                try await Self.unpack(entry, into: folder)
            }
            var preview = try extensions.makePreview(of: folder)
            // Start with the variant for the mode the user is in, if there is one.
            let dark = Preferences.shared.isDark
            preview.colorThemeID = (preview.colorThemes.first { $0.isDark == dark } ?? preview.colorThemes.first)?.id
            preview.iconThemeID = (preview.iconThemes.first { $0.isDark == dark } ?? preview.iconThemes.first)?.id
            previewEntry = entry
            extensions.preview = preview
        } catch {
            failures[entry.id] = Self.describe(error)
        }
    }

    public func endPreview() {
        extensions.preview = nil
        previewEntry = nil
    }

    /// Installs (or updates) `entry`; reuses the try-on download of the same version.
    public func install(_ entry: CatalogEntry) async {
        guard !busy.contains(entry.id) else { return }
        busy.insert(entry.id)
        failures[entry.id] = nil
        defer { busy.remove(entry.id) }
        do {
            let staging = Self.previewDirectory.appending(path: entry.id, directoryHint: .isDirectory)
            if (try? extensions.makePreview(of: staging))?.manifest.version != entry.version {
                try await Self.unpack(entry, into: staging)
            }
            let destination = Extensions.userDirectory.appending(path: entry.id, directoryHint: .isDirectory)
            let manager = FileManager.default
            try manager.createDirectory(at: Extensions.userDirectory, withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: staging, to: destination)
            extensions.reload()
            if extensions.preview?.manifest.id == entry.id { adoptPreview() }
        } catch {
            failures[entry.id] = Self.describe(error)
        }
    }

    /// Picks the themes being tried on for good, then ends the preview.
    private func adoptPreview() {
        guard let preview = extensions.preview else { return }
        let preferences = Preferences.shared
        if let theme = preview.colorTheme {
            if theme.isDark { preferences.darkThemeID = theme.id } else { preferences.lightThemeID = theme.id }
        }
        if let icons = preview.iconTheme {
            preferences.lightIconThemeID = icons.id
            preferences.darkIconThemeID = icons.id
        }
        endPreview()
    }

    /// Moves a user extension to the Trash; picked themes from it fall back to the defaults.
    public func uninstall(_ installed: InstalledExtension) {
        guard !installed.isBuiltin else { return }
        do {
            try FileManager.default.trashItem(at: installed.directory, resultingItemURL: nil)
        } catch {
            failures[installed.id] = Self.describe(error)
        }
        extensions.reload()
    }

    // MARK: Download

    static var previewDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "dev.orbit.app/ExtensionPreviews", directoryHint: .isDirectory)
    }

    /// Downloads Zed's packaged extension (a .tar.gz of the built extension
    /// folder) and leaves only what Orbit reads in `folder`.
    nonisolated static func unpack(_ entry: CatalogEntry, into folder: URL) async throws {
        let data = try await download(apiBase.appending(path: "extensions/\(entry.id)/\(entry.version)/download"))

        let manager = FileManager.default
        let work = manager.temporaryDirectory.appending(path: "orbit-extension-\(UUID().uuidString)", directoryHint: .isDirectory)
        let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let archive = work.appending(path: "extension.tar.gz")
        try data.write(to: archive)
        try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", unpacked.path])

        // Zed packs the folder's contents; tolerate a single wrapping folder too.
        var root = unpacked
        let manifestNames = ["extension.toml", "extension.json"]
        if !manifestNames.contains(where: { manager.fileExists(atPath: unpacked.appending(path: $0).path) }) {
            let children = (try? manager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            if children.count == 1 { root = children[0] }
        }
        // Language support is compiled Zed code (WASM) and grammars Orbit has its own of.
        for name in ["extension.wasm", "grammars", "languages", "debug_adapter_schemas"] {
            try? manager.removeItem(at: root.appending(path: name))
        }

        try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: folder.path) { try manager.removeItem(at: folder) }
        try manager.moveItem(at: root, to: folder)
    }

    nonisolated private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Orbit", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExtensionError.invalid("the catalog answered \(http.statusCode)")
        }
        return data
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExtensionError.invalid("couldn't unpack the download"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? URLError, error.code == .notConnectedToInternet { return "No internet connection." }
        return error.localizedDescription
    }
}
