import AppKit
import SwiftUI
import OrbitAPI
import OrbitUI
import STTextView
import SwiftTreeSitter
import Synchronization

/// Tree-sitter highlighting for STTextView. Parsing and queries run on a
/// background queue (`HighlightWorker`), embedded languages included (D69);
/// the main thread keeps a highlight cache for the whole document and paints
/// the visible part from it (D48).
struct SyntaxHighlightPlugin: STPlugin {
    let palette: SyntaxPalette
    let grammar: Grammar

    func setUp(context: any Context) {
        context.events.onWillChangeText { affectedRange, _ in
            context.coordinator?.willChangeText(in: NSRange(affectedRange, in: context.textView.textContentManager))
        }

        context.events.onDidChangeText { _, replacementString in
            context.coordinator?.didChangeText(replacementLength: replacementString?.utf16.count ?? 0)
        }

        context.events.onDidLayoutViewport { _ in
            context.coordinator?.viewportDidChange()
        }
    }

    func makeCoordinator(context: CoordinatorContext) -> SyntaxHighlightCoordinator? {
        SyntaxHighlightCoordinator(textView: context.textView, palette: palette, grammar: grammar)
    }
}

/// The color theme an editor highlights with. The editor swaps `theme` on a
/// theme or light/dark switch and the highlighter restyles what's on screen.
@MainActor
final class SyntaxPalette {
    var theme: ColorTheme {
        didSet {
            guard theme != oldValue else { return }
            styles.removeAll()
            onThemeChange?(theme)
            onChange?()
        }
    }

    /// Also called after a font size change: styled tokens carry their own fonts.
    var onChange: (() -> Void)?
    /// Code a server marked unnecessary (an unused import or variable), drawn
    /// with its colors faded (D78). Set by the editor from its problems.
    var faded = IndexSet() {
        didSet { if faded != oldValue { onFadedChange?(faded.symmetricDifference(oldValue)) } }
    }
    var onFadedChange: ((IndexSet) -> Void)?
    /// How much of a color faded code keeps (VS Code's unnecessary-code opacity).
    static let fadedAlpha: CGFloat = 0.55
    var onThemeChange: ((ColorTheme) -> Void)?
    /// Names the language server classified, colored over tree-sitter's (D201),
    /// in text order. Set by the editor; the highlighter moves them with edits.
    var semantic: [SemanticSpan] = [] {
        didSet {
            guard semantic != oldValue else { return }
            var changed = IndexSet()
            for span in oldValue + semantic { changed.insert(integersIn: Range(span.range) ?? 0..<0) }
            onSemanticChange?(changed)
        }
    }
    var onSemanticChange: ((IndexSet) -> Void)?
    /// Colored runs of a range from the highlighter's cache, for text drawn
    /// outside the text view (sticky headers): nil without a highlighter.
    var colors: ((NSRange) -> [(range: NSRange, color: NSColor, font: NSFont?)])?
    /// Offsets in a range that are inside strings or comments, from the
    /// highlighter's cache: bracket matching skips them (D202).
    var literals: ((NSRange) -> IndexSet)?
    private var styles: [String: SyntaxStyle?] = [:]
    private var fonts: [String: NSFont] = [:]

    init(theme: ColorTheme) {
        self.theme = theme
    }

    /// A semantic span's color: the first of its captures the theme styles.
    func semanticColor(_ captures: [String]) -> NSColor? {
        for capture in captures {
            if let color = style(forCapture: capture)?.color { return color.nsColor }
        }
        return nil
    }

    /// Spans keep their text through an edit; the ones it touched go until the server answers again.
    func moveSemantic(by edit: TextEdit) {
        guard !semantic.isEmpty else { return }
        let end = NSMaxRange(edit.range)
        // Not through `didSet`: the highlighter repaints the edit itself.
        let moved = semantic.compactMap { span -> SemanticSpan? in
            if NSMaxRange(span.range) <= edit.range.location { return span }
            guard span.range.location >= end else { return nil }
            var span = span
            span.range.location += edit.delta
            return span
        }
        let handler = onSemanticChange
        onSemanticChange = nil
        semantic = moved
        onSemanticChange = handler
    }

    func style(forCapture capture: String) -> SyntaxStyle? {
        if let cached = styles[capture] { return cached }
        let style = theme.style(forCapture: capture)
        styles[capture] = style
        return style
    }

