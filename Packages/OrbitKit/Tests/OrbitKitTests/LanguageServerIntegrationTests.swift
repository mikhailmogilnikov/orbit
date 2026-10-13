import Foundation
@testable import OrbitACP
@testable import OrbitAPI
@testable import OrbitLanguages
import Testing
#if canImport(Glibc)
import Glibc
#endif

/// Each supported language against its real server, the way the editor uses
/// it (D55): errors arrive at the right UTF-16 spot, follow edits, hover and
/// go to definition answer, and the process is gone after shutdown. A server
/// that isn't installed skips its test. Adding a language = a fixture folder
/// in `Fixtures/Languages` + a `LanguageCase`.
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct LanguageServerIntegrationTests {
    @Test(.enabled(if: LanguageCase.swift.isAvailable))
    func swift() async throws { try await exercise(.swift) }

    /// TypeScript 7 is native: the project's `tsc --lsp`, pull diagnostics.
    @Test(.enabled(if: LanguageCase.typeScript7.isAvailable))
    func typeScript7InProject() async throws { try await exercise(.typeScript7) }

    /// TypeScript 5/6 go through typescript-language-server over tsserver.
    @Test(.enabled(if: LanguageCase.typeScript5.isAvailable))
    func typeScript5InProject() async throws { try await exercise(.typeScript5) }

    /// No TypeScript in the project: the latest one through npx.
    @Test(.enabled(if: LanguageCase.typeScriptBare.isAvailable))
    func typeScriptWithoutProjectInstall() async throws { try await exercise(.typeScriptBare) }

    /// The alert shows why a server died: its last stderr lines.
    @Test func serverDyingInHandshakeSaysWhy() async throws {
        let config = LanguageServerConfig(
            id: "broken", name: "Broken", languages: ["broken": "broken"],
            resolve: { _, _ in AgentCommand(executable: "/bin/sh", arguments: ["-c", "echo 'no tsserver.js here' >&2; exit 3"]) },
            missing: ""
        )
        let server = LanguageServer(config: config, root: FileManager.default.temporaryDirectory)
        #expect(await server.start(environment: Task { ProcessInfo.processInfo.environment }) == false)
        guard case .failed(let message) = server.state else {
            Issue.record("expected a failure, got \(server.state)")
            return
        }
        #expect(message.contains("no tsserver.js here"))
    }

    @Test func missingServerSaysWhatToInstall() async {
        let config = LanguageServerConfig(
            id: "absent", name: "Absent", languages: ["absent": "absent"],
            resolve: { _, _ in nil }, missing: "Install the absent server."
        )
        let server = LanguageServer(config: config, root: FileManager.default.temporaryDirectory)
        #expect(await server.start(environment: Task { [:] }) == false)
        #expect(server.state == .unavailable("Install the absent server."))
    }

    // MARK: The scenario

    private func exercise(_ language: LanguageCase) async throws {
        let root = try language.makeProject()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = LanguageServer(config: language.config, root: root)
        let started = await server.start(environment: Task { ProcessInfo.processInfo.environment })
        try #require(started, "\(language.name) didn't start: \(server.state)")
        let pid = try #require(server.processIdentifier)

        // Opening the file reports its error where it is (UTF-16, after an emoji and Cyrillic).
        let main = root.appendingPathComponent(language.main)
        var text = try String(contentsOf: main, encoding: .utf8)
        server.sync(main, text: text)
        let error = try await firstError(server, main, language.timeout) { _ in true }
        #expect(error.message.contains(language.errorMessage), "\(error.message)")
        #expect(error.range.start == Self.position(of: language.errorAt, in: text))

        // Hover and go to definition on the call into the other file.
        let call = try #require(Self.position(of: language.callAt, in: text, inside: true))
        let hover = await server.hover(at: call, in: main)
        #expect(hover?.markdown.contains(language.hoverContains) == true, "\(hover?.markdown ?? "no hover")")
        let definitions = await server.definition(at: call, in: main)
        let target = root.appendingPathComponent(language.definitionFile)
        let targetText = try String(contentsOf: target, encoding: .utf8)
        let expected = try #require(Self.position(of: language.definitionAt, in: targetText))
        #expect(definitions.contains { $0.url.path == target.standardizedFileURL.path && $0.range.start.line == expected.line },
                "\(definitions)")

        // An edit above moves the error down with it (incremental sync).
        text = "\n\n" + text
        server.sync(main, text: text)
        let moved = try await firstError(server, main, language.timeout) { $0.range.start.line == error.range.start.line + 2 }
        #expect(moved.range.start.character == error.range.start.character)

        // Fixing it clears it.
        text = text.replacingOccurrences(of: language.fix.from, with: language.fix.to)
        server.sync(main, text: text)
        try await eventually(language.timeout, "the error to go away") {
            !(server.diagnostics[main.standardizedFileURL] ?? []).contains { $0.severity == .error }
        }

        // Nothing keeps running after shutdown, including what npx started.
        let processes = [pid] + Self.descendants(of: pid)
        server.shutdown()
        try await eventually(.seconds(10), "the server's processes \(processes) to exit") {
            processes.allSatisfy { kill($0, 0) != 0 }
        }
    }

    private func firstError(
        _ server: LanguageServer, _ url: URL, _ timeout: Duration, where matches: @escaping (Diagnostic) -> Bool
    ) async throws -> Diagnostic {
        var found: Diagnostic?
        try await eventually(timeout, "an error in \(url.lastPathComponent); state \(server.state)") {
            found = server.diagnostics[url.standardizedFileURL]?.first { $0.severity == .error && matches($0) }
            return found != nil
        }
        return try #require(found)
    }

    private func eventually(_ timeout: Duration, _ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func descendants(of pid: Int32) -> [Int32] {
        guard let output = try? Self.run("/usr/bin/pgrep", ["-P", String(pid)]) else { return [] }
        let children = output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        return children + children.flatMap { descendants(of: $0) }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Where `needle` starts in `text`, as a server counts it; `inside` points into it.
    static func position(of needle: String, in text: String, inside: Bool = false) -> SourcePosition? {
        let string = text as NSString
        let range = string.range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return SourcePosition(offset: range.location + (inside ? 1 : 0), in: SourcePosition.lineStarts(of: string))
    }
}

/// A language, its fixture project and what its server must say about it.
struct LanguageCase: Sendable {
    var name: String
    var fixture: String
    var config: LanguageServerConfig
    /// Installed into the fixture's node_modules (cached between runs).
    var npmPackages: [String] = []
    var main: String
    var errorMessage: String
    var errorAt: String
    var callAt: String
    var hoverContains: String
    var definitionFile: String
    var definitionAt: String
    var fix: (from: String, to: String)
    /// Cold servers index the project first (SourceKit-LSP builds the package).
    var timeout: Duration = .seconds(60)

    static let swift = LanguageCase(
        name: "Swift", fixture: "swift", config: .swift,
        main: "Sources/Demo/main.swift",
        errorMessage: "convert value of type 'String' to specified type 'Int'",
        errorAt: "message\n",
        callAt: "greet()",
        hoverContains: "func greet() -> String",
        definitionFile: "Sources/Demo/Greeter.swift", definitionAt: "greet()",
        fix: ("let count: Int", "let count: String"),
        timeout: .seconds(180)
    )

    private static let typeScript = LanguageCase(
        name: "TypeScript", fixture: "typescript", config: .typescript,
        main: "src/main.ts",
        errorMessage: "Type 'string' is not assignable to type 'number'",
        errorAt: "count: number",
        callAt: "greet()",
        hoverContains: "greet(): string",
        definitionFile: "src/greeter.ts", definitionAt: "greet()",
        fix: ("count: number", "count: string")
    )

    static let typeScript7 = with(typeScript) { $0.name = "TypeScript 7"; $0.npmPackages = ["typescript@7"] }
    static let typeScript5 = with(typeScript) {
        $0.name = "TypeScript 5"
        $0.npmPackages = ["typescript@5", "typescript-language-server@5"]
    }
    static let typeScriptBare = with(typeScript) { $0.name = "TypeScript (npx)" }

    private static func with(_ base: LanguageCase, _ change: (inout LanguageCase) -> Void) -> LanguageCase {
        var copy = base
        change(&copy)
        return copy
    }

    var isAvailable: Bool {
        let environment = ProcessInfo.processInfo.environment
        if !npmPackages.isEmpty { return Shell.which("npm", in: environment) != nil }
        return config.resolve(Self.fixtures.appendingPathComponent(fixture), environment) != nil
    }

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Languages")

    /// A fresh copy of the fixture, opened through a symlink like macOS's
    /// /var → /private/var: servers answer with the real path.
    func makeProject() throws -> URL {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("orbit-lsp-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        try manager.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: real)
        if !npmPackages.isEmpty {
            try manager.createSymbolicLink(at: real.appendingPathComponent("node_modules"), withDestinationURL: try installedPackages())
        }
        let link = base.appendingPathComponent("project")
        try manager.createSymbolicLink(at: link, withDestinationURL: real)
        return link
    }

    /// One install per package set, reused by later runs.
    private func installedPackages() throws -> URL {
        let key = npmPackages.joined(separator: "+").replacingOccurrences(of: "/", with: "_")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-lsp-npm/\(key)")
        let modules = directory.appendingPathComponent("node_modules")
        if FileManager.default.fileExists(atPath: modules.appendingPathComponent(".installed").path) { return modules }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        let npm = try #require(Shell.which("npm", in: environment))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = ["install", "--no-save", "--no-audit", "--no-fund", "--prefix", directory.path] + npmPackages
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "npm install \(npmPackages) failed")
        _ = FileManager.default.createFile(atPath: modules.appendingPathComponent(".installed").path, contents: nil)
        return modules
    }
}
