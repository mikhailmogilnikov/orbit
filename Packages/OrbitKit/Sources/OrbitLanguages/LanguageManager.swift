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
    private(set) var servers: [String: LanguageServer] = [:]
    /// Servers that couldn't start, so files of their language say why without retrying on every keystroke.
    private(set) var unavailable: [String: LanguageServerState] = [:]

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
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var idleTasks: [String: Task<Void, Never>] = [:]

    /// Typing pauses this long before the server hears about it.
    private static let syncDelay: Duration = .milliseconds(120)
    /// A server with no open files of its language is stopped after this.
    private static let idleTimeout: Duration = .seconds(600)

    init(workspace: Workspace) {
        self.workspace = workspace
        environment = Task.detached { await ShellEnvironment.resolve() }
        root = workspace.root
        observe()
    }

    // MARK: Following the workspace

    /// Re-arms on every change to the open documents' set or text.
    private func observe() {
        withObservationTracking {
            _ = workspace.root
            for document in workspace.documents.open.values { _ = document.revision }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleSync()
                self?.observe()
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
        if workspace.root != root {
            root = workspace.root
            for server in servers.values { server.shutdown() }
            servers.removeAll()
            unavailable.removeAll()
        }
        guard let root else { return }

        let documents = workspace.documents.open.values.filter { $0.loadError == nil }
        var wanted: [String: [TextDocument]] = [:]
        for document in documents {
            guard let config = LanguageServerConfig.config(for: document.url) else { continue }
            wanted[config.id, default: []].append(document)
        }

        for (id, server) in servers {
            let open = Set((wanted[id] ?? []).map(\.url))
            for url in server.openDocuments where !open.contains(url) { server.close(url) }
            if open.isEmpty { scheduleIdleShutdown(id) } else { idleTasks.removeValue(forKey: id)?.cancel() }
        }

        for (id, documents) in wanted where unavailable[id] == nil {
            guard let config = LanguageServerConfig.all.first(where: { $0.id == id }) else { continue }
            let server: LanguageServer
            if let running = servers[id] {
                server = running
            } else {
                server = LanguageServer(config: config, root: root)
                servers[id] = server
            }
            guard await server.start(environment: environment) else {
                unavailable[id] = server.state
                servers[id] = nil
                continue
            }
            for document in documents { server.sync(document.url, text: document.text) }
        }
    }

    private func scheduleIdleShutdown(_ id: String) {
        guard idleTasks[id] == nil else { return }
        idleTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, let self else { return }
            idleTasks[id] = nil
            guard let server = servers[id], server.openDocuments.isEmpty else { return }
            server.shutdown()
            servers[id] = nil
        }
    }

    /// Before asking about a file, send its latest text right away.
    private func flush(_ url: URL) async -> LanguageServer? {
        guard let config = LanguageServerConfig.config(for: url), let server = servers[config.id] else { return nil }
        if let document = workspace.documents.existingDocument(for: url) { server.sync(document.url, text: document.text) }
        return server
    }

    /// Stops every server and forgets failures; open files start them again.
    func restart() {
        for server in servers.values { server.shutdown() }
        servers.removeAll()
        unavailable.removeAll()
        scheduleSync()
    }

    func shutdown() {
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
        let root = workspace.root ?? FileManager.default.homeDirectoryForCurrentUser
        let (receipts, found) = await Task.detached(priority: .utility) {
            var receipts: [String: LanguageInstaller.Receipt] = [:]
            var found: [String: String] = [:]
            for config in LanguageServerConfig.all {
                if let install = config.install, let receipt = installer.receipt(for: install.package) {
                    receipts[install.package] = receipt
                }
                if let command = config.resolve(root, environment) { found[config.id] = command.executable }
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
    private func restartServer(_ id: String) {
        servers.removeValue(forKey: id)?.shutdown()
        unavailable[id] = nil
        scheduleSync()
    }

    private static let declinedKey = "orbit.languages.declinedInstalls"
    private var declined = Set(UserDefaults.standard.stringArray(forKey: LanguageManager.declinedKey) ?? [])

    func installOffer(for url: URL) -> LanguageInstallOffer? {
        guard let config = config(for: url), let install = config.install, !declined.contains(config.id) else { return nil }
        let isInstalling = installing.contains(config.id)
        let failure = installFailures[config.id]
        var isMissing = false
        if case .unavailable = unavailable[config.id] { isMissing = true }
        guard isInstalling || failure != nil || isMissing else { return nil }
        return LanguageInstallOffer(name: config.name, needs: install.needs, isInstalling: isInstalling, failure: failure)
    }

    func installServer(for url: URL) {
        guard let config = config(for: url) else { return }
        Task { await install(config.id) }
    }

    func declineInstall(for url: URL) {
        guard let config = config(for: url) else { return }
        declined.insert(config.id)
        UserDefaults.standard.set(declined.sorted(), forKey: Self.declinedKey)
    }

    func config(for url: URL) -> LanguageServerConfig? {
        LanguageServerConfig.config(for: url)
    }

    // MARK: LanguageIntelligence

    func diagnostics(for url: URL) -> [Diagnostic] {
        guard let config = LanguageServerConfig.config(for: url) else { return [] }
        return servers[config.id]?.diagnostics[url.standardizedFileURL] ?? []
    }

    func server(for url: URL) -> (name: String, state: LanguageServerState)? {
        guard let config = LanguageServerConfig.config(for: url) else { return nil }
        if let state = unavailable[config.id] { return (config.name, state) }
        return (config.name, servers[config.id]?.state ?? .starting)
    }

    func hover(at position: SourcePosition, in url: URL) async -> HoverInfo? {
        await flush(url)?.hover(at: position, in: url.standardizedFileURL)
    }

    func definition(at position: SourcePosition, in url: URL) async -> [SourceLocation] {
        await flush(url)?.definition(at: position, in: url.standardizedFileURL) ?? []
    }

    func triggers(for url: URL) -> LanguageTriggers {
        guard let config = LanguageServerConfig.config(for: url), let server = servers[config.id], server.state == .running else {
            return LanguageTriggers()
        }
        return server.triggers
    }

    func completions(at position: SourcePosition, in url: URL, trigger: CompletionTrigger) async -> CompletionList? {
        await flush(url)?.completions(at: position, in: url.standardizedFileURL, trigger: trigger)
    }

    func resolve(_ item: CompletionItem, in url: URL) async -> CompletionItem {
        guard let config = LanguageServerConfig.config(for: url), let server = servers[config.id] else { return item }
        return await server.resolve(item)
    }

    func signatureHelp(at position: SourcePosition, in url: URL, trigger: String?, isRetrigger: Bool) async -> SignatureHelp? {
        await flush(url)?.signatureHelp(at: position, in: url.standardizedFileURL, trigger: trigger, isRetrigger: isRetrigger)
    }
}