    /// `base` itself unless the style asks for another weight or italics, so most
    /// tokens need no font edit.
    func font(for style: SyntaxStyle, base: NSFont) -> NSFont {
        let weight = style.weight.map(Self.weight) ?? .regular
        guard weight != .regular || style.isItalic else { return base }
        let key = "\(base.fontName)|\(base.pointSize)|\(weight.rawValue)|\(style.isItalic)|\(base.fontDescriptor.object(forKey: .featureSettings) != nil)"
        if let font = fonts[key] { return font }
        // SF Mono (a hidden "." font) has every weight; a picked family (D180) gets its nearest.
        var font = base.fontName.hasPrefix(".")
            ? NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: weight)
            : NSFontManager.shared.font(withFamily: base.familyName ?? "", traits: [], weight: Self.managerWeight(weight), size: base.pointSize).map { font in
                // Keep the base's features (ligatures off, D188).
                guard let features = base.fontDescriptor.object(forKey: .featureSettings) else { return font }
                return NSFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: features]), size: base.pointSize) ?? font
            } ?? base
        if style.isItalic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: base.pointSize) ?? font
        }
        fonts[key] = font
        return font
    }

    /// NSFontManager's 0–15 scale: 5 is regular, 9 bold.
    private static func managerWeight(_ weight: NSFont.Weight) -> Int {
        switch weight {
        case ..<NSFont.Weight.light: 2
        case ..<NSFont.Weight.regular: 3
        case ..<NSFont.Weight.medium: 5
        case ..<NSFont.Weight.semibold: 6
        case ..<NSFont.Weight.bold: 8
        default: 9
        }
    }

    private static func weight(_ css: Int) -> NSFont.Weight {
        switch css {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }
}

@MainActor
final class SyntaxHighlightCoordinator {
    private weak var textView: STTextView?
    private let palette: SyntaxPalette
    private let worker: HighlightWorker
    private var cache = HighlightCache()
    /// Text whose on-screen colors already match the cache.
    private var painted = IndexSet()
    /// Text whose fonts already match the cache; unlike colors, fonts are also
    /// filled in off screen while the editor is idle (see `scheduleIdleFonts`).
    private var fontsDone = IndexSet()
    private var idleFonts: Task<Void, Never>?
    private var pendingEditRange: NSRange?
    /// The text as of the last edit, to shrink whole-document replacements.
    private var snapshot = TextSnapshot(string: "")
    /// Indexed by `CaptureTable` id; 0 is "no capture".
    private var styles: [(color: NSColor, font: NSFont?)?] = []
    /// An embedded language's grammar got installed: its layers get parsed.
    private var grammarObserver: (any NSObjectProtocol)?

    /// Longer texts aren't highlighted.
    private static let maxLength = 8_000_000
    /// How long a keystroke may wait for its own highlights, as in Zed: small
    /// and medium files parse within it; in bigger ones the typed token gets
    /// its color a frame later while the shifted old colors stay.
    private static let editWait = DispatchTimeInterval.milliseconds(1)
    /// How long opening a file may wait for the first screen to be colored.
    private static let openWait = DispatchTimeInterval.milliseconds(40)

    /// Lets the worker's callback reach the coordinator, which doesn't exist yet when the worker is made.
    private final class Link: @unchecked Sendable {
        weak var coordinator: SyntaxHighlightCoordinator?
    }

    /// Embedded languages this file found missing; their install reloads its layers.
    private var awaitedGrammars: Set<String> = []

