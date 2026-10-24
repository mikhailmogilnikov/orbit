import Foundation

// The stress run (D244): `make stress` drives a debug build through every
// feature, in a fixed order and at random, and stops on a crash, a hang, a busy
// main thread or a broken check. Each plugin brings its own part through
// `context.stress`: steps (what to do with its features), checks (what has to
// hold after any step), files for the run's project, and exemptions (what a
// run leaves out, with why). A command, panel, editor or Settings pane that
// no step reaches and nothing exempts fails the run, and `StressCoverageTests`.

/// One thing a run does: type, split, simulate an agent edit, commit.
public struct StressStep: Identifiable {
    public let id: String
    public internal(set) var pluginID: String?
    /// How often the random part picks it, against the others' weights.
    public let weight: Int
    /// What it reaches besides what it runs through `StressContext.run`:
    /// coverage keys such as "provider:git.diff" (`StressCoverage`).
    public let covers: [String]
    /// A sequence that once broke Orbit: every run plays it in its fixed part.
    public let isRegression: Bool
    public let isAvailable: @MainActor (StressContext) -> Bool
    public let run: @MainActor (StressContext) async -> Void

    public init(
        _ id: String, weight: Int = 3, covers: [String] = [], regression: Bool = false,
        when isAvailable: @escaping @MainActor (StressContext) -> Bool = { _ in true },
        run: @escaping @MainActor (StressContext) async -> Void
    ) {
        self.id = id
        self.weight = weight
        self.covers = covers
        isRegression = regression
        self.isAvailable = isAvailable
        self.run = run
    }
}

/// What has to hold after every step: nil when it does, else what's wrong.
public struct StressCheck: Identifiable {
    public let id: String
    public internal(set) var pluginID: String?
    public let verify: @MainActor (StressContext) -> String?

    public init(_ id: String, verify: @escaping @MainActor (StressContext) -> String?) {
        self.id = id
        self.verify = verify
    }
}

/// A step's view of the run: the window's registries, the run's project and
/// its random numbers (seeded, so a run replays).
@MainActor
public final class StressContext {
    public let workspace: Workspace
    public let commands: CommandRegistry
    public let ui: UIRegistry
    public let services: ServiceRegistry
    /// The run's project: every plugin's files (`StressRegistry.addFile`) in it.
    public let project: URL
    private var random: StressRandom
    private let reached: (String) -> Void
    private let waitForIdle: () async -> Void
    private let log: (String) -> Void

    public init(
        host: PluginHost, project: URL, seed: UInt64,
        reached: @escaping (String) -> Void, settle: @escaping () async -> Void, note: @escaping (String) -> Void
    ) {
        workspace = host.workspace
        commands = host.commands
        ui = host.ui
        services = host.services
        self.project = project
        random = StressRandom(seed: seed)
        self.reached = reached
        waitForIdle = settle
        log = note
    }

    public func file(_ path: String) -> URL { project.appendingPathComponent(path) }

    /// Runs a command if it's enabled, counting it as reached; false when it wasn't.
    @discardableResult
    public func run(_ commandID: String) -> Bool {
        guard let command = commands.all.first(where: { $0.id == commandID }), command.isEnabled() else { return false }
        reached(StressCoverage.command(commandID))
        command.run()
        return true
    }

    /// Opens a file of the run's project and waits for its editor.
    public func open(_ path: String) async {
        workspace.openFile(file(path))
        await settle()
    }

    /// Waits until the main thread has nothing left to do (layout, highlighting
    /// passes): what a step did has landed.
    public func settle() async { await waitForIdle() }

    /// A line in the run's log under the step.
    public func note(_ text: String) { log(text) }

    public func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(random.next() % UInt64(range.count))
    }

    public func chance(_ probability: Double) -> Bool {
        Double(random.next() % 1_000_000) / 1_000_000 < probability
    }

    public func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[int(0...(items.count - 1))]
    }

    /// Several of `items`, in random order.
    public func some<T>(_ items: [T], count: Int) -> [T] {
        var pool = items, result: [T] = []
        while result.count < count, !pool.isEmpty { result.append(pool.remove(at: int(0...(pool.count - 1)))) }
        return result
    }
}

/// SplitMix64: small, fast, and the same numbers for the same seed on every Mac.
public struct StressRandom {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What a run has to reach: everything the registries hold, by kind.
public enum StressCoverage {
    public static func command(_ id: String) -> String { "command:\(id)" }
    public static func panel(_ id: String) -> String { "panel:\(id)" }
    public static func provider(_ id: String) -> String { "provider:\(id)" }
    public static func settings(_ id: String) -> String { "settings:\(id)" }
    public static func status(_ id: String) -> String { "status:\(id)" }
    public static func source(_ kind: ExtensionKind) -> String { "source:\(kind.rawValue)" }
    public static func plugin(_ id: String) -> String { "plugin:\(id)" }
    public static func step(_ id: String) -> String { "step:\(id)" }

