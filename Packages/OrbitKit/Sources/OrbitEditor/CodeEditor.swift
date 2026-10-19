import AppKit
import OrbitAPI
import OrbitUI
@_spi(Plugins) import STTextView
import SwiftUI

/// SwiftUI bridge around STTextView, bound to a `TextDocument`, with
/// agent changes shown inline.
struct CodeEditor: NSViewRepresentable {
    let document: TextDocument
    var hunks: [DiffHunk] = []
    var onKeep: (DiffHunk) -> Void = { _ in }
    var onRevert: (DiffHunk) -> Void = { _ in }
    /// The file's review notes (D125); nil when there's no agent to send them to.
    var comments: [ReviewComment]?
    var onSaveComment: (ReviewComment) -> Void = { _ in }
    var onRemoveComment: (ReviewComment.ID) -> Void = { _ in }
    /// 0-based line (and UTF-16 column) to scroll to once; `onRevealHandled` clears the request.
    var reveal: (line: Int, column: Int?)?
    var onRevealHandled: () -> Void = {}
    /// Git's copy of the file; the gutter marks lines that differ from it.
    var gitBaseline: String?
    var fontSize = Preferences.defaultCodeFontSize
    var wrapsLines = false
    var highlightsCurrentLine = true
    /// From the language server (D54); hover, ⌘-click and the squiggles use them.
    var diagnostics: [Diagnostic] = []
    var languages: LanguageIntelligence?
    var showsInlayHints = true
    var showsStickyScroll = true
    var showsIndentGuides = true
    /// Bumped when the server's hints went stale.
    var inlayHintsRevision = 0
    var onOpenLocation: (SourceLocation) -> Void = { _ in }
    /// `GrammarRegistry.revision`: a grammar was installed, re-pick this file's.
    var grammarRevision = 0
    /// For `.editorconfig`.
    var workspaceRoot: URL?
    /// Picked in the status bar; nil until the file's is detected.
    var indentation: Indentation?
    /// False when the explorer opened the file while browsing (D98).
    var takesFocus = true
    /// `Workspace.editorFocusRequest` for this file: a new value takes the focus.
    var focusRequest: Int?
    /// This window's commands, for the right-click menu.
    var commands: CommandRegistry?
    /// The caret's 0-based line and UTF-16 column, for Go Back (D99).
    var onCaretMove: (Int, Int) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        // `STTextView.scrollableTextView()`, in our scroll view (see `EditorScrollView`).
        let scrollView = EditorScrollView()
        scrollView.clipsToBounds = true
        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        let textView: STTextView = OrbitTextView()
        scrollView.documentView = textView
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Our own ruler instead of STTextView's gutter (see LineNumberRuler).
        textView.showsLineNumbers = false
        textView.highlightSelectedLine = highlightsCurrentLine
        textView.isHorizontallyResizable = !wrapsLines
        textView.isIncrementalSearchingEnabled = true
        textView.text = document.text
        textView.textDelegate = context.coordinator
        context.coordinator.applyIndentation(
            indentation ?? EditorIndentation.shared.detect(document.url, text: document.text, root: workspaceRoot), to: textView
        )