    init?(textView: STTextView, palette: SyntaxPalette, grammar: Grammar) {
        guard textView.textContentManager.length <= Self.maxLength else { return nil }
        let link = Link()
        guard let worker = HighlightWorker(grammar: grammar, theme: palette.theme, notify: {
            DispatchQueue.main.async { MainActor.assumeIsolated { link.coordinator?.drain() } }
        }) else { return nil }
        self.textView = textView
        self.palette = palette
        self.worker = worker
        link.coordinator = self

        palette.onThemeChange = { [weak self] theme in self?.worker.setTheme(theme) }
        grammarObserver = NotificationCenter.default.addObserver(forName: GrammarStore.didChange, object: nil, queue: .main) { [weak self] note in
            // Background installs (a folder's languages) don't concern files that didn't ask for them.
            let name = note.object as? String
            MainActor.assumeIsolated {
                guard let self, let name, self.awaitedGrammars.remove(name) != nil else { return }
                self.worker.reloadLayers()
            }
        }
        palette.onChange = { [weak self] in self?.restyle() }
        palette.colors = { [weak self] range in
            guard let self else { return [] }
            var runs: [(range: NSRange, color: NSColor, font: NSFont?)] = []
            cache.spans.forEach(in: range) { span in
                guard let style = self.style(span.capture) else { return }
                let clipped = NSIntersectionRange(NSRange(location: span.start, length: span.end - span.start), range)
                if clipped.length > 0 { runs.append((clipped, style.color, style.font)) }
            }
            return runs
        }
        palette.literals = { [weak self] range in
            guard let self else { return IndexSet() }
            var set = IndexSet()
            cache.spans.forEach(in: range) { span in
                guard self.isLiteral(span.capture) else { return }
                set.insert(integersIn: max(span.start, range.location)..<min(span.end, NSMaxRange(range)))
            }
            return set
        }
        palette.onFadedChange = { [weak self] changed in
            guard let self else { return }
            painted.subtract(changed)
            paintVisible()
        }
        palette.onSemanticChange = { [weak self] changed in
            guard let self else { return }
            painted.subtract(changed)
            paintVisible()
        }

        snapshot = currentSnapshot()
        let waiter = DispatchSemaphore(value: 0)
        worker.setFocus(NSRange(location: 0, length: 16 * 1024))
        worker.reset(snapshot, version: cache.version, waiter: waiter)
        _ = waiter.wait(timeout: .now() + Self.openWait)
        drain()
    }

    isolated deinit {
        worker.cancel()
        if let grammarObserver { NotificationCenter.default.removeObserver(grammarObserver) }
        idleFonts?.cancel()
    }

