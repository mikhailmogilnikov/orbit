#if DEBUG
import AppKit
import OrbitKit
import os

/// Debug builds only: runs a stress plan (D244). `scripts/stress.sh` starts a
/// copy of the build with `orbit.stress` set; the runner writes the plugins'
/// project, opens it and goes through everything the window's registries hold
/// (every command, panel, Settings pane, plugin switch and plugin step, the
/// regressions), then random steps. After each step the main thread has to go
/// idle, the checks have to hold and no sheet may be left up. It writes its
/// log, coverage and result to the plan's folder and exits; a hang is the
/// watchdog's, a crash the script's to report.
@MainActor
final class StressRunner {
    static let shared = StressRunner()
    nonisolated(unsafe) private static var exceptionFile: String?
    nonisolated(unsafe) private static var resultFile: String?

    struct Plan: Decodable {
        var seed: UInt64
        var steps: Int
        var project: String
        var output: String
        var background: Bool
        /// Only the fixed part (`STEPS=0`) still checks coverage.
        var checksCoverage: Bool?
        /// A failed run's log.txt: its steps again, in its order, and nothing else.
        var replay: String?
        /// Parallel copies split the fixed part: this one takes every `shards`th
        /// thing from `shard` on, and the script adds up their coverage.
        var shard: Int?
        var shards: Int?
        /// Thousands of files in the project, for the index, search and the tree.
        var bigProject: Bool?
        /// `leaks` on the process once the steps pass: Orbit's objects nothing points to fail the run (D246).
        var leaks: Bool?
        /// A footprint over this fails the run (D246).
        var memoryLimitMB: Int?
        /// The plugin modules whose code changed since a run passed: only
        /// their plugins' part runs, with what uses them, and the shell's (D246).
        var changed: [String]?
        /// Allocations are logged (for `malloc_history`): everything is slower.
        var stacks: Bool?
        /// After the fixed part, every panel, Settings pane and a few editors
        /// shown and shot for the run's gallery (D248).
        var gallery: Bool?
        /// Measure instead of break: perf.json (D248).
        var perf: Bool?
        /// False: what steps let go of isn't checked, so a crash past a
        /// flaky leak can be played again (`PILING=0`, D250).
        var piling: Bool?
    }

    private var plan: Plan?
    private var random = StressRandom(seed: 0)
    private var log: FileHandle?
    private var stepCount = 0
    private var reached: Set<String> = []
    private var known: Set<String> = []
    /// Every key, run or not: an exemption matching none is stale.
    private var allKnown: Set<String> = []
    /// With `changed`, the plugins this run covers; nil when all.
    private var covering: Set<String>?
    private var owners: [String: String] = [:]
    private var exemptions: [String: String] = [:]
    private var unavailable: Set<String> = []
    private var sentBack: Set<Int> = []
    private var openMenu: NSMenu?
    private let heartbeat = OSAllocatedUnfairLock(initialState: (beat: Date(), step: "", paused: false))
    private var toFree: [(what: String, object: Weak)] = []
    /// What steps let go of and still lives, by kind, weakly.
    private var lettingGo: [String: [Weak]] = [:]
    private var peakFootprint = 0
    private var alertCount = 0
    private var windowAfter: TimeInterval = 0

    private final class Weak {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    /// Full screen takes a Space of its own and switches to it: only in front.
    var inBackground: Bool { plan?.background ?? true }

    private var output: URL { URL(fileURLWithPath: plan?.output ?? "/tmp") }
    private var project: URL { URL(fileURLWithPath: plan?.project ?? "/tmp") }

    func start() {
        guard let json = UserDefaults.standard.string(forKey: "orbit.stress"),
              let plan = try? JSONDecoder().decode(Plan.self, from: Data(json.utf8)) else { return }
        self.plan = plan
        StressRegistry.isRunning = true
        random = StressRandom(seed: plan.seed)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: output.appendingPathComponent("log.txt").path, contents: nil)
        log = try? FileHandle(forWritingTo: output.appendingPathComponent("log.txt"))
        ProjectWindows.shared.activatesApp = !plan.background
        StressAnswers.alert = { [weak self] alert in self?.answer(alert) ?? .cancel }
        // An exception's reason, which the crash report leaves out (AppKit's
        // layout loops say which view): exception.txt beside the log (D247).
        Self.exceptionFile = output.appendingPathComponent("exception.txt").path
        NSSetUncaughtExceptionHandler { exception in
            guard let path = StressRunner.exceptionFile else { return }
            let text = "\(exception.name.rawValue): \(exception.reason ?? "")\n\(exception.userInfo.map { "\($0)" } ?? "")\n" + exception.callStackSymbols.joined(separator: "\n")
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
        // A copy that quits on its own (an exit, AppKit terminating) leaves no
        // crash report: who quit it goes in result.txt instead (D250).
        Self.resultFile = output.appendingPathComponent("result.txt").path
        atexit_b {
            guard let path = StressRunner.resultFile, !FileManager.default.fileExists(atPath: path) else { return }
            let quit = (path as NSString).deletingLastPathComponent + "/quit.txt"
            FileManager.default.createFile(atPath: quit, contents: Data(Thread.callStackSymbols.joined(separator: "\n").utf8))
            FileManager.default.createFile(atPath: path, contents: Data("quit on its own, no crash (quit.txt says from where)".utf8))
        }
        NSScrollView.watchForTileLoops()
        TileLoops.report = { [weak self] in self?.note($0) }
        startHeartbeat()
        Task { await run() }
    }

    // MARK: The run

