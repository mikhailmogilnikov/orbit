import AppKit
import OrbitAPI
import SwiftTerm

/// Settings → Terminal (D178). One per window's plugin; a change in one
/// window reaches the others through `didChange`.
@MainActor
@Observable
final class TerminalOptions {
    enum Cursor: String, CaseIterable, Identifiable {
        case block, bar, underline
        nonisolated var id: String { rawValue }

        var title: String {
            switch self {
            case .block: "Block"
            case .bar: "Bar"
            case .underline: "Underline"
            }
        }
    }

    static let scrollbackChoices = [1_000, 10_000, 50_000, 100_000]
    static let didChange = Notification.Name("orbit.terminalOptionsDidChange")

    /// nil: the login shell ($SHELL).
    var shell: String? { didSet { save() } }
    var cursor: Cursor { didSet { save() } }
    var cursorBlinks: Bool { didSet { save() } }
    var optionAsMeta: Bool { didSet { save() } }
    var scrollback: Int { didSet { save() } }

    /// Re-applies the options to open terminals.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let settings: PluginSettings
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(settings: PluginSettings) {
        self.settings = settings
        shell = nil
        cursor = .block
        cursorBlinks = true
        optionAsMeta = false
        scrollback = 10_000
        load()
        observer = NotificationCenter.default.addObserver(forName: Self.didChange, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self) else { return }
                self.load()
                self.onChange()
            }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The shell new tabs start: the picked one while it still exists.
    var effectiveShell: String {
        if let shell, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return TerminalSession.loginShell
    }

    /// Shells macOS lets you pick (`/etc/shells`), plus the picked one.
    static func availableShells(including picked: String?) -> [String] {
        let listed = ((try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        var shells: [String] = []
        for shell in listed + [picked].compactMap(\.self) where !shells.contains(shell) { shells.append(shell) }
        return shells
    }

    func apply(to view: OrbitTerminalView) {
        view.optionAsMetaKey = optionAsMeta
        view.getTerminal().setCursorStyle(cursorStyle)
        view.changeScrollback(scrollback)
    }

    private var cursorStyle: CursorStyle {
        switch (cursor, cursorBlinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        shell = settings.string("shell")
        cursor = settings.string("cursor").flatMap(Cursor.init) ?? .block
        cursorBlinks = settings.bool("cursorBlinks", default: true)
        optionAsMeta = settings.bool("optionAsMeta")
        let lines = settings.string("scrollback").flatMap(Int.init) ?? 0
        scrollback = Self.scrollbackChoices.contains(lines) ? lines : 10_000
    }

    private func save() {
        guard !isLoading else { return }
        settings.set(shell, for: "shell")
        settings.set(cursor.rawValue, for: "cursor")
        settings.set(cursorBlinks, for: "cursorBlinks")
        settings.set(optionAsMeta, for: "optionAsMeta")
        settings.set(String(scrollback), for: "scrollback")
        onChange()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