        let coordinator = context.coordinator
        coordinator.updateGrammar(revision: grammarRevision, in: textView)
        (textView as? OrbitTextView)?.syntaxLanguage = GrammarCatalog.shared.language(
            for: document.url, firstLine: StaticHighlighter.firstLine(of: document.text)
        )
        GrammarRegistry.shared.ensureInstalled(for: document.url, firstLine: StaticHighlighter.firstLine(of: document.text))
        coordinator.inlineDiff.textView = textView
        textView.addPlugin(InlineDiffPlugin(controller: coordinator.inlineDiff))
        coordinator.diagnosticsController.textView = textView
        coordinator.diagnosticsController.onFadedChange = { [weak palette = coordinator.palette] faded in palette?.faded = faded }
        textView.addPlugin(DiagnosticsPlugin(controller: coordinator.diagnosticsController))
        coordinator.symbolHighlights.textView = textView
        coordinator.symbolHighlights.url = document.url
        coordinator.definitionLink.textView = textView
        coordinator.definitionLink.url = document.url
        coordinator.definitionLink.characterOffset = { [weak coordinator] point in coordinator?.characterOffset(at: point) }
        textView.addPlugin(SymbolHighlightPlugin(controller: coordinator.symbolHighlights))
        coordinator.bracketMatch.textView = textView
        coordinator.indentGuides.textView = textView
        coordinator.indentGuides.isEnabled = showsIndentGuides
        textView.addPlugin(IndentGuidesPlugin(controller: coordinator.indentGuides))
        textView.addPlugin(BracketMatchPlugin(controller: coordinator.bracketMatch))
        coordinator.inlayHints.textView = textView
        coordinator.inlayHints.url = document.url
        textView.addPlugin(InlayHintPlugin(controller: coordinator.inlayHints))
        coordinator.folding.textView = textView
        coordinator.folding.url = document.url
        (textView.textContentManager as? NSTextContentStorage)?.delegate = coordinator.folding
        textView.addPlugin(FoldingPlugin(controller: coordinator.folding))
        if let orbitView = textView as? OrbitTextView {
            orbitView.onMouseMoved = { [weak coordinator] point in coordinator?.mouseMoved(to: point) }
            orbitView.onMouseExited = { [weak coordinator] in coordinator?.mouseExited() }
            orbitView.onCommandClick = { [weak coordinator] point in coordinator?.commandClick(at: point) ?? false }
            orbitView.onCommand = { [weak coordinator] selector in coordinator?.completion.handle(selector) ?? false }
            orbitView.onResignFocus = { [weak coordinator] in coordinator?.closePopups() }
            orbitView.onModifiersChanged = { [weak coordinator] flags in coordinator?.definitionLink.update(modifiers: flags) }
        }
        coordinator.observeScrolling(of: scrollView)

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        textView.addPlugin(LineNumberRulerPlugin(ruler: ruler))
        coordinator.ruler = ruler
        let overview = OverviewRuler()
        scrollView.addSubview(overview, positioned: .below, relativeTo: scrollView.verticalScroller)
        scrollView.overview = overview
        coordinator.overview = overview
        coordinator.symbolHighlights.onChange = { [weak overview] in overview?.highlights = $0 }
        coordinator.folding.ruler = ruler
        let sticky = coordinator.stickyScroll
        sticky.textView = textView
        sticky.ruler = ruler
        sticky.inlayHints = coordinator.inlayHints
        sticky.isEnabled = showsStickyScroll
        sticky.onReveal = { [weak coordinator] line in coordinator?.revealPinned(line: line) }
        textView.addPlugin(StickyScrollPlugin(controller: sticky))
        coordinator.folding.onRegionsChange = { [weak sticky] in sticky?.setNeedsUpdate() }
        ruler.onToggleFold = { [weak coordinator] line in coordinator?.folding.toggle(line: line) }