    private func run() async {
        guard let host = await waitForHost() else { return finish("no window to run in") }
        windowAfter = Self.sinceLaunch()
        // Writing the project runs git on this thread, slowly the first time on a new Mac: not a hang.
        heartbeat.withLock { $0.paused = true }
        do {
            try? FileManager.default.removeItem(at: project)
            try host.stress.makeProject(at: project)
        } catch {
            return finish("couldn't write the project: \(error.localizedDescription)")
        }
        if plan!.bigProject == true { writeBigProject() }
        heartbeat.withLock { $0.paused = false; $0.beat = Date() }
        guard await openProject() else { return finish("the project didn't open") }
        chooseCovered()
        noteCoverage()
        note("project \(project.path), seed \(plan!.seed)")

        if let replay = plan!.replay {
            return await replaySteps(from: replay)
        }
        if plan!.perf == true { return await measure() }

        // The fixed part: everything once, in a fixed order, this copy's share of it.
        let commands = currentHost.commands.all.map(\.id).sorted().filter { !isExempt(StressCoverage.command($0)) }
        for id in commands where isMine(StressCoverage.command(id)) {
            await step("command \(id)") { context in
                if !context.run(id) {
                    // Most need a file open; still off, it's the coverage report's.
                    await context.open(Self.textFile)
                    context.run(id)
                }
            }
        }
        for panel in panels() where isMine(StressCoverage.panel(panel.id)) {
            await step("panel \(panel.id)") { [weak self] _ in self?.reveal(panel.id) }
        }
        for pane in currentHost.ui.settingsPanes.map(\.id) where isMine(StressCoverage.settings(pane)) {
            await step("settings \(pane)") { [weak self] context in
                context.ui.showSettings(pane)
                self?.reached.insert(StressCoverage.settings(pane))
            }
        }
        await step("settings closed") { context in context.ui.isSettingsVisible = false }
        for entry in currentHost.entries where !entry.manifest.isRequired && !isExempt(StressCoverage.plugin(entry.id))
            && isMine(StressCoverage.plugin(entry.id)) {
            await step("plugin \(entry.id) off and on") { [weak self] _ in
                guard let self else { return }
                // Three times: a leak keeps all three.
                for _ in 0..<3 {
                    await turnOffAndOn(entry.id)
                    await settle()
                }
                reached.insert(StressCoverage.plugin(entry.id))
            }
        }
        // By id, each looked up when it runs: a list of steps holds their
        // closures, and so the models of a plugin a step turns off.
        for id in currentHost.stress.steps.map(\.id).sorted() where isMine(StressCoverage.step(id)) {
            if let stressStep = currentHost.stress.steps.first(where: { $0.id == id }) { await run(stressStep, preparing: true) }
        }
        // Commands that were off the first time (nothing to go back to, no
        // split, no stash, no agent change): each step that makes such state,
        // then every command still off that it turned on, again while it turns
        // more on (Keep Change takes the change Undo Change needed) (D246; one
        // by one, each command ran every setup until it came on).
        var waiting = commands.filter { isMine(StressCoverage.command($0)) && !reached.contains(StressCoverage.command($0)) }
        for setup in ["", "shell.richState", "review.agentTurn", "git.stash", "git.stage", "preview.markdown", "terminal.command", "agents.reviewComments", "open"] {
            for _ in 0..<(setup.isEmpty || setup == "open" ? 1 : 3) where !waiting.isEmpty {
                switch setup {
                case "": break
                case "open": await step("open docs/readme.md") { context in await context.open("docs/readme.md") }
                default:
                    guard let prepare = currentHost.stress.steps.first(where: { $0.id == setup }) else { break }
                    await run(prepare, preparing: false)
                }
                let before = waiting.count
                for id in waiting where currentHost.commands.all.first(where: { $0.id == id })?.isEnabled() == true {
                    await step("command \(id)") { context in context.run(id) }
                }
                waiting.removeAll { reached.contains(StressCoverage.command($0)) }
                if waiting.count == before { break }
            }
        }
        note("fixed part: \(stepCount) steps")
        if plan!.gallery == true { await galleryTour() }
        // With shards each copy reached only its share: the script decides.
        if (plan!.shards ?? 1) == 1, plan!.checksCoverage ?? true, let uncovered = uncoveredReport() {
            return finish(uncovered)
        }

        // The random part.
        for _ in 0..<plan!.steps {
            await randomStep()
        }
        finish(nil)
    }

    private static let textFile = "src/short.tsx"

    /// Whether a thing of the fixed part is this copy's: by its key, so every
    /// copy splits the same way without knowing the others' lists.
    /// The changed plugins, and what uses them (it requires them, or looked
    /// up their services: the editor shows Source Control's and Review's).
    private func chooseCovered() {
        guard let changed = plan?.changed else { return }
        let host = currentHost
        var covered = Set(host.entries.map(\.id).filter { host.moduleName(of: $0).map(changed.contains) == true })
        var added = covered
        while !added.isEmpty {
            added = Set(added.flatMap { host.users(of: $0) }).subtracting(covered)
            covered.formUnion(added)
        }
        covering = covered
        note("changed since a run passed: \(changed.sorted().joined(separator: ", ")); covering \(covered.sorted().joined(separator: ", ")) and the shell")
    }

    /// The shell's keys always; a plugin's when this run covers it.
    private func isCovered(_ key: String) -> Bool {
        guard let covering else { return true }
        if owners[key] == nil { owners = StressCoverage.owners(in: currentHost) }
        guard let owner = owners[key] else { return true }
        return covering.contains(owner)
    }

    private func isMine(_ key: String) -> Bool {
        guard isCovered(key) else { return false }
        let shards = UInt64(max(1, plan?.shards ?? 1))
        guard shards > 1 else { return true }
        // FNV-1a: the same on every run (Swift's hashValue isn't).
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return hash % shards == UInt64(plan?.shard ?? 0)
    }

