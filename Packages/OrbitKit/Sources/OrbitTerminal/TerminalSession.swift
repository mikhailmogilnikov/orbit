import AppKit
import OrbitACP
import OrbitAPI
import OrbitUI
import SwiftTerm

/// One shell, or one agent command, in a pseudo-terminal. The view lives as
/// long as the session, so hiding the panel or switching tabs never loses scrollback.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    nonisolated let id = UUID()
    private(set) var title: String
    private(set) var isRunning = true
    /// Set when this runs an agent's command rather than the user's shell.
    @ObservationIgnored private(set) var agentTerminal: AgentTerminal?
    /// Set for a task's own tab (D128): its title stays the command.
    @ObservationIgnored private(set) var taskID: String?
    /// A task's errors and warnings, read from what it prints (D137).
    @ObservationIgnored private(set) var output: TaskOutputParser?
    @ObservationIgnored var onProblems: (TerminalSession) -> Void = { _ in }
    @ObservationIgnored let view: OrbitTerminalView
    @ObservationIgnored var onExit: (TerminalSession) -> Void = { _ in }
    @ObservationIgnored private var delegate: Delegate?

    init(directory: URL, task: ProjectTask? = nil, root: URL? = nil, shell: String = TerminalSession.loginShell) {
        title = task?.command ?? (shell as NSString).lastPathComponent
        taskID = task?.id
        view = OrbitTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let delegate = Delegate(session: self)
        self.delegate = delegate
        view.processDelegate = delegate
        view.directories = [directory] + (root.map { [$0] } ?? [])
        if task != nil {
            output = TaskOutputParser(directories: [directory] + (root.map { [$0] } ?? []))
            view.onData = { [weak self] bytes in self?.read(bytes) }
        }

        var env = ShellEnvironment.withoutHostAgentVariables()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Orbit"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // A leading dash makes it a login shell, like Terminal.app: profile files run.
        view.startProcess(
            executable: shell,
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: directory.path
        )
    }

    /// Runs an agent's command: through the user's shell when it comes as one
    /// command line, directly when it has separate arguments.
    init(agentTerminal: AgentTerminal) {
        let request = agentTerminal.request
        title = request.displayCommand
        self.agentTerminal = agentTerminal
        view = OrbitTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        let delegate = Delegate(session: self)
        self.delegate = delegate
        view.processDelegate = delegate
        view.onData = { [weak agentTerminal] bytes in agentTerminal?.receive(bytes) }
        view.directories = [request.directory]

        var env = request.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Orbit"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let (executable, arguments) = request.arguments.isEmpty
            ? (Self.loginShell, ["-c", request.command])
            : ("/usr/bin/env", [request.command] + request.arguments)
        view.startProcess(
            executable: executable,
            args: arguments,
            environment: env.map { "\($0.key)=\($0.value)" },
            currentDirectory: request.directory.path
        )
    }

    /// Shows output without a process of its own: a command the agent runs
    /// itself, or one whose tab was closed and is opened again. Draws what it
    /// printed so far, then follows along while it still runs.
    init(displaying agentTerminal: AgentTerminal) {
        title = agentTerminal.request.displayCommand
        isRunning = agentTerminal.isRunning
        self.agentTerminal = agentTerminal
        let view = OrbitTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        self.view = view
        view.feed(byteArray: Self.terminalLines("$ \(title)\n")[...])
        view.feed(byteArray: Self.terminalLines(agentTerminal.transcript)[...])
        agentTerminal.onDisplay = { [weak view] bytes in view?.feed(byteArray: Self.terminalLines(bytes)[...]) }
        agentTerminal.onFinish = { [weak self] in self?.processDidExit(nil) }
    }

    /// Agents send plain `\n` line ends; a terminal needs `\r\n` to return to column 0.
    private static func terminalLines(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var result: [UInt8] = []
        var previous: UInt8 = 0
        for byte in bytes {
            if byte == 0x0A, previous != 0x0D { result.append(0x0D) }
            result.append(byte)
            previous = byte
        }
        return result
    }

    private static func terminalLines(_ text: String) -> [UInt8] { terminalLines(Array(text.utf8)) }

    var isAgent: Bool { agentTerminal != nil }
    var isTask: Bool { taskID != nil }

    /// Something other than the shell owns the terminal (a dev server, a build).
    var isBusy: Bool {
        let fd = view.process.childfd
        guard isRunning, fd >= 0 else { return false }
        let group = tcgetpgrp(fd)
        return group > 0 && group != view.process.shellPid
    }

    /// Types a command into the shell, as if typed: it stays in the history
    /// and the output stays in the tab. A command still running gets ⌃C first.
    func type(_ command: String) {
        if output != nil {
            output?.reset()
            onProblems(self)
        }
        guard isBusy else { return view.send(txt: command + "\r") }
        view.send([3])
        Task { [weak self] in
            // Give it a moment to stop and the shell to print its prompt.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if self?.isBusy != true { break }
            }
            self?.view.send(txt: command + "\r")
        }
    }

    private func read(_ bytes: ArraySlice<UInt8>) {
        guard let revision = output?.revision else { return }
        output?.feed(bytes)
        if output?.revision != revision { onProblems(self) }
    }

    /// ⌃C to what runs in it, as if typed.
    func interrupt() {
        if isBusy { view.send([3]) }
    }

    func terminate() {
        if isAgent {
            kill()
        } else {
            view.terminate()
        }
    }

    /// Stops an agent command and whatever it started (the whole process group).
    func kill() {
        guard isRunning, agentTerminal?.ownsProcess != false else { return }
        let pid = view.process.shellPid
        if pid > 0 { Darwin.kill(-pid, SIGTERM) }
        // SwiftTerm stops watching the process here, so report the exit ourselves.
        view.terminate()
        processDidExit(SIGTERM)
    }

    fileprivate func processDidExit(_ waitStatus: Int32?) {
        guard isRunning else { return }
        isRunning = false
        if let agentTerminal {
            let status = waitStatus.map(TerminalExitStatus.init(waitStatus:)) ?? TerminalExitStatus()
            Task {
                // The last output may still be on its way from the pty.
                try? await Task.sleep(for: .milliseconds(150))
                agentTerminal.finish(status)
            }
        }
        onExit(self)
    }

    func focus() {
        view.window?.makeFirstResponder(view)
    }

    fileprivate func setTitle(_ title: String) {
        guard !isAgent, !isTask else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { self.title = trimmed }
    }

    static var loginShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    private final class Delegate: LocalProcessTerminalViewDelegate {
        weak var session: TerminalSession?

        init(session: TerminalSession) {
            self.session = session
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor [weak session] in session?.setTitle(title) }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        /// `exitCode` is the raw `waitpid` status.
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor [weak session] in session?.processDidExit(exitCode) }
        }
    }
}

