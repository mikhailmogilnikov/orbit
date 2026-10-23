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
    }

    private var plan: Plan?
    private var random = StressRandom(seed: 0)
    private var log: FileHandle?
    private var stepCount = 0
    private var reached: Set<String> = []
    private var known: Set<String> = []
    private var exemptions: [String: String] = [:]
    private var unavailable: Set<String> = []
    private var sentBack: Set<Int> = []
    private var openMenu: NSMenu?
    private let heartbeat = OSAllocatedUnfairLock(initialState: (beat: Date(), step: ""))

    /// Full screen takes a Space of its own and switches to it: only in front.
    var inBackground: Bool { plan?.background ?? true }

    private var output: URL { URL(fileURLWithPath: plan?.output ?? "/tmp") }
    private var project: URL { URL(fileURLWithPath: plan?.project ?? "/tmp") }

    func start() {
        guard let json = UserDefaults.standard.string(forKey: "orbit.stress"),
              let plan = try? JSONDecoder().decode(Plan.self, from: Data(json.utf8)) else { return }
        self.plan = plan
        random = StressRandom(seed: plan.seed)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: output.appendingPathComponent("log.txt").path, contents: nil)
        log = try? FileHandle(forWritingTo: output.appendingPathComponent("log.txt"))
        ProjectWindows.shared.activatesApp = !plan.background
        StressAnswers.alert = { [weak self] alert in self?.answer(alert) ?? .cancel }
        startHeartbeat()
        Task { await run() }
    }

    // MARK: The run

    private func run() async {
        guard let host = await waitForHost() else { return finish("no window to run in") }
        do {
            try? FileManager.default.removeItem(at: project)
            try host.stress.makeProject(at: project)
        } catch {
            return finish("couldn't write the project: \(error.localizedDescription)")
        }
        guard await openProject() else { return finish("the project didn't open") }
        noteCoverage()
        note("project \(project.path), seed \(plan!.seed)")

        if let replay = plan!.replay {
            return await replaySteps(from: replay)
        }

        // The fixed part: everything once, in a fixed order.
        for id in currentHost.commands.all.map(\.id).sorted() where !isExempt(StressCoverage.command(id)) {
            await step("command \(id)") { context in
                if !context.run(id) {
                    // Most need a file open; still off, it's the coverage report's.
                    await context.open(Self.textFile)
                    context.run(id)
                }
            }
        }
        for panel in panels() {
            await step("panel \(panel.id)") { [weak self] _ in self?.reveal(panel.id) }
        }
        for pane in currentHost.ui.settingsPanes.map(\.id) {
            await step("settings \(pane)") { [weak self] context in
                context.ui.showSettings(pane)
                self?.reached.insert(StressCoverage.settings(pane))
            }
        }
        await step("settings closed") { context in context.ui.isSettingsVisible = false }
        for entry in currentHost.entries where !entry.manifest.isRequired && !isExempt(StressCoverage.plugin(entry.id)) {
            await step("plugin \(entry.id) off and on") { [weak self] _ in
                guard let self else { return }
                currentHost.setEnabled(false, pluginID: entry.id)
                await settle()
                do { try check() } catch { finish("with \(entry.id) off: \(error)") }
                currentHost.setEnabled(true, pluginID: entry.id)
                reached.insert(StressCoverage.plugin(entry.id))
            }
        }
        for stressStep in currentHost.stress.steps.sorted(by: { $0.id < $1.id }) {
            await run(stressStep, preparing: true)
        }
        // Commands that were off the first time (nothing to go back to, no
        // split, no stash, no agent change): again, now that steps made that
        // state, each after the steps that make the most of it.
        for id in currentHost.commands.all.map(\.id).sorted()
        where !reached.contains(StressCoverage.command(id)) && !isExempt(StressCoverage.command(id)) {
            await step("command \(id), again") { [weak self] context in
                guard let self, !context.run(id) else { return }
                for setup in ["shell.richState", "review.agentTurn", "git.stash", "git.stage", "preview.markdown"] {
                    if let prepare = currentHost.stress.steps.first(where: { $0.id == setup }) { await prepare.run(context) }
                    await settle()
                    if context.run(id) { return }
                }
                await context.open("docs/readme.md")
                context.run(id)
            }
        }
        note("fixed part: \(stepCount) steps")
        if plan!.checksCoverage ?? true, let uncovered = uncoveredReport() {
            return finish(uncovered)
        }

        // The random part.
        for _ in 0..<plan!.steps {
            await randomStep()
        }
        finish(nil)
    }

    private static let textFile = "src/short.tsx"

    /// A log's steps again (`REPLAY=…/log.txt make stress`), to reproduce a failure.
    private func replaySteps(from path: String) async {
        guard let log = try? String(contentsOfFile: path, encoding: .utf8) else { return finish("no log at \(path)") }
        for line in log.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":"), Int(line[..<colon]) != nil else { continue }
            let label = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let words = label.split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2 else {
                if label == "settings closed" { await step(label) { context in context.ui.isSettingsVisible = false } }
                continue
            }
            let argument = words[1]
            switch words[0] {
            case "command":
                let id = argument.replacingOccurrences(of: ", again", with: "")
                await step("command \(id)") { context in context.run(id) }
            case "open": await step("open \(argument)") { context in await context.open(argument) }
            case "panel": await step("panel \(argument)") { [weak self] _ in self?.reveal(argument) }
            case "settings": await step("settings \(argument)") { context in context.ui.showSettings(argument) }
            case "plugin":
                let id = String(argument.split(separator: " ")[0])
                await step("plugin \(id) off and on") { [weak self] _ in
                    guard let self else { return }
                    currentHost.setEnabled(false, pluginID: id)
                    await settle()
                    currentHost.setEnabled(true, pluginID: id)
                }
            case "step", "regression":
                if let found = currentHost.stress.steps.first(where: { $0.id == argument }) { await run(found, preparing: false) }
            default: continue
            }
        }
        finish(nil)
    }

    /// Picked from everything, available or not (skipped then): what's
    /// available depends on timing (a language server's answer), and the same
    /// seed has to give the same steps.
    private func randomStep() async {
        let steps = currentHost.stress.steps.sorted { $0.id < $1.id }
        let total = steps.reduce(0) { $0 + $1.weight }
        // A command or a file a quarter of the time each, a plugin's step otherwise.
        switch random.next() % 4 {
        case 0:
            let commands = currentHost.commands.all.map(\.id).filter { !isExempt(StressCoverage.command($0)) }.sorted()
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
            for candidate in steps {
                roll -= candidate.weight
                if roll < 0 { return await run(candidate, preparing: false) }
            }
        }
    }

    private func run(_ stressStep: StressStep, preparing: Bool) async {
        if !stressStep.isAvailable(context()) {
            guard preparing else { return note("skipped, not available: \(stressStep.id)") }
            await context().open(Self.textFile)
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
        let line = "\(stepCount): \(label)"
        heartbeat.withLock { $0.step = line }
        write(line)
        if currentHost.workspace.root?.standardizedFileURL != project.standardizedFileURL {
            guard await openProject() else { return finish("the project didn't open again after \(label)") }
        }
        await body(context())
        dismissModals()
        await settle()
        do { try check() } catch { finish("\(line): \(error)") }
        noteCoverage()
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
            if Date().timeIntervalSince(started) > 20 {
                return finish("busy for 20 s after \(heartbeat.withLock { $0.step }): the main thread woke \(Int(last.lateness * 1000)) ms late, \(Int(last.cpu * 100))% CPU")
            }
        }
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
        // A step's extra windows (New Window): the run keeps to its first.
        let projectWindows = NSApp.windows.filter { ProjectWindows.shared.host(for: $0) != nil && $0.isVisible }
        if projectWindows.count > 2, let extra = projectWindows.last, extra !== window { extra.performClose(nil) }
    }

    private func noteCoverage() {
        let host = currentHost
        known.formUnion(StressCoverage.keys(in: host))
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
        let stale = StressCoverage.staleExemptions(exemptions, keys: known)
        var lines = ["reached \(reached.intersection(known).count) of \(known.count); \(exemptions.count) exempt"]
        lines += exemptions.sorted { $0.key < $1.key }.map { "exempt \($0.key): \($0.value)" }
        lines += uncovered.map { "UNCOVERED \($0)" }
        lines += stale.map { "STALE EXEMPTION \($0) (nothing has that key)" }
        lines += unavailable.sorted().map { "unavailable step \($0)" }
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("coverage.txt"), atomically: true, encoding: .utf8)
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
            note: { [weak self] in self?.note($0) }
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
        let index = alert.buttons.isEmpty ? 0 : Int(random.next() % UInt64(alert.buttons.count))
        note("alert \"\(alert.messageText)\": \(alert.buttons.indices.contains(index) ? alert.buttons[index].title : "OK")")
        return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    // MARK: Output

    private func note(_ text: String) { write("   \(text)") }

    private func write(_ line: String) {
        log?.write(Data((line + "\n").utf8))
    }

    private func finish(_ failure: String?) {
        if let failure { note("FAILED: \(failure)") }
        _ = uncoveredReport()
        try? (failure.map { "failed: \($0)" } ?? "passed: \(stepCount) steps").write(
            to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8
        )
        try? log?.synchronize()
        exit(failure == nil ? 0 : 3)
    }

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
                let (beat, step) = heartbeat.withLock { ($0.beat, $0.step) }
                if Date().timeIntervalSince(beat) > 10 {
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
