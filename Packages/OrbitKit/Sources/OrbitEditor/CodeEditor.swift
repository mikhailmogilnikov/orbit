import AppKit
import OrbitAPI
import OrbitUI
import STPluginNeon
@_spi(Plugins) import STTextView
import SwiftUI
import TreeSitterResource

/// SwiftUI bridge around STTextView, bound to a `TextDocument`, with
/// agent changes shown inline.
struct CodeEditor: NSViewRepresentable {
    let document: TextDocument
    var hunks: [DiffHunk] = []
    var onKeep: (DiffHunk) -> Void = { _ in }
    var onRevert: (DiffHunk) -> Void = { _ in }
    /// 0-based line to scroll to once; `onRevealHandled` clears the request.
    var revealLine: Int?
    var onRevealHandled: () -> Void = {}
    /// Git's copy of the file; the gutter marks lines that differ from it.
    var gitBaseline: String?
    var fontSize = Preferences.defaultCodeFontSize
    var wrapsLines = false
    var highlightsCurrentLine = true
    /// From the language server (D54); hover, ⌘-click and the squiggles use them.
    var diagnostics: [Diagnostic] = []
    var languages: LanguageIntelligence?
    var onOpenLocation: (SourceLocation) -> Void = { _ in }
    /// `GrammarRegistry.revision`: a grammar was installed, re-pick this file's.
    var grammarRevision = 0

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = OrbitTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Our own ruler instead of STTextView's gutter (see LineNumberRuler).
        textView.showsLineNumbers = false
        textView.highlightSelectedLine = highlightsCurrentLine
        textView.isHorizontallyResizable = !wrapsLines
        textView.isIncrementalSearchingEnabled = true
        textView.text = document.text
        textView.textDelegate = context.coordinator

        let coordinator = context.coordinator
        coordinator.updateGrammar(revision: grammarRevision, in: textView)
        GrammarRegistry.shared.ensureInstalled(for: document.url)
        coordinator.inlineDiff.textView = textView
        textView.addPlugin(InlineDiffPlugin(controller: coordinator.inlineDiff))
        coordinator.diagnosticsController.textView = textView
        textView.addPlugin(DiagnosticsPlugin(controller: coordinator.diagnosticsController))
        if let orbitView = textView as? OrbitTextView {
            orbitView.onMouseMoved = { [weak coordinator] point in coordinator?.mouseMoved(to: point) }
            orbitView.onMouseExited = { [weak coordinator] in coordinator?.mouseExited() }
            orbitView.onCommandClick = { [weak coordinator] point in coordinator?.commandClick(at: point) ?? false }
            orbitView.onCommand = { [weak coordinator] selector in coordinator?.completion.handle(selector) ?? false }
            orbitView.onResignFocus = { [weak coordinator] in coordinator?.closePopups() }
        }
        coordinator.observeScrolling(of: scrollView)

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        textView.addPlugin(LineNumberRulerPlugin(ruler: ruler))
        coordinator.ruler = ruler

