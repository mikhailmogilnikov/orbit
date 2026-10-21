import CryptoKit
import Foundation
@testable import OrbitAPI
import Testing

/// Orbit's extension registry (D224): the index, checked downloads, programs asked about.
@MainActor
@Suite struct ExtensionRegistryTests {
    @Test func theIndexKeepsTheNewestVersionThisOrbitCanUse() throws {
        let json = """
        {"schema": 1, "extensions": [
          {"id": "b", "name": "Beta", "version": "1.2.0", "archive": "https://example.com/b.tar.gz", "sha256": "AA"},
          {"id": "b", "name": "Beta", "version": "1.10.0", "archive": "https://example.com/b2.tar.gz", "sha256": "bb"},
          {"id": "b", "name": "Beta", "version": "2.0.0", "archive": "https://example.com/b3.tar.gz", "sha256": "cc", "minimumOrbitVersion": "9.0"},
          {"id": "a", "name": "Alpha", "version": "0.1.0", "archive": "https://example.com/a.zip", "sha256": "dd", "provides": ["tasks"]}
        ]}
        """
        let entries = try ExtensionRegistry.decode(Data(json.utf8), orbitVersion: "0.2.0")
        #expect(entries.map(\.id) == ["a", "b"])
        #expect(entries[1].version == "1.10.0")
        #expect(entries[0].runsPrograms)
        #expect(!entries[1].runsPrograms)
        #expect(ExtensionRegistry.isOlder("0.9.0", than: "0.10.0"))
    }

    @Test func aDownloadIsCheckedUnpackedFromItsFolderAndMarked() async throws {
        let work = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        // As GitHub packs a repository: one wrapping folder, the extension deeper in it.
        let package = work.appending(path: "repo-abc123/packages/kotlin")
        try write(#"{"id": "kotlin", "name": "Kotlin Tools", "version": "1.0.0"}"#, to: package.appending(path: "extension.json"))
        try write(#"{"tasks": [{"name": "build", "command": "gradle build"}]}"#, to: package.appending(path: "tasks.json"))
        try write(#"{"id": "k", "name": "K Agent", "command": {"executable": "k-agent", "arguments": ["--acp"]}}"#, to: package.appending(path: "agents/k.json"))
        let archive = work.appending(path: "kotlin.tar.gz")
        try tar(archive, from: work, folder: "repo-abc123")
        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()

        var entry = RegistryEntry(id: "kotlin", name: "Kotlin Tools", version: "1.0.0", archive: archive, sha256: digest)
        entry.path = "packages/kotlin"
        let destination = work.appending(path: "installed/kotlin")
        try await ExtensionRegistry.unpack(entry, into: destination)
        #expect(ExtensionRegistry.isFromRegistry(destination))
        #expect(Extensions.programs(in: destination) == [
            ExtensionProgram(kind: .agent, name: "K Agent", command: "k-agent --acp"),
            ExtensionProgram(kind: .task, name: "build", command: "gradle build"),
        ])

        var tampered = entry
        tampered.sha256 = String(repeating: "0", count: 64)
        await #expect(throws: (any Error).self) { try await ExtensionRegistry.unpack(tampered, into: work.appending(path: "x")) }

        var otherVersion = entry
        otherVersion.version = "2.0.0"
        await #expect(throws: (any Error).self) { try await ExtensionRegistry.unpack(otherVersion, into: work.appending(path: "y")) }

        var escaping = entry
        escaping.path = "../../.."
        await #expect(throws: (any Error).self) { try await ExtensionRegistry.unpack(escaping, into: work.appending(path: "z")) }
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "orbit-registry-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func tar(_ archive: URL, from root: URL, folder: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archive.path, "-C", root.path, folder]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