        coordinator.textView = textView
        coordinator.syncedRevision = document.revision
        coordinator.applyTheme()
        (textView as? OrbitTextView)?.onAppearanceChange = { [weak coordinator] in coordinator?.applyTheme() }
        ActiveEditor.shared.coordinator = coordinator
        OpenEditors.shared.register(coordinator)
        coordinator.folding.onRestore = { [weak coordinator] in coordinator?.foldsWereRestored() }
        let restores = reveal == nil, takesFocus = takesFocus
        coordinator.focusRequest = focusRequest
        coordinator.onCaretMove = onCaretMove
        coordinator.commands = commands
        DispatchQueue.main.async {
            if restores { coordinator.restoreViewState() }
            // Before this, the caret is where a new text view puts it, not where the user left it.
            coordinator.reportsCaret = true
            if takesFocus { textView.window?.makeFirstResponder(textView) }
        }
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
                textView.textSelection = NSRange(location: location, length: 0)
                coordinator.isApplyingExternalChange = false
                coordinator.inlineDiff.invalidate()
                coordinator.diagnosticsController.textDidChange()
                coordinator.symbolHighlights.textDidChange()
                coordinator.inlayHints.textWasReplaced()
                coordinator.folding.textWasReplaced(old: old)
            }
        }

        if textView.font.pointSize != fontSize {
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            coordinator.inlineDiff.invalidate()
            coordinator.palette.onChange?()
            coordinator.inlayHints.fontDidChange()
            if let orbit = textView as? OrbitTextView { coordinator.applyIndentation(orbit.indentation, to: textView) }
        }
        if let indentation, (textView as? OrbitTextView)?.indentation != indentation {
            coordinator.applyIndentation(indentation, to: textView)
        }
        if textView.isHorizontallyResizable == wrapsLines { textView.isHorizontallyResizable = !wrapsLines }
        if textView.highlightSelectedLine != highlightsCurrentLine { textView.highlightSelectedLine = highlightsCurrentLine }
        coordinator.updateGrammar(revision: grammarRevision, in: textView)
        coordinator.setGitBaseline(gitBaseline)
        coordinator.inlineDiff.onKeep = onKeep
        coordinator.inlineDiff.onRevert = onRevert
        coordinator.inlineDiff.url = document.url
        coordinator.inlineDiff.onSaveComment = comments == nil ? nil : onSaveComment
        coordinator.inlineDiff.onRemoveComment = onRemoveComment
        coordinator.inlineDiff.update(hunks: hunks, comments: comments ?? [], revision: document.revision)
        coordinator.languages = languages
        coordinator.symbolHighlights.languages = languages
        coordinator.definitionLink.languages = languages
        coordinator.onOpenLocation = onOpenLocation
        coordinator.onCaretMove = onCaretMove
        coordinator.commands = commands
        if let focusRequest, focusRequest != coordinator.focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        let shownDiagnostics = coordinator.diagnosticsController.diagnostics
        coordinator.diagnosticsController.update(diagnostics)
        coordinator.updateOverview()
        coordinator.inlayHints.languages = languages
        if coordinator.folding.languages == nil, languages != nil {
            coordinator.folding.languages = languages
            coordinator.folding.refresh()
        }
        coordinator.inlayHints.isEnabled = showsInlayHints
        coordinator.stickyScroll.isEnabled = showsStickyScroll
        coordinator.indentGuides.isEnabled = showsIndentGuides
        // New problems mean the server has caught up with the text: its hints may have changed too.
        if coordinator.inlayHintsRevision != inlayHintsRevision || coordinator.diagnosticsController.diagnostics != shownDiagnostics {
            coordinator.inlayHintsRevision = inlayHintsRevision
            coordinator.inlayHints.refresh(after: .milliseconds(150))
            coordinator.folding.refresh(after: .milliseconds(150))
        }

        if let reveal {
            DispatchQueue.main.async {
                coordinator.reveal(line: reveal.line, column: reveal.column)
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
        ActiveEditor.shared.remove(coordinator)
        coordinator.closePopups()
        coordinator.inlineDiff.closeComment()
        coordinator.inlineEditPopover?.close()
        coordinator.rememberViewState()
        EditorViewStates.flush()
        OpenEditors.shared.unregister(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        let document: TextDocument
        var focusRequest: Int?
        let inlineDiff = InlineDiffController()
        /// ⌘K's instruction popover (D127).
        var inlineEditPopover: NSPopover?
        let diagnosticsController = DiagnosticsController()
        lazy var symbolHighlights = SymbolHighlightController(geometry: diagnosticsController)
        lazy var bracketMatch = BracketMatchController(geometry: diagnosticsController)
        let indentGuides = IndentGuidesController()
        lazy var definitionLink = DefinitionLinkController(geometry: diagnosticsController)
        lazy var inlayHints = InlayHintController(geometry: diagnosticsController)
        lazy var folding = FoldingController(geometry: diagnosticsController)
        lazy var stickyScroll = StickyScrollController(geometry: diagnosticsController, folding: folding, palette: palette)
        var inlayHintsRevision: Int?
        var languages: LanguageIntelligence?
        var onOpenLocation: (SourceLocation) -> Void = { _ in }
        private var hoverTask: Task<Void, Never>?
        private var hoverPanel: HoverPanel?
        private var hoverRect: CGRect?
        private var scrollObserver: NSObjectProtocol?
        let palette = SyntaxPalette(theme: .system(dark: false))
        weak var textView: STTextView?
        weak var ruler: LineNumberRuler?
        weak var overview: OverviewRuler?
        var syncedRevision = 0
        /// The line scrolled back to on open; folds coming back later shift the text, so it's scrolled to again.
        var restoredTopLine: (line: Int, at: Date)?
        var isApplyingExternalChange = false
        var onCaretMove: (Int, Int) -> Void = { _, _ in }
        var reportsCaret = false
        weak var commands: CommandRegistry?
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
            hoverPanel?.hide()
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
            textView.insertionPointColor = theme.cursor?.nsColor ?? systemInsertionPoint ?? Theme.accentNSColor
            textView.selectedLineHighlightColor = theme.activeLineBackground?.nsColor
                ?? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.25)

            inlineDiff.colors = InlineDiffController.Colors(
                added: theme.added?.nsColor ?? .systemGreen,
                deleted: theme.deleted?.nsColor ?? .systemRed
            )
            let ink: NSColor = isDark ? .white : .black
            symbolHighlights.colors = SymbolHighlightController.Colors(
                read: theme.symbolHighlight?.nsColor ?? ink.withAlphaComponent(isDark ? 0.1 : 0.07),
                write: theme.symbolHighlightWrite?.nsColor ?? ink.withAlphaComponent(isDark ? 0.17 : 0.12)
            )
            bracketMatch.color = foreground.withAlphaComponent(isDark ? 0.5 : 0.4)
            indentGuides.color = theme.indentGuide?.nsColor ?? ink.withAlphaComponent(isDark ? 0.12 : 0.1)
            inlayHints.colors = InlayHintController.Colors(
                text: theme.hint?.nsColor ?? ink.withAlphaComponent(0.5),
                background: theme.hintBackground?.nsColor ?? ink.withAlphaComponent(isDark ? 0.08 : 0.05)
            )
            folding.colors = FoldingController.Colors(
                text: theme.hint?.nsColor ?? ink.withAlphaComponent(0.5),
                background: theme.hintBackground?.nsColor ?? ink.withAlphaComponent(isDark ? 0.08 : 0.05),
                editor: background ?? .textBackgroundColor
            )
            diagnosticsController.colors = DiagnosticsController.Colors(
                error: theme.error?.nsColor ?? .systemRed,
                warning: theme.warning?.nsColor ?? .systemYellow,
                info: theme.info?.nsColor ?? .systemBlue,
                strike: (theme.editorForeground?.nsColor ?? ink).withAlphaComponent(0.7)
            )
            stickyScroll.colors = StickyScrollController.Colors(
                background: background ?? .textBackgroundColor,
                number: theme.lineNumber?.nsColor ?? .tertiaryLabelColor,
                text: foreground,
                separator: ink.withAlphaComponent(isDark ? 0.14 : 0.1)
            )
            ruler?.colors = LineNumberRuler.Colors(
                background: background ?? .textBackgroundColor,
                number: theme.lineNumber?.nsColor ?? .tertiaryLabelColor,
                currentNumber: theme.activeLineNumber?.nsColor ?? .secondaryLabelColor,
                added: theme.added?.nsColor ?? .systemGreen,
                modified: theme.modified?.nsColor ?? .systemBlue,
                deleted: theme.deleted?.nsColor ?? .systemRed
            )
            let diagnostics = diagnosticsController.colors
            overview?.colors = OverviewRuler.Colors(
                added: (theme.added?.nsColor ?? .systemGreen).withAlphaComponent(0.7),
                modified: (theme.modified?.nsColor ?? .systemBlue).withAlphaComponent(0.7),
                deleted: (theme.deleted?.nsColor ?? .systemRed).withAlphaComponent(0.7),
                error: diagnostics.error,
                warning: diagnostics.warning,
                info: diagnostics.info,
                highlight: ink.withAlphaComponent(isDark ? 0.45 : 0.35),
                caret: ink.withAlphaComponent(isDark ? 0.5 : 0.4)
            )
        }

        func textView(_ textView: STTextView, willChangeTextIn affectedCharRange: NSTextRange, replacementString: String) {
            let range = NSRange(affectedCharRange, in: textView.textContentManager)
            pendingEdit = (range.location, range.length, replacementString)
        }

        /// A pinned line was clicked: the caret goes there, the line to the top.
        func applyIndentation(_ indentation: Indentation, to textView: STTextView) {
            (textView as? OrbitTextView)?.indentation = indentation
            // Restamps the whole text's paragraph style: the diff gaps go with it.
            if IndentEditing.apply(indentation, to: textView) { inlineDiff.invalidate() }
        }

        func updateOverview() {
            guard let overview, let textView else { return }
            let starts = diagnosticsController.lineStarts
            overview.lineCount = starts.count
            overview.diagnostics = diagnosticsController.diagnostics
            overview.caretLine = SourcePosition(offset: min(textView.textSelection.location, diagnosticsController.length), in: starts).line
        }

        func revealPinned(line: Int) {
            guard let textView else { return }
            let starts = diagnosticsController.lineStarts
            guard line < starts.count else { return }
            textView.textSelection = NSRange(location: starts[line], length: 0)
            scroll(toTopLine: line)
            textView.window?.makeFirstResponder(textView)
        }

        func foldsWereRestored() {
            guard let restored = restoredTopLine, Date().timeIntervalSince(restored.at) < 5 else { return }
            DispatchQueue.main.async { [weak self] in self?.scroll(toTopLine: restored.line) }
        }

        func textViewDidChangeText(_ notification: Notification) {
            restoredTopLine = nil
            scheduleGitMarkers()
            diagnosticsController.textDidChange()
            updateOverview()
            symbolHighlights.textDidChange()
            definitionLink.clear()
            closeHover()
            let edit = pendingEdit
            pendingEdit = nil
            if let edit, !isApplyingExternalChange {
                let change = TextEdit(range: NSRange(location: edit.location, length: edit.length), newLength: edit.replacement.utf16.count)
                inlayHints.textDidChange(change)
                folding.textDidChange(change)
            }
            guard !isApplyingExternalChange, let textView else {
                closePopups()
                return
            }
            document.text = textView.text ?? ""
            syncedRevision = document.revision
            // Completion inserts at one caret: with several it would leave the others behind.
            if textView.hasMultipleSelections {
                closePopups()
            } else if let edit {
                completion.textDidChange(location: edit.location, oldLength: edit.length, replacement: edit.replacement)
            }
        }

        /// Highlights with the file's grammar, switching when a better one got installed.
        func updateGrammar(revision: Int, in textView: STTextView) {
            guard grammarRevision != revision else { return }
            grammarRevision = revision
            let grammar = Grammar.matching(document.url, firstLine: StaticHighlighter.firstLine(of: document.text))
            guard grammar?.key != highlighter?.key else { return }
            if let highlighter { textView.removePlugin(highlighter.id) }
            highlighter = grammar.map { (textView.addPlugin(SyntaxHighlightPlugin(palette: palette, grammar: $0)), $0.key) }
        }

        func toggleComment() {
            guard let textView = textView as? OrbitTextView, let language = textView.syntaxLanguage else { return }
            EditingRules.toggleComment(in: textView, language: language)
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
                overview?.changes = LineMarkers()
                return
            }
            markersTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let current = self?.textView?.text else { return }
                let markers = await Task.detached(priority: .utility) { LineMarkers(baseline: baseline, current: current) }.value
                guard !Task.isCancelled else { return }
                self?.ruler?.changeMarkers = markers
                self?.overview?.changes = markers
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            completion.selectionDidChange()
            closeHover()
            if let textView { symbolHighlights.caretMoved(to: textView.textSelection) }
            bracketMatch.caretMoved()
            folding.revealCaret()
            ActiveEditor.shared.coordinator = self
            ruler?.needsDisplay = true
            updateOverview()
            EditorSelectionService.shared.cursorMoved(in: self)
            // Text pushed in from outside moves the caret with it: not a jump.
            if reportsCaret, !isApplyingExternalChange, let textView {
                let position = SourcePosition(
                    offset: min(textView.textSelection.location, diagnosticsController.length), in: diagnosticsController.lineStarts
                )
                onCaretMove(position.line, position.character)
            }
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

        /// 0-based lines the selection touches (a selection ending at a line's start leaves that line out).
        var selectedLines: ClosedRange<Int> {
            guard let textView else { return 0...0 }
            let text = (textView.text ?? "") as NSString
            let starts = InlineDiffController.lineStarts(of: text)
            let range = textView.textSelection
            func line(_ offset: Int) -> Int { max(0, (starts.lastIndex { $0 <= min(offset, text.length) } ?? 0)) }
            let first = line(range.location)
            var last = line(range.location + range.length)
            if range.length > 0, last > first, starts[last] == range.location + range.length { last -= 1 }
            return first...last
        }

        func reveal(line: Int, column: Int? = nil) {
            guard let textView else { return }
            let text = (textView.text ?? "") as NSString
            let starts = InlineDiffController.lineStarts(of: text)
            let offset = column.map { SourcePosition(line: line, character: $0).offset(in: starts, length: text.length) }
                ?? starts[min(max(0, line), starts.count - 1)]
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
                    self?.definitionLink.clear()
                    self?.completion.signatures.close()
                    self?.completion.reposition()
                    self?.stickyScroll.setNeedsUpdate()
                }
            }
        }

        /// The pointer rested: after a pause, the problems and symbol info under it.
        func mouseMoved(to point: NSPoint) {
            definitionLink.pointer = point
            definitionLink.update()
            if hoverPanel?.isVisible == true, let hoverRect {
                if hoverRect.insetBy(dx: -6, dy: -6).contains(point) || isOnTheWayToPopover(point, from: hoverRect) { return }
                closeHover()
            }
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                await self?.showHover(at: point)
            }
        }

        /// Leaving for the card keeps it, so its text can be selected.
        func mouseExited() {
            definitionLink.pointer = nil
            definitionLink.clear()
            hoverTask?.cancel()
            guard hoverPanel?.isVisible == true else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, let panel = hoverPanel, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { closeHover() }
            }
        }

        /// Between the word and its card (the gap above the line), so the card's buttons stay reachable.
        private func isOnTheWayToPopover(_ point: NSPoint, from rect: CGRect) -> Bool {
            guard let textView, let window = textView.window,
                  let card = hoverPanel?.isVisible == true ? hoverPanel?.frame : nil else { return false }
            let inView = textView.convert(window.convertFromScreen(card), from: nil)
            return rect.union(inView).insetBy(dx: -6, dy: -6).contains(point)
        }

        func closeHover() {
            hoverTask?.cancel()
            hoverPanel?.hide()
            hoverRect = nil
        }

        private func showHover(at point: NSPoint) async {
            guard let textView, let offset = characterOffset(at: point) else { return }
            let controller = diagnosticsController
            let problems = controller.diagnostics(at: offset)
            let position = SourcePosition(offset: offset, in: controller.lineStarts)
            let info = await languages?.hover(at: position, in: document.url)
            guard !Task.isCancelled, !problems.isEmpty || info != nil else { return }
            // Fixes for the problem under the pointer, offered right in the card.
            var actions: [CodeAction] = []
            if let problem = problems.first, let languages {
                actions = await languages.codeActions(for: problem.range, in: document.url)
                guard !Task.isCancelled else { return }
            }
            actions = actions.filter { $0.disabledReason == nil }
            let fixes = actions.filter { $0.isPreferred || $0.kind?.hasPrefix("quickfix") == true }

            let starts = controller.lineStarts, length = controller.length
            let anchor = info?.range.map { $0.nsRange(in: starts, length: length) }
                ?? problems.first.map { $0.range.nsRange(in: starts, length: length) }
                ?? NSRange(location: offset, length: 1)
            let rects = controller.rects(for: anchor.length > 0 ? anchor : NSRange(location: offset, length: 1))
            guard let first = rects.first else { return }
            let rect = rects.dropFirst().reduce(first) { $0.union($1) }

            let fixStart = problems.first.map { $0.range.nsRange(in: starts, length: length).location } ?? offset
            let card = HoverCard(
                diagnostics: problems, markdown: info?.markdown, colors: controller.colors,
                fixes: Array(fixes.prefix(3)),
                hasMoreActions: actions.count > min(fixes.count, 3),
                showsSymbolKeys: info != nil,
                onFix: { [weak self] action in
                    self?.closeHover()
                    self?.runCodeAction(action)
                },
                onMoreActions: { [weak self] in
                    guard let self else { return }
                    self.closeHover()
                    self.presentCodeActions(actions, at: self.screenRect(at: fixStart))
                },
                highlight: { [url = document.url] code, language in
                    await StaticHighlighter().highlight(code, language: language, fallback: url)
                }
            )
            guard let window = textView.window, let scrollView = textView.enclosingScrollView else { return }
            let onScreen = window.convertToScreen(textView.convert(rect, to: nil))
            let visible = window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil))
            closeHover()
            let panel = hoverPanel ?? HoverPanel()
            hoverPanel = panel
            panel.onExit = { [weak self] in
                guard let self, let textView = self.textView, let window = textView.window, let hoverRect = self.hoverRect else { return }
                // Back over the word keeps it; anywhere else closes it.
                let point = textView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                if !hoverRect.insetBy(dx: -6, dy: -6).contains(point) { self.closeHover() }
            }
            panel.show(card, at: onScreen, within: visible, in: window)
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