    private func writeBigProject() {
        // 20 000 files in 400 folders: what a real monorepo's tree, index and search go through.
        let big = project.appendingPathComponent("big")
        for folder in 0..<400 {
            let directory = big.appendingPathComponent("package\(folder)/src/module\(folder % 7)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in 0..<50 {
                try? "export const value\(file) = \(folder * 50 + file)\n".write(
                    to: directory.appendingPathComponent("file\(file).ts"), atomically: false, encoding: .utf8)
            }
        }
        // Committed, as a monorepo's are: untracked, every `git status` listed them all.
        for arguments in [["add", "big"], ["-c", "user.name=Orbit Stress", "-c", "user.email=stress@orbit.invalid", "commit", "-qm", "A big tree"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = project
            try? git.run()
            git.waitUntilExit()
        }
    }

    /// A log's steps again (`REPLAY=…/log.txt make stress`), to reproduce a failure.
    private func replaySteps(from path: String) async {
        guard let log = try? String(contentsOfFile: path, encoding: .utf8) else { return finish("no log at \(path)") }
        // The failed run's seed and step numbers: each step's random numbers
        // come from both, so a step plays as it did with others left out (D246).
        if let seed = log.firstMatch(of: /, seed (\d+)\n/).flatMap({ UInt64($0.1) }) { plan?.seed = seed }
        for line in log.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":"), let number = Int(line[..<colon]) else { continue }
            stepCount = number - 1
            let label = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let words = label.split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2 else {
                if label == "settings closed" { await step(label) { context in context.ui.isSettingsVisible = false } }
                continue
            }
            let argument = words[1]
            switch words[0] {
            case "command":
                // As the fixed part runs one: again with a file open when it was off.
                let id = argument.replacingOccurrences(of: ", again", with: "")
                await step("command \(id)") { context in
                    if !context.run(id) {
                        await context.open(Self.textFile)
                        context.run(id)
                    }
                }
            case "open": await step("open \(argument)") { context in await context.open(argument) }
            case "panel": await step("panel \(argument)") { [weak self] _ in self?.reveal(argument) }
            case "settings": await step("settings \(argument)") { context in context.ui.showSettings(argument) }
            case "plugin":
                let id = String(argument.split(separator: " ")[0])
                await step("plugin \(id) off and on") { [weak self] _ in
                    for _ in 0..<3 { await self?.turnOffAndOn(id) }
                }
            case "step", "regression":
                if let found = currentHost.stress.steps.first(where: { $0.id == argument }) { await run(found, preparing: true) }
            default: continue
            }
        }
        finish(nil)
    }

    /// Picked from everything, available or not (skipped then): what's
    /// available depends on timing (a language server's answer), and the same
    /// seed has to give the same steps.
    private func randomStep() async {
        let (steps, total) = Self.weights(currentHost.stress.steps.filter { isCovered(StressCoverage.step($0.id)) })
        // A command or a file a quarter of the time each, a plugin's step otherwise.
        switch random.next() % 4 {
        case 0:
            let commands = currentHost.commands.all.map(\.id).filter { !isExempt(StressCoverage.command($0)) && isCovered(StressCoverage.command($0)) }.sorted()
            guard !commands.isEmpty else { return }
            let command = commands[Int(random.next() % UInt64(commands.count))]
            await step("command \(command)") { context in context.run(command) }
        case 1:
            let files = projectFiles()
            guard !files.isEmpty else { return }
            let file = files[Int(random.next() % UInt64(files.count))]
            await step("open \(file)") { context in await context.open(file) }
        default:
            guard total > 0 else { return }
            var roll = Int(random.next() % UInt64(total))
            for (id, weight) in steps {
                roll -= weight
                if roll < 0, let candidate = currentHost.stress.steps.first(where: { $0.id == id }) {
                    return await run(candidate, preparing: false)
                }
            }
        }
    }

    /// Ids and weights, not the steps: see the fixed part.
    private static func weights(_ steps: [StressStep]) -> (steps: [(id: String, weight: Int)], total: Int) {
        let sorted = steps.sorted { $0.id < $1.id }.map { ($0.id, $0.weight) }
        return (sorted, sorted.reduce(0) { $0 + $1.1 })
    }

    private func run(_ stressStep: StressStep, preparing: Bool) async {
        if !stressStep.isAvailable(context()) {
            guard preparing else { return note("skipped, not available: \(stressStep.id)") }
            if let needs = stressStep.needs, let prepare = currentHost.stress.steps.first(where: { $0.id == needs }) {
                note("first \(needs)")
                await prepare.run(context())
                await settle()
            }
            if !stressStep.isAvailable(context()) { await context().open(Self.textFile) }
            guard stressStep.isAvailable(context()) else {
                unavailable.insert(stressStep.id)
                return note("unavailable: \(stressStep.id)")
            }
        }
        await step("\(stressStep.isRegression ? "regression" : "step") \(stressStep.id)") { [weak self] context in
            self?.reached.insert(StressCoverage.step(stressStep.id))
            self?.reached.formUnion(stressStep.covers)
            await stressStep.run(context)
        }
    }

    /// One step: logged first (a crash names it), run, then the sheets it left
    /// closed, the main thread idle and every check holding.
    private func step(_ label: String, _ body: (StressContext) async -> Void) async {
        stepCount += 1
        alertCount = 0
        let line = "\(stepCount): \(label)"
        heartbeat.withLock { $0.step = line }
        write(line)
        if currentHost.workspace.root?.standardizedFileURL != project.standardizedFileURL {
            guard await openProject() else { return finish("the project didn't open again after \(label)") }
        }
        let started = Date()
        await body(context())
        dismissModals()
        await settle()
        do { try check() } catch { finish("\(line): \(error)") }
        if plan?.piling != false, let leaked = await pilingUp() { finish("\(line): piling up: \(leaked)") }
        checkFootprint()
        noteCoverage()
        let took = Date().timeIntervalSince(started)
        if took > 2 { note("slow: \(took.formatted(.number.precision(.fractionLength(1)))) s") }
    }