    private var storage: NSTextStorage? {
        (textView?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    private func currentSnapshot() -> TextSnapshot {
        TextSnapshot(string: (storage?.string ?? "") as NSString)
    }

    // MARK: Edits

    func willChangeText(in range: NSRange) {
        pendingEditRange = range
    }

    func didChangeText(replacementLength: Int) {
        guard let range = pendingEditRange else { return }
        pendingEditRange = nil
        let new = currentSnapshot()
        var edit = TextEdit(range: range, newLength: replacementLength)
        // Agent edits and reloads replace the whole text: keep the unchanged
        // head and tail so their highlights survive.
        if range.length > 4096 || replacementLength > 4096 { edit = edit.trimmed(old: snapshot.string, new: new.string) }
        snapshot = new

        let version = cache.apply(edit)
        palette.moveSemantic(by: edit)
        let lines = Range(new.string.lineRange(for: NSRange(location: edit.range.location, length: edit.newLength))) ?? 0..<0
        painted = edit.map(painted)
        painted.remove(integersIn: lines)
        fontsDone = edit.map(fontsDone)
        fontsDone.remove(integersIn: lines)

        let waiter = DispatchSemaphore(value: 0)
        worker.edit(edit, snapshot: new, version: version, waiter: waiter)
        _ = waiter.wait(timeout: .now() + Self.editWait)
        drain()
        paintVisible()
    }

    private func drain() {
        for name in worker.takeMissingGrammars() {
            awaitedGrammars.insert(name)
            GrammarRegistry.shared.ensureInstalled(named: name)
        }
        let patches = worker.takePatches()
        guard !patches.isEmpty else { return }
        let touched = cache.apply(patches)
        painted.subtract(touched)
        fontsDone.subtract(touched)
        paintVisible()
        scheduleIdleFonts()
    }

    // MARK: Painting

    func viewportDidChange() {
        guard let visible = visibleRange else { return }
        worker.setFocus(Self.expanded(visible))
        paintVisible()
    }

    private var visibleRange: NSRange? {
        guard let textView, let viewport = textView.textLayoutManager.textViewportLayoutController.viewportRange else { return nil }
        return NSRange(viewport, in: textView.textContentManager)
    }

    /// The visible text plus a screen above and below, so scrolling finds it painted.
    private static func expanded(_ visible: NSRange) -> NSRange {
        let margin = max(visible.length, 4096)
        let lower = max(0, visible.location - margin)
        return NSRange(location: lower, length: NSMaxRange(visible) + margin - lower)
    }

    /// Colors are TextKit 2 rendering attributes: no relayout, only a redraw.
    private func paintVisible() {
        guard let textView, let visible = visibleRange else { return }
        let manager = textView.textContentManager
        let target = NSIntersectionRange(Self.expanded(visible), NSRange(location: 0, length: manager.length))
        let targetSet = IndexSet(integersIn: Range(target) ?? 0..<0)
        let fontTodo = targetSet.subtracting(fontsDone)
        applyFonts(in: fontTodo)
        fontsDone.formUnion(fontTodo)
        let todo = targetSet.subtracting(painted)
        guard !todo.isEmpty else { return }

        let layoutManager = textView.textLayoutManager
        for run in todo.rangeView {
            let range = NSRange(run)
            guard let textRange = NSTextRange(range, in: manager) else { continue }
            layoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
            cache.spans.forEach(in: range) { span in
                guard let style = self.style(span.capture) else { return }
                let clipped = NSIntersectionRange(NSRange(location: span.start, length: span.end - span.start), range)
                guard clipped.length > 0, let spanRange = NSTextRange(clipped, in: manager) else { return }
                layoutManager.addRenderingAttribute(.foregroundColor, value: style.color, for: spanRange)
            }
            paintSemantic(in: range)
            paintFaded(in: range)
        }
        painted.formUnion(todo)
        redraw(todo)
    }

    /// Whether a capture id is a string or a comment, by its name.
    private var literalCaptures: [Bool] = []

    private func isLiteral(_ id: UInt16) -> Bool {
        let index = Int(id)
        if index >= literalCaptures.count {
            literalCaptures += CaptureTable.names(from: literalCaptures.count).map { $0.hasPrefix("string") || $0.hasPrefix("comment") }
        }
        return index < literalCaptures.count && literalCaptures[index]
    }

    /// Semantic colors by their captures, resolved once per theme.
    private var semanticColors: [[String]: NSColor?] = [:]

    private func paintSemantic(in range: NSRange) {
        let spans = palette.semantic
        guard let textView, !spans.isEmpty else { return }
        let manager = textView.textContentManager
        let layoutManager = textView.textLayoutManager
        // The first span ending after the range starts.
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(spans[middle].range) <= range.location { low = middle + 1 } else { high = middle }
        }
        var index = low
        while index < spans.count, spans[index].range.location < NSMaxRange(range) {
            let span = spans[index]
            index += 1
            let color: NSColor?
            if let cached = semanticColors[span.captures] {
                color = cached
            } else {
                color = palette.semanticColor(span.captures)
                semanticColors[span.captures] = color
            }
            let clipped = NSIntersectionRange(span.range, range)
            guard let color, clipped.length > 0, let textRange = NSTextRange(clipped, in: manager) else { continue }
            layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
        }
    }

    /// Faded code keeps its colors at lower opacity; plain text in it fades from the text color.
    private func paintFaded(in range: NSRange) {
        guard let textView, let run = Range(range) else { return }
        let faded = palette.faded.intersection(IndexSet(integersIn: run))
        guard !faded.isEmpty else { return }
        let manager = textView.textContentManager
        let layoutManager = textView.textLayoutManager
        let alpha = SyntaxPalette.fadedAlpha
        let plain = (palette.theme.editorForeground?.nsColor ?? textView.textColor).withAlphaComponent(alpha)
        for part in faded.rangeView {
            let partRange = NSRange(part)
            guard let textRange = NSTextRange(partRange, in: manager) else { continue }
            layoutManager.addRenderingAttribute(.foregroundColor, value: plain, for: textRange)
            cache.spans.forEach(in: partRange) { span in
                guard let style = self.style(span.capture) else { return }
                let clipped = NSIntersectionRange(NSRange(location: span.start, length: span.end - span.start), partRange)
                guard clipped.length > 0, let spanRange = NSTextRange(clipped, in: manager) else { return }
                layoutManager.addRenderingAttribute(.foregroundColor, value: style.color.withAlphaComponent(alpha), for: spanRange)
            }
        }
    }

    /// STTextView redraws a line only when its layout changes, so new colors for
    /// lines already drawn (the first parse landing after the first frame) stay
    /// invisible until a scroll or a keystroke. Mark those lines dirty.
    private func redraw(_ set: IndexSet) {
        guard let textView, let first = set.first, let last = set.last else { return }
        let manager = textView.textContentManager
        guard let start = NSTextRange(NSRange(location: first, length: 0), in: manager)?.location else { return }
        var dirty = NSRect.null
        textView.textLayoutManager.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            guard NSRange(fragment.rangeInElement, in: manager).location <= last else { return false }
            dirty = dirty.union(fragment.layoutFragmentFrame)
            return true
        }
        guard !dirty.isNull else { return }
        // Line views live a couple of levels down, in internal STTextView containers.
        func mark(_ view: NSView, depth: Int) {
            for subview in view.subviews where subview.convert(subview.bounds, to: textView).intersects(dirty) {
                subview.needsDisplay = true
                if depth < 3 { mark(subview, depth: depth + 1) }
            }
        }
        mark(textView, depth: 0)
    }

