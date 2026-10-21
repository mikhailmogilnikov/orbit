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
        case themes, iconThemes, snippets

        var zedName: String {
            switch self {
            case .themes: "themes"
            case .iconThemes: "icon-themes"
            case .snippets: "snippets"
            }
        }

        /// Themes and icons can be tried on before installing; snippets can't (D195).
        public var canTryOn: Bool { self != .snippets }
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
        // A package from Orbit's registry with the same id updates from there (D224).
        extensions.installed.first { $0.id == entry.id && !$0.isBuiltin && !ExtensionRegistry.isFromRegistry($0.directory) }
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

    /// Every theme extension, most downloaded first, for the theme selector;
    /// loaded once per launch.
    public private(set) var themeCatalog: [CatalogEntry] = []
    @ObservationIgnored private var themeCatalogTask: Task<Void, Never>?

    public func loadThemeCatalog() {
        guard themeCatalog.isEmpty, themeCatalogTask == nil else { return }
        themeCatalogTask = Task {
            themeCatalog = (try? await Self.fetch(query: "", kind: .themes)) ?? []
            if themeCatalog.isEmpty { themeCatalogTask = nil }
        }
    }

    // MARK: Samples

    /// Themes of catalog entries, for the color thumbnails in the list.
    public private(set) var samples: [String: [ColorTheme]] = [:]
    @ObservationIgnored private var sampleQueue: [CatalogEntry] = []
    @ObservationIgnored private var sampleRequested: Set<String> = []
    @ObservationIgnored private var sampleLoads = 0

    /// Loads `entry`'s themes for a thumbnail: from the try-on cache, else
    /// downloaded (a few at a time, once per version). Extensions that also
    /// carry language support are skipped: their archives are large.
    public func requestSample(_ entry: CatalogEntry) {
        let light: Set<String> = ["themes", "icon-themes", "snippets"]
        guard entry.provides.contains("themes"), entry.provides.allSatisfy(light.contains),
              sampleRequested.insert(entry.id).inserted else { return }
        if let cached = cachedPreview(entry) {
            samples[entry.id] = cached.colorThemes
            return
        }
        sampleQueue.append(entry)
        pumpSamples()
    }

    private func pumpSamples() {
        while sampleLoads < 4, !sampleQueue.isEmpty {
            let entry = sampleQueue.removeFirst()
            sampleLoads += 1
            Task {
                if let preview = try? await prepare(entry) { samples[entry.id] = preview.colorThemes }
                sampleLoads -= 1
                pumpSamples()
            }
        }
    }

    // MARK: Try on, install, uninstall

    @ObservationIgnored private var preparing: [String: Task<ExtensionPreview, Error>] = [:]

    private func cachedPreview(_ entry: CatalogEntry) -> ExtensionPreview? {
        let folder = Self.previewDirectory.appending(path: entry.id, directoryHint: .isDirectory)
        guard let preview = try? extensions.makePreview(of: folder), preview.manifest.version == entry.version else { return nil }
        return preview
    }

    /// `entry` unpacked in the cache and read, ready to show; one download at
    /// a time per extension (a thumbnail and a try-on can ask together).
    public func prepare(_ entry: CatalogEntry) async throws -> ExtensionPreview {
        if let cached = cachedPreview(entry) { return cached }
        if let running = preparing[entry.id] { return try await running.value }
        let task = Task {
            defer { preparing[entry.id] = nil }
            let folder = Self.previewDirectory.appending(path: entry.id, directoryHint: .isDirectory)
            try await Self.unpack(entry, into: folder)
            return try extensions.makePreview(of: folder)
        }
        preparing[entry.id] = task
        return try await task.value
    }

    /// Draws with `preview` until `install` or `endPreview`; `entry` is what
    /// Install installs (nil for an installed theme shown by the theme selector).
    public func show(_ preview: ExtensionPreview?, for entry: CatalogEntry?) {
        previewEntry = preview == nil ? nil : entry
        extensions.preview = preview
    }

    /// Downloads the extension into the cache and draws with it until
    /// `install` or `endPreview`.
    public func tryOn(_ entry: CatalogEntry) async {
        guard !busy.contains(entry.id) else { return }
        busy.insert(entry.id)
        failures[entry.id] = nil
        defer { busy.remove(entry.id) }
        do {
            show(Self.startingVariant(of: try await prepare(entry)), for: entry)
        } catch {
            failures[entry.id] = Self.describe(error)
        }
    }

    /// Starts on the variant for the mode the user is in, if there is one.
    public static func startingVariant(of preview: ExtensionPreview) -> ExtensionPreview {
        var preview = preview
        let dark = Preferences.shared.isDark
        preview.colorThemeID = (preview.colorThemes.first { $0.isDark == dark } ?? preview.colorThemes.first)?.id
        preview.iconThemeID = (preview.iconThemes.first { $0.isDark == dark } ?? preview.iconThemes.first)?.id
        return preview
    }

    public func endPreview() {
        show(nil, for: nil)
    }

    /// Installs (or updates) `entry`, reusing a cached download of the same
    /// version. While it is tried on — or with `pick` — its themes are picked.
    public func install(_ entry: CatalogEntry, pick: Bool = false) async {
        guard !busy.contains(entry.id) else { return }
        busy.insert(entry.id)
        failures[entry.id] = nil
        defer { busy.remove(entry.id) }
        do {
            // Only what draws can be read as a preview; snippets are unpacked as they are (D195).
            let staging: URL
            if entry.provides.contains("themes") || entry.provides.contains("icon-themes") {
                staging = try await prepare(entry).directory
            } else {
                staging = Self.previewDirectory.appending(path: entry.id, directoryHint: .isDirectory)
                try await Self.unpack(entry, into: staging)
            }
            let destination = Extensions.userDirectory.appending(path: entry.id, directoryHint: .isDirectory)
            let manager = FileManager.default
            try manager.createDirectory(at: Extensions.userDirectory, withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: staging, to: destination)
            extensions.reload()
            if pick || extensions.preview?.manifest.id == entry.id { adopt(entry) }
        } catch {
            failures[entry.id] = Self.describe(error)
        }
    }

    /// Updates every installed catalog extension with a newer version
    /// (Settings → General → Keep Up to Date, D186), once a day.
    public func updateInstalled() async {
        guard Preferences.shared.autoUpdatesExtensions, Preferences.shared.claimDailyCheck("extensions") else { return }
        var seen = Set<String>()
        for kind in Kind.allCases {
            guard let entries = try? await Self.fetch(query: "", kind: kind) else { continue }
            for entry in entries where seen.insert(entry.id).inserted && hasUpdate(entry) {
                await install(entry)
            }
        }
    }

    /// Picks the installed extension's themes (the ones tried on, else the
    /// current mode's, with their light/dark partner), then ends a preview of it.
    private func adopt(_ entry: CatalogEntry) {
        let preview = extensions.preview?.manifest.id == entry.id ? extensions.preview : nil
        let family = extensions.colorThemes.filter { $0.extensionID == entry.id }
        let dark = Preferences.shared.isDark
        let tried = preview?.colorTheme.flatMap { tried in family.first { $0.id == tried.id } }
        if let theme = tried ?? family.first(where: { $0.isDark == dark }) ?? family.first {
            extensions.choose(theme, from: family)
        }
        if let icons = preview?.iconTheme {
            let preferences = Preferences.shared
            preferences.lightIconThemeID = icons.id
            preferences.darkIconThemeID = icons.id
        }
        if preview != nil { endPreview() }
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
