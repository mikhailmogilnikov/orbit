import AppKit
import SwiftUI
import OrbitAPI
import OrbitUI
import STTextView
import SwiftTreeSitter
import Synchronization
import TreeSitterResource

/// Tree-sitter highlighting for STTextView. Parsing and queries run on a
/// background queue (`HighlightWorker`); the main thread keeps a highlight
/// cache for the whole document and paints the visible part from it (D48).
struct SyntaxHighlightPlugin: STPlugin {
    let palette: SyntaxPalette
    let language: TreeSitterLanguage

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
        SyntaxHighlightCoordinator(textView: context.textView, palette: palette, language: language)
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
    var onThemeChange: ((ColorTheme) -> Void)?
    private var styles: [String: SyntaxStyle?] = [:]
    private var fonts: [String: NSFont] = [:]

    init(theme: ColorTheme) {
        self.theme = theme
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
        let key = "\(base.pointSize)|\(weight.rawValue)|\(style.isItalic)"
        if let font = fonts[key] { return font }
        var font = NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: weight)
        if style.isItalic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: base.pointSize) ?? font
        }
        fonts[key] = font
        return font
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
    /// Indexed by capture id; 0 is "no capture".
    private var styles: [(color: NSColor, font: NSFont?)?] = []

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

    init?(textView: STTextView, palette: SyntaxPalette, language: TreeSitterLanguage) {
        guard textView.textContentManager.length <= Self.maxLength else { return nil }
        let link = Link()
        guard let worker = HighlightWorker(language: language, theme: palette.theme, notify: {
            DispatchQueue.main.async { MainActor.assumeIsolated { link.coordinator?.drain() } }
        }) else { return nil }
        self.textView = textView
        self.palette = palette
        self.worker = worker
        link.coordinator = self
        resolveStyles()

        palette.onThemeChange = { [weak self] theme in self?.worker.setTheme(theme) }
        palette.onChange = { [weak self] in self?.restyle() }

        snapshot = currentSnapshot()
        let waiter = DispatchSemaphore(value: 0)
        worker.setFocus(NSRange(location: 0, length: 16 * 1024))
        worker.reset(snapshot, version: cache.version, waiter: waiter)
        _ = waiter.wait(timeout: .now() + Self.openWait)
        drain()
    }

    isolated deinit {
        worker.cancel()
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
                guard let style = styles[Int(span.capture)] else { return }
                let clipped = NSIntersectionRange(NSRange(location: span.start, length: span.end - span.start), range)
                guard clipped.length > 0, let spanRange = NSTextRange(clipped, in: manager) else { return }
                layoutManager.addRenderingAttribute(.foregroundColor, value: style.color, for: spanRange)
            }
        }
        painted.formUnion(todo)
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
                guard let font = styles[Int(span.capture)]?.font else { return }
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

    private func resolveStyles() {
        guard let textView else { return }
        let base = textView.font
        styles = [nil] + worker.captureNames.map { name in
            guard let style = palette.style(forCapture: name), let color = style.color else { return nil }
            let font = palette.font(for: style, base: base)
            return (color.nsColor, font === base ? nil : font)
        }
    }

    /// Theme, font size or text color changed: repaint everything from the cache.
    private func restyle() {
        resolveStyles()
        painted.removeAll()
        fontsDone.removeAll()
        paintVisible()
        scheduleIdleFonts()
    }
}

/// Compiled highlight queries, shared by all editors. Compiling one is slow
/// (~230 ms for Swift), and doing it per editor delayed every file open.
enum HighlightQueries {
    private static let cache = Mutex<[String: Query]>([:])

    static func query(for language: TreeSitterLanguage) -> Query? {
        let key = String(describing: language)
        // Compiling under the lock lets a file open wait for an in-flight prewarm
        // of the same language instead of compiling it twice.
        return cache.withLock { cache in
            if let query = cache[key] { return query }
            let parser = SwiftTreeSitter.Language(language: language.parser)
            // The combined query names JavaScript nodes; should a grammar version not
            // have one, TypeScript's own patterns still beat no colors at all.
            guard let query = querySources(for: language).lazy.compactMap({ try? Query(language: parser, data: Data($0.utf8)) }).first
            else { return nil }
            cache[key] = query
            return query
        }
    }

    /// TypeScript's query only adds what JavaScript lacks (types, `private`…);
    /// like Neovim and Helix, it's read after JavaScript's, which colors
    /// keywords, strings and comments. Later patterns win.
    private static func querySources(for language: TreeSitterLanguage) -> [String] {
        func read(_ url: URL?) -> String? { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
        guard let own = read(language.highlightQueryURL) else { return [] }
        guard language == .typescript, let base = read(TreeSitterLanguage.javascript.highlightQueryURL) else { return [own] }
        return [base + "\n" + own, own]
    }

    /// Compiles every language off the main thread so the first open is instant too.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            for language in TreeSitterLanguage.allCases { _ = query(for: language) }
        }
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
        let captures = await Task.detached(priority: .userInitiated) { Self.captures(in: text, url: url) }.value
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
    nonisolated private static func captures(in text: String, url: URL) -> [(String, NSRange)] {
        guard let language = Language.treeSitter(for: url), let query = HighlightQueries.query(for: language) else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(SwiftTreeSitter.Language(language: language.parser))) != nil,
              let tree = parser.parse(text) else { return [] }
        return query.execute(in: tree).resolve(with: .init(string: text)).highlights().map { ($0.name, $0.range) }
    }
}