        coordinator.textView = textView
        coordinator.syncedRevision = document.revision
        coordinator.applyTheme()
        (textView as? OrbitTextView)?.onAppearanceChange = { [weak coordinator] in coordinator?.applyTheme() }
        ActiveEditor.shared.coordinator = coordinator
        OpenEditors.shared.register(coordinator)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }

        // Only push text in when it changed outside the view (agent, review, reload).
        if document.revision != coordinator.syncedRevision {
            coordinator.syncedRevision = document.revision
            let old = (textView.text ?? "") as NSString
            if old as String != document.text {
                let new = document.text as NSString
                let location = Self.location(textView.textSelection.location, from: old, to: new)
                coordinator.isApplyingExternalChange = true
                textView.text = document.text
                coordinator.isApplyingExternalChange = false
                textView.textSelection = NSRange(location: location, length: 0)
                coordinator.inlineDiff.invalidate()
                coordinator.diagnosticsController.textDidChange()
            }
        }

        if textView.font.pointSize != fontSize {
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            coordinator.inlineDiff.invalidate()
            coordinator.palette.onChange?()
        }
        if textView.isHorizontallyResizable == wrapsLines { textView.isHorizontallyResizable = !wrapsLines }
        if textView.highlightSelectedLine != highlightsCurrentLine { textView.highlightSelectedLine = highlightsCurrentLine }
        coordinator.updateGrammar(revision: grammarRevision, in: textView)
        coordinator.setGitBaseline(gitBaseline)
        coordinator.inlineDiff.onKeep = onKeep
        coordinator.inlineDiff.onRevert = onRevert
        coordinator.inlineDiff.update(hunks: hunks, revision: document.revision)
        coordinator.languages = languages
        coordinator.onOpenLocation = onOpenLocation
        coordinator.diagnosticsController.update(diagnostics)

        if let revealLine {
            DispatchQueue.main.async {
                coordinator.reveal(line: revealLine)
                onRevealHandled()
            }
        }
    }

    /// Keeps the caret on the same text when lines above it changed (a merged-in agent edit).
    static func location(_ location: Int, from old: NSString, to new: NSString) -> Int {
        let shorter = min(old.length, new.length)
        var prefix = 0
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        guard location > prefix else { return min(location, new.length) }
        var suffix = 0
        while suffix < shorter - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        if location >= old.length - suffix { return min(new.length, max(0, location + new.length - old.length)) }
        return min(location, new.length)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if ActiveEditor.shared.coordinator === coordinator { ActiveEditor.shared.coordinator = nil }
        coordinator.closePopups()
        OpenEditors.shared.unregister(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        let document: TextDocument
        let inlineDiff = InlineDiffController()
        let diagnosticsController = DiagnosticsController()
        var languages: LanguageIntelligence?
        var onOpenLocation: (SourceLocation) -> Void = { _ in }
        private var hoverTask: Task<Void, Never>?
        private var popover: NSPopover?
        private var hoverRect: CGRect?
        private var scrollObserver: NSObjectProtocol?
        let palette = SyntaxPalette(theme: .system(dark: false))
        weak var textView: STTextView?
        weak var ruler: LineNumberRuler?
        var syncedRevision = 0
        var isApplyingExternalChange = false
        private var themeObserver: NSObjectProtocol?
        private var systemInsertionPoint: NSColor?
        /// Completion and signature help (D56).
        lazy var completion = CompletionController(editor: self)
        private var highlighter: (id: STPluginIdentifier, key: String)?
        private var grammarRevision: Int?
        /// The edit being made, from `willChangeTextIn`, for completion after it lands.
        private var pendingEdit: (location: Int, length: Int, replacement: String)?

        init(document: TextDocument) {
            self.document = document
            super.init()
            themeObserver = NotificationCenter.default.addObserver(forName: Extensions.themeDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTheme() }
            }
        }

        isolated deinit {
            if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            popover?.close()
        }

        /// Colors for the view's current appearance; called again on every theme
        /// or light/dark switch (colors are resolved, not dynamic, so they match the theme picked for that mode).
        func applyTheme() {
            guard let textView else { return }
            let isDark = textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let theme = Extensions.shared.colorTheme(dark: isDark)
            palette.theme = theme

            let background = theme.editorBackground?.nsColor
            if textView.backgroundColor != background { textView.backgroundColor = background }
            if let scrollView = textView.enclosingScrollView {
                scrollView.drawsBackground = background != nil
                if let background { scrollView.backgroundColor = background }
            }
            // Setting the text color restyles the whole document: only when it changes.
            let foreground = theme.editorForeground?.nsColor ?? .textColor
            if textView.textColor != foreground {
                textView.textColor = foreground
                // Restamping the text color drops the highlighter's colors without telling it.
                palette.onChange?()
            }
            if systemInsertionPoint == nil { systemInsertionPoint = textView.insertionPointColor }
            textView.insertionPointColor = theme.cursor?.nsColor ?? systemInsertionPoint ?? .controlAccentColor
            textView.selectedLineHighlightColor = theme.activeLineBackground?.nsColor
                ?? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.25)

            inlineDiff.colors = InlineDiffController.Colors(
                added: theme.added?.nsColor ?? .systemGreen,
                deleted: theme.deleted?.nsColor ?? .systemRed
            )
            diagnosticsController.colors = DiagnosticsController.Colors(
                error: theme.error?.nsColor ?? .systemRed,
                warning: theme.warning?.nsColor ?? .systemYellow,
                info: theme.info?.nsColor ?? .systemBlue
            )
            ruler?.colors = LineNumberRuler.Colors(
                background: background ?? .textBackgroundColor,
                number: theme.lineNumber?.nsColor ?? .tertiaryLabelColor,
                currentNumber: theme.activeLineNumber?.nsColor ?? .secondaryLabelColor,
                added: theme.added?.nsColor ?? .systemGreen,
                modified: theme.modified?.nsColor ?? .systemBlue,
                deleted: theme.deleted?.nsColor ?? .systemRed
            )
        }

        func textView(_ textView: STTextView, willChangeTextIn affectedCharRange: NSTextRange, replacementString: String) {
            let range = NSRange(affectedCharRange, in: textView.textContentManager)
            pendingEdit = (range.location, range.length, replacementString)
        }

        func textViewDidChangeText(_ notification: Notification) {
            scheduleGitMarkers()
            diagnosticsController.textDidChange()
            closeHover()
            let edit = pendingEdit
            pendingEdit = nil
            guard !isApplyingExternalChange, let textView else {
                closePopups()
                return
            }
            document.text = textView.text ?? ""
            syncedRevision = document.revision
            if let edit { completion.textDidChange(location: edit.location, oldLength: edit.length, replacement: edit.replacement) }
        }

        /// Highlights with the file's grammar, switching when a better one got installed.
        func updateGrammar(revision: Int, in textView: STTextView) {
            guard grammarRevision != revision else { return }
            grammarRevision = revision
            let grammar = Grammar.matching(document.url)
            guard grammar?.key != highlighter?.key else { return }
            if let highlighter { textView.removePlugin(highlighter.id) }
            highlighter = grammar.map { (textView.addPlugin(SyntaxHighlightPlugin(palette: palette, grammar: $0)), $0.key) }
        }

        func closePopups() {
            completion.close()
            completion.signatures.close()
        }

        /// A character's rect on screen (for popups); nil when it isn't laid out.
        func screenRect(at offset: Int) -> NSRect? {
            guard let textView, let window = textView.window else { return nil }
            let content = textView.textContentManager
            let manager = textView.textLayoutManager
            guard let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
            var frame: CGRect?
            manager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: [.upstreamAffinity, .rangeNotRequired]) { _, segment, _, _ in
                frame = segment
                return false
            }
            guard let frame else { return nil }
            let contentFrame = textView.contentFrame
            let local = frame.offsetBy(dx: contentFrame.minX, dy: contentFrame.minY)
            guard textView.visibleRect.intersects(local.insetBy(dx: -1, dy: -1)) else { return nil }
            return window.convertToScreen(textView.convert(local, to: nil))
        }

        // MARK: Git change markers

        private var gitBaseline: String?
        private var markersTask: Task<Void, Never>?

        func setGitBaseline(_ baseline: String?) {
            guard baseline != gitBaseline else { return }
            gitBaseline = baseline
            scheduleGitMarkers(delay: .zero)
        }

        /// Diffing a big file on every keystroke would stutter: wait for a pause, diff off the main actor.
        private func scheduleGitMarkers(delay: Duration = .milliseconds(300)) {
            markersTask?.cancel()
            guard let baseline = gitBaseline else {
                ruler?.changeMarkers = LineMarkers()
                return
            }
            markersTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let current = self?.textView?.text else { return }
                let markers = await Task.detached(priority: .utility) { LineMarkers(baseline: baseline, current: current) }.value
                guard !Task.isCancelled else { return }
                self?.ruler?.changeMarkers = markers
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            completion.selectionDidChange()
            ActiveEditor.shared.coordinator = self
            ruler?.needsDisplay = true
            EditorSelectionService.shared.cursorMoved(in: self)
        }

        /// 0-based line of the insertion point.
        var cursorLine: Int {
            guard let textView else { return 0 }
            let text = (textView.text ?? "") as NSString
            let location = min(textView.textSelection.location, text.length)
            var line = 0
            text.enumerateSubstrings(in: NSRange(location: 0, length: location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
                line += 1
            }
            // `byLines` doesn't count a trailing empty line segment.
            if location > 0, text.character(at: location - 1) == 0x0A { return line }
            return max(0, line - 1)
        }

        func reveal(line: Int) {
            guard let textView else { return }
            let text = (textView.text ?? "") as NSString
            let starts = InlineDiffController.lineStarts(of: text)
            let offset = starts[min(max(0, line), starts.count - 1)]
            textView.textSelection = NSRange(location: offset, length: 0)
            // Scroll a few lines past the target so the removed-lines gap above it is visible too.
            let context = starts[min(starts.count - 1, max(0, line + 6))]
            textView.scrollRangeToVisible(NSRange(location: context, length: 0))
            textView.scrollRangeToVisible(NSRange(location: starts[max(0, line - 4)], length: 0))
            textView.window?.makeFirstResponder(textView)
        }

        // MARK: Language server: hover, definition, problems

        func observeScrolling(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.closeHover()
                    self?.completion.signatures.close()
                    self?.completion.reposition()
                }
            }
        }

        /// The pointer rested: after a pause, the problems and symbol info under it.
        func mouseMoved(to point: NSPoint) {
            if popover?.isShown == true, let hoverRect {
                if hoverRect.insetBy(dx: -6, dy: -6).contains(point) { return }
                closeHover()
            }
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                await self?.showHover(at: point)
            }
        }

        /// Leaving for the popover keeps it, so its text can be selected.
        func mouseExited() {
            hoverTask?.cancel()
            guard popover != nil else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, let window = popover?.contentViewController?.view.window else { return }
                if !window.frame.contains(NSEvent.mouseLocation) { closeHover() }
            }
        }

        func closeHover() {
            hoverTask?.cancel()
            popover?.close()
            popover = nil
            hoverRect = nil
        }

        private func showHover(at point: NSPoint) async {
            guard let textView, let offset = characterOffset(at: point) else { return }
            let controller = diagnosticsController
            let problems = controller.diagnostics(at: offset)
            let position = SourcePosition(offset: offset, in: controller.lineStarts)
            let info = await languages?.hover(at: position, in: document.url)
            guard !Task.isCancelled, !problems.isEmpty || info != nil else { return }

            let starts = controller.lineStarts, length = controller.length
            let anchor = info?.range.map { $0.nsRange(in: starts, length: length) }
                ?? problems.first.map { $0.range.nsRange(in: starts, length: length) }
                ?? NSRange(location: offset, length: 1)
            let rects = controller.rects(for: anchor.length > 0 ? anchor : NSRange(location: offset, length: 1))
            guard let first = rects.first else { return }
            let rect = rects.dropFirst().reduce(first) { $0.union($1) }

            let host = NSHostingController(rootView: HoverCard(diagnostics: problems, markdown: info?.markdown, colors: controller.colors))
            host.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = false
            popover.contentViewController = host
            closeHover()
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            self.popover = popover
            hoverRect = rect
        }

        /// The character under a point; nil past the end of a line or between lines.
        func characterOffset(at point: NSPoint) -> Int? {
            guard let textView else { return nil }
            let manager = textView.textLayoutManager
            let content = textView.contentFrame
            let local = CGPoint(x: point.x - content.minX, y: point.y - content.minY)
            guard let fragment = manager.textLayoutFragment(for: local),
                  let location = manager.caretLocation(interactingAt: local, inContainerAt: fragment.rangeInElement.location) else { return nil }
            let offset = textView.textContentManager.offset(from: manager.documentRange.location, to: location)
            // The location snaps to the nearest caret spot: take the character actually under the point.
            for candidate in [offset, offset - 1] where candidate >= 0 && candidate < diagnosticsController.length {
                if diagnosticsController.rects(for: NSRange(location: candidate, length: 1)).contains(where: { $0.contains(point) }) {
                    return candidate
                }
            }
            return nil
        }

        /// ⌘-click: jump to the definition of what's under the pointer.
        func commandClick(at point: NSPoint) -> Bool {
            guard languages?.server(for: document.url) != nil, let offset = characterOffset(at: point) else { return false }
            closeHover()
            goToDefinition(at: offset)
            return true
        }

        func goToDefinition(at offset: Int) {
            guard let languages else {
                NSSound.beep()
                return
            }
            let position = SourcePosition(offset: offset, in: diagnosticsController.lineStarts)
            let url = document.url
            Task { [weak self] in
                guard let location = await languages.definition(at: position, in: url).first else {
                    NSSound.beep()
                    return
                }
                self?.onOpenLocation(location)
            }
        }

        /// Moves the caret to the next squiggle, wrapping around.
        func revealNextProblem() {
            guard let textView else { return }
            let starts = diagnosticsController.lineStarts, length = diagnosticsController.length
            let offsets = diagnosticsController.diagnostics.map { $0.range.nsRange(in: starts, length: length).location }.sorted()
            guard let wrapped = offsets.first else {
                NSSound.beep()
                return
            }
            let caret = textView.textSelection.location
            let target = offsets.first { $0 > caret } ?? wrapped
            textView.textSelection = NSRange(location: target, length: 0)
            textView.scrollRangeToVisible(NSRange(location: target, length: 0))
            textView.window?.makeFirstResponder(textView)
        }

        func revealHunk(after line: Int, forward: Bool) {
            let hunks = inlineDiff.hunks
            guard !hunks.isEmpty else { return }
            let target = forward
                ? hunks.first { $0.newRange.lowerBound > line } ?? hunks.first
                : hunks.last { $0.newRange.lowerBound < line } ?? hunks.last
            if let target { reveal(line: target.newRange.lowerBound) }
        }
    }
}

