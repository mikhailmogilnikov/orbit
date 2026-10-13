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
    /// The server answers `textDocument/diagnostic` instead of pushing (TypeScript 7).
    @ObservationIgnored private var pullsDiagnostics = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private(set) var triggers = LanguageTriggers()
    @ObservationIgnored private var completes = false
    @ObservationIgnored private var resolvesCompletions = false
    @ObservationIgnored private var helpsWithSignatures = false
    /// The latest completion response as the server sent it, for `completionItem/resolve`.
    @ObservationIgnored private var completionGeneration = 0
    @ObservationIgnored private var completionRaw: (generation: Int, items: [JSONValue]) = (0, [])

    /// The folder's real path when it was opened through a symlink (macOS's
    /// /tmp, /var): servers answer with that one, or half-resolved ones.
    @ObservationIgnored private let realRoot: String?

    init(config: LanguageServerConfig, root: URL) {
        self.config = config
        self.root = root
        let real = Self.realPath(root.path)
        realRoot = real == root.standardizedFileURL.path ? nil : real
    }

    var openDocuments: Set<URL> { Set(documents.keys) }

    var processIdentifier: Int32? { connection?.processIdentifier }

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
            onRequest: { [weak self] method, params in
                if method == "workspace/diagnostic/refresh" {
                    Task { @MainActor in self?.pullAllDiagnostics() }
                    return .null
                }
                return try Self.answer(method, params, root: root)
            },
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
            pullsDiagnostics = result["capabilities"]?["diagnosticProvider"].map { !$0.isNull } ?? false
            readFeatures(result["capabilities"])
            connection.notify("initialized")
            state = .running
            return true
        } catch {
            // A server that dies during the handshake says why on stderr; `didExit` reports it.
            try? await Task.sleep(for: .milliseconds(300))
            if state == .starting { state = .failed("\(config.name) didn't start: \(error.localizedDescription)") }
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
                    "diagnostic": ["dynamicRegistration": false, "relatedDocumentSupport": false],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "completion": [
                        "contextSupport": true,
                        "completionItem": [
                            "snippetSupport": true,
                            "insertReplaceSupport": true,
                            "labelDetailsSupport": true,
                            "deprecatedSupport": true,
                            "preselectSupport": true,
                            "tagSupport": ["valueSet": [1]],
                            "documentationFormat": ["markdown", "plaintext"],
                            "resolveSupport": ["properties": ["documentation", "detail", "additionalTextEdits"]],
                        ],
                        "completionList": ["itemDefaults": ["editRange", "insertTextFormat", "data"]],
                    ],
                    "signatureHelp": [
                        "contextSupport": true,
                        "signatureInformation": [
                            "documentationFormat": ["markdown", "plaintext"],
                            "parameterInformation": ["labelOffsetSupport": true],
                            "activeParameterSupport": true,
                        ],
                    ],
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

    private func readFeatures(_ capabilities: JSONValue?) {
        func strings(_ value: JSONValue?) -> Set<String> { Set(value?.array?.compactMap(\.string) ?? []) }
        let completion = capabilities?["completionProvider"]
        let signature = capabilities?["signatureHelpProvider"]
        completes = completion.map { !$0.isNull } ?? false
        resolvesCompletions = completion?["resolveProvider"]?.bool ?? false
        helpsWithSignatures = signature.map { !$0.isNull } ?? false
        triggers = LanguageTriggers(
            completion: strings(completion?["triggerCharacters"]),
            signatureHelp: strings(signature?["triggerCharacters"]),
            signatureHelpRetrigger: strings(signature?["retriggerCharacters"])
        )
    }

    private func handleNotification(_ method: String, _ params: JSONValue) {
        guard method == "textDocument/publishDiagnostics",
              let uri = params["uri"]?.string, let url = Self.fileURL(uri).map(local) else { return }
        let parsed = (params["diagnostics"]?.array ?? []).compactMap(Self.diagnostic)
        if diagnostics[url] != parsed { diagnostics[url] = parsed }
    }

    /// Servers re-encode URIs their own way; compare files by path.
    nonisolated static func fileURL(_ uri: String) -> URL? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }

    /// A server's path as the editor knows the file: under the folder as opened.
    func local(_ url: URL) -> URL {
        guard let realRoot, let real = Self.realPath(url.path), real.hasPrefix(realRoot + "/") else { return url }
        return URL(fileURLWithPath: root.standardizedFileURL.path + real.dropFirst(realRoot.count)).standardizedFileURL
    }

    nonisolated static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
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
        let lines = stderr.split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
        state = .failed("\(config.name) stopped (status \(status))" + (lines.isEmpty ? "" : ":\n\(lines)"))
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
            pullDiagnostics(for: url)
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
        pullDiagnostics(for: url)
    }

    /// Asks for a file's problems; an answer for an older version is dropped.
    private func pullDiagnostics(for url: URL) {
        guard pullsDiagnostics, let connection, let version = documents[url]?.version else { return }
        Task { [weak self] in
            guard let result = try? await connection.request("textDocument/diagnostic", ["textDocument": ["uri": .string(url.absoluteString)]]),
                  let self, documents[url]?.version == version else { return }
            // "unchanged" keeps what we have.
            guard result["kind"]?.string == "full" else { return }
            let parsed = (result["items"]?.array ?? []).compactMap(Self.diagnostic)
            if diagnostics[url] != parsed { diagnostics[url] = parsed }
        }
    }

    /// The server's view changed (a config or another file): ask again for every open file.
    private func pullAllDiagnostics() {
        for url in documents.keys { pullDiagnostics(for: url) }
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
            guard let uri = item["uri"]?.string ?? item["targetUri"]?.string, let target = Self.fileURL(uri).map(local),
                  let range = Self.range(item["range"] ?? item["targetSelectionRange"] ?? item["targetRange"]) else { return nil }
            return SourceLocation(url: target, range: range)
        }
    }

    // MARK: Completion

    /// Parsing a long list (TypeScript sends every global) happens off the main actor.
    func completions(at position: SourcePosition, in url: URL, trigger: CompletionTrigger) async -> CompletionList? {
        guard let connection, completes, documents[url] != nil else { return nil }
        let context: JSONValue = switch trigger {
        case .invoked: ["triggerKind": 1]
        case .character(let character): ["triggerKind": 2, "triggerCharacter": .string(character)]
        case .incomplete: ["triggerKind": 3]
        }
        let params: JSONValue = [
            "textDocument": ["uri": .string(url.absoluteString)], "position": Self.json(position), "context": context,
        ]
        completionGeneration += 1
        let generation = completionGeneration
        guard let (list, raw) = await Self.fetchCompletions(connection, params, generation: generation, resolves: resolvesCompletions),
              !Task.isCancelled else { return nil }
        if resolvesCompletions, generation == completionGeneration { completionRaw = (generation, raw) }
        return list
    }

    private nonisolated static func fetchCompletions(
        _ connection: JSONRPCConnection, _ params: JSONValue, generation: Int, resolves: Bool
    ) async -> (CompletionList, [JSONValue])? {
        guard let result = try? await connection.request("textDocument/completion", params) else { return nil }
        return completionList(result, generation: generation, resolves: resolves)
    }

    /// Item tokens carry the response they came from, so a resolve never mixes lists up.
    nonisolated static func completionList(_ result: JSONValue, generation: Int, resolves: Bool) -> (CompletionList, [JSONValue]) {
        let items = result.array ?? result["items"]?.array ?? []
        let defaults = result["itemDefaults"]
        var raw: [JSONValue] = []
        var parsed: [CompletionItem] = []
        parsed.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            guard var completion = completionItem(item, defaults: defaults, token: generation << 20 | index) else { continue }
            completion.needsResolve = resolves && (completion.documentation == nil || item["additionalTextEdits"] == nil)
            parsed.append(completion)
            if resolves {
                // Servers expect their `data` back; a list may have put it in the defaults.
                if item["data"] == nil, let data = defaults?["data"], var object = item.object {
                    object["data"] = data
                    raw.append(.object(object))
                } else {
                    raw.append(item)
                }
            }
        }
        if resolves, raw.count != items.count { raw = items }
        return (CompletionList(items: parsed, isIncomplete: result["isIncomplete"]?.bool ?? false), raw)
    }

    nonisolated static func completionItem(_ item: JSONValue, defaults: JSONValue?, token: Int) -> CompletionItem? {
        guard let label = item["label"]?.string else { return nil }
        let labelDetails = item["labelDetails"]
        let edit = item["textEdit"]
        // InsertReplaceEdit: insert, like other editors by default.
        let editRange = range(edit?["range"] ?? edit?["insert"])
            ?? range(defaults?["editRange"]?["insert"] ?? defaults?["editRange"])
        let text = edit?["newText"]?.string ?? item["textEditText"]?.string ?? item["insertText"]?.string ?? label
        let format = item["insertTextFormat"]?.int ?? defaults?["insertTextFormat"]?.int
        let documentation = markdown(item["documentation"])
        return CompletionItem(
            token: token,
            label: label + (labelDetails?["detail"]?.string ?? ""),
            kind: item["kind"]?.int.flatMap(CompletionItem.Kind.init(rawValue:)),
            detail: item["detail"]?.string ?? labelDetails?["description"]?.string,
            documentation: documentation.isEmpty ? nil : documentation,
            sortText: item["sortText"]?.string,
            filterText: item["filterText"]?.string ?? label,
            insertText: text,
            isSnippet: format == 2,
            range: editRange,
            additionalEdits: (item["additionalTextEdits"]?.array ?? []).compactMap(textEdit),
            isPreselected: item["preselect"]?.bool ?? false,
            isDeprecated: item["deprecated"]?.bool == true || item["tags"]?.array?.contains(1) == true
        )
    }

    nonisolated static func textEdit(_ value: JSONValue) -> SourceEdit? {
        guard let range = range(value["range"]), let text = value["newText"]?.string else { return nil }
        return SourceEdit(range: range, newText: text)
    }

    func resolve(_ item: CompletionItem) async -> CompletionItem {
        let index = item.token & (1 << 20 - 1)
        guard item.needsResolve, let connection, completionRaw.generation == item.token >> 20, index < completionRaw.items.count,
              let result = try? await connection.request("completionItem/resolve", completionRaw.items[index]),
              let resolved = Self.completionItem(result, defaults: nil, token: item.token) else { return item }
        var item = item
        item.needsResolve = false
        item.documentation = resolved.documentation ?? item.documentation
        item.detail = resolved.detail ?? item.detail
        if !resolved.additionalEdits.isEmpty { item.additionalEdits = resolved.additionalEdits }
        return item
    }

    // MARK: Signature help

    func signatureHelp(at position: SourcePosition, in url: URL, trigger: String?, isRetrigger: Bool) async -> SignatureHelp? {
        guard let connection, helpsWithSignatures, documents[url] != nil else { return nil }
        var context: [String: JSONValue] = ["triggerKind": trigger == nil ? 3 : 2, "isRetrigger": .bool(isRetrigger)]
        if let trigger { context["triggerCharacter"] = .string(trigger) }
        let params: JSONValue = [
            "textDocument": ["uri": .string(url.absoluteString)], "position": Self.json(position), "context": .object(context),
        ]
        guard let result = try? await connection.request("textDocument/signatureHelp", params), !result.isNull else { return nil }
        return Self.signatureHelp(result)
    }

    nonisolated static func signatureHelp(_ value: JSONValue) -> SignatureHelp? {
        let signatures: [SignatureHelp.Signature] = (value["signatures"]?.array ?? []).compactMap { signature in
            guard let label = signature["label"]?.string else { return nil }
            let text = label as NSString
            var searchFrom = 0
            let parameters: [NSRange] = (signature["parameters"]?.array ?? []).map { parameter in
                if let offsets = parameter["label"]?.array, offsets.count == 2, let start = offsets[0].int, let end = offsets[1].int {
                    return NSRange(location: start, length: max(0, end - start))
                }
                guard let name = parameter["label"]?.string, searchFrom <= text.length else { return NSRange(location: 0, length: 0) }
                let found = text.range(of: name, range: NSRange(location: searchFrom, length: text.length - searchFrom))
                if found.location != NSNotFound { searchFrom = NSMaxRange(found) }
                return found.location == NSNotFound ? NSRange(location: 0, length: 0) : found
            }
            let documentation = markdown(signature["documentation"])
            return SignatureHelp.Signature(
                label: label, documentation: documentation.isEmpty ? nil : documentation,
                parameters: parameters, activeParameter: signature["activeParameter"]?.int
            )
        }
        guard !signatures.isEmpty else { return nil }
        return SignatureHelp(
            signatures: signatures,
            activeSignature: min(max(0, value["activeSignature"]?.int ?? 0), signatures.count - 1),
            activeParameter: value["activeParameter"]?.int ?? 0
        )
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

    private nonisolated static func positionParams(_ url: URL, _ position: SourcePosition) -> JSONValue {
        ["textDocument": ["uri": .string(url.absoluteString)], "position": json(position)]
    }

    private nonisolated static func json(_ position: SourcePosition) -> JSONValue {
        ["line": .number(Double(position.line)), "character": .number(Double(position.character))]
    }

    private nonisolated static func json(_ range: SourceRange) -> JSONValue {
        ["start": json(range.start), "end": json(range.end)]
    }

    // MARK: Shutdown

    /// Polite `shutdown` + `exit` and end of input, then the process is ended if it lingers.
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
            connection.closeInput()
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
