import Foundation
import Observation
import OrbitACP
import OrbitAPI

/// One running language server for one project (D54): it starts on the first
/// open file of its language, keeps those files in sync with incremental
/// changes, and is shut down when none has been open for a while.
@MainActor
@Observable
final class LanguageServer {
    let config: LanguageServerConfig
    let root: URL
    private(set) var state: LanguageServerState = .starting
    private(set) var diagnostics: [URL: [Diagnostic]] = [:]

    @ObservationIgnored private var connection: JSONRPCConnection?
    @ObservationIgnored private var started: Task<Bool, Never>?
    /// What the server has of each open file: its version and text.
    @ObservationIgnored private var documents: [URL: (version: Int, text: String)] = [:]
    @ObservationIgnored private var incremental = true
    @ObservationIgnored private var isShuttingDown = false

    init(config: LanguageServerConfig, root: URL) {
        self.config = config
        self.root = root
    }

    var openDocuments: Set<URL> { Set(documents.keys) }

    /// Starts the process and the LSP handshake once; true when it's usable.
    func start(environment: Task<[String: String], Never>) async -> Bool {
        if let started { return await started.value }
        let task = Task { await launch(environment: await environment.value) }
        started = task
        return await task.value
    }

    private func launch(environment: [String: String]) async -> Bool {
        let config = config, root = root
        let command = await Task.detached(priority: .userInitiated) { config.resolve(root, environment) }.value
        guard let command else {
            state = .unavailable(config.missing)
            return false
        }
        var env = environment
        env.merge(command.environment) { _, new in new }
        let connection = JSONRPCConnection(
            executable: URL(fileURLWithPath: command.executable),
            arguments: command.arguments,
            environment: env,
            currentDirectory: root,
            framing: .contentLength,
            onNotification: { [weak self] method, params in
                Task { @MainActor in self?.handleNotification(method, params) }
            },
            onRequest: { method, params in try Self.answer(method, params, root: root) },
            onExit: { [weak self] status, stderr in
                Task { @MainActor in self?.didExit(status: status, stderr: stderr) }
            }
        )
        do {
            try connection.start()
            self.connection = connection
            let result = try await connection.request("initialize", initializeParams)
            // `change`: 1 full text, 2 incremental (an object or a bare number).
            let sync = result["capabilities"]?["textDocumentSync"]
            incremental = (sync?["change"]?.int ?? sync?.int ?? 2) == 2
            connection.notify("initialized")
            state = .running
            return true
        } catch {
            state = .failed(error.localizedDescription)
            connection.terminate()
            self.connection = nil
            return false
        }
    }