/// STTextView hardened against invalid input from accessibility clients
/// (VoiceOver, automation): out-of-range selections crash the stock view.
final class OrbitTextView: STTextView {
    var onAppearanceChange: (() -> Void)?
    /// Pointer moves (text-view coordinates), for hover info.
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    /// ⌘-click; returns whether it was handled (go to definition).
    var onCommandClick: ((NSPoint) -> Bool)?
    /// Key commands (arrows, Return, Tab, Esc, ⌃Space) the completion list may take; true when handled.
    var onCommand: ((Selector) -> Bool)?
    var onResignFocus: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), onCommandClick?(convert(event.locationInWindow, from: nil)) == true { return }
        super.mouseDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if onCommand?(selector) == true { return }
        super.doCommand(by: selector)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignFocus?() }
        return resigned
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        super.setAccessibilitySelectedTextRange(clamped(range))
    }

    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        super.setAccessibilitySelectedTextRanges(ranges?.map { NSValue(range: clamped($0.rangeValue)) })
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let length = textContentManager.length
        let location = range.location == NSNotFound ? length : min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }
}

/// The editor that last had focus, for keyboard commands.
@MainActor
final class ActiveEditor {
    static let shared = ActiveEditor()
    weak var coordinator: CodeEditor.Coordinator?
}

