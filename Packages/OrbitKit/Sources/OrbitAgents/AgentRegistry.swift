import CryptoKit
import Foundation
import OrbitACP
import OrbitAPI

/// An agent in the ACP registry (agentclientprotocol.com/registry), the list
/// Zed and JetBrains IDEs install agents from.
struct RegistryAgent: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var version: String
    var description: String?
    var repository: String?
    var website: String?
    var authors: [String]?
    var icon: String?
    var distribution: Distribution

    struct Distribution: Decodable, Hashable, Sendable {
        var binary: [String: Binary]?
        var npx: Package?
        var uvx: Package?
    }

    struct Binary: Decodable, Hashable, Sendable {
        var archive: String
        var sha256: String?
        var cmd: String
        var args: [String]?
        var env: [String: String]?
    }

    struct Package: Decodable, Hashable, Sendable {
        var package: String
        var args: [String]?
        var env: [String: String]?
    }

    static var platform: String {
        #if arch(arm64)
        "darwin-aarch64"
        #else
        "darwin-x86_64"
        #endif
    }

    /// How Orbit runs it on this Mac: a download needs nothing else installed,
    /// so it wins over `npx` (Node.js) and `uvx` (uv).
    enum Method: Hashable, Sendable {
        case binary(Binary)
        case npx(Package)
        case uvx(Package)

        var name: String {
            switch self {
            case .binary: "binary"
            case .npx: "npx"
            case .uvx: "uvx"
            }
        }
    }

    var method: Method? {
        if let binary = distribution.binary?[Self.platform] { return .binary(binary) }
        if let npx = distribution.npx { return .npx(npx) }
        if let uvx = distribution.uvx { return .uvx(uvx) }
        return nil
    }
}

/// Lists the ACP registry and installs agents from it into `~/.orbit/agents`
/// (D52). Nothing is built in: Claude Code, Codex and the rest are installed
/// the same way, and only what's installed shows up in Orbit.
@MainActor
@Observable
final class AgentRegistry {
    nonisolated static let indexURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!

    private(set) var agents: [RegistryAgent] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Agent ids being installed or updated.
    private(set) var busy: Set<String> = []
    private(set) var failures: [String: String] = [:]

    /// Fetches the index; keeps the last good list on failure.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            struct Index: Decodable { var agents: [RegistryAgent] }
            let data = try await Self.download(Self.indexURL)
            agents = try JSONDecoder().decode(Index.self, from: data).agents
                .filter { $0.method != nil }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func agent(for provider: AgentProvider) -> RegistryAgent? {
        agents.first { $0.id == provider.id }
    }

    func hasUpdate(_ provider: AgentProvider) -> Bool {
        guard let installed = provider.registry?.version, let agent = agent(for: provider) else { return false }
        return agent.version != installed
    }

    /// Installs (or updates) `agent`; true when its manifest was written.
    @discardableResult
    func install(_ agent: RegistryAgent) async -> Bool {
        guard !busy.contains(agent.id), let method = agent.method else { return false }
        busy.insert(agent.id)
        failures[agent.id] = nil
        defer { busy.remove(agent.id) }
        do {
            let provider = try await Self.install(agent, method: method)
            let data = try JSONEncoder.pretty.encode(provider)
            try data.write(to: AgentProvider.manifestFile(for: agent.id), options: .atomic)
            return true
        } catch {
            failures[agent.id] = error.localizedDescription
            return false
        }
    }

    /// Moves the manifest and the agent's folder to the Trash.
    func uninstall(_ provider: AgentProvider) {
        let manager = FileManager.default
        for url in [AgentProvider.manifestFile(for: provider.id), AgentProvider.directory(for: provider.id)]
        where manager.fileExists(atPath: url.path) {
            do { try manager.trashItem(at: url, resultingItemURL: nil) } catch { failures[provider.id] = error.localizedDescription }
        }
    }

    // MARK: Installing

    private nonisolated static func install(_ agent: RegistryAgent, method: RegistryAgent.Method) async throws -> AgentProvider {
        let manager = FileManager.default
        let folder = AgentProvider.directory(for: agent.id)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let command: AgentCommand
        switch method {
        case .npx(let package):
            // -y: npx would otherwise ask before downloading the package, and nobody can answer.
            command = AgentCommand(executable: "npx", arguments: ["-y", package.package] + (package.args ?? []), environment: package.env ?? [:])
        case .uvx(let package):
            command = AgentCommand(executable: "uvx", arguments: [package.package] + (package.args ?? []), environment: package.env ?? [:])
        case .binary(let binary):
            let executable = try await installBinary(binary, into: folder)
            command = AgentCommand(executable: executable.path, arguments: binary.args ?? [], environment: binary.env ?? [:])
        }

        if let icon = agent.icon, let url = URL(string: icon, relativeTo: indexURL),
           let data = try? await download(url), data.count < 256 * 1024 {
            try? data.write(to: folder.appendingPathComponent("icon.svg"), options: .atomic)
        }

        return AgentProvider(
            id: agent.id,
            name: agent.name,
            command: command,
            registry: AgentProvider.RegistryInstall(version: agent.version, description: agent.description, distribution: method.name)
        )
    }

    /// Downloads, checks and unpacks the archive into `folder/bin`, replacing
    /// an older version; returns the executable.
    private nonisolated static func installBinary(_ binary: RegistryAgent.Binary, into folder: URL) async throws -> URL {
        guard let url = URL(string: binary.archive) else { throw RegistryError("the download link is invalid") }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("orbit-agent-\(UUID().uuidString)", isDirectory: true)
        let unpacked = work.appendingPathComponent("bin", isDirectory: true)
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }

        let data = try await download(url)
        if let expected = binary.sha256?.lowercased() {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw RegistryError("the download doesn't match its checksum") }
        }
        let name = url.lastPathComponent.lowercased()
        let archives = [".zip", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2"]
        if archives.contains(where: { name.hasSuffix($0) }) {
            let archive = work.appendingPathComponent(url.lastPathComponent)
            try data.write(to: archive)
            // bsdtar reads zip as well as the tarballs.
            try await run("/usr/bin/tar", ["-xf", archive.path, "-C", unpacked.path])
        } else {
            try data.write(to: unpacked.appendingPathComponent(cleanPath(binary.cmd)))
        }

        let destination = folder.appendingPathComponent("bin", isDirectory: true)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: unpacked, to: destination)
        let executable = destination.appendingPathComponent(cleanPath(binary.cmd))
        guard manager.fileExists(atPath: executable.path) else { throw RegistryError("the download has no \(binary.cmd)") }
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private nonisolated static func cleanPath(_ cmd: String) -> String {
        cmd.hasPrefix("./") ? String(cmd.dropFirst(2)) : cmd
    }

    private nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Orbit", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RegistryError("the server answered \(http.statusCode)")
        }
        return data
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) async throws {
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
                    continuation.resume(throwing: RegistryError("couldn't unpack the download"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

struct RegistryError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