    /// The exemption that leaves `key` out: its own, or one ending in "*" that it starts with.
    public static func exemption(for key: String, in exemptions: [String: String]) -> String? {
        if let reason = exemptions[key] { return reason }
        return exemptions.first { $0.key.hasSuffix("*") && key.hasPrefix($0.key.dropLast()) }?.value
    }

    /// Exemptions no key matches any more: the feature went, the exemption should too.
    public static func staleExemptions(_ exemptions: [String: String], keys: Set<String>) -> [String] {
        exemptions.keys.filter { exemption in
            exemption.hasSuffix("*") ? !keys.contains { $0.hasPrefix(exemption.dropLast()) } : !keys.contains(exemption)
        }.sorted()
    }

    /// Every key of the window's registries.
    @MainActor
    public static func keys(in host: PluginHost) -> Set<String> {
        let ui = host.ui
        var keys = Set(host.commands.all.map { command($0.id) })
        keys.formUnion((ui.sidebarPanels + ui.inspectorPanels + ui.bottomPanels).map { panel($0.id) })
        keys.formUnion(ui.editorProviders.map { provider($0.id) })
        keys.formUnion(ui.settingsPanes.map { settings($0.id) })
        keys.formUnion(ui.statusItems.map { status($0.id) })
        keys.formUnion(ui.extensionSources.map { source($0.kind) })
        keys.formUnion(host.entries.filter { !$0.manifest.isRequired }.map { plugin($0.id) })
        keys.formUnion(host.stress.steps.map { step($0.id) })
        return keys
    }
}

@MainActor
final class StressState {
    var steps: [StressStep] = []
    var checks: [StressCheck] = []
    var files: [(owner: String?, path: String, contents: Data)] = []
    var preparations: [(owner: String?, prepare: @MainActor (URL) throws -> Void)] = []
    var exemptions: [String: (owner: String?, reason: String)] = [:]
}

/// The window's stress parts; like `UIRegistry`, one per plugin over shared
/// contents, stamped with its id (D194).
@MainActor
public final class StressRegistry {
    let state: StressState
    let owner: String?
    private let lifetime: PluginLifetime?

    init() {
        state = StressState()
        owner = nil
        lifetime = nil
    }

    init(sharing registry: StressRegistry, owner: String, lifetime: PluginLifetime) {
        state = registry.state
        self.owner = owner
        self.lifetime = lifetime
    }

    private var accepts: Bool { lifetime?.isActive ?? true }

    /// Set by the runner before any window: a plugin keeps a run off the user's
    /// own things (Agents lists only a pretend agent).
    public static var isRunning = false

    public var steps: [StressStep] { state.steps }
    public var checks: [StressCheck] { state.checks }
    /// Coverage keys left out of runs, with why ("command:git.push": "pushes to a remote").
    public var exemptions: [String: String] { state.exemptions.mapValues(\.reason) }

    public func add(_ step: StressStep) {
        guard accepts else { return }
        var step = step
        step.pluginID = owner
        state.steps.removeAll { $0.id == step.id }
        state.steps.append(step)
    }

    public func add(_ check: StressCheck) {
        guard accepts else { return }
        var check = check
        check.pluginID = owner
        state.checks.removeAll { $0.id == check.id }
        state.checks.append(check)
    }

    /// A file of the run's project, at a path relative to its root.
    public func addFile(_ path: String, _ text: String) { addFile(path, Data(text.utf8)) }

    public func addFile(_ path: String, _ contents: Data) {
        guard accepts else { return }
        state.files.append((owner, path, contents))
    }

    /// Run on the written project before it opens (a git repository, links).
    public func prepare(_ work: @escaping @MainActor (URL) throws -> Void) {
        guard accepts else { return }
        state.preparations.append((owner, work))
    }

    /// Leaves a coverage key out of runs. The reason is the one a reviewer reads.
    public func exempt(_ key: String, because reason: String) {
        guard accepts else { return }
        state.exemptions[key] = (owner, reason)
    }

    /// Writes every plugin's files under `root` and runs their preparations.
    public func makeProject(at root: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for file in state.files {
            let url = root.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: url)
        }
        for preparation in state.preparations { try preparation.prepare(root) }
    }

    func removeAll() { state.steps = []; state.checks = []; state.files = []; state.preparations = []; state.exemptions = [:] }

    func remove(owner: String) {
        state.steps.removeAll { $0.pluginID == owner }
        state.checks.removeAll { $0.pluginID == owner }
        state.files.removeAll { $0.owner == owner }
        state.preparations.removeAll { $0.owner == owner }
        state.exemptions = state.exemptions.filter { $0.value.owner != owner }
    }
}
