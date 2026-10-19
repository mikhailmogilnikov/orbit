import AppKit
import OrbitAPI
import OrbitUI
@_spi(Plugins) import STTextView
import SwiftUI

/// The editors on screen by file, so language-server edits (a rename, a quick
/// fix, formatting) go through the text view: one undo step, caret kept (D59).
@MainActor
final class OpenEditors: SourceEditing {
    static let shared = OpenEditors()

    private final class Entry {
        weak var coordinator: CodeEditor.Coordinator?
        init(_ coordinator: CodeEditor.Coordinator) { self.coordinator = coordinator }
    }

    private var entries: [URL: Entry] = [:]

    var coordinators: [CodeEditor.Coordinator] { entries.values.compactMap(\.coordinator) }

    func register(_ coordinator: CodeEditor.Coordinator) {
        entries[coordinator.document.url.standardizedFileURL] = Entry(coordinator)
    }

    func unregister(_ coordinator: CodeEditor.Coordinator) {
        let url = coordinator.document.url.standardizedFileURL
        if entries[url]?.coordinator === coordinator { entries[url] = nil }
    }

    func apply(_ edits: [SourceEdit], to url: URL) -> Bool {
        guard let coordinator = entries[url.standardizedFileURL]?.coordinator, coordinator.textView != nil else { return false }
        coordinator.applyEdits(edits)
        return true
    }
}

extension CodeEditor.Coordinator {
    /// Server edits (positions in the current text) as one undo step. Formatting
    /// sends hundreds of one-space edits: they're turned into a few changed line
    /// blocks first, so the view (highlighting, sync, squiggles) handles a
    /// handful of replacements. Undo puts the caret back where it was.
    func applyEdits(_ edits: [SourceEdit]) {
        guard let textView, let current = diagnosticsController.string, !edits.isEmpty else { return }
        let old = current as String
        let new = SourceEdit.apply(edits, to: old)
        guard new != old else { return }
        let patch = LinePatch(from: old, to: new)
        let before = textView.textSelection
        let caret = patch.map(before.location)
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        // Registered first, so it runs last when undoing: after the text is back.
        undo?.registerUndo(withTarget: self) { coordinator in
            MainActor.assumeIsolated { coordinator.restoreCaret(before) }
        }
        textView.breakUndoCoalescing()
        completion.whileApplying {
            // In document order: each range is shifted by what came before.
            for replacement in patch.replacements {
                textView.insertText(replacement.text, replacementRange: replacement.range)
            }
        }
        textView.breakUndoCoalescing()
        undo?.endUndoGrouping()
        textView.textSelection = NSRange(location: min(caret, diagnosticsController.length), length: 0)
    }

    private func restoreCaret(_ selection: NSRange) {
        guard let textView else { return }
        let clamped = NSRange(location: min(selection.location, diagnosticsController.length), length: 0)
        textView.textSelection = clamped
        textView.scrollRangeToVisible(clamped)
    }

    // MARK: Code actions (⇧⌘A)

    /// Fixes and refactorings at the caret (or selection), in a menu there.
    func showCodeActions() {
        guard let textView, let languages else {
            NSSound.beep()
            return
        }
        let url = document.url
        let selection = textView.textSelection
        let starts = diagnosticsController.lineStarts
        var range = SourceRange(
            start: SourcePosition(offset: selection.location, in: starts),
            end: SourcePosition(offset: NSMaxRange(selection), in: starts)
        )
        // On a squiggle's line without a selection: the problem's own range.
        if selection.length == 0, let problem = diagnosticsController.diagnostics(at: selection.location).first {
            range = problem.range
        }
        let anchor = screenRect(at: selection.location)
        Task { [weak self] in
            let actions = await languages.codeActions(for: range, in: url)
            guard let self, self.textView != nil else { return }
            self.presentCodeActions(actions, at: anchor)
        }
    }

