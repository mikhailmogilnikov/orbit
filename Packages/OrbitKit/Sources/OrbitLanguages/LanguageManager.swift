import Foundation
import Observation
import OrbitACP
import OrbitAPI

/// Runs language servers for the open folder and answers the editor (D54).
/// Servers start lazily with the first open file of their language, get
/// changes coalesced while typing, and stop after a while with none open.
@MainActor
@Observable
final class LanguageManager: LanguageIntelligence {
    private let workspace: Workspace
    /// One per server and project root inside the folder (D65): a folder with
    /// two Rust workspaces runs two rust-analyzers, a JS monorepo one TypeScript.
    struct ServerKey: Hashable {
        var id: String
        var root: URL
    }

    private(set) var servers: [ServerKey: LanguageServer] = [:]
    /// Servers that couldn't start, so files of their language say why without retrying on every keystroke.
    private(set) var unavailable: [ServerKey: LanguageServerState] = [:]

    let environment: Task<[String: String], Never>
    @ObservationIgnored let installer = LanguageInstaller.shared

    // Installing (D57), by config id unless noted.
    private(set) var installing: Set<String> = []
    private(set) var installFailures: [String: String] = [:]
    /// By Mason package.
    private(set) var receipts: [String: LanguageInstaller.Receipt] = [:]
    /// By Mason package, from the registry.
    private(set) var latestVersions: [String: String] = [:]
    /// Servers already on the machine (not Orbit's copy): config id → executable.
    private(set) var foundOnMachine: [String: String] = [:]
    private(set) var isLoadingRegistry = false
    private(set) var registryError: String?
    @ObservationIgnored private var root: URL?
    /// `environment` once resolved, for checks that can't wait for it.
    @ObservationIgnored private var shellEnvironment: [String: String]?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var idleTasks: [ServerKey: Task<Void, Never>] = [:]
    /// When each server last crashed and was started again, for the restart budget.
    @ObservationIgnored private var crashes: [ServerKey: [ContinuousClock.Instant]] = [:]
    /// The open folder's files, for servers that leave watching the disk to us (D77).
    @ObservationIgnored private var fileEvents: FileEventStream?
    /// Each file's servers: its language's, then the companions its project uses (ESLint, Tailwind).
    @ObservationIgnored private var placements: [URL: [ServerKey]] = [:]
    /// Servers as `.orbit/settings.json` made them (another server, a command, its settings), by id.
    @ObservationIgnored private var effective: [String: LanguageServerConfig] = [:]
    @ObservationIgnored private var serverSettings: Result<[LanguageServerSettings], Error> = .success([])
    /// Companions turned off or configured, actions on save (D81); invalid JSON is reported by `serverSettings`.
    @ObservationIgnored private var toolSettings: [ToolSettings] = []
    /// When the settings files last changed: an edit restarts the servers.
    @ObservationIgnored private var settingsStamp: [Date?]?
    /// Bumped on every reload, so views showing the chosen server redraw.
    private var settingsRevision = 0

    /// Typing pauses this long before the server hears about it.
    private static let syncDelay: Duration = .milliseconds(120)
    /// A server with no open files of its language is stopped after this.
    private static let idleTimeout: Duration = .seconds(600)
    /// Hover and fixes wait no longer than this: the card also carries the problems, which mustn't wait on a slow server.
    private static let queryDeadline: Duration = .milliseconds(1500)
    /// A crashed server starts again, like VS Code's client: up to 4 times in 3 minutes,
    /// then it stays down with its message (a server that dies on start would loop).
    private static let restartLimit = 4
    private static let restartWindow: Duration = .seconds(180)

    /// The agent's changes, from the Review plugin (it may start after this one).
    @ObservationIgnored var changes: () -> ChangeTracking? = { nil }
    /// Files checked without being open (D75): what the agent changed, kept
    /// after review while they still have problems.
    @ObservationIgnored private var checked: [URL] = []
    @ObservationIgnored private var diskTexts: [URL: (generation: Int, text: String)] = [:]
    private static let checkedLimit = 100

    init(workspace: Workspace) {
        self.workspace = workspace
        let environment = Task.detached { await ShellEnvironment.resolve() }
        self.environment = environment
        root = workspace.root
        observe()
        Task { [weak self] in
            let resolved = await environment.value
            self?.shellEnvironment = resolved
        }
    }

    // MARK: Following the workspace