    // MARK: Waiting and checking

    private struct Failure: Error, CustomStringConvertible { let description: String }

    /// Idle: two 100 ms windows in a row in which the main thread woke on time
    /// and the process used under half a core. A layout loop never gets there.
    private func settle() async {
        let started = Date()
        var quiet = 0
        var last = (lateness: 0.0, cpu: 0.0)
        while quiet < 2 {
            let cpu = Self.cpuTime(), clock = Date()
            try? await Task.sleep(for: .milliseconds(100))
            let elapsed = Date().timeIntervalSince(clock)
            last = (elapsed - 0.1, (Self.cpuTime() - cpu) / elapsed)
            quiet = last.lateness < 0.03 && last.cpu < 0.5 ? quiet + 1 : 0
            // Logging every allocation for leaks makes everything a few times slower.
            let limit: TimeInterval = plan?.stacks == true ? 60 : 20
            if Date().timeIntervalSince(started) > limit {
                let problem = "busy for \(Int(limit)) s after \(heartbeat.withLock { $0.step }): the main thread woke \(Int(last.lateness * 1000)) ms late, \(Int(last.cpu * 100))% CPU"
                // Still busy for the script to sample what spins, then the end.
                try? "busy: \(problem)".write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(8))
                return finish(problem)
            }
        }
    }

    /// What steps let go of (`StressContext.expectFreed`), by kind, while it
    /// lives. One of a kind may stay a while, even two: AppKit and SwiftUI
    /// keep what a view last drew (a hidden column, a tab in the background,
    /// Settings' search field, a layout engine's pending views) until it draws
    /// again, and work in flight (git, a server, an agent turn's checkpoint of
    /// a big project) holds its own until it returns. A leak keeps every one:
    /// three of a kind let go and all alive fail the run (D246).
    private func pilingUp() async -> String? {
        for (what, object) in toFree { lettingGo[what, default: []].append(object) }
        toFree = []
        guard !piled().isEmpty else { return nil }
        let waited = Date()
        for _ in 0..<300 where !piled().isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        if !piled().isEmpty {
            await redrawEverything()
            for _ in 0..<40 where !piled().isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let kinds = piled()
        note("waited \(Date().timeIntervalSince(waited).formatted(.number.precision(.fractionLength(1)))) s for what was let go\(kinds.isEmpty ? "" : ": still \(kinds.joined(separator: ", "))")")
        guard !kinds.isEmpty else { return nil }
        // What holds each: the chains of references to it, from leaks.
        var trees = ""
        for kind in kinds.prefix(3) {
            guard let object = lettingGo[kind]?.first?.object else { continue }
            let address = String(format: "%#lx", UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque()))
            let tree = await leaks(["--traceTree=\(address)"])
            trees += "== \(kind) at \(address)\n" + tree + "\n"
            // Tasks and closures say nothing of whose they are: where they were
            // made does (with LEAKS, the copy logs its allocations). The
            // nearest holders: the tree's first three levels.
            let lines: [String] = tree.split(separator: "\n").map(String.init)
            let near = lines.filter { (line: String) -> Bool in
                let indent = line.prefix { " +!:|".contains($0) }.count
                return indent >= 6 && indent <= 10 && line.dropFirst(indent).first?.isNumber == true
            }
            let holders = near.compactMap { $0.firstMatch(of: /<(?:Task stack|Closure context[^>]*?|Swift HeapGenericLocalVariable|Swift HeapLocalVariable) (0x[0-9a-f]+)>/).map { String($0.1) } }
            for holder in Array(Set(holders)).sorted().prefix(plan?.stacks == true ? 6 : 0) {
                trees += "-- made at \(holder)\n" + (await run("/usr/bin/malloc_history", ["\(getpid())", holder])) + "\n"
            }
            // A text view on the way is a leak of its own (it holds its editor's parts): what holds it.
            if let textView = tree.firstMatch(of: /<OrbitTextView (0x[0-9a-f]+)>/).map({ String($0.1) }) {
                trees += "== the OrbitTextView on the way, at \(textView)\n" + (await leaks(["--traceTree=\(textView)"])) + "\n"
            }
        }
        try? trees.write(to: output.appendingPathComponent("retainers.txt"), atomically: true, encoding: .utf8)
        return kinds.map { "\(lettingGo[$0]?.count ?? 0) × \($0)" }.joined(separator: ", ")
            + (plan?.stacks == true ? " (retainers.txt)" : " (retainers.txt; STACKS=1 REPLAY= the log says where the holders were made)")
    }

    /// The kinds with three or more still alive; the freed ones dropped.
    private func piled() -> [String] {
        lettingGo = lettingGo.mapValues { $0.filter { $0.object != nil } }.filter { !$0.value.isEmpty }
        return lettingGo.filter { $0.value.count >= 3 }.keys.sorted()
    }

    /// Every tab shown, the columns, the bottom panel and Settings shown and
    /// put back, a window that changed size, the menu bar updated as when it
    /// opens: what a view last drew is drawn again.
    private func redrawEverything() async {
        guard let window else { return }
        let workspace = currentHost.workspace
        let focused = workspace.focusedGroup, shown = workspace.groups.map { ($0.id, $0.activeTabID) }
        for group in workspace.groups {
            for tab in group.tabs {
                workspace.activate(tab.id, in: group.id)
                await settle()
            }
        }
        for case let (group, tab?) in shown { workspace.activate(tab, in: group) }
        workspace.focusGroup(focused)
        NSApp.mainMenu?.update()
        for item in NSApp.mainMenu?.items ?? [] { item.submenu?.update() }
        for column in ["shell.toggleAgents", "shell.toggleSidebar"] {
            currentHost.commands.run(column)
            await settle()
            currentHost.commands.run(column)
            await settle()
        }
        let ui = currentHost.ui
        ui.isBottomPanelVisible.toggle()
        await settle()
        ui.isBottomPanelVisible.toggle()
        if !ui.isSettingsVisible {
            ui.isSettingsVisible = true
            await settle()
            ui.isSettingsVisible = false
            await settle()
        }
        let frame = window.frame
        window.setFrame(frame.insetBy(dx: 1, dy: 1), display: true)
        await settle()
        window.setFrame(frame, display: true)
        await settle()
    }

    /// Off, with every check holding, then on again; what it held is let go (D246).
    func turnOffAndOn(_ id: String) async {
        // Held weakly from here: a list of them would keep them.
        for (name, object) in currentHost.objectsFreed(whenOff: id) { toFree.append((name, Weak(object))) }
        currentHost.setEnabled(false, pluginID: id)
        await settle()
        do { try check() } catch { finish("with \(id) off: \(error)") }
        currentHost.setEnabled(true, pluginID: id)
    }

    /// Noted every 25 steps; over the plan's limit fails the run.
    private func checkFootprint() {
        let megabytes = Self.footprint() / 1_048_576
        peakFootprint = max(peakFootprint, megabytes)
        if stepCount % 25 == 0 { note("memory: \(megabytes) MB") }
        if let limit = plan?.memoryLimitMB, megabytes > limit { finish("memory: \(megabytes) MB, over the run's \(limit) MB") }
    }

    /// What Activity Monitor shows as the process's memory.
    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func check() throws {
        let context = context()
        for check in currentHost.stress.checks {
            if let problem = check.verify(context) { throw Failure(description: "check \(check.id): \(problem)") }
        }
    }

    /// Sheets and pickers a step left up: closed as Esc would, so SwiftUI's state follows.
    private func dismissModals() {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                sheet.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
                if window.attachedSheet === sheet { window.endSheet(sheet, returnCode: .cancel) }
            }
        }
        currentHost.ui.dismissQuickPick()
        CheatSheetState.shared.shownFor = nil
        // Help → Welcome to Orbit plays the tour over the window: skipped, or
        // every later step ran (and the gallery shot) under it (D248).
        if Onboarding.shared.isShowing(in: currentHost) { Onboarding.shared.finish() }
        // A step's extra windows (New Window): the run keeps to its first.
        let projectWindows = NSApp.windows.filter { ProjectWindows.shared.host(for: $0) != nil && $0.isVisible }
        if projectWindows.count > 2, let extra = projectWindows.last, extra !== window { extra.performClose(nil) }
    }

    private func noteCoverage() {
        let host = currentHost
        let keys = StressCoverage.keys(in: host)
        allKnown.formUnion(keys)
        known.formUnion(keys.filter(isCovered))
        exemptions.merge(host.stress.exemptions) { first, _ in first }
        for tab in host.workspace.allTabs {
            if let provider = host.ui.provider(for: tab) { reached.insert(StressCoverage.provider(provider.id)) }
        }
        for item in host.ui.statusItems where item.isVisible() { reached.insert(StressCoverage.status(item.id)) }
    }

    /// Exempt by its key, or by one ending in "*" that it starts with ("command:agents.new*").
    private func isExempt(_ key: String) -> Bool { StressCoverage.exemption(for: key, in: exemptions) != nil }

    /// What no step reached and nothing exempts; nil when that's nothing.
    private func uncoveredReport() -> String? {
        let uncovered = known.subtracting(reached).filter { !isExempt($0) }.sorted()
        let stale = StressCoverage.staleExemptions(exemptions, keys: allKnown)
        var lines = ["reached \(reached.intersection(known).count) of \(known.count); \(exemptions.count) exempt"]
        lines += exemptions.sorted { $0.key < $1.key }.map { "exempt \($0.key): \($0.value)" }
        lines += uncovered.map { "UNCOVERED \($0)" }
        lines += stale.map { "STALE EXEMPTION \($0) (nothing has that key)" }
        lines += unavailable.sorted().map { "unavailable step \($0)" }
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("coverage.txt"), atomically: true, encoding: .utf8)
        let json: [String: Any] = ["known": known.sorted(), "all": allKnown.sorted(), "reached": reached.sorted(), "exemptions": exemptions]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("coverage.json"))
        }
        guard !uncovered.isEmpty || !stale.isEmpty else { return nil }
        return "coverage: \(uncovered.count) uncovered, \(stale.count) stale exemptions (coverage.txt)"
    }

    // MARK: The window

    private var currentHost: PluginHost {
        window.flatMap { ProjectWindows.shared.host(for: $0) } ?? ProjectWindows.shared.activeHost ?? ProjectWindows.shared.allHosts[0]
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && ProjectWindows.shared.host(for: $0) != nil }
    }

    /// Seeded by the step, not drawn from the run's generator: asking a step
    /// whether it's available must not change what the run picks next.
    private func context() -> StressContext {
        var seed = StressRandom(seed: (plan?.seed ?? 0) &+ UInt64(stepCount) &* 0x9E37_79B9)
        return StressContext(
            host: currentHost, project: project, seed: seed.next(),
            reached: { [weak self] in self?.reached.insert($0) },
            settle: { [weak self] in await self?.settle() },
            note: { [weak self] in self?.note($0) },
            expectFreed: { [weak self] object, what in self?.toFree.append((what, Weak(object))) }
        )
    }

    private func waitForHost() async -> PluginHost? {
        for _ in 0..<300 {
            if window != nil, let host = ProjectWindows.shared.activeHost { return host }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Into the window the run uses, not a new one (which ProjectWindows would activate).
    private func openProject() async -> Bool {
        currentHost.workspace.requestOpenFolder(project)
        for _ in 0..<200 {
            if currentHost.workspace.root?.standardizedFileURL == project.standardizedFileURL {
                await settle()
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func panels() -> [PanelContribution] {
        let ui = currentHost.ui
        return (ui.sidebarPanels + ui.inspectorPanels + ui.bottomPanels).filter { !isExempt(StressCoverage.panel($0.id)) }
    }

    private func reveal(_ id: String) {
        let ui = currentHost.ui
        if ui.sidebarPanels.contains(where: { $0.id == id }) { ui.revealSidebarPanel(id) }
        if ui.inspectorPanels.contains(where: { $0.id == id }) { ui.revealInspectorPanel(id) }
        if ui.bottomPanels.contains(where: { $0.id == id }) { ui.revealBottomPanel(id) }
        reached.insert(StressCoverage.panel(id))
    }

    private func projectFiles() -> [String] {
        let root = project.standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(at: project, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathComponents.contains(".git") { enumerator?.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(String(url.standardizedFileURL.path.dropFirst(root.count)))
            }
        }
        return files.sorted()
    }

    /// An alert's answer: one of its buttons at random, so both sides of a confirmation run.
    private func answer(_ alert: NSAlert) -> NSApplication.ModalResponse {
        alertCount += 1
        var random = StressRandom(seed: (plan?.seed ?? 0) &+ UInt64(stepCount) &* 0x9E37_79B9 &+ UInt64(alertCount))
        let index = alert.buttons.isEmpty ? 0 : Int(random.next() % UInt64(alert.buttons.count))
        note("alert \"\(alert.messageText)\": \(alert.buttons.indices.contains(index) ? alert.buttons[index].title : "OK")")
        return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    // MARK: Performance (D248)

    /// What a person waits for, timed in a copy with no neighbours: launch,
    /// opening files, typing, scrolling, switching tabs, Settings, memory per
    /// tab and the CPU left busy at rest. Each action a few times, the median;
    /// the script compares perf.json with the accepted baseline.
    private func measure() async {
        var results: [String: Double] = [:]
        _ = await quiet()
        results["launch to a window ms"] = windowAfter * 1000
        let host = currentHost, workspace = host.workspace
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        func timed(_ action: () async -> Void) async -> Double {
            let started = Date()
            await action()
            let wait = await quiet()
            return max(0, Date().timeIntervalSince(started) - wait) * 1000
        }
        func reopen(_ path: String) async -> Double {
            if let tab = workspace.allTabs.first(where: { $0.url?.lastPathComponent == (path as NSString).lastPathComponent }) {
                workspace.close(tab.id)
                _ = await quiet()
            }
            return await timed { workspace.openFile(project.appendingPathComponent(path)) }
        }
        for (name, path) in [("open small file ms", "src/short.tsx"), ("open 6 000-line file ms", "src/long.swift"), ("open 120 000-line log ms", "huge.log")] {
            var times: [Double] = []
            for _ in 0..<5 { times.append(await reopen(path)) }
            results[name] = median(times)
        }
        // The long file again, until it's drawn: the rest of its colors come after (D250).
        var drawn: [Double] = []
        for _ in 0..<5 {
            if let tab = workspace.allTabs.first(where: { $0.url?.lastPathComponent == "long.swift" }) {
                workspace.close(tab.id)
                _ = await quiet()
            }
            let shown = Self.textView(in: window)
            let started = Date()
            workspace.openFile(project.appendingPathComponent("src/long.swift"))
            while Self.textView(in: window) === shown, Date().timeIntervalSince(started) < 2 { try? await Task.sleep(for: .milliseconds(1)) }
            window?.displayIfNeeded()
            drawn.append(Date().timeIntervalSince(started) * 1000)
            _ = await quiet()
        }
        results["open 6 000-line file, drawn ms"] = median(drawn)
        // Typing and scrolling: the text view as a key press reaches it, laid out and drawn each time.
        _ = await reopen("src/long.swift")
        if let textView = Self.textView(in: window) as? (NSView & NSTextInputClient) {
            var keys: [Double] = []
            for character in "let measured = 1 // typing in a long file".map(String.init) {
                let started = Date()
                textView.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
                window?.displayIfNeeded()
                keys.append(Date().timeIntervalSince(started) * 1000)
            }
            results["typing ms per key"] = median(keys)
            _ = await quiet()
            if let clip = textView.enclosingScrollView?.contentView {
                var pages: [Double] = []
                for page in 1...30 {
                    let started = Date()
                    clip.scroll(to: NSPoint(x: 0, y: CGFloat(page) * clip.bounds.height))
                    textView.enclosingScrollView?.reflectScrolledClipView(clip)
                    window?.displayIfNeeded()
                    pages.append(Date().timeIntervalSince(started) * 1000)
                }
                results["scroll ms per page"] = median(pages)
            }
            _ = await quiet()
        }
        // Six tabs; back and forth between two, as ⌃Tab does: until the
        // other file is drawn, and until the tabs' animation is over too.
        for path in ["tabs.go", "crlf.txt", "unicode.txt", "src/short.tsx", "one-line.txt"] {
            workspace.openFile(project.appendingPathComponent(path))
            _ = await quiet()
        }
        var switches: [Double] = []
        drawn = []
        for index in 0..<12 {
            let shown = Self.textView(in: window)
            let started = Date()
            workspace.showAdjacentTab(index.isMultiple(of: 2) ? -1 : 1)
            while Self.textView(in: window) === shown, Date().timeIntervalSince(started) < 2 { try? await Task.sleep(for: .milliseconds(1)) }
            window?.displayIfNeeded()
            drawn.append(Date().timeIntervalSince(started) * 1000)
            let wait = await quiet()
            switches.append(max(0, Date().timeIntervalSince(started) - wait) * 1000)
        }
        results["switch tab ms"] = median(switches)
        results["switch tab, drawn ms"] = median(drawn)
        var settings: [Double] = []
        for _ in 0..<3 {
            settings.append(await timed { host.ui.showSettings("editor") })
            host.ui.isSettingsVisible = false
            _ = await quiet()
        }
        results["open Settings ms"] = median(settings)
        // Memory: ten more files open, the footprint they added. Each side
        // redrawn, for AppKit and SwiftUI to let go of the views they drew
        // last, and freed memory given back: reused by the tabs, it hid what
        // they took.
        await redrawEverything()
        malloc_zone_pressure_relief(nil, 0)
        let before = Self.footprint()
        for path in projectFiles().filter({ $0.hasPrefix("big/") == false && !$0.hasSuffix(".bin") }).prefix(10) {
            workspace.openFile(project.appendingPathComponent(path))
            _ = await quiet()
        }
        await redrawEverything()
        malloc_zone_pressure_relief(nil, 0)
        results["memory MB per tab"] = Double(max(0, Self.footprint() - before)) / 1_048_576 / 10
        // At rest: what's still running with nothing to do.
        try? await Task.sleep(for: .seconds(2))
        let cpu = Self.cpuTime(), clock = Date()
        try? await Task.sleep(for: .seconds(3))
        results["CPU % at rest"] = (Self.cpuTime() - cpu) / Date().timeIntervalSince(clock) * 100
        results["memory MB at the end"] = Double(Self.footprint()) / 1_048_576
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: output.appendingPathComponent("perf.json"))
        }
        for (name, value) in results.sorted(by: { $0.key < $1.key }) { note("\(name): \(value.formatted(.number.precision(.fractionLength(1))))") }
        finish(nil)
    }

    /// Waits for the main thread to keep its time for 50 ms (five 10 ms ticks
    /// on time, finer than `settle`); returns that wait, to take off a timing.
    private func quiet() async -> TimeInterval {
        let started = Date()
        var onTime = 0
        while onTime < 5, Date().timeIntervalSince(started) < 20 {
            let tick = Date()
            try? await Task.sleep(for: .milliseconds(10))
            onTime = Date().timeIntervalSince(tick) - 0.01 < 0.004 ? onTime + 1 : 0
        }
        return 0.05
    }

    private static func textView(in window: NSWindow?) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "OrbitTextView", view.window != nil, !view.isHiddenOrHasHiddenAncestor { return view }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return window?.contentView.flatMap(find)
    }

    /// Since the process started, from the kernel.
    private static func sinceLaunch() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        return Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    // MARK: Output

    /// Every panel and Settings pane, a few kinds of file and a split editor,
    /// each shot as it shows (D248): every copy the same, so the gallery puts
    /// the modes side by side.
    private func galleryTour() async {
        let ui = currentHost.ui
        for panel in ui.sidebarPanels + ui.inspectorPanels + ui.bottomPanels {
            await step("panel \(panel.id)") { [weak self] _ in self?.reveal(panel.id) }
            shoot("panel \(panel.id)")
        }
        for pane in ui.settingsPanes.map(\.id) {
            await step("settings \(pane)") { context in context.ui.showSettings(pane) }
            shoot("settings \(pane)")
        }
        await step("settings closed") { context in context.ui.isSettingsVisible = false }
        for file in ["src/short.tsx", "src/long.swift", "docs/readme.md", "unicode.txt", "conflict.txt", "binary.bin"] {
            await step("open \(file)") { context in await context.open(file) }
            shoot("file \(file)")
        }
        if !currentHost.workspace.isSplit {
            await step("command shell.splitEditor") { context in context.run("shell.splitEditor") }
        }
        shoot("split editor")
    }

    private typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// The run's window as the window server composites it (glass included),
    /// alone, though it's behind the user's windows: shots/ for the gallery
    /// (D248). The call is gone from the SDK, not from the system; an app may
    /// capture its own windows without asking.
    private func shoot(_ label: String) {
        guard let window,
              let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: WindowImage.self)
        // That window only, with its shadow trimmed.
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else { return }
        let folder = output.appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        try? data?.write(to: folder.appendingPathComponent("\(name).jpg"))
    }

    private func note(_ text: String) { write("   \(text)") }

    private func write(_ line: String) {
        log?.write(Data((line + "\n").utf8))
    }

    private func finish(_ failure: String?) {
        if failure == nil, plan?.leaks == true {
            plan?.leaks = false
            Task { finish(await leaks()) }
            return
        }
        if let failure { note("FAILED: \(failure)") }
        _ = uncoveredReport()
        try? (failure.map { "failed: \($0)" } ?? "passed: \(stepCount) steps, \(peakFootprint) MB at most").write(
            to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8
        )
        try? log?.synchronize()
        exit(failure == nil ? 0 : 3)
    }

    /// `leaks` on this process: what nothing points to any more and is Orbit's own, or of the
    /// libraries it builds on, fails the run. AppKit's and SwiftUI's own
    /// leaks are only counted. The whole report is leaks.txt.
    private func leaks() async -> String? {
        // Closed tabs and windows go after the run loop turns a few times.
        await settle()
        let text = await leaks([])
        try? text.write(to: output.appendingPathComponent("leaks.txt"), atomically: true, encoding: .utf8)
        guard text.contains("leaks for") else { return "leaks didn't run (leaks.txt)" }
        let roots = text.split(separator: "\n").filter { $0.contains("ROOT LEAK") || $0.contains("ROOT CYCLE") }
        let names = Self.ownClassNames
        // leaks names a Swift class without its module ("<TerminalOptions>"): by the classes in the app's own images too.
        let ours = roots.filter { line in
            Self.ownModules.contains { line.contains($0) } || names.contains { line.contains("<\($0) ") || line.contains("<\($0)>") }
        }
        note("leaks: \(roots.count) roots, \(ours.count) of them Orbit's")
        for line in ours.prefix(20) { note("leak: \(line.trimmingCharacters(in: .whitespaces))") }
        return ours.isEmpty ? nil : "leaks: \(ours.count) of Orbit's objects nothing points to (leaks.txt\(plan?.stacks == true ? "" : "; STACKS=1 LEAKS=1 REPLAY= the log says where they were made"))"
    }

    /// /usr/bin/leaks on this process. A try that caught malloc mid-change says so: again.
    private func leaks(_ arguments: [String]) async -> String {
        var text = ""
        for _ in 0..<3 {
            text = await run("/usr/bin/leaks", ["\(getpid())"] + arguments)
            if !text.contains("[fatal]") { break }
        }
        return text
    }

    /// A tool that stops this process while it looks (leaks, malloc_history): the watchdog waits.
    private func run(_ tool: String, _ arguments: [String]) async -> String {
        heartbeat.withLock { $0.paused = true }
        defer { heartbeat.withLock { $0.paused = false; $0.beat = Date() } }
        return await Task.detached { () -> String in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// The classes Orbit's own images define, the libraries linked into them included.
    private static var ownClassNames: Set<String> {
        var names = Set<String>()
        var imageCount: UInt32 = 0
        let images = objc_copyImageNames(&imageCount)
        defer { free(images) }
        for index in 0..<Int(imageCount) where String(cString: images[index]).hasPrefix(Bundle.main.bundlePath) {
            var classCount: UInt32 = 0
            guard let classes = objc_copyClassNamesForImage(images[index], &classCount) else { continue }
            defer { free(classes) }
            for item in 0..<Int(classCount) {
                guard let type = NSClassFromString(String(cString: classes[item])) else { continue }
                let name = NSStringFromClass(type).components(separatedBy: ".").last ?? ""
                if name.count > 3 { names.insert(name) }
            }
        }
        return names
    }

    private static let ownModules = ["<Orbit", " Orbit", "STTextView", "SwiftTerm", "Neon", "SwiftTreeSitter"]

    /// The watchdog: a main thread that hasn't ticked for 10 s is stuck. It
    /// writes the step and leaves the process to the script, which samples it.
    private func startHeartbeat() {
        // A menu a step pops up (Code Actions) tracks in its own loop until
        // clicked: in the background it stayed over the user's work and held
        // the run. It's closed as it opens, as Esc would.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            // Main-thread AppKit objects, posted and closed on the main thread.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let menu, menu !== NSApp.mainMenu else { return }
                let runner = StressRunner.shared
                runner.note("menu closed: \(menu.items.prefix(5).map(\.title))")
                runner.openMenu = menu
                RunLoop.main.perform(inModes: [.common, .eventTracking]) {
                    MainActor.assumeIsolated {
                        StressRunner.shared.openMenu?.cancelTrackingWithoutAnimation()
                        StressRunner.shared.openMenu = nil
                    }
                }
            }
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let runner = StressRunner.shared
                runner.heartbeat.withLock { $0.beat = Date() }
                if runner.plan?.background == true { runner.sendWindowsBack() }
            }
        }
        // Common modes: it also ticks in a modal session or a menu's tracking.
        RunLoop.main.add(timer, forMode: .common)
        let heartbeat = heartbeat, result = output.appendingPathComponent("result.txt")
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 1)
                let (beat, step, paused) = heartbeat.withLock { ($0.beat, $0.step, $0.paused) }
                if !paused, Date().timeIntervalSince(beat) > 10 {
                    try? "hung: the main thread stopped at \(step)".write(to: result, atomically: true, encoding: .utf8)
                    return
                }
            }
        }
    }

    /// Each new window once: behind every other app's, so it covers no one's work.
    private func sendWindowsBack() {
        for window in NSApp.windows where window.isVisible && !sentBack.contains(window.windowNumber) {
            sentBack.insert(window.windowNumber)
            window.orderBack(nil)
        }
    }
}
#endif