/// Follows the app's appearance (colors are resolved when assigned, so they
/// are re-applied on every light/dark switch) and uses the editor's font.
final class OrbitTerminalView: LocalProcessTerminalView {
    /// Raw output as it arrives, for agent commands.
    var onData: (@MainActor (ArraySlice<UInt8>) -> Void)?
    /// Where relative paths in the output start (the shell's folder, then the project's).
    var directories: [URL] = []
    /// ⌘-click on `file:line:col` (D148): opens it in the editor; false when it isn't a file here.
    var onOpenFile: ((URL, Int?, Int?) -> Bool)?

    private var themeObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = Preferences.shared.codeFont(size: Preferences.shared.effectiveTerminalFontSize)
        // Option types special characters (macOS keyboard layouts), as in Terminal.app,
        // unless Settings → Terminal makes it Meta (`TerminalOptions`).
        optionAsMetaKey = false
        registerForDraggedTypes([.fileURL])
        applyColors()
        themeObserver = NotificationCenter.default.addObserver(forName: Extensions.themeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyColors() }
        }
    }

    isolated deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// SwiftTerm's `keyDown` can't be overridden; a local monitor also sees ⌘ keys
    /// before the menus (⌘K is Edit with Agent in the editor).
    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window, self.window?.firstResponder === self else { return false }
                return self.handle(event)
            }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !hasMarkedText() else { return false }
        if let bytes = controlKey(event) {
            send(bytes)
            return true
        }
        guard let action = TerminalKeys.action(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }
        switch action {
        case .send(let bytes): send(bytes)
        case .clear: clear()
        case .scrollToTop: scrollUp(lines: Int(Int32.max))
        case .scrollToBottom: scrollDown(lines: Int(Int32.max))
        }
        return true
    }

    @objc func clear() {
        clearScrollback()
        send([0x0C])
    }

    /// Something runs here to take keys (not an agent command shown without one).
    private var takesInput: Bool { process.running }

    // MARK: Mouse, as in Terminal.app and iTerm (D219)

    /// Where an ⌥-click went down; the cursor moves if it comes up there (a drag selects).
    private var optionClick: (col: Int, row: Int)?

    /// ⌥-click moves the cursor there, while the program doesn't take the mouse itself.
    override func mouseDown(with event: NSEvent) {
        optionClick = nil
        super.mouseDown(with: event)
        guard event.clickCount == 1, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .option,
              takesInput, getTerminal().mouseMode == .off,
              // The cursor's row is on screen only while scrolled to the bottom.
              !canScroll || scrollPosition >= 1 else { return }
        optionClick = cell(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let target = optionClick, let up = cell(at: convert(event.locationInWindow, from: nil)), up == target else { return }
        optionClick = nil
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        let arrows = TerminalKeys.arrows(from: (cursor.x, cursor.y), to: target, cols: terminal.cols, application: terminal.applicationCursor)
        if !arrows.isEmpty { send(arrows) }
    }

    /// The screen cell under a point: SwiftTerm's cell size (the font's "W", snapped to pixels) and the caret's height.
    private func cell(at point: NSPoint) -> (col: Int, row: Int)? {
        let scale = window?.backingScaleFactor ?? 2
        let width = (font.advancement(forGlyph: font.glyph(withName: "W")).width * scale).rounded() / scale
        let height = caretFrame.height
        guard width > 0, height > 0 else { return nil }
        let terminal = getTerminal()
        return (min(max(0, Int(point.x / width)), terminal.cols - 1), min(max(0, Int((frame.height - point.y) / height)), terminal.rows - 1))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ key: String, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            item.isEnabled = enabled
        }
        add("Copy", #selector(copy(_:)), "c", enabled: selectionActive)
        add("Paste", #selector(paste(_:)), "v", enabled: takesInput && NSPasteboard.general.string(forType: .string) != nil)
        add("Select All", #selector(selectAll(_:)), "a")
        menu.addItem(.separator())
        add("Clear", #selector(clear), "k")
        return menu
    }

    // MARK: Files dropped in type their paths (D219)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPaths(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let paths = droppedPaths(sender) else { return false }
        send(txt: paths.map(TerminalKeys.shellQuoted).joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    private func droppedPaths(_ info: NSDraggingInfo) -> [String]? {
        guard takesInput,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return urls.map(\.path)
    }

    /// ⌃ letters SwiftTerm gets wrong (D217): in a Cyrillic layout it sent
    /// nothing for ⌃C; and with the kitty keyboard protocol on (left on by a
    /// program that didn't turn it off) ⌃C became `CSI 99;5u` text, so a dev
    /// server never got SIGINT. While the pty turns ⌃C into a signal, the
    /// program can't be reading keys raw: the plain byte is what it needs.
    private func controlKey(_ event: NSEvent) -> [UInt8]? {
        guard event.modifierFlags.intersection([.command, .option, .control]) == .control,
              let typed = event.charactersIgnoringModifiers?.first else { return nil }
        if typed.isASCII {
            guard !getTerminal().keyboardEnhancementFlags.isEmpty, signalsKeys else { return nil }
            return TerminalKeys.control(typed)
        }
        return TerminalKeys.latinCharacter(keyCode: event.keyCode).flatMap(TerminalKeys.control)
    }

    /// The pty is in a mode where ⌃C, ⌃Z and ⌃\ become signals (ISIG).
    private var signalsKeys: Bool {
        let fd = process.childfd
        var attributes = termios()
        return fd >= 0 && tcgetattr(fd, &attributes) == 0 && attributes.c_lflag & tcflag_t(ISIG) != 0
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let target = TerminalLink.file(link, in: directories), onOpenFile?(target.url, target.line, target.column) == true { return }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onData?(slice)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The color theme's terminal colors, falling back to its editor colors, then to the system's.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let theme = Extensions.shared.colorTheme(dark: isDark)
            let fallback = isDark ? TerminalPalette.dark : TerminalPalette.light
            installColors(zip(theme.terminalANSI, fallback).map { themed, system in
                themed.map(TerminalPalette.color) ?? system
            })
            nativeForegroundColor = (theme.terminalForeground ?? theme.editorForeground)?.nsColor ?? .textColor
            // The editor's background, not `terminal.background`: themes make that
            // darker (GitHub's near-black), a block cut out of the window (D191).
            nativeBackgroundColor = theme.editorBackground?.nsColor ?? .textBackgroundColor
            caretColor = theme.cursor?.nsColor ?? Theme.accentNSColor
            selectedTextBackgroundColor = theme.selection?.nsColor ?? .selectedTextBackgroundColor
        }
    }
}

/// ANSI colors close to Apple's system palette; the light variant keeps
/// "white" readable on a white background.
@MainActor
enum TerminalPalette {
    static let dark = colors([
        0x1A1A1A, 0xFF453A, 0x32D74B, 0xFFD60A, 0x0A84FF, 0xBF5AF2, 0x5AC8F5, 0xC7C7CC,
        0x636366, 0xFF6961, 0x5EE07A, 0xFFE15C, 0x5AA9FF, 0xD48CF7, 0x8FDCFF, 0xFFFFFF,
    ])
    static let light = colors([
        0x1A1A1A, 0xC9302C, 0x1E8E3E, 0x9A6B00, 0x0B62D6, 0x8E44AD, 0x0E7C9A, 0x8E8E93,
        0x6E6E73, 0xE5483F, 0x28A745, 0xB8860B, 0x2F7DF6, 0xA55BC8, 0x1B98B8, 0x3A3A3C,
    ])

    static func color(_ color: ThemeColor) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(color.red * 65535), green: UInt16(color.green * 65535), blue: UInt16(color.blue * 65535))
    }

    private static func colors(_ hex: [UInt32]) -> [SwiftTerm.Color] {
        hex.map { value in
            SwiftTerm.Color(
                red: UInt16((value >> 16) & 0xFF) * 257,
                green: UInt16((value >> 8) & 0xFF) * 257,
                blue: UInt16(value & 0xFF) * 257
            )
        }
    }
}
