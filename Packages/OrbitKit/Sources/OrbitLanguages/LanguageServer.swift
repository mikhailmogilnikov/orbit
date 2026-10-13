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
    /// Diagnostics as the server sent them: code actions need them back verbatim.
    @ObservationIgnored private var rawDiagnostics: [URL: [JSONValue]] = [:]
    @ObservationIgnored private var hasCodeActions = false
    @ObservationIgnored private var resolvesCodeActions = false
    @ObservationIgnored private var renames = false
    @ObservationIgnored private var preparesRename = false
    @ObservationIgnored private(set) var formats = false
    @ObservationIgnored private var findsReferences = false
    @ObservationIgnored private var highlightsSymbols = false
    @ObservationIgnored private var outlines = false
    @ObservationIgnored private(set) var searchesSymbols = false
    @ObservationIgnored private var hasInlayHints = false
    /// Bumped on `workspace/inlayHint/refresh`: editors fetch their hints again.
    private(set) var inlayHintsRevision = 0
    @ObservationIgnored private var actionGeneration = 0
    @ObservationIgnored private var actionRaw: (generation: Int, items: [JSONValue]) = (0, [])
    /// Applies an edit the server asks for (after running one of its commands).
    @ObservationIgnored var onApplyEdit: (@MainActor (WorkspaceEdit) -> Bool)?
    /// Runs a tsserver request for a server that can't (Vue's, D74): the
    /// response body, or nil when there's no answer.
    @ObservationIgnored var onTypeScriptRequest: (@MainActor (_ command: String, _ arguments: JSONValue) async -> JSONValue?)?

    /// The folder's real path when it was opened through a symlink (macOS's
    /// /tmp, /var): servers answer with that one, or half-resolved ones.
    @ObservationIgnored private let realRoot: String?

    let installer: LanguageInstaller
    /// The file that started it and the open folder: where the project's own
    /// tools are looked for (D65). Without them, only `root`.
    private let origin: URL?
    private let folder: URL

    init(config: LanguageServerConfig, root: URL, origin: URL? = nil, folder: URL? = nil, installer: LanguageInstaller = .shared) {
        self.config = config
        self.root = root
        self.origin = origin
        self.folder = folder ?? root
        self.installer = installer
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
        let config = config, root = root, origin = origin, folder = folder
        let installer = installer
        let launched = await Task.detached(priority: .userInitiated) {
            config.command(file: origin, root: folder, environment: environment, installer: installer).map { command in
                (command, ProjectFiles.environment(for: origin, root: folder, base: environment))
            }
        }.value
        guard let (command, projectEnvironment) = launched else {
            state = .unavailable(config.missing)
            return false
        }
        var env = projectEnvironment
        env.merge(command.environment) { _, new in new }
        let settings = config.settings(for: root, installer: installer)
        let connection = JSONRPCConnection(
            executable: URL(fileURLWithPath: command.executable),
            arguments: command.arguments.map { $0 == "${dataDir}" ? dataDirectory.path : $0 },
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
                if method == "workspace/applyEdit" {
                    let applied = await self?.applyFromServer(params) ?? false
                    return ["applied": .bool(applied)]
                }
                if method == "workspace/inlayHint/refresh" {
                    Task { @MainActor in self?.inlayHintsRevision += 1 }
                    return .null
                }
                if method == "client/registerCapability" {
                    Task { @MainActor in self?.register(params["registrations"]?.array ?? []) }
                    return .null
                }
                return try Self.answer(method, params, root: root, settings: settings)
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

    /// For servers that keep an index of their own per project (`${dataDir}`, Java's `-data`).
    private var dataDirectory: URL {
        let name = root.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
        let directory = installer.root.appendingPathComponent("data/\(config.id)/\(name)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var initializeParams: JSONValue {
        let rootURI = JSONValue.string(root.absoluteString)
        var params: JSONValue = [
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "Orbit"],
            "rootUri": rootURI,
            "workspaceFolders": [["uri": rootURI, "name": .string(root.lastPathComponent)]],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "textDocument": [
                    "synchronization": ["dynamicRegistration": false],
                    // `codeActionsInline`: SourceKit-LSP's fix-its ride on its diagnostics.
                    "publishDiagnostics": ["relatedInformation": false, "codeActionsInline": true],
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
                    "codeAction": [
                        "codeActionLiteralSupport": ["codeActionKind": ["valueSet": [
                            "", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite",
                            "source", "source.organizeImports", "source.fixAll",
                        ]]],
                        "isPreferredSupport": true,
                        "disabledSupport": true,
                        "dataSupport": true,
                        "resolveSupport": ["properties": ["edit"]],
                    ],
                    "rename": ["prepareSupport": true],
                    "formatting": ["dynamicRegistration": false],
                    "signatureHelp": [
                        "contextSupport": true,
                        "signatureInformation": [
                            "documentationFormat": ["markdown", "plaintext"],
                            "parameterInformation": ["labelOffsetSupport": true],
                            "activeParameterSupport": true,
                        ],
                    ],
                    "definition": ["linkSupport": true],
                    "references": ["dynamicRegistration": false],
                    "documentHighlight": ["dynamicRegistration": false],
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "inlayHint": ["dynamicRegistration": false],
                ],
                "workspace": [
                    "workspaceFolders": true, "configuration": true, "applyEdit": true,
                    "workspaceEdit": ["documentChanges": true],
                    // No `resolveSupport`: results must come with their ranges.
                    "symbol": ["dynamicRegistration": false],
                    "inlayHint": ["refreshSupport": true],
                ],
            ],
        ]
        if case .object(var object) = params, let options = config.initializationOptions(for: root, installer: installer) {
            object["initializationOptions"] = options
            params = .object(object)
        }
        return params
    }

    /// Server-to-client requests we have to answer so servers don't stall.
    private nonisolated static func answer(_ method: String, _ params: JSONValue, root: URL, settings: JSONValue?) throws -> JSONValue {
        switch method {
        case "workspace/configuration":
            // The config's settings by section (dotted), else the server's defaults:
            // an empty object for a whole section (the CSS server fails on null),
            // null for a single value (Astro iterates `html.customData ?? []`).
            let items = params["items"]?.array ?? []
            return .array(items.map { item in
                let keys = (item["section"]?.string ?? "").split(separator: ".")
                let unset: JSONValue = keys.count > 1 ? .null : .object([:])
                guard var value = settings else { return unset }
                for key in keys {
                    guard let next = value[String(key)] else { return unset }
                    value = next
                }
                return value
            })
        // ESLint's own requests (D64): run the project's ESLint without asking; nothing to show for the rest.
        case "eslint/confirmESLintExecution":
            return 4
        case "eslint/probeFailed", "eslint/noLibrary", "eslint/openDoc":
            return .object([:])
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
        func enabled(_ value: JSONValue?) -> Bool { value.map { !$0.isNull && $0.bool != false } ?? false }
        let actions = capabilities?["codeActionProvider"]
        hasCodeActions = enabled(actions)
        resolvesCodeActions = actions?["resolveProvider"]?.bool ?? false
        let rename = capabilities?["renameProvider"]
        renames = enabled(rename)
        preparesRename = rename?["prepareProvider"]?.bool ?? false
        formats = enabled(capabilities?["documentFormattingProvider"])
        findsReferences = enabled(capabilities?["referencesProvider"])
        highlightsSymbols = enabled(capabilities?["documentHighlightProvider"])
        outlines = enabled(capabilities?["documentSymbolProvider"])
        searchesSymbols = enabled(capabilities?["workspaceSymbolProvider"])
        hasInlayHints = enabled(capabilities?["inlayHintProvider"])
        triggers = LanguageTriggers(
            completion: strings(completion?["triggerCharacters"]),
            signatureHelp: strings(signature?["triggerCharacters"]),
            signatureHelpRetrigger: strings(signature?["retriggerCharacters"])
        )
    }

    /// Features some servers turn on only after starting (the vscode-langservers' diagnostics).
    private func register(_ registrations: [JSONValue]) {
        for registration in registrations {
            let options = registration["registerOptions"]
            func strings(_ value: JSONValue?) -> Set<String> { Set(value?.array?.compactMap(\.string) ?? []) }
            switch registration["method"]?.string {
            case "textDocument/diagnostic":
                pullsDiagnostics = true
                pullAllDiagnostics()
            case "textDocument/completion":
                completes = true
                resolvesCompletions = options?["resolveProvider"]?.bool ?? resolvesCompletions
                triggers.completion.formUnion(strings(options?["triggerCharacters"]))
            case "textDocument/codeAction":
                hasCodeActions = true
                resolvesCodeActions = options?["resolveProvider"]?.bool ?? resolvesCodeActions
            case "textDocument/rename":
                renames = true
                preparesRename = options?["prepareProvider"]?.bool ?? preparesRename
            case "textDocument/formatting":
                formats = true
            case "textDocument/references":
                findsReferences = true
            case "textDocument/documentHighlight":
                highlightsSymbols = true
            case "textDocument/documentSymbol":
                outlines = true
            case "workspace/symbol":
                searchesSymbols = true
            case "textDocument/inlayHint":
                hasInlayHints = true
                inlayHintsRevision += 1
            case "textDocument/signatureHelp":
                helpsWithSignatures = true
                triggers.signatureHelp.formUnion(strings(options?["triggerCharacters"]))
                triggers.signatureHelpRetrigger.formUnion(strings(options?["retriggerCharacters"]))
            default:
                break
            }
        }
    }

    private func handleNotification(_ method: String, _ params: JSONValue) {
        if method == "tsserver/request" {
            answerTypeScriptRequests(params)
            return
        }
        guard method == "textDocument/publishDiagnostics",
              let uri = params["uri"]?.string, let url = Self.fileURL(uri).map(local) else { return }
        let raw = params["diagnostics"]?.array ?? []
        rawDiagnostics[url] = raw
        let parsed = raw.compactMap(Self.diagnostic)
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
        let lines = Self.crashSummary(stderr)
        state = .failed("\(config.name) stopped (status \(status))" + (lines.isEmpty ? "" : ":\n\(lines)"))
    }

    /// A stack trace says what went wrong at its top (`TypeError: …`) and only
    /// frames at the bottom, so its error line and first frames beat the tail.
    nonisolated static func crashSummary(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        let error = lines.lastIndex { line in
            guard let first = line.first, !first.isWhitespace else { return false }
            let head = line.prefix { $0 != ":" }
            return head.count < line.count && (head.hasSuffix("Error") || head.hasSuffix("Exception") || head.hasPrefix("panicked"))
        }
        guard let error else { return lines.suffix(4).joined(separator: "\n") }
        return lines[error...].prefix(4).joined(separator: "\n")
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
            let raw = result["items"]?.array ?? []
            rawDiagnostics[url] = raw
            let parsed = raw.compactMap(Self.diagnostic)
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
        rawDiagnostics[url] = nil
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
        return locations(result)
    }

    /// Location, LocationLink (targetUri / targetSelectionRange), or a list of either.
    private func locations(_ result: JSONValue) -> [SourceLocation] {
        let items = result.array ?? (result.isNull ? [] : [result])
        return items.compactMap { item in
            guard let uri = item["uri"]?.string ?? item["targetUri"]?.string, let target = Self.fileURL(uri).map(local),
                  let range = Self.range(item["range"] ?? item["targetSelectionRange"] ?? item["targetRange"]) else { return nil }
            return SourceLocation(url: target, range: range)
        }
    }

    // MARK: Navigation (D62)

    func references(at position: SourcePosition, in url: URL) async -> [SourceLocation] {
        guard let connection, findsReferences, documents[url] != nil else { return [] }
        var params = Self.positionParams(url, position).object ?? [:]
        params["context"] = ["includeDeclaration": true]
        guard let result = try? await connection.request("textDocument/references", .object(params)) else { return [] }
        return locations(result)
    }

    func highlights(at position: SourcePosition, in url: URL) async -> [SymbolHighlight] {
        guard let connection, highlightsSymbols, documents[url] != nil,
              let result = try? await connection.request("textDocument/documentHighlight", Self.positionParams(url, position)) else { return [] }
        return (result.array ?? []).compactMap { item in
            // Kind 3 is a write; 1 (text) and 2 (read) look the same.
            Self.range(item["range"]).map { SymbolHighlight(range: $0, isWrite: item["kind"]?.int == 3) }
        }
    }

    func inlayHints(in range: SourceRange, url: URL) async -> [InlayHint] {
        guard let connection, hasInlayHints, documents[url] != nil,
              let result = try? await connection.request("textDocument/inlayHint", [
                  "textDocument": ["uri": .string(url.absoluteString)], "range": Self.json(range),
              ]) else { return [] }
        return (result.array ?? []).compactMap(Self.inlayHint)
    }

    /// A label is a string or a list of parts (each may link somewhere; only the text is kept).
    nonisolated static func inlayHint(_ value: JSONValue) -> InlayHint? {
        guard let position = position(value["position"]) else { return nil }
        let label = value["label"]?.string ?? (value["label"]?.array ?? []).compactMap { $0["value"]?.string }.joined()
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return InlayHint(
            position: position, label: label,
            kind: value["kind"]?.int.flatMap(InlayHint.Kind.init(rawValue:)),
            tooltip: value["tooltip"]?.string ?? value["tooltip"]?["value"]?.string,
            paddingLeft: value["paddingLeft"]?.bool ?? false,
            paddingRight: value["paddingRight"]?.bool ?? false
        )
    }

    func symbols(in url: URL) async -> [LanguageSymbol]? {
        guard let connection, outlines, documents[url] != nil,
              let result = try? await connection.request("textDocument/documentSymbol", ["textDocument": ["uri": .string(url.absoluteString)]]),
              let items = result.array else { return nil }
        return Self.outline(items, in: url)
    }

    /// Hierarchical `DocumentSymbol`s flattened parents first, or flat
    /// `SymbolInformation`s nested by which range holds which.
    nonisolated static func outline(_ items: [JSONValue], in url: URL) -> [LanguageSymbol] {
        var symbols: [LanguageSymbol] = []
        if items.first?["selectionRange"] != nil {
            func walk(_ items: [JSONValue], depth: Int, container: String?) {
                let sorted = items.sorted { (range($0["range"])?.start ?? .init(line: 0, character: 0)) < (range($1["range"])?.start ?? .init(line: 0, character: 0)) }
                for item in sorted {
                    guard let name = item["name"]?.string, let selection = range(item["selectionRange"]) else { continue }
                    symbols.append(LanguageSymbol(
                        name: name, detail: item["detail"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                        kind: item["kind"]?.int.flatMap(SymbolKind.init(rawValue:)) ?? .variable,
                        location: SourceLocation(url: url, range: selection), container: container, depth: depth
                    ))
                    walk(item["children"]?.array ?? [], depth: depth + 1, container: name)
                }
            }
            walk(items, depth: 0, container: nil)
            return symbols
        }
        let flat = items.compactMap { item -> (LanguageSymbol, SourceRange)? in
            guard let name = item["name"]?.string, let range = range(item["location"]?["range"]) else { return nil }
            let symbol = LanguageSymbol(
                name: name, kind: item["kind"]?.int.flatMap(SymbolKind.init(rawValue:)) ?? .variable,
                location: SourceLocation(url: url, range: range), container: item["containerName"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            )
            return (symbol, range)
        }
        .sorted { $0.1.start < $1.1.start }
        var open: [SourceRange] = []
        for (var symbol, range) in flat {
            while let last = open.last, !(last.contains(range.start) && range.end <= last.end) { open.removeLast() }
            symbol.depth = open.count
            open.append(range)
            symbols.append(symbol)
        }
        return symbols
    }

    func projectSymbols(matching query: String) async -> [LanguageSymbol] {
        guard let connection, searchesSymbols,
              let result = try? await connection.request("workspace/symbol", ["query": .string(query)]) else { return [] }
        return (result.array ?? []).compactMap { item in
            guard let name = item["name"]?.string, let uri = item["location"]?["uri"]?.string,
                  let url = Self.fileURL(uri).map(local) else { return nil }
            // `WorkspaceSymbol` may leave the range out; the top of the file then.
            let range = Self.range(item["location"]?["range"]) ?? SourceRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0))
            return LanguageSymbol(
                name: name, kind: item["kind"]?.int.flatMap(SymbolKind.init(rawValue:)) ?? .variable,
                location: SourceLocation(url: url, range: range),
                container: item["containerName"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            )
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

    // MARK: Code actions, rename, formatting (D59)

    /// Fixes and refactorings for a range, with the problems there as context.
    func codeActions(for range: SourceRange, in url: URL) async -> [CodeAction] {
        guard let connection, hasCodeActions, documents[url] != nil else { return [] }
        let overlapping = (rawDiagnostics[url.standardizedFileURL] ?? []).filter { raw in
            guard let problem = Self.range(raw["range"]) else { return false }
            return problem.start <= range.end && range.start <= problem.end
        }
        let params: JSONValue = [
            "textDocument": ["uri": .string(url.absoluteString)],
            "range": Self.json(range),
            "context": ["diagnostics": .array(overlapping), "triggerKind": 1],
        ]
        actionGeneration += 1
        let generation = actionGeneration
        guard let result = try? await connection.request("textDocument/codeAction", params), generation == actionGeneration else { return [] }
        let items = result.array ?? []
        actionRaw = (generation, items)
        return items.enumerated().compactMap { index, item in
            guard let title = item["title"]?.string else { return nil }
            return CodeAction(
                token: generation << 20 | index, title: title, kind: item["kind"]?.string,
                isPreferred: item["isPreferred"]?.bool ?? false, disabledReason: item["disabled"]?["reason"]?.string
            )
        }
    }

    /// Applies the action's edit through `apply`, then runs its command (which
    /// may send more edits through `workspace/applyEdit`).
    func perform(_ action: CodeAction, apply: (WorkspaceEdit) -> Bool) async -> Bool {
        let index = action.token & (1 << 20 - 1)
        guard let connection, actionRaw.generation == action.token >> 20, index < actionRaw.items.count else { return false }
        var item = actionRaw.items[index]
        // A bare Command: just run it.
        if let command = item["command"]?.string {
            return (try? await connection.request("workspace/executeCommand", [
                "command": .string(command), "arguments": item["arguments"] ?? .array([]),
            ])) != nil
        }
        if item["edit"] == nil, resolvesCodeActions, let resolved = try? await connection.request("codeAction/resolve", item) {
            item = resolved
        }
        if let edit = item["edit"] {
            guard apply(workspaceEdit(edit)) else { return false }
        }
        if let command = item["command"], let name = command["command"]?.string {
            _ = try? await connection.request("workspace/executeCommand", [
                "command": .string(name), "arguments": command["arguments"] ?? .array([]),
            ])
        }
        return true
    }

    // MARK: tsserver requests (D74)

    /// `[[id, command, arguments]]`; each gets `[[id, body]]` back, null when it
    /// can't be run, or the server waits on it forever.
    private func answerTypeScriptRequests(_ params: JSONValue) {
        for request in params.array ?? [] {
            guard let id = request[0], let command = request[1]?.string else { continue }
            let arguments = request[2] ?? .null
            Task { [weak self] in
                let body = await self?.onTypeScriptRequest?(command, arguments) ?? .null
                self?.connection?.notify("tsserver/response", [[id, body]])
            }
        }
    }

    /// Runs a raw tsserver request (typescript-language-server's `typescript.tsserverRequest`).
    func typeScriptRequest(_ command: String, _ arguments: JSONValue) async -> JSONValue? {
        guard let connection, state == .running else { return nil }
        let result = try? await connection.request("workspace/executeCommand", [
            "command": "typescript.tsserverRequest", "arguments": [.string(command), arguments],
        ])
        return result?["body"]
    }

    /// The symbol a rename at `position` would change; nil when nothing there can be renamed.
    func prepareRename(at position: SourcePosition, in url: URL) async -> RenameTarget? {
        guard let connection, renames, let text = documents[url]?.text else { return nil }
        if preparesRename {
            guard let result = try? await connection.request("textDocument/prepareRename", Self.positionParams(url, position)),
                  !result.isNull else { return nil }
            if let range = Self.range(result) ?? Self.range(result["range"]) {
                return RenameTarget(range: range, placeholder: result["placeholder"]?.string ?? Self.text(in: range, of: text))
            }
            // `defaultBehavior`: the word at the position.
        }
        return Self.word(at: position, in: text)
    }

    func rename(at position: SourcePosition, in url: URL, to newName: String) async throws -> WorkspaceEdit {
        guard let connection, renames, documents[url] != nil else { throw JSONRPCError(code: -32601, message: "This language can't rename.") }
        var params = Self.positionParams(url, position).object ?? [:]
        params["newName"] = .string(newName)
        let result = try await connection.request("textDocument/rename", .object(params))
        return workspaceEdit(result)
    }

    /// The whole document's formatting edits; nil when the server doesn't format.
    func formatting(_ url: URL, tabSize: Int, insertSpaces: Bool) async -> [SourceEdit]? {
        guard let connection, formats, documents[url] != nil else { return nil }
        let params: JSONValue = [
            "textDocument": ["uri": .string(url.absoluteString)],
            "options": ["tabSize": .number(Double(tabSize)), "insertSpaces": .bool(insertSpaces), "trimTrailingWhitespace": true, "insertFinalNewline": true],
        ]
        guard let result = try? await connection.request("textDocument/formatting", params) else { return nil }
        return (result.array ?? []).compactMap(Self.textEdit)
    }

    private func applyFromServer(_ params: JSONValue) -> Bool {
        guard let edit = params["edit"] else { return false }
        return onApplyEdit?(workspaceEdit(edit)) ?? false
    }

    /// `changes` or `documentChanges`, under the folder as opened.
    func workspaceEdit(_ value: JSONValue) -> WorkspaceEdit {
        var files: [URL: [SourceEdit]] = [:]
        var hasFileOperations = false
        for (uri, edits) in value["changes"]?.object ?? [:] {
            guard let url = Self.fileURL(uri).map(local) else { continue }
            files[url, default: []] += (edits.array ?? []).compactMap(Self.textEdit)
        }
        for change in value["documentChanges"]?.array ?? [] {
            if change["kind"] != nil {
                hasFileOperations = true
                continue
            }
            guard let uri = change["textDocument"]?["uri"]?.string, let url = Self.fileURL(uri).map(local) else { continue }
            files[url, default: []] += (change["edits"]?.array ?? []).compactMap(Self.textEdit)
        }
        return WorkspaceEdit(files: files, hasFileOperations: hasFileOperations)
    }

    nonisolated static func text(in range: SourceRange, of text: String) -> String {
        let string = text as NSString
        return string.substring(with: range.nsRange(in: SourcePosition.lineStarts(of: string), length: string.length))
    }

    /// The identifier around a position, for servers without `prepareRename`.
    nonisolated static func word(at position: SourcePosition, in text: String) -> RenameTarget? {
        let string = text as NSString
        let starts = SourcePosition.lineStarts(of: string)
        let offset = position.offset(in: starts, length: string.length)
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < string.length else { return false }
            let unit = string.character(at: index)
            if unit == 0x5F || unit == 0x24 { return true }
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
        }
        var start = offset, end = offset
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        guard end > start else { return nil }
        let range = SourceRange(start: SourcePosition(offset: start, in: starts), end: SourcePosition(offset: end, in: starts))
        return RenameTarget(range: range, placeholder: string.substring(with: NSRange(location: start, length: end - start)))
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
            connection.notify("exit", .null)
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
