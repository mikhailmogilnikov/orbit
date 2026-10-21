import CryptoKit
import Foundation
import Observation

/// One version of an extension in Orbit's registry (D224): where its archive
/// is, its hash, and enough to list it before downloading.
public struct RegistryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var authors: [String]
    public var repository: String?
    /// A .tar.gz or .zip; GitHub's archive of a tag or commit works.
    public var archive: URL
    public var sha256: String
    /// The extension's folder inside the archive, when it isn't the root
    /// (or the single folder GitHub wraps it in).
    public var path: String?
    /// `themes`, `icon-themes`, `snippets`, `agents`, `language-servers`, `tasks`.
    public var provides: [String]
    public var minimumOrbitVersion: String?

    public init(id: String, name: String, version: String, archive: URL, sha256: String, provides: [String] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.authors = []
        self.archive = archive
        self.sha256 = sha256
        self.provides = provides
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, authors, repository, archive, sha256, path, provides, minimumOrbitVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try container.decode(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        authors = try container.decodeIfPresent([String].self, forKey: .authors) ?? []
        repository = try container.decodeIfPresent(String.self, forKey: .repository)
        archive = try container.decode(URL.self, forKey: .archive)
        sha256 = try container.decode(String.self, forKey: .sha256).lowercased()
        path = try container.decodeIfPresent(String.self, forKey: .path)
        provides = try container.decodeIfPresent([String].self, forKey: .provides) ?? []
        minimumOrbitVersion = try container.decodeIfPresent(String.self, forKey: .minimumOrbitVersion)
    }

    /// Agents, language servers and tasks start programs on the Mac.
    public var runsPrograms: Bool { !Set(provides).isDisjoint(with: ["agents", "language-servers", "tasks"]) }
}

/// Something a package can start (D195): shown on its page and asked about
/// before a download that brings it is installed (D224).
public struct ExtensionProgram: Sendable, Hashable {
    public enum Kind: Sendable { case agent, languageServer, task }
    public var kind: Kind
    public var name: String
    public var command: String
}

extension Extensions {
    /// Every program the extension in `folder` can start, read from its files.
    nonisolated public static func programs(in folder: URL) -> [ExtensionProgram] {
        func json(_ url: URL) -> [String: Any]? {
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.json5Allowed]) as? [String: Any] }
        }
        var programs: [ExtensionProgram] = []
        let agents = (try? FileManager.default.contentsOfDirectory(at: folder.appending(path: "agents"), includingPropertiesForKeys: nil)) ?? []
        for file in agents.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let object = json(file)
            let command = object?["command"] as? [String: Any]
            let line = ([command?["executable"] as? String ?? "?"] + (command?["arguments"] as? [String] ?? [])).joined(separator: " ")
            programs.append(ExtensionProgram(kind: .agent, name: object?["name"] as? String ?? file.deletingPathExtension().lastPathComponent, command: line))
        }
        for server in json(folder.appending(path: "language_servers.json"))?["servers"] as? [[String: Any]] ?? [] {
            let install = (server["install"] as? [String: Any])?["mason"] as? String
            let command = server["command"] as? String ?? install.map { "Mason: \($0)" } ?? "?"
            programs.append(ExtensionProgram(kind: .languageServer, name: server["name"] as? String ?? "Language server", command: command))
        }
        for task in json(folder.appending(path: "tasks.json"))?["tasks"] as? [[String: Any]] ?? [] {
            programs.append(ExtensionProgram(kind: .task, name: task["name"] as? String ?? "Task", command: task["command"] as? String ?? "?"))
        }
        return programs
    }
}

/// Orbit's own extension registry (D224): a GitHub repository whose
/// `index.json` lists packages Zed's catalog can't carry — agents, language
/// servers, tasks — and any others. Archives are checked against their hash;
/// a package that starts programs is installed only after the user agrees.
@MainActor
@Observable
public final class ExtensionRegistry {
    public static let shared = ExtensionRegistry()

    public private(set) var entries: [RegistryEntry] = []
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public private(set) var busy: Set<String> = []
    public private(set) var failures: [String: String] = [:]

    /// The index; `orbit.extensionRegistryURL` points Orbit at a fork or a local file.
    nonisolated static var indexURL: URL {
        UserDefaults.standard.string(forKey: "orbit.extensionRegistryURL").flatMap(URL.init(string:))
            ?? URL(string: "https://raw.githubusercontent.com/mikhailmogilnikov/orbit-extensions/main/index.json")!
    }

    /// Written into a package installed from here, so Zed's catalog leaves it
    /// alone and updates come from here.
    nonisolated static let markerName = ".orbit-registry.json"

    @ObservationIgnored private var loaded = false

    private init() {}

    private var extensions: Extensions { .shared }

    // MARK: Listing