    /// Re-arms on every change to the open documents' set or text.
    private func observe() {
        withObservationTracking {
            _ = workspace.root
            _ = workspace.fileSystemGeneration
            _ = changes()?.changedFiles
            for document in workspace.documents.open.values { _ = document.revision }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.workspace.isClosed else { return }
                self.scheduleSync()
                self.observe()
            }
        }
        scheduleSync()
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: Self.syncDelay)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func sync() async {
        // Which of a language's servers is installed decides which one a file gets.
        if shellEnvironment == nil { shellEnvironment = await environment.value }
        reloadSettingsIfChanged()
        if workspace.root != root {
            root = workspace.root
            fileEvents = root.flatMap { root in
                FileEventStream(root: root) { [weak self] changes in
                    guard let self else { return }
                    for server in servers.values { server.filesChanged(changes) }
                }
            }
            for server in servers.values { server.shutdown() }
            servers.removeAll()
            unavailable.removeAll()
            placements.removeAll()
            checked.removeAll()
            diskTexts.removeAll()
        }
        guard let root else { return }

        let documents = workspace.documents.open.values.filter { $0.loadError == nil && !$0.isLimited }
        let files = documents.map { (url: $0.url, text: $0.text) } + checkedFiles(excluding: Set(documents.map(\.url)), in: root)
        var wanted: [ServerKey: [(url: URL, text: String)]] = [:]
        for file in files {
            for key in keys(for: file.url) { wanted[key, default: []].append(file) }
        }

        for (key, server) in servers {
            let open = Set((wanted[key] ?? []).map(\.url))
            for url in server.openDocuments where !open.contains(url) { server.close(url) }
            if open.isEmpty { scheduleIdleShutdown(key) } else { idleTasks.removeValue(forKey: key)?.cancel() }
        }

        for (key, documents) in wanted where unavailable[key] == nil {
            guard let config = serverConfig(id: key.id) else { continue }
            if let crashed = servers[key], case .failed = crashed.state {
                let now = ContinuousClock.now
                let recent = (crashes[key] ?? []).filter { now - $0 < Self.restartWindow }
                guard recent.count < Self.restartLimit else {
                    unavailable[key] = crashed.state
                    servers[key] = nil
                    continue
                }
                crashes[key] = recent + [now]
                servers[key] = nil
            }
            let server: LanguageServer
            if let running = servers[key] {
                server = running
            } else {
                server = LanguageServer(config: config, root: key.root, origin: documents.first?.url, folder: root)
                server.onApplyEdit = { [weak self] edit in self?.apply(edit) ?? false }
                server.onCrash = { [weak self] in self?.scheduleSync() }
                if let typeScript = config.typeScriptServer {
                    let typeScriptKey = ServerKey(id: typeScript, root: key.root)
                    server.onTypeScriptRequest = { [weak self] command, arguments in
                        await self?.servers[typeScriptKey]?.typeScriptRequest(command, arguments)
                    }
                }
                servers[key] = server
            }
            guard await server.start(environment: environment) else {
                unavailable[key] = server.state
                servers[key] = nil
                continue
            }
            for file in documents { server.sync(file.url, text: file.text) }
        }
    }

    /// The agent's changed files as they are on disk, so their servers report
    /// them before anyone opens them; a file stays after review until its
    /// problems are fixed (D75).
    private func checkedFiles(excluding open: Set<URL>, in root: URL) -> [(url: URL, text: String)] {
        let changed = changes()?.changedFiles ?? []
        let kept = checked.filter { changed.contains($0) || !diagnostics(for: $0).isEmpty }
        checked = Array((kept + changed.filter { !kept.contains($0) }).filter { url in
            url.path.hasPrefix(root.path + "/") && FileManager.default.fileExists(atPath: url.path) && !keys(for: url).isEmpty
        }.prefix(Self.checkedLimit))
        let generation = workspace.fileSystemGeneration
        var files: [(url: URL, text: String)] = []
        for url in checked {
            // The editor's text wins; on close the file is read again (saving doesn't bump the generation).
            if open.contains(url) {
                diskTexts[url] = nil
            } else if let cached = diskTexts[url], cached.generation == generation {
                files.append((url, cached.text))
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                diskTexts[url] = (generation, text)
                files.append((url, text))
            }
        }
        diskTexts = diskTexts.filter { checked.contains($0.key) }
        return files
    }

    private func scheduleIdleShutdown(_ key: ServerKey) {
        guard idleTasks[key] == nil else { return }
        idleTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, let self else { return }
            idleTasks[key] = nil
            guard let server = servers[key], server.openDocuments.isEmpty else { return }
            server.shutdown()
            servers[key] = nil
        }
    }

    /// The file's language server first, then the tools its project uses beside it (D64),
    /// each at the project root it runs in (D65).
    func keys(for url: URL) -> [ServerKey] {
        guard let root else { return [] }
        let file = url.standardizedFileURL
        if let cached = placements[file] { return cached }
        let chosen = languageConfig(for: file, in: root)
        let language: LanguageServerConfig?
        switch serverSettings {
        case .success(let layers): language = LanguageServerSettings.resolve(for: file, layers: layers, default: chosen)
        case .failure(let error): language = chosen.map { LanguageServerSettings.broken(file, $0, error.localizedDescription) }
        }
        if let language { effective[language.id] = language }
        let companions = LanguageServerConfig.companions(for: url).compactMap { config -> LanguageServerConfig? in
            var config = config
            switch ToolSettings.companion(config.id, in: toolSettings) {
            case .off?: return nil
            case .on(let overrides)?: config.apply(overrides)
            case .configured(let overrides)?:
                guard config.isUsed(by: file, in: root) else { return nil }
                config.apply(overrides)
            case nil:
                return config.isUsed(by: file, in: root) ? config : nil
            }
            effective[config.id] = config
            return config
        }
        let configs = (language.map { [$0] } ?? []) + companions
        let keys = configs.map { ServerKey(id: $0.id, root: $0.root(for: file, in: root)) }
        // Until the shell's PATH is known, what's installed can't be told: decide again then.
        if shellEnvironment != nil { placements[file] = keys }
        return keys
    }

    private func languageConfig(for file: URL, in root: URL) -> LanguageServerConfig? {
        guard let environment = shellEnvironment else { return LanguageServerConfig.config(for: file) }
        return LanguageServerConfig.choose(for: file, in: root, environment: environment, installer: installer)
    }

    private func serverConfig(id: String) -> LanguageServerConfig? {
        effective[id] ?? LanguageServerConfig.config(id: id)
    }

    private func reloadSettingsIfChanged() {
        let files = [root.map(FormatterSettings.projectFile), FormatterSettings.userFile()].compactMap { $0 }
        let stamp = files.map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        guard stamp != settingsStamp else { return }
        let first = settingsStamp == nil
        settingsStamp = stamp
        serverSettings = Result { try LanguageServerSettings.layers(root: root) }
        toolSettings = (try? ToolSettings.layers(root: root)) ?? []
        settingsRevision += 1
        placements.removeAll()
        effective.removeAll()
        guard !first else { return }
        for server in servers.values { server.shutdown() }
        servers.removeAll()
        unavailable.removeAll()
        crashes.removeAll()
    }

    /// A file whose language server the settings turned off: (the language, which file says so).
    func turnedOff(_ url: URL) -> String? {
        _ = settingsRevision
        guard languageKey(for: url) == nil, let usual = LanguageServerConfig.config(for: url),
              case .success(let layers) = serverSettings,
              layers.contains(where: { $0.rule(for: url) == .off }) else { return nil }
        return usual.name
    }

    /// The server the settings name for this file type, if they do.
    func chosenInSettings(_ url: URL) -> String? {
        _ = settingsRevision
        guard case .success(let layers) = serverSettings else { return nil }
        for layer in layers {
            switch layer.rule(for: url) {
            case .server(let id, _)?: return id
            case .off?: return "off"
            case .command?: return "command"
            case nil: continue
            }
        }
        return nil
    }

    /// Servers that could take the file, for choosing another: (id, what to show).
    func alternatives(for url: URL) -> [(id: String, title: String)] {
        LanguageServerConfig.alternatives(for: url).map { config in
            (config.id, config.isImported ? "\(config.name) — \(config.id)" : config.name)
        }
    }

    /// Remembers the server for this file type in `~/.orbit/settings.json`
    /// ("off" for none, nil back to Orbit's choice); the servers restart with it.
    func chooseServer(_ id: String?, for url: URL) -> String? {
        let type = url.pathExtension.isEmpty ? url.lastPathComponent.lowercased() : url.pathExtension.lowercased()
        do {
            try LanguageServerSettings.choose(id, forType: type)
        } catch {
            return error.localizedDescription
        }
        scheduleSync()
        return nil
    }

    /// A task for the agent when a file's language server can't run (D65): what
    /// Orbit tried, and the two ways out it has — install the tool, or point
    /// Orbit at a server in the project's `.orbit/settings.json`.
    func setUpPrompt(for url: URL, problem: String) -> String {
        let config = config(for: url)
        let type = url.pathExtension.isEmpty ? url.lastPathComponent : ".\(url.pathExtension)"
        let others = alternatives(for: url).map(\.id).filter { $0 != config?.id }
        let launch = config.map { config in
            config.launch.map { source -> String in
                switch source {
                case .project(let package, let binary, _, _): "node_modules/.bin/\(binary)" + (package.map { " (npm package \($0))" } ?? "")
                case .installed: config.install.map { "Orbit's copy of Mason package \($0.package)" } ?? "Orbit's copy"
                case .path(let binary, let arguments): ([binary] + arguments).joined(separator: " ") + " on PATH"
                case .xcrun(let tool, _): "xcrun --find \(tool)"
                case .file(let path, let arguments): ([path] + arguments).joined(separator: " ")
                }
            }.joined(separator: ", then ")
        } ?? "nothing: no server is known for this file type"
        return """
        Orbit (the editor) can't run a language server for \(type) files in this project, e.g. \(relativePath(url)).

        Server: \(config.map { "\($0.name) (\($0.id))" } ?? "none")
        Orbit looks for it as: \(launch)
        Problem: \(problem)

        Please get it working for this project. Either install what's missing (say what you install and how), or, if this project needs a different server or command, add a rule to .orbit/settings.json in the project root, merged with what's there:

        { "languageServers": { "\(type.trimmingCharacters(in: CharacterSet(charactersIn: ".")))": "<server>" } }

        where <server> is one of \(others.isEmpty ? "the servers nvim-lspconfig names" : others.prefix(6).joined(separator: ", ")), or "off", or { "command": "<executable>", "arguments": [...], "settings": {...}, "initializationOptions": {...} }. Rules are keyed by file type ("ts, tsx" works); settings are sent as the answer to workspace/configuration. Orbit restarts its servers when the file changes. Check that the server starts in this project before you finish.
        """
    }

    private func relativePath(_ url: URL) -> String {
        guard let root, url.path.hasPrefix(root.path + "/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    /// Opens `~/.orbit/settings.json` (creating it) to set servers up by hand.
    func editServerSettings() {
        let url = FormatterSettings.userFile()
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "{\n  \"languageServers\": {}\n}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        workspace.openFile(url)
    }

    /// The file's language server's key.
    private func languageKey(for url: URL) -> ServerKey? {
        keys(for: url).first { serverConfig(id: $0.id)?.isCompanion == false }
    }

    /// The file's server of config `id` (a code action's or completion's).
    private func server(id: String, for url: URL) -> LanguageServer? {
        keys(for: url).first { $0.id == id }.flatMap { servers[$0] }
    }

    /// Before asking about a file, send its latest text right away; the file's language server.
    private func flush(_ url: URL) async -> LanguageServer? {
        guard let key = languageKey(for: url), let server = servers[key] else { return nil }
        if let document = workspace.documents.existingDocument(for: url) { server.sync(document.url, text: document.text) }
        return server
    }

    /// Every server the file has, its language server first, with its latest text.
    private func flushAll(_ url: URL) -> [LanguageServer] {
        let document = workspace.documents.existingDocument(for: url)
        return keys(for: url).compactMap { key in
            guard let server = servers[key] else { return nil }
            if let document { server.sync(document.url, text: document.text) }
            return server
        }
    }

    /// Asks every server of the file at once; answers in the servers' order.
    /// With a `deadline`, servers that haven't answered by then are left out
    /// (cancelled), so one stuck companion can't hold back the others' answers.
    private func gather<T: Sendable>(
        _ url: URL, deadline: Duration? = nil, _ ask: @escaping @MainActor (LanguageServer) async -> T?
    ) async -> [(LanguageServer, T)] {
        let servers = flushAll(url)
        // Tasks rather than a group (the region checker can't follow one here);
        // cancelling the caller still cancels the requests (`$/cancelRequest`).
        let tasks = servers.map { server in Task { await ask(server) } }
        let timer = deadline.map { deadline in
            Task {
                try? await Task.sleep(for: deadline)
                guard !Task.isCancelled else { return }
                for task in tasks { task.cancel() }
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            var answers: [(LanguageServer, T)] = []
            for (server, task) in zip(servers, tasks) {
                if let answer = await task.value { answers.append((server, answer)) }
            }
            return answers
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }

    /// Stops every server and forgets failures; open files start them again.
    func restart() {
        for server in servers.values { server.shutdown() }
        servers.removeAll()
        unavailable.removeAll()
        crashes.removeAll()
        placements.removeAll()
        effective.removeAll()
        diskTexts.removeAll()
        settingsStamp = nil
        scheduleSync()
    }

    func shutdown() {
        fileEvents = nil
        syncTask?.cancel()
        for task in idleTasks.values { task.cancel() }
        for server in servers.values { server.shutdown() }
        servers.removeAll()
    }

    // MARK: Installing

    /// Installed versions, the registry's latest, and what's already on the machine.
    func refreshInstalls() async {
        guard !isLoadingRegistry else { return }
        isLoadingRegistry = true
        defer { isLoadingRegistry = false }
        let installer = installer
        let environment = await environment.value
        let (receipts, found) = await Task.detached(priority: .utility) {
            var receipts: [String: LanguageInstaller.Receipt] = [:]
            var found: [String: String] = [:]
            for config in LanguageServerConfig.all {
                if let install = config.install, let receipt = installer.receipt(for: install.package) {
                    receipts[install.package] = receipt
                }
                if let command = config.machineCommand(environment: environment) { found[config.id] = command.executable }
            }
            return (receipts, found)
        }.value
        self.receipts = receipts
        foundOnMachine = found
        do {
            let versions = try await Task.detached(priority: .utility) {
                let registry = try installer.registry()
                var versions: [String: String] = [:]
                for config in LanguageServerConfig.all {
                    guard let package = config.install?.package, let id = registry[package]?["source"]?["id"]?.string,
                          let url = PackageURL(id) else { continue }
                    versions[package] = url.version
                }
                return versions
            }.value
            latestVersions = versions
            registryError = nil
        } catch {
            registryError = error.localizedDescription
        }
    }

    func install(_ id: String) async {
        guard let config = LanguageServerConfig.config(id: id), let install = config.install, !installing.contains(id) else { return }
        installing.insert(id)
        installFailures[id] = nil
        defer { installing.remove(id) }
        let installer = installer
        let environment = await environment.value
        do {
            let receipt = try await Task.detached(priority: .userInitiated) {
                let registry = try installer.registry(maxAge: 3600)
                guard let package = registry[install.package] else {
                    throw LanguageInstaller.Failure.failed("\(install.package) isn't in the Mason registry.")
                }
                return try installer.install(package, environment: environment)
            }.value
            receipts[install.package] = receipt
            latestVersions[install.package] = latestVersions[install.package] ?? receipt.version
            restartServer(id)
        } catch {
            installFailures[id] = error.localizedDescription
        }
    }

    func uninstall(_ id: String) {
        guard let install = LanguageServerConfig.config(id: id)?.install else { return }
        do {
            try installer.uninstall(install.package)
            receipts[install.package] = nil
            restartServer(id)
        } catch {
            installFailures[id] = error.localizedDescription
        }
    }

    /// A new or removed copy takes over from the running one; open files start it again.
    /// So do the servers sharing its package (TypeScript and Vue's tsserver) and the
    /// tsserver that loads Vue's plugin from it (D74).
    private func restartServer(_ id: String) {
        let config = LanguageServerConfig.config(id: id)
        var ids: Set<String> = [id]
        if let package = config?.install?.package {
            ids.formUnion(LanguageServerConfig.all.filter { $0.install?.package == package }.map(\.id))
        }
        if let typeScript = config?.typeScriptServer { ids.insert(typeScript) }
        for key in servers.keys where ids.contains(key.id) { servers.removeValue(forKey: key)?.shutdown() }
        unavailable = unavailable.filter { !ids.contains($0.key.id) }
        placements.removeAll()
        scheduleSync()
    }

    private static let declinedKey = "orbit.languages.declinedInstalls"
    private var declined = Set(UserDefaults.standard.stringArray(forKey: LanguageManager.declinedKey) ?? [])

    // MARK: Fixes, rename, formatting (D59)

    /// The editor's way to apply edits to open files; the editor plugin starts after this one.
    @ObservationIgnored var editing: () -> SourceEditing? = { nil }
    @ObservationIgnored var tasks: () -> TaskProblems? = { nil }

    private func runningServer(for url: URL) -> LanguageServer? {
        languageKey(for: url).flatMap { servers[$0] }
    }

    func codeActions(for range: SourceRange, in url: URL) async -> [CodeAction] {
        let file = url.standardizedFileURL
        return await gather(url, deadline: Self.queryDeadline) { await $0.codeActions(for: range, in: file) }.flatMap { server, actions in
            actions.map { action in
                var action = action
                action.server = server.config.id
                return action
            }
        }
    }

    /// Code actions on save (D81), in the order the settings list them: for
    /// each kind, the first server offering it applies its action. Kinds no
    /// running server offers (ESLint's where the project has no ESLint) are skipped.
    func runSaveActions(_ url: URL) async {
        _ = keys(for: url)
        _ = await runCodeActions(ToolSettings.actionsOnSave(for: url, in: toolSettings), in: url)
    }

    /// Runs the first action of each kind any of the file's servers offers; the number run.
    func runCodeActions(_ kinds: [String], in url: URL) async -> Int {
        let file = url.standardizedFileURL
        var count = 0
        for kind in kinds {
            guard !Task.isCancelled, let document = workspace.documents.existingDocument(for: url) else { return count }
            let text = document.text as NSString
            let end = SourcePosition(offset: text.length, in: SourcePosition.lineStarts(of: text))
            let whole = SourceRange(start: SourcePosition(line: 0, character: 0), end: end)
            let offers = await gather(url, deadline: Self.queryDeadline) { await $0.codeActions(for: whole, in: file, only: [kind]) }
            for (server, actions) in offers {
                guard let action = actions.first(where: { action in
                    action.disabledReason == nil && action.kind.map { $0 == kind || $0.hasPrefix(kind + ".") } == true
                }) else { continue }
                var chosen = action
                chosen.server = server.config.id
                if await perform(chosen, in: url) == nil { count += 1 }
                break
            }
        }
        return count
    }

    func perform(_ action: CodeAction, in url: URL) async -> String? {
        guard let server = action.server.flatMap({ server(id: $0, for: url) }) ?? runningServer(for: url) else { return "The language server isn't running." }
        if let reason = action.disabledReason { return reason }
        let worked = await server.perform(action) { [weak self] edit in self?.apply(edit) ?? false }
        return worked ? nil : "The language server couldn't apply “\(action.title)”."
    }

    func prepareRename(at position: SourcePosition, in url: URL) async -> RenameTarget? {
        await flush(url)?.prepareRename(at: position, in: url.standardizedFileURL)
    }

    func rename(at position: SourcePosition, in url: URL, to newName: String) async -> Result<Int, RenameFailure> {
        guard let server = await flush(url) else { return .failure(RenameFailure("The language server isn't running.")) }
        do {
            let edit = try await server.rename(at: position, in: url.standardizedFileURL, to: newName)
            guard !edit.isEmpty else { return .failure(RenameFailure("Nothing to rename here.")) }
            guard apply(edit) else { return .failure(RenameFailure("Some files couldn't be changed.")) }
            return .success(edit.files.filter { !$0.value.isEmpty }.count)
        } catch {
            return .failure(RenameFailure(error.localizedDescription))
        }
    }

    func canFormat(_ url: URL) -> Bool {
        switch try? formatterChoice(for: url) {
        case .tool?, nil: return true
        case .off?: return false
        case .server?:
            guard let server = formatter(for: url), server.state == .running else { return false }
            return server.formats
        }
    }

    /// The repo's formatter (Prettier, Ruff… or one set in `.orbit/settings.json`)
    /// if there is one, else the server, indented per `.editorconfig` (D60, D61).
    func format(_ url: URL, lines: ClosedRange<Int>?) async -> FormatOutcome {
        guard let document = workspace.documents.existingDocument(for: url) else { return .failed("The file isn't open.") }
        let environment = await environment.value
        let choice: FormatterChoice
        do {
            choice = try formatterChoice(for: url, environment: environment)
        } catch {
            return .failed(error.localizedDescription)
        }
        switch choice {
        case .off(let source):
            return .failed("Formatting .\(url.pathExtension) files is turned off in \(source).")
        case .tool(let formatter):
            let text = document.text
            let formatted: String
            do {
                formatted = try await formatter.format(text, file: url, environment: environment)
            } catch {
                return .failed(error.localizedDescription, formatter: formatter.name)
            }
            let kept = lines.map { LineDiff.changes(from: text, to: formatted, within: $0) } ?? formatted
            // Typed into while it ran: those keystrokes win.
            guard document.text == text, kept != text else { return FormatOutcome(formatter: formatter.name) }
            guard apply(WorkspaceEdit(files: [url.standardizedFileURL: [Self.replacement(of: text, with: kept)]])) else {
                return .failed("The file couldn't be changed.", formatter: formatter.name)
            }
            return FormatOutcome(formatter: formatter.name, changed: true)
        case .server:
            let nothing = "Nothing formats .\(url.pathExtension) files here: the language server can't, and the project has no formatter Orbit recognizes (\(FormatterPreset.all.map(\.name).joined(separator: ", "))). Set one for this file type in .orbit/settings.json — Settings → Languages → Formatting."
            guard let server = await formattingServer(url) else { return .failed(nothing) }
            if server.state == .starting {
                return .failed("The \(server.config.name) language server is still starting. Try again in a moment.")
            }
            guard server.state == .running, server.formats else { return .failed(nothing) }
            let name = "\(server.config.name) language server"
            let indent = Indentation.of(url, text: document.text, root: root)
            guard let edits = await server.formatting(url.standardizedFileURL, tabSize: indent.size, insertSpaces: indent.spaces) else {
                return .failed("It couldn't format this file.", formatter: name)
            }
            guard !edits.isEmpty else { return FormatOutcome(formatter: name) }
            var change = edits
            if let lines {
                let text = document.text
                let kept = LineDiff.changes(from: text, to: SourceEdit.apply(edits, to: text), within: lines)
                guard kept != text else { return FormatOutcome(formatter: name) }
                change = [Self.replacement(of: text, with: kept)]
            }
            guard apply(WorkspaceEdit(files: [url.standardizedFileURL: change])) else { return .failed("The file couldn't be changed.", formatter: name) }
            return FormatOutcome(formatter: name, changed: true)
        }
    }

    /// One edit over just the part that differs: the caret and scroll stay put outside it.
    nonisolated static func replacement(of old: String, with new: String) -> SourceEdit {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Never between the halves of a surrogate pair (an emoji).
        while prefix > 0, UTF16.isTrailSurrogate(a[min(prefix, a.count - 1)]), prefix < a.count { prefix -= 1 }
        while suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let starts = SourcePosition.lineStarts(of: old as NSString)
        let range = SourceRange(
            start: SourcePosition(offset: prefix, in: starts),
            end: SourcePosition(offset: a.count - suffix, in: starts)
        )
        let text = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return SourceEdit(range: range, newText: text)
    }

    /// The language server, or the one of the file's servers it leaves formatting to (Vue's, D74).
    private func formatter(for url: URL) -> LanguageServer? {
        guard let key = languageKey(for: url) else { return nil }
        if let other = serverConfig(id: key.id)?.formatsWith { return server(id: other, for: url) }
        return servers[key]
    }

    /// `formatter(for:)` with the file's latest text.
    private func formattingServer(_ url: URL) async -> LanguageServer? {
        guard let server = formatter(for: url) else { return nil }
        if let document = workspace.documents.existingDocument(for: url) { server.sync(document.url, text: document.text) }
        return server
    }

    private func formatterChoice(for url: URL, environment: [String: String]? = nil) throws -> FormatterChoice {
        try ProjectFormatter.choice(for: url, root: root, environment: environment ?? shellEnvironment ?? ProcessInfo.processInfo.environment)
    }

    var hasFolder: Bool { workspace.root != nil }

    /// For Settings: what formats what in the open folder, and why.
    func formattingOverview() async -> FormattingOverview {
        let environment = await environment.value
        let root = root
        return await Task.detached(priority: .userInitiated) { FormattingOverview(root: root, environment: environment) }.value
    }

    /// Opens `.orbit/settings.json` (the project's, or the user's without a folder), creating it with an example.
    func editFormatterSettings(project: Bool) {
        let url = project ? root.map(FormatterSettings.projectFile) : FormatterSettings.userFile()
        guard let url else { return }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FormatterSettings.example.write(to: url, atomically: true, encoding: .utf8)
        }
        workspace.openFile(url)
    }

    var problems: [FileProblems] {
        // A file's language server and ESLint report the same file.
        var byFile: [URL: [Diagnostic]] = [:]
        for server in servers.values {
            for (url, diagnostics) in server.diagnostics where !diagnostics.isEmpty { byFile[url, default: []] += diagnostics }
        }
        for file in tasks()?.problems ?? [] {
            byFile[file.url] = Self.adding(file.diagnostics, to: byFile[file.url] ?? [])
        }
        return byFile.map { url, diagnostics in FileProblems(url: url, diagnostics: diagnostics.sorted { $0.range.start < $1.range.start }) }
        .sorted { lhs, rhs in
            let left = lhs.diagnostics.map(\.severity).max() ?? .hint, right = rhs.diagnostics.map(\.severity).max() ?? .hint
            return left != right ? left > right : lhs.url.path < rhs.url.path
        }
    }

    /// Open files change through the editor (one undo step each); others are edited on disk.
    @discardableResult
    func apply(_ edit: WorkspaceEdit) -> Bool {
        var worked = true
        for (url, edits) in edit.files where !edits.isEmpty {
            if editing()?.apply(edits, to: url) == true { continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                worked = false
                continue
            }
            // A file that isn't open is edited on disk without opening a buffer for
            // it: a project-wide rename would otherwise keep every file in memory.
            let document = workspace.documents.existingDocument(for: url)
            guard let current = document?.text ?? workspace.documents.currentText(of: url) else {
                worked = false
                continue
            }
            let text = SourceEdit.apply(edits, to: current)
            do {
                if let document, document.isDirty {
                    document.text = text
                } else {
                    try workspace.documents.write(TextFile.normalized(text), to: url)
                }
            } catch {
                worked = false
            }
        }
        return worked
    }

    /// The first of the file's servers (its language's, then ESLint, Tailwind…) that isn't installed.
    private func offeredConfig(for url: URL) -> LanguageServerConfig? {
        keys(for: url).lazy.compactMap { key -> LanguageServerConfig? in
            guard let config = self.serverConfig(id: key.id), config.install != nil, !self.declined.contains(config.id) else { return nil }
            if self.installing.contains(config.id) || self.installFailures[config.id] != nil { return config }
            if case .unavailable = self.unavailable[key] { return config }
            return nil
        }.first
    }

    func installOffer(for url: URL) -> LanguageInstallOffer? {
        guard let config = offeredConfig(for: url), let install = config.install else { return nil }
        return LanguageInstallOffer(
            name: config.name, needs: install.needs,
            isInstalling: installing.contains(config.id), failure: installFailures[config.id], purpose: config.purpose
        )
    }

    func installServer(for url: URL) {
        guard let config = offeredConfig(for: url) else { return }
        Task { await install(config.id) }
    }

    func declineInstall(for url: URL) {
        guard let config = offeredConfig(for: url) else { return }
        declined.insert(config.id)
        UserDefaults.standard.set(declined.sorted(), forKey: Self.declinedKey)
    }

    func config(for url: URL) -> LanguageServerConfig? {
        languageKey(for: url).flatMap { serverConfig(id: $0.id) }
    }

    // MARK: LanguageIntelligence

    func diagnostics(for url: URL) -> [Diagnostic] {
        let file = url.standardizedFileURL
        let reported = keys(for: url).flatMap { servers[$0]?.diagnostics[file] ?? [] }
        guard let printed = tasks()?.problems.first(where: { $0.url == file }) else { return reported }
        return Self.adding(printed.diagnostics, to: reported)
    }

    /// A task's errors beside the servers', without the ones a server reports too (`tsc` and tsserver).
    nonisolated static func adding(_ printed: [Diagnostic], to reported: [Diagnostic]) -> [Diagnostic] {
        let known = Set(reported.map { "\($0.range.start.line):\($0.message)" })
        return reported + printed.filter { !known.contains("\($0.range.start.line):\($0.message)") }
    }

    /// ESLint, Tailwind… running beside the file's language server, for the status bar.
    func companions(for url: URL) -> [(name: String, state: LanguageServerState)] {
        keys(for: url).compactMap { key in
            guard let config = serverConfig(id: key.id), config.isCompanion else { return nil }
            return (config.name, unavailable[key] ?? servers[key]?.state ?? .starting)
        }
    }

    func server(for url: URL) -> (name: String, state: LanguageServerState)? {
        guard let key = languageKey(for: url), let config = serverConfig(id: key.id) else { return nil }
        if let state = unavailable[key] { return (config.name, state) }
        return (config.name, servers[key]?.state ?? .starting)
    }

    /// The language server's, then what the others add (Tailwind's CSS for a class).
    func hover(at position: SourcePosition, in url: URL) async -> HoverInfo? {
        let file = url.standardizedFileURL
        let answers = await gather(url, deadline: Self.queryDeadline) { await $0.hover(at: position, in: file) }.map(\.1)
        guard let first = answers.first else { return nil }
        return HoverInfo(markdown: answers.map(\.markdown).joined(separator: "\n\n"), range: first.range)
    }

    func definition(at position: SourcePosition, in url: URL) async -> [SourceLocation] {
        await flush(url)?.definition(at: position, in: url.standardizedFileURL) ?? []
    }

    func triggers(for url: URL) -> LanguageTriggers {
        var triggers = LanguageTriggers()
        for key in keys(for: url) {
            guard let server = servers[key], server.state == .running else { continue }
            triggers.completion.formUnion(server.triggers.completion)
            // Signature help is the language server's alone.
            if !server.config.isCompanion {
                triggers.signatureHelp = server.triggers.signatureHelp
                triggers.signatureHelpRetrigger = server.triggers.signatureHelpRetrigger
            }
        }
        return triggers
    }

    /// Every server's suggestions in one list; each item remembers its server for `resolve`.
    func completions(at position: SourcePosition, in url: URL, trigger: CompletionTrigger) async -> CompletionList? {
        let file = url.standardizedFileURL
        let lists = await gather(url) { server -> CompletionList? in
            // A trigger character belongs to the server that declared it.
            if case .character(let character) = trigger, !server.triggers.completion.contains(character) { return nil }
            return await server.completions(at: position, in: file, trigger: trigger)
        }
        guard !lists.isEmpty, !Task.isCancelled else { return nil }
        if lists.count == 1, let (server, list) = lists.first, !server.config.isCompanion { return list }
        var items: [CompletionItem] = []
        for (server, list) in lists {
            items += list.items.map { item in
                var item = item
                item.server = server.config.id
                return item
            }
        }
        return CompletionList(items: items, isIncomplete: lists.contains { $0.1.isIncomplete })
    }

    func resolve(_ item: CompletionItem, in url: URL) async -> CompletionItem {
        guard let server = item.server.flatMap({ server(id: $0, for: url) }) ?? runningServer(for: url) else { return item }
        return await server.resolve(item)
    }

    func signatureHelp(at position: SourcePosition, in url: URL, trigger: String?, isRetrigger: Bool) async -> SignatureHelp? {
        await flush(url)?.signatureHelp(at: position, in: url.standardizedFileURL, trigger: trigger, isRetrigger: isRetrigger)
    }

    // MARK: Navigation (D62)

    func references(at position: SourcePosition, in url: URL) async -> [SourceLocation] {
        await flush(url)?.references(at: position, in: url.standardizedFileURL) ?? []
    }

    func highlights(at position: SourcePosition, in url: URL) async -> [SymbolHighlight] {
        await flush(url)?.highlights(at: position, in: url.standardizedFileURL) ?? []
    }

    func symbols(in url: URL) async -> [LanguageSymbol]? {
        await flush(url)?.symbols(in: url.standardizedFileURL)
    }

    // MARK: Inlay hints

    /// The language server's alone: companions (ESLint, Tailwind) have none.
    func inlayHints(in range: SourceRange, url: URL) async -> [InlayHint] {
        await flush(url)?.inlayHints(in: range, url: url.standardizedFileURL) ?? []
    }

    func inlayHintsRevision(for url: URL) -> Int {
        runningServer(for: url)?.inlayHintsRevision ?? 0
    }

    func foldingRanges(in url: URL) async -> [FoldingRange]? {
        await flush(url)?.foldingRanges(in: url.standardizedFileURL)
    }

    /// Only servers already running answer: one for a language nobody opened isn't started for a search.
    func projectSymbols(matching query: String) async -> [LanguageSymbol] {
        let searching = servers.values.filter { $0.state == .running && $0.searchesSymbols }
        return await withTaskGroup(of: [LanguageSymbol].self) { group in
            for server in searching {
                group.addTask { await server.projectSymbols(matching: query) }
            }
            var all: [LanguageSymbol] = []
            for await symbols in group { all += symbols }
            return all
        }
    }
}