    /// Fonts for the rest of the document, a chunk per pass once typing pauses,
    /// so a jump elsewhere finds them set and doesn't relayout twice.
    private func scheduleIdleFonts() {
        idleFonts?.cancel()
        idleFonts = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled, let self, let length = self.storage?.length {
                var missing = IndexSet(integersIn: 0..<length)
                missing.subtract(self.fontsDone)
                guard let run = missing.rangeView.first else { return }
                let chunk = IndexSet(integersIn: run.lowerBound..<min(run.upperBound, run.lowerBound + 16 * 1024))
                self.applyFonts(in: chunk)
                self.fontsDone.formUnion(chunk)
                try? await Task.sleep(for: .milliseconds(4))
            }
        }
    }

    /// Weights and italics change glyph widths, so they're real text-storage
    /// attributes and a change relayouts. They're painted near the viewport like
    /// colors (a `"` that turns the rest of the file into a string must not
    /// restyle all of it), batched, and only where they differ.
    private func applyFonts(in set: IndexSet) {
        guard let textView, let storage, !set.isEmpty else { return }
        let base = textView.font
        let length = storage.length
        var current: [NSRange] = []
        var wanted: [(range: NSRange, font: NSFont)] = []
        var differs = false
        for run in set.rangeView {
            let range = NSIntersectionRange(NSRange(run), NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            let firstWanted = wanted.count
            cache.spans.forEach(in: range) { span in
                guard let font = self.style(span.capture)?.font else { return }
                let clipped = NSIntersectionRange(NSRange(location: span.start, length: span.end - span.start), range)
                guard clipped.length > 0 else { return }
                // Neighbors with the same font merge, as the storage's attribute runs do.
                if wanted.count > firstWanted, let last = wanted.last, last.font == font, NSMaxRange(last.range) == clipped.location {
                    wanted[wanted.count - 1].range.length += clipped.length
                } else {
                    wanted.append((clipped, font))
                }
            }
            var index = firstWanted
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                guard let font = value as? NSFont, font != base else { return }
                current.append(subrange)
                if index < wanted.count, wanted[index].range == subrange, wanted[index].font == font {
                    index += 1
                } else {
                    differs = true
                }
            }
            if index != wanted.count { differs = true }
        }
        guard differs else { return }
        textView.textContentManager.performEditingTransaction {
            // Without begin/end the storage processes every attribute change on its own.
            storage.beginEditing()
            for range in current { storage.addAttribute(.font, value: base, range: range) }
            for (range, font) in wanted { storage.addAttribute(.font, value: font, range: range) }
            storage.endEditing()
        }
    }

    /// Ids grow on the worker as embedded languages bring new capture names,
    /// so styles are resolved for them as they show up.
    private func style(_ id: UInt16) -> (color: NSColor, font: NSFont?)? {
        let index = Int(id)
        if index >= styles.count, let textView {
            let base = textView.font
            if styles.isEmpty { styles.append(nil) }
            styles += CaptureTable.names(from: styles.count).map { name in
                guard let style = palette.style(forCapture: name), let color = style.color else { return nil }
                let font = palette.font(for: style, base: base)
                return (color.nsColor, font === base ? nil : font)
            }
        }
        return index < styles.count ? styles[index] : nil
    }

    /// Theme, font size or text color changed: repaint everything from the cache.
    private func restyle() {
        styles.removeAll()
        semanticColors.removeAll()
        painted.removeAll()
        fontsDone.removeAll()
        paintVisible()
        scheduleIdleFonts()
    }
}