@MainActor
@Observable
final class EditorSelectionService: EditorSelectionProviding {
    static let shared = EditorSelectionService()

    private(set) var cursor: EditorCursor?
    @ObservationIgnored private var cursorTask: Task<Void, Never>?

    /// Counting lines walks the text, so wait until the caret rests.
    func cursorMoved(in coordinator: CodeEditor.Coordinator) {
        cursorTask?.cancel()
        cursorTask = Task { [weak coordinator] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let coordinator else { return }
            let cursor = EditorCursor(url: coordinator.document.url, line: coordinator.cursorLine)
            if cursor != self.cursor { self.cursor = cursor }
        }
    }

    var selection: EditorSelection? {
        guard let coordinator = ActiveEditor.shared.coordinator, let textView = coordinator.textView else { return nil }
        let text = (textView.text ?? "") as NSString
        let range = NSIntersectionRange(textView.textSelection, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return nil }
        let selected = text.substring(with: range)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let starts = InlineDiffController.lineStarts(of: text)
        func line(at offset: Int) -> Int { (starts.lastIndex { $0 <= offset } ?? 0) + 1 }
        // A selection ending right after a newline doesn't include the next line.
        let first = line(at: range.location)
        let last = max(first, line(at: NSMaxRange(range) - 1))
        return EditorSelection(url: coordinator.document.url, text: selected, lines: first...last)
    }
}

enum Language {
    static func treeSitter(for url: URL) -> TreeSitterLanguage? {
        switch url.pathExtension.lowercased() {
        case "swift": .swift
        case "js", "mjs", "cjs", "jsx": .javascript
        case "ts", "mts", "cts", "tsx": .typescript
        case "json", "jsonc": .json
        case "py": .python
        case "rb": .ruby
        case "rs": .rust
        case "go": .go
        case "c", "h": .c
        case "cpp", "cc", "cxx", "hpp", "mm", "m": .cpp
        case "cs": .csharp
        case "java", "kt": .java
        case "php": .php
        case "html", "htm": .html
        case "css", "scss": .css
        case "md", "markdown": .markdown
        case "sh", "bash", "zsh": .bash
        case "sql": .sql
        case "toml": .toml
        case "yml", "yaml": .yaml
        default: nil
        }
    }
}