#if DEBUG
/// Which scroll view a layout loop spins in (D245): `tile` counted per scroll
/// view; one tiled hundreds of times in two seconds is written to the log
/// with what it shows, before the watchdog gives up on the main thread.
extension NSScrollView {
    @MainActor static func watchForTileLoops() {
        guard let original = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.tile)),
              let counting = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.stressCountedTile)) else { return }
        method_exchangeImplementations(original, counting)
    }

    @objc dynamic func stressCountedTile() {
        stressCountedTile()
        // Counted without MainActor.assumeIsolated: a scroll view tiled while
        // an autorelease pool freed it crashed in that check itself (D250).
        guard Thread.isMainThread, TileLoops.count(self) else { return }
        MainActor.assumeIsolated { TileLoops.report(self) }
    }
}

enum TileLoops {
    nonisolated(unsafe) private static var counts: [ObjectIdentifier: (count: Int, since: Date)] = [:]
    @MainActor static var report: ((String) -> Void)?

    /// On the main thread; true the 300th time in two seconds.
    static func count(_ view: NSScrollView) -> Bool {
        let key = ObjectIdentifier(view)
        var entry = counts[key] ?? (0, Date())
        if Date().timeIntervalSince(entry.since) > 2 { entry = (0, Date()) }
        entry.count += 1
        counts[key] = entry
        return entry.count == 300
    }

    @MainActor static func report(_ view: NSScrollView) {
        var chain: [String] = []
        var parent = view.superview
        while let current = parent, chain.count < 12 {
            chain.append(String(describing: type(of: current)).prefix(60).description + " \(Int(current.frame.width))×\(Int(current.frame.height))")
            parent = current.superview
        }
        report?("tile loop: \(type(of: view)) frame \(NSStringFromRect(view.frame)) doc \(view.documentView.map { "\(type(of: $0)) \(NSStringFromRect($0.frame))" } ?? "none") style \(view.scrollerStyle.rawValue) autohides \(view.autohidesScrollers) vertical \(view.verticalScroller?.isHidden == false) horizontal \(view.horizontalScroller?.isHidden == false)\n      in \(chain.joined(separator: " < "))")
    }
}
#endif