/// Compiled highlight and injection queries, shared by all editors. Compiling
/// one is slow (~230 ms for Swift), and doing it per editor delayed every file open.
enum HighlightQueries {
    private static let cache = Mutex<[String: LanguageQueries?]>([:])

    static func queries(for grammar: Grammar) -> LanguageQueries? {
        // Compiling under the lock lets a second editor of the same language
        // wait for the first one's compile instead of doing it twice.
        cache.withLock { cache in
            if let queries = cache[grammar.key] { return queries }
            let queries = compile(grammar)
            cache[grammar.key] = queries
            return queries
        }
    }

    private static func compile(_ grammar: Grammar) -> LanguageQueries? {
        guard let language = grammar.language, let source = grammar.highlightsQuery,
              let highlights = try? Query(language: language, data: Data(source.utf8)) else { return nil }
        return LanguageQueries(grammar: grammar, language: language, highlights: highlights, injections: injections(for: grammar, language: language))
    }

    private static func injections(for grammar: Grammar, language: SwiftTreeSitter.Language) -> Query? {
        grammar.injectionsQuery.flatMap { try? Query(language: language, data: Data($0.utf8)) }
    }
}

/// Highlights whole texts at once for read-only views: one tree-sitter parse
/// off the main actor, no text view involved.
@MainActor
final class StaticHighlighter: SyntaxHighlighting {
    /// Bigger texts aren't worth a parse just to color a diff.
    private static let maxLength = 1_000_000

    func highlight(_ text: String, as url: URL) async -> [SyntaxSpan] {
        guard text.utf16.count <= Self.maxLength else { return [] }
        let captures = await Task.detached(priority: .userInitiated) {
            Self.captures(in: text, grammar: Grammar.matching(url, firstLine: Self.firstLine(of: text)))
        }.value
        return Self.spans(captures)
    }

    /// A code fence's text (a hover's signature), by the language it names; unnamed, as `fallback`'s.
    func highlight(_ text: String, language: String, fallback: URL?) async -> [SyntaxSpan] {
        guard text.utf16.count <= Self.maxLength else { return [] }
        let captures = await Task.detached(priority: .userInitiated) {
            Self.captures(in: text, grammar: language.isEmpty ? fallback.flatMap { Grammar.matching($0) } : Grammar.named(language))
        }.value
        return Self.spans(captures)
    }

    func highlight(_ text: String, language: String) async -> [SyntaxSpan] {
        await highlight(text, language: language, fallback: nil)
    }

    private static func spans(_ captures: [(String, NSRange)]) -> [SyntaxSpan] {
        let light = Extensions.shared.colorTheme(dark: false)
        let dark = Extensions.shared.colorTheme(dark: true)
        var colors: [String: Color?] = [:]
        return captures.compactMap { name, range in
            guard range.length > 0 else { return nil }
            let color = colors[name] ?? {
                let lightColor = light.style(forCapture: name)?.color?.nsColor
                let darkColor = dark.style(forCapture: name)?.color?.nsColor
                guard lightColor != nil || darkColor != nil else { return nil }
                return Color(nsColor: .dynamic(light: lightColor ?? .textColor, dark: darkColor ?? .textColor))
            }()
            colors[name] = color
            return color.map { SyntaxSpan(range: range, color: $0) }
        }
    }

    /// Capture names and ranges, less specific first (later ones win).
    nonisolated private static func captures(in text: String, grammar: Grammar?) -> [(String, NSRange)] {
        guard let grammar, let queries = HighlightQueries.queries(for: grammar) else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(queries.language)) != nil,
              let tree = parser.parse(text) else { return [] }
        return queries.highlights.execute(in: tree).resolve(with: .init(string: text)).highlights().map { ($0.name, $0.range) }
    }

    nonisolated static func firstLine(of text: String) -> String {
        String(text.prefix(256).prefix { !$0.isNewline })
    }
}

/// A name the server classified, as the captures to color it with (D201).
struct SemanticSpan: Equatable {
    var range: NSRange
    var captures: [String]
}