    /// Fetches the index (once per launch unless `force`); falls back to the
    /// last one fetched when offline.
    public func refresh(force: Bool = false) async {
        guard !isLoading, force || !loaded else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let data = try await Self.download(Self.indexURL)
            entries = try Self.decode(data, orbitVersion: Self.orbitVersion)
            loaded = true
            try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: Self.cachedIndex)
        } catch {
            if entries.isEmpty, let data = try? Data(contentsOf: Self.cachedIndex),
               let cached = try? Self.decode(data, orbitVersion: Self.orbitVersion) {
                entries = cached
            } else {
                loadError = Self.describe(error)
            }
        }
    }

    /// The index's entries this version of Orbit can use, by name; the newest
    /// usable version when an id is listed more than once.
    nonisolated static func decode(_ data: Data, orbitVersion: String?) throws -> [RegistryEntry] {
        struct Index: Decodable { var extensions: [RegistryEntry] }
        let all = try JSONDecoder().decode(Index.self, from: data).extensions
        var newest: [String: RegistryEntry] = [:]
        for entry in all {
            if let minimum = entry.minimumOrbitVersion, let orbitVersion, isOlder(orbitVersion, than: minimum) { continue }
            if let other = newest[entry.id], !isOlder(other.version, than: entry.version) { continue }
            newest[entry.id] = entry
        }
        return newest.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func isOlder(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedAscending
    }

    nonisolated static var orbitVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The installed package `entry` would replace, when it came from here.
    public func installed(_ entry: RegistryEntry) -> InstalledExtension? {
        extensions.installed.first { $0.id == entry.id && !$0.isBuiltin && Self.isFromRegistry($0.directory) }
    }

    /// Something else already has the id: a package of the user's or from Zed's catalog.
    public func isTaken(_ entry: RegistryEntry) -> Bool {
        extensions.installed.contains { $0.id == entry.id } && installed(entry) == nil
    }

    public func hasUpdate(_ entry: RegistryEntry) -> Bool {
        guard let installed = installed(entry) else { return false }
        return Self.isOlder(installed.manifest.version, than: entry.version)
    }

    nonisolated static func isFromRegistry(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: markerName).path)
    }

    // MARK: Install

    /// Asked before installing a package that starts programs, with them;
    /// false cancels. An update asks only when its programs changed.
    public typealias Confirm = @MainActor (RegistryEntry, [ExtensionProgram]) async -> Bool

    /// Downloads, checks and installs (or updates) `entry`.
    public func install(_ entry: RegistryEntry, confirm: Confirm) async {
        guard !busy.contains(entry.id) else { return }
        busy.insert(entry.id)
        failures[entry.id] = nil
        defer { busy.remove(entry.id) }
        do {
            let staging = Self.cacheDirectory.appending(path: "Downloads/\(entry.id)", directoryHint: .isDirectory)
            try await Self.unpack(entry, into: staging)
            let programs = Extensions.programs(in: staging)
            let current = installed(entry).map { Extensions.programs(in: $0.directory) }
            if !programs.isEmpty, programs != current, !(await confirm(entry, programs)) {
                try? FileManager.default.removeItem(at: staging)
                return
            }
            try Self.move(staging, to: Extensions.userDirectory.appending(path: entry.id, directoryHint: .isDirectory))
            extensions.reload()
        } catch {
            failures[entry.id] = Self.describe(error)
        }
    }

    /// Updates packages from here once a day (Settings → General → Keep Up to
    /// Date, D186), except those whose update starts other programs: they wait
    /// for Update, which asks.
    public func updateInstalled() async {
        guard Preferences.shared.autoUpdatesExtensions, Preferences.shared.claimDailyCheck("registry") else { return }
        await refresh(force: true)
        for entry in entries where hasUpdate(entry) {
            await install(entry) { _, _ in false }
        }
    }

    // MARK: Download

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "dev.orbit.app/ExtensionRegistry", directoryHint: .isDirectory)
    }

    private static var cachedIndex: URL { cacheDirectory.appending(path: "index.json") }

    /// Downloads `entry`'s archive, checks its hash and leaves the extension
    /// folder in `folder`, marked as coming from here.
    nonisolated static func unpack(_ entry: RegistryEntry, into folder: URL) async throws {
        let data = try await download(entry.archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else {
            throw ExtensionError.invalid("the download doesn't match the registry's checksum")
        }

        let manager = FileManager.default
        let work = manager.temporaryDirectory.appending(path: "orbit-registry-\(UUID().uuidString)", directoryHint: .isDirectory)
        let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let archive = work.appending(path: "archive")
        try data.write(to: archive)
        // bsdtar reads .tar.gz and .zip alike.
        try await run("/usr/bin/tar", ["-xf", archive.path, "-C", unpacked.path])

        var root = unpacked
        let children = (try? manager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        if !hasManifest(unpacked), children.count == 1 { root = children[0] }
        if let path = entry.path {
            root = root.appending(path: path, directoryHint: .isDirectory).standardizedFileURL
            guard root.path.hasPrefix(unpacked.standardizedFileURL.path + "/") else { throw ExtensionError.invalid("the registry's path leaves the archive") }
        }
        let folderRoot = root
        guard let manifest = try await MainActor.run(body: { try Extensions.load(folderRoot, isBuiltin: false)?.entry.manifest }) else {
            throw ExtensionError.invalid("the download has no extension manifest")
        }
        guard manifest.id == entry.id, manifest.version == entry.version else {
            throw ExtensionError.invalid("the download is \(manifest.id) \(manifest.version), not \(entry.id) \(entry.version)")
        }
        let marker = ["version": entry.version, "sha256": entry.sha256, "archive": entry.archive.absoluteString]
        try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: markerName))
        try move(root, to: folder)
    }

    nonisolated private static func hasManifest(_ folder: URL) -> Bool {
        ["extension.json", "extension.toml"].contains { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    nonisolated private static func move(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: source, to: destination)
    }

    nonisolated private static func download(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Orbit", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExtensionError.invalid("\(url.host() ?? "the server") answered \(http.statusCode)")
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

    nonisolated private static func describe(_ error: Error) -> String {
        if let error = error as? URLError, error.code == .notConnectedToInternet { return "No internet connection." }
        return error.localizedDescription
    }
}