    private var initializeParams: JSONValue {
        let rootURI = JSONValue.string(root.absoluteString)
        return [
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "Orbit"],
            "rootUri": rootURI,
            "workspaceFolders": [["uri": rootURI, "name": .string(root.lastPathComponent)]],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "textDocument": [
                    "synchronization": ["dynamicRegistration": false],
                    "publishDiagnostics": ["relatedInformation": false],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "definition": ["linkSupport": true],
                ],
                "workspace": ["workspaceFolders": true, "configuration": true],
            ],
        ]
    }

    /// Server-to-client requests we have to answer so servers don't stall.
    private nonisolated static func answer(_ method: String, _ params: JSONValue, root: URL) throws -> JSONValue {
        switch method {
        case "workspace/configuration":
            // No settings of our own: the server's defaults for each asked section.
            return .array(Array(repeating: .null, count: params["items"]?.array?.count ?? 0))
        case "workspace/workspaceFolders":
            return [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]]
        case "window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability",
             "window/showMessageRequest", "workspace/diagnostic/refresh", "workspace/semanticTokens/refresh":
            return .null
        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    private func handleNotification(_ method: String, _ params: JSONValue) {
        guard method == "textDocument/publishDiagnostics",
              let uri = params["uri"]?.string, let url = Self.fileURL(uri) else { return }
        let parsed = (params["diagnostics"]?.array ?? []).compactMap(Self.diagnostic)
        if diagnostics[url] != parsed { diagnostics[url] = parsed }
    }

    /// Servers re-encode URIs their own way; compare files by path.
    nonisolated static func fileURL(_ uri: String) -> URL? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }

    nonisolated static func diagnostic(_ value: JSONValue) -> Diagnostic? {
        guard let range = range(value["range"]), let message = value["message"]?.string else { return nil }
        return Diagnostic(
            range: range,
            severity: value["severity"]?.int.flatMap(Diagnostic.Severity.init(rawValue:)) ?? .error,
            message: message,
            source: value["source"]?.string
        )
    }

    nonisolated static func range(_ value: JSONValue?) -> SourceRange? {
        guard let value, let start = position(value["start"]), let end = position(value["end"]) else { return nil }
        return SourceRange(start: start, end: end)
    }

    nonisolated static func position(_ value: JSONValue?) -> SourcePosition? {
        guard let line = value?["line"]?.int, let character = value?["character"]?.int else { return nil }
        return SourcePosition(line: line, character: character)
    }

    private func didExit(status: Int32, stderr: String) {
        connection = nil
        documents.removeAll()
        diagnostics.removeAll()
        guard !isShuttingDown else { return }
        let reason = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exited with status \(status)"
        state = .failed("\(config.name) stopped: \(reason)")
    }

    // MARK: Documents

    /// Opens the file on the server or sends what changed since last time.
    func sync(_ url: URL, text: String) {
        guard let connection, state == .running else { return }
        let identifier: JSONValue = .string(url.absoluteString)
        guard let current = documents[url] else {
            documents[url] = (1, text)
            connection.notify("textDocument/didOpen", ["textDocument": [
                "uri": identifier, "languageId": .string(config.languageID(for: url)), "version": 1, "text": .string(text),
            ]])
            return
        }
        guard current.text != text else { return }
        let version = current.version + 1
        documents[url] = (version, text)
        let change: JSONValue
        if incremental, let edit = TextChange(from: current.text, to: text) {
            change = ["range": Self.json(edit.range), "text": .string(edit.text)]
        } else {
            change = ["text": .string(text)]
        }
        connection.notify("textDocument/didChange", [
            "textDocument": ["uri": identifier, "version": .number(Double(version))],
            "contentChanges": [change],
        ])
    }

    func close(_ url: URL) {
        guard documents.removeValue(forKey: url) != nil else { return }
        connection?.notify("textDocument/didClose", ["textDocument": ["uri": .string(url.absoluteString)]])
        diagnostics[url] = nil
    }

    // MARK: Queries

    func hover(at position: SourcePosition, in url: URL) async -> HoverInfo? {
        guard let connection, documents[url] != nil,
              let result = try? await connection.request("textDocument/hover", Self.positionParams(url, position)),
              !result.isNull else { return nil }
        let markdown = Self.markdown(result["contents"])
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return HoverInfo(markdown: markdown, range: Self.range(result["range"]))
    }

    func definition(at position: SourcePosition, in url: URL) async -> [SourceLocation] {
        guard let connection, documents[url] != nil,
              let result = try? await connection.request("textDocument/definition", Self.positionParams(url, position)) else { return [] }
        let items = result.array ?? (result.isNull ? [] : [result])
        return items.compactMap { item in
            // Location, or LocationLink (targetUri / targetSelectionRange).
            guard let uri = item["uri"]?.string ?? item["targetUri"]?.string, let target = Self.fileURL(uri),
                  let range = Self.range(item["range"] ?? item["targetSelectionRange"] ?? item["targetRange"]) else { return nil }
            return SourceLocation(url: target, range: range)
        }
    }

    /// MarkupContent, a MarkedString or an array of them, as markdown.
    nonisolated static func markdown(_ contents: JSONValue?) -> String {
        guard let contents else { return "" }
        if let text = contents.string { return text }
        if let parts = contents.array { return parts.map { markdown($0) }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
        if let value = contents["value"]?.string {
            // MarkedString with a language is a code block; MarkupContent has a `kind`.
            if let language = contents["language"]?.string { return "```\(language)\n\(value)\n```" }
            return value
        }
        return ""
    }

    private static func positionParams(_ url: URL, _ position: SourcePosition) -> JSONValue {
        ["textDocument": ["uri": .string(url.absoluteString)], "position": json(position)]
    }

    private static func json(_ position: SourcePosition) -> JSONValue {
        ["line": .number(Double(position.line)), "character": .number(Double(position.character))]
    }

    private static func json(_ range: SourceRange) -> JSONValue {
        ["start": json(range.start), "end": json(range.end)]
    }

    // MARK: Shutdown

    /// Polite `shutdown` + `exit`, then the process is ended if it lingers.
    func shutdown() {
        isShuttingDown = true
        started?.cancel()
        guard let connection else { return }
        self.connection = nil
        documents.removeAll()
        diagnostics.removeAll()
        Task {
            _ = try? await withTimeout(seconds: 2) { try await connection.request("shutdown", .null) }
            connection.notify("exit")
            try? await Task.sleep(for: .seconds(1))
            connection.terminate()
        }
    }
}

private func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
