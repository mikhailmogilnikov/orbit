import AppKit
import OrbitAPI
@_spi(Plugins) import STTextView

/// Where the caret and the scroll were in each file, so switching back to a
/// tab or reopening a file returns there (D80). Kept by line and column, which
/// survive edits made while the file was closed better than offsets.
@MainActor
enum EditorViewStates {
    struct State: Codable, Equatable {
        var selectionStart: [Int]
        var selectionEnd: [Int]
        /// The first line at the top of the view.
        var topLine: Int
    }

    private struct Stored: Codable {
        var states: [String: State] = [:]
        /// Least recently used first.
        var order: [String] = []
    }

    private static let key = "orbit.editorViewStates"
    private static let limit = 300
    /// Read once; written back when an editor closes and when the app quits, not on every caret move.
    private static var stored: Stored = UserDefaults.standard.data(forKey: key)
        .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    private static var isDirty = false
    private static var terminationObserver: NSObjectProtocol?

    static func state(for url: URL) -> State? {
        stored.states[url.standardizedFileURL.path]
    }

    static func remember(_ state: State, for url: URL) {
        let path = url.standardizedFileURL.path
        guard stored.states[path] != state else { return }
        stored.states[path] = state
        stored.order.removeAll { $0 == path }
        stored.order.append(path)
        while stored.order.count > limit { stored.states[stored.order.removeFirst()] = nil }
        isDirty = true
        observeTermination()
    }

    static func flush() {
        guard isDirty, let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
        isDirty = false
    }

    /// The editors still open when the app quits save theirs too.
    private static func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for coordinator in OpenEditors.shared.coordinators { coordinator.rememberViewState() }
                flush()
            }
        }
    }
}

extension CodeEditor.Coordinator {
    func rememberViewState() {
        guard let textView, textView.window != nil else { return }
        let starts = diagnosticsController.lineStarts, length = diagnosticsController.length
        let selection = textView.textSelection
        let start = SourcePosition(offset: min(selection.location, length), in: starts)
        let end = SourcePosition(offset: min(NSMaxRange(selection), length), in: starts)
        EditorViewStates.remember(EditorViewStates.State(
            selectionStart: [start.line, start.character], selectionEnd: [end.line, end.character],
            topLine: topVisibleLine() ?? start.line
        ), for: document.url)
    }

    private func topVisibleLine() -> Int? {
        guard let textView else { return nil }
        let manager = textView.textLayoutManager
        let point = CGPoint(x: 0, y: textView.visibleRect.minY - textView.contentFrame.minY + 1)
        guard let fragment = manager.textLayoutFragment(for: point) else { return nil }
        let offset = textView.textContentManager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
        return SourcePosition(offset: offset, in: diagnosticsController.lineStarts).line
    }

    /// Puts the caret and the scroll back where they were.
    func restoreViewState() {
        guard let textView, let state = EditorViewStates.state(for: document.url),
              state.selectionStart.count == 2, state.selectionEnd.count == 2 else { return }
        let starts = diagnosticsController.lineStarts, length = diagnosticsController.length
        let lower = SourcePosition(line: state.selectionStart[0], character: state.selectionStart[1]).offset(in: starts, length: length)
        let upper = SourcePosition(line: state.selectionEnd[0], character: state.selectionEnd[1]).offset(in: starts, length: length)
        textView.textSelection = NSRange(location: lower, length: max(0, upper - lower))
        restoredTopLine = (state.topLine, Date())
        scroll(toTopLine: state.topLine)
    }

    /// Scrolls a line to the top without laying out the text above it:
    /// TextKit 2 moves the viewport there and estimates what's skipped.
    func scroll(toTopLine line: Int) {
        guard let textView else { return }
        let starts = diagnosticsController.lineStarts
        let content = textView.textContentManager
        guard line > 0, line < starts.count,
              let location = content.location(content.documentRange.location, offsetBy: starts[line]) else { return }
        let manager = textView.textLayoutManager
        manager.textViewportLayoutController.relocateViewport(to: location)
        guard let fragment = manager.textLayoutFragment(for: location) else { return }
        textView.scroll(CGPoint(x: 0, y: fragment.layoutFragmentFrame.minY + textView.contentFrame.minY))
    }
}