/// Puts the text beside the line-number ruler instead of under it. AppKit
/// lays a ruler over a full-width clip view with a left inset; STTextView
/// sizes itself to the clip view minus only the right inset, so it came out
/// a ruler wider than what's visible and always scrolled sideways.
final class EditorScrollView: NSScrollView {
    weak var overview: OverviewRuler?

    override func tile() {
        super.tile()
        if let overview {
            let content = contentView.frame
            overview.frame = NSRect(x: bounds.maxX - OverviewRuler.width, y: content.minY, width: OverviewRuler.width, height: content.height)
        }
        guard rulersVisible, let ruler = verticalRulerView, contentView.contentInsets.left > 0 else { return }
        contentView.contentInsets.left = 0
        var frame = contentView.frame
        frame.origin.x += ruler.ruleThickness
        frame.size.width -= ruler.ruleThickness
        contentView.frame = frame
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
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    /// The file's language: comments and bracket pairs (D73).
    var syntaxLanguage: SyntaxLanguage?
    var indentation = Indentation(size: 4, spaces: true)
    private var hoverArea: NSTrackingArea?

    /// Typing (no replacement range; marked text from an input method passes through).
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if replacementRange.location == NSNotFound, !hasMarkedText(), !hasMultipleSelections, let language = syntaxLanguage,
           let typed = (string as? String) ?? (string as? NSAttributedString)?.string, typed.count == 1,
           EditingRules.type(typed, in: self, language: language) {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // The indentation and bracket rules know one caret; with several, plain edits at each.
    override func insertTab(_ sender: Any?) {
        guard !hasMultipleSelections else {
            return insertText(indentation.spaces ? String(repeating: " ", count: indentation.size) : "\t", replacementRange: .notFound)
        }
        IndentEditing.insertTab(in: self, indentation: indentation)
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMultipleSelections else { return }
        IndentEditing.insertBacktab(in: self, indentation: indentation)
    }

    override func insertNewline(_ sender: Any?) {
        guard !hasMultipleSelections else { return super.insertNewline(sender) }
        IndentEditing.insertNewline(in: self, indentation: indentation)
    }

    override func deleteBackward(_ sender: Any?) {
        guard !hasMultipleSelections else { return super.deleteBackward(sender) }
        if IndentEditing.deleteBackward(in: self, indentation: indentation) { return }
        if let language = syntaxLanguage, EditingRules.deleteBackward(in: self, language: language) { return }
        super.deleteBackward(sender)
    }

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
        // ⌥-click as in VS Code and Cursor, ⌃⇧-click as in Xcode: add a caret, or remove one.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.clickCount == 1, modifiers == .option || modifiers == [.control, .shift], toggleCaret(at: event) { return }
        super.mouseDown(with: event)
    }

    private func toggleCaret(at event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let content = contentFrame
        let local = CGPoint(x: point.x - content.minX, y: point.y - content.minY)
        let manager = textLayoutManager
        guard let location = manager.textSelectionNavigation.textSelections(
            interactingAt: local, inContainerAt: manager.documentRange.location, anchors: [], modifiers: [],
            selecting: false, bounds: manager.usageBoundsForTextContainer
        ).first?.textRanges.first?.location else { return false }
        let offset = textContentManager.offset(from: manager.documentRange.location, to: location)
        var ranges = selectionRanges
        if let index = ranges.firstIndex(where: { $0.location <= offset && offset <= NSMaxRange($0) }) {
            guard ranges.count > 1 else { return true }
            ranges.remove(at: index)
        } else {
            ranges.append(NSRange(location: offset, length: 0))
        }
        window?.makeFirstResponder(self)
        selectionRanges = ranges
        return true
    }

    override func doCommand(by selector: Selector) {
        if onCommand?(selector) == true { return }
        super.doCommand(by: selector)
    }

    /// ⌥Esc and ⌃Space land here: our list, not STTextView's.
    override func complete(_ sender: Any?) {
        if onCommand?(#selector(NSResponder.complete(_:))) == true { return }
        super.complete(sender)
    }

    /// Esc only closes things (handled before this); STTextView would open
    /// completion here, as Xcode does, which surprised (D66 addendum).
    override func cancelOperation(_ sender: Any?) {
        if hasMultipleSelections, let primary = selectionRanges.last { selectionRanges = [primary] }
    }

    /// ⌃Space isn't a key binding AppKit knows. macOS takes it for switching
    /// input sources when there are several; Esc works then.
    /// ⌃⇧I by key position: menus match ⌃ shortcuts (without ⌘) by the
    /// character, so in a Russian layout the menu item never sees "i".
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .control, event.keyCode == 49 {
            complete(nil)
            return
        }
        if modifiers == [.control, .shift], event.keyCode == 34, KeyBindings.shared.binding(for: "editor.format") == nil {
            ActiveEditor.shared.coordinator?.formatDocument()
            return
        }
        if let commands = ActiveEditor.shared.commands,
           let command = commands.all.first(where: { $0.editorShortcut.map { EditorKeys.matches(event, $0) } == true }) {
            commands.run(command.id)
            return
        }
        super.keyDown(with: event)
    }

    /// Commands placed in the editor menu, with their shortcuts shown, above
    /// STTextView's Cut, Copy, Paste: where features are found, and their keys learned.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let commands = ActiveEditor.shared.commands else { return menu }
        var index = 0
        var lastGroup: EditorMenuPlacement.Group?
        for command in commands.editorMenuCommands() {
            guard let placement = command.editorMenu else { continue }
            if let lastGroup, lastGroup != placement.group {
                menu.insertItem(.separator(), at: index)
                index += 1
            }
            lastGroup = placement.group
            let item = NSMenuItem(title: placement.title ?? command.title, action: #selector(EditorMenuTarget.run(_:)), keyEquivalent: "")
            item.target = EditorMenuTarget.shared
            item.representedObject = command.id
            item.isEnabled = command.isEnabled()
            if let symbol = command.systemImage { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            if let shortcut = command.displayShortcut { EditorMenuTarget.setKeyEquivalent(of: item, to: shortcut) }
            menu.insertItem(item, at: index)
            index += 1
        }
        if index > 0, menu.items.count > index { menu.insertItem(.separator(), at: index) }
        return menu
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        onModifiersChanged?(event.modifierFlags)
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

/// The editor that last had focus, for keyboard commands: the main window's
/// own (D101), so a command never reaches another window's editor.
@MainActor
final class ActiveEditor {
    static let shared = ActiveEditor()

    private final class Entry {
        weak var coordinator: CodeEditor.Coordinator?
        init(_ coordinator: CodeEditor.Coordinator) { self.coordinator = coordinator }
    }

    /// Most recent first; a new editor isn't in a window yet, so the window is checked when asked.
    private var recent: [Entry] = []

    var coordinator: CodeEditor.Coordinator? {
        get {
            let live = recent.compactMap(\.coordinator)
            guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return live.first }
            return live.first { $0.textView?.window === window }
        }
        set {
            recent.removeAll { $0.coordinator == nil || $0.coordinator === newValue }
            if let newValue { recent.insert(Entry(newValue), at: 0) }
        }
    }

    func remove(_ coordinator: CodeEditor.Coordinator) {
        recent.removeAll { $0.coordinator == nil || $0.coordinator === coordinator }
    }

    /// For the right-click menu, which lists commands placed there (`EditorMenuPlacement`).
    var commands: CommandRegistry? { coordinator?.commands }
}

/// Runs a right-click menu item; a menu item needs an Objective-C target.
@MainActor
final class EditorMenuTarget: NSObject {
    static let shared = EditorMenuTarget()

    @objc func run(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        // After the menu closes: some commands open popovers or move focus.
        DispatchQueue.main.async { ActiveEditor.shared.commands?.run(id, teaching: true) }
    }

    /// Only drawn in the menu: the key itself still goes through the main menu.
    static func setKeyEquivalent(of item: NSMenuItem, to shortcut: KeyboardShortcut) {
        let key: String = switch shortcut.key {
        case .return: "\r"
        case .delete: "\u{8}"
        case .escape: "\u{1b}"
        case .tab: "\t"
        case .upArrow: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .downArrow: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case .leftArrow: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .rightArrow: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        default: String(shortcut.key.character)
        }
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { mask.insert(.command) }
        if shortcut.modifiers.contains(.control) { mask.insert(.control) }
        if shortcut.modifiers.contains(.option) { mask.insert(.option) }
        if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }
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

    var caret: SourceLocation? {
        guard let coordinator = ActiveEditor.shared.coordinator, let textView = coordinator.textView else { return nil }
        let controller = coordinator.diagnosticsController
        let position = SourcePosition(offset: min(textView.textSelection.location, controller.length), in: controller.lineStarts)
        return SourceLocation(url: coordinator.document.url, range: SourceRange(start: position, end: position))
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