    func presentCodeActions(_ actions: [CodeAction], at anchor: NSRect?) {
        guard let textView, let window = textView.window else { return }
        let menu = NSMenu(title: "Code Actions")
        menu.autoenablesItems = false
        // Fixes first (preferred ones on top), then refactorings, then whole-file actions.
        func rank(_ action: CodeAction) -> Int {
            if action.isPreferred { return 0 }
            guard let kind = action.kind else { return 2 }
            if kind.hasPrefix("quickfix") { return 1 }
            if kind.hasPrefix("refactor") { return 3 }
            return 4
        }
        // Servers also list what doesn't apply here (TypeScript's refactorings,
        // with a reason); VS Code leaves those out of this menu, and so do we.
        let actions = actions.filter { $0.disabledReason == nil }
        let sorted = actions.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        if sorted.isEmpty {
            let item = NSMenuItem(title: "No Code Actions Here", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        var lastGroup: Int?
        for action in sorted {
            let group = rank(action) <= 1 ? 1 : rank(action)
            if let lastGroup, lastGroup != group { menu.addItem(.separator()) }
            lastGroup = group
            let item = NSMenuItem(title: action.title, action: #selector(CodeActionTarget.run(_:)), keyEquivalent: "")
            item.target = CodeActionTarget.shared
            item.representedObject = CodeActionTarget.Payload(action: action, coordinator: self)
            if group == 1 {
                item.image = NSImage(systemSymbolName: action.isPreferred ? "wand.and.sparkles" : "wrench.adjustable", accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        let point: NSPoint
        if let anchor {
            let inWindow = window.convertFromScreen(anchor)
            point = textView.convert(NSPoint(x: inWindow.minX, y: inWindow.minY), from: nil)
        } else {
            point = NSPoint(x: textView.visibleRect.minX + 40, y: textView.visibleRect.minY + 40)
        }
        _ = menu.popUp(positioning: menu.items.first, at: point, in: textView)
    }

    func runCodeAction(_ action: CodeAction) {
        guard let languages else { return }
        let url = document.url
        Task {
            if let failure = await languages.perform(action, in: url) {
                let alert = NSAlert()
                alert.messageText = "Couldn't apply “\(action.title)”"
                alert.informativeText = failure
                alert.runModal()
            }
        }
    }

    // MARK: Rename (⌃⌘E)

    func startRename() {
        guard let textView, let languages else {
            NSSound.beep()
            return
        }
        let url = document.url
        let caret = textView.textSelection.location
        let position = SourcePosition(offset: caret, in: diagnosticsController.lineStarts)
        Task { [weak self] in
            guard let target = await languages.prepareRename(at: position, in: url) else {
                NSSound.beep()
                return
            }
            self?.presentRename(target, at: position)
        }
    }

    private func presentRename(_ target: RenameTarget, at position: SourcePosition) {
        guard let textView, let languages else { return }
        let starts = diagnosticsController.lineStarts, length = diagnosticsController.length
        let symbol = target.range.nsRange(in: starts, length: length)
        let rects = diagnosticsController.rects(for: symbol.length > 0 ? symbol : NSRange(location: symbol.location, length: 1))
        guard let first = rects.first else { return }
        let rect = rects.dropFirst().reduce(first) { $0.union($1) }
        let url = document.url

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let field = RenameField(original: target.placeholder) { [weak popover] newName in
            popover?.close()
            guard newName != target.placeholder, !newName.isEmpty else { return }
            Task {
                switch await languages.rename(at: position, in: url, to: newName) {
                case .success: break
                case .failure(let failure):
                    let alert = NSAlert()
                    alert.messageText = "Couldn't rename “\(target.placeholder)”"
                    alert.informativeText = failure.message
                    alert.runModal()
                }
            }
        } cancel: { [weak popover] in
            popover?.close()
        }
        let host = NSHostingController(rootView: field)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        closeHover()
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
    }

    // MARK: Formatting (⌃⇧I)

    /// With text selected, only its lines change (D140).
    func formatDocument() {
        // Always asked, even when it can't: it says why and where to set a formatter up.
        guard let languages, let textView = textView as? OrbitTextView, let scrollView = textView.enclosingScrollView else {
            NSSound.beep()
            return
        }
        let url = document.url
        let lines = Self.lines(of: textView.selectionRanges.filter { $0.length > 0 }, in: (textView.text ?? "") as NSString)
        // Only slow formatters (a cold Node start) say they're working.
        let working = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            EditorToast.show("Formatting…", busy: true, over: scrollView, hideAfter: nil)
        }
        Task {
            let outcome = await languages.format(url, lines: lines)
            working.cancel()
            if let failure = outcome.failure {
                EditorToast.hide()
                let alert = NSAlert()
                alert.messageText = outcome.formatter.map { "\($0) couldn't format “\(url.lastPathComponent)”" } ?? "Couldn't format “\(url.lastPathComponent)”"
                alert.informativeText = failure
                alert.runModal()
                return
            }
            let name = outcome.formatter ?? "Formatter"
            let what = lines == nil ? "" : " selection"
            EditorToast.show(outcome.changed ? "Formatted\(what) · \(name)" : "Already formatted · \(name)", over: scrollView)
        }
    }

    /// The lines from the first selection's to the last one's; nil without a selection.
    static func lines(of selections: [NSRange], in text: NSString) -> ClosedRange<Int>? {
        guard let first = selections.map(\.location).min(), let end = selections.map(NSMaxRange).max() else { return nil }
        let starts = InlineDiffController.lineStarts(of: text)
        func line(_ offset: Int) -> Int { starts.lastIndex { $0 <= min(offset, text.length) } ?? 0 }
        var last = line(end)
        // Selected up to the start of a line: that line isn't part of it.
        if last > line(first), starts[last] == end { last -= 1 }
        return line(first)...last
    }
}

/// A short note in the editor's top right corner: what just ran ("Formatted · Prettier").
@MainActor
enum EditorToast {
    private static weak var shown: NSView?
    private static var hiding: Task<Void, Never>?

    static func show(_ text: String, busy: Bool = false, over scrollView: NSScrollView, hideAfter delay: Duration? = .milliseconds(1800)) {
        hiding?.cancel()
        shown?.removeFromSuperview()

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        var views: [NSView] = [label]
        if busy {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            views.insert(spinner, at: 0)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        let size = stack.fittingSize

        let toast = NSVisualEffectView()
        toast.material = .popover
        toast.blendingMode = .withinWindow
        toast.state = .active
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 8
        toast.layer?.masksToBounds = true
        stack.frame = NSRect(origin: .zero, size: size)
        stack.autoresizingMask = [.width, .height]
        toast.addSubview(stack)
        // Frames, not constraints: SwiftUI's host of the editor never runs
        // Auto Layout for views added to it, so a constrained toast stayed 0×0.
        // A sibling above the scroll view, not inside it, so it stays put while scrolling.
        let container = scrollView.superview ?? scrollView
        let area = container === scrollView ? scrollView.bounds : scrollView.frame
        let y = container.isFlipped ? area.minY + 8 : area.maxY - 8 - size.height
        toast.frame = NSRect(x: area.maxX - 18 - size.width, y: y, width: size.width, height: size.height)
        toast.autoresizingMask = container.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        container.addSubview(toast, positioned: .above, relativeTo: container === scrollView ? nil : scrollView)
        shown = toast
        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            toast.animator().alphaValue = 1
        }
        if let delay {
            hiding = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                hide()
            }
        }
    }

    static func hide() {
        hiding?.cancel()
        guard let toast = shown else { return }
        shown = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            toast.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            toast.removeFromSuperview()
        }
    }
}

/// NSMenu items need an Objective-C target; this one forwards to the editor.
@MainActor
final class CodeActionTarget: NSObject {
    static let shared = CodeActionTarget()

    final class Payload: NSObject {
        let action: CodeAction
        weak var coordinator: CodeEditor.Coordinator?

        init(action: CodeAction, coordinator: CodeEditor.Coordinator) {
            self.action = action
            self.coordinator = coordinator
        }
    }

    @objc func run(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload else { return }
        payload.coordinator?.runCodeAction(payload.action)
    }
}

/// The new name, typed where the symbol is; Return renames everywhere, Esc cancels.
struct RenameField: View {
    let original: String
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var name: String
    @FocusState private var focused: Bool

    init(original: String, commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.original = original
        self.commit = commit
        self.cancel = cancel
        _name = State(initialValue: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rename “\(original)” everywhere")
                .font(.orbit(.micro))
                .foregroundStyle(.secondary)
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.orbit(.control, design: .monospaced))
                .frame(width: 260)
                .focused($focused)
                .onSubmit { commit(name.trimmingCharacters(in: .whitespaces)) }
                .onExitCommand(perform: cancel)
        }
        .padding(10)
        .onAppear { focused = true }
    }
}

