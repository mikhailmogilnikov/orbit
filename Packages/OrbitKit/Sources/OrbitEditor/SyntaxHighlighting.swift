import AppKit
import SwiftUI
import Neon
import OrbitAPI
import OrbitUI
import STPluginNeon
import STTextView
import SwiftTreeSitter
import Synchronization
import TreeSitterClient
import TreeSitterResource

/// Tree-sitter highlighting for STTextView. A copy of `NeonPlugin` from
/// STTextView-Plugin-Neon with one fix: tree-sitter emits zero-length tokens
/// (markdown block markers, MISSING nodes for an unclosed `"`), and TextKit 2
/// throws on `addRenderingAttribute` for an empty range, crashing the app.
struct SyntaxHighlightPlugin: STPlugin {
    let palette: SyntaxPalette
    let language: TreeSitterLanguage

    func setUp(context: any Context) {
        context.events.onWillChangeText { affectedRange, _ in
            let range = NSRange(affectedRange, in: context.textView.textContentManager)
            context.coordinator.willChangeContent(in: range)
        }

        context.events.onDidChangeText { affectedRange, replacementString in
            guard let replacementString else { return }
            let manager = context.textView.textContentManager
            let range = NSRange(affectedRange, in: manager)
            context.coordinator.didChangeContent(
                manager, in: range,
                delta: replacementString.utf16.count - range.length,
                limit: manager.length
            )
        }

        context.events.onDidLayoutViewport { viewportRange in
            context.coordinator.updateViewportRange(viewportRange)
        }
    }

    func makeCoordinator(context: CoordinatorContext) -> SyntaxHighlightCoordinator {
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
            onChange?()
        }
    }

    /// Also called after a font size change: styled tokens carry their own fonts.
    var onChange: (() -> Void)?
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
    private var highlighter: Neon.Highlighter?
    private let language: TreeSitterLanguage
    private let tsLanguage: SwiftTreeSitter.Language
    private let tsClient: TreeSitterClient
    private var prevViewportRange: NSTextRange?

    init(textView: STTextView, palette: SyntaxPalette, language: TreeSitterLanguage) {
        self.language = language
        tsLanguage = SwiftTreeSitter.Language(language: language.parser)

        tsClient = try! TreeSitterClient(language: tsLanguage) { codePointIndex in
            guard let location = textView.textContentManager.location(at: codePointIndex),
                  let position = textView.textContentManager.position(location)
            else { return .zero }
            return Point(row: position.row, column: position.column)
        }

        tsClient.invalidationHandler = { [weak self] indexSet in
            self?.highlighter?.invalidate(.set(indexSet))
        }

        // Uncolored tokens get no attribute and show in the editor's text color.
        let interface = HighlightTextInterface(textView: textView) { [weak textView] token in
            guard let textView, let style = palette.style(forCapture: token.name), let color = style.color else { return nil }
            return (color.nsColor, palette.font(for: style, base: textView.font))
        }
        highlighter = Neon.Highlighter(textInterface: interface, tokenProvider: tokenProvider(textContentManager: textView.textContentManager))
        palette.onChange = { [weak self] in self?.highlighter?.invalidate(.all) }
        // Bigger token requests than Neon's 1 KB default: each applied batch redraws the
        // viewport, so fewer, larger ones scroll smoother; 4 KB avoids first-paint hitches.
        highlighter?.requestLengthLimit = 4096

        let manager = textView.textContentManager
        let fullRange = NSRange(manager.documentRange, in: manager)
        tsClient.willChangeContent(in: fullRange)
        tsClient.didChangeContent(
            in: fullRange, delta: manager.length, limit: manager.length,
            readHandler: Parser.readFunction(for: manager.attributedString(in: nil)?.string ?? ""),
            completionHandler: {}
        )
    }

    private func tokenProvider(textContentManager: NSTextContentManager) -> Neon.TokenProvider? {
        guard let highlightsQuery = HighlightQueries.query(for: language) else { return nil }

        return tsClient.tokenProvider(with: highlightsQuery) { range, _ in
            guard !range.isEmpty else { return nil }
            return textContentManager.attributedString(in: NSTextRange(range, provider: textContentManager))?.string
        }
    }

    func updateViewportRange(_ range: NSTextRange?) {
        if range != prevViewportRange {
            highlighter?.visibleContentDidChange()
        }
        prevViewportRange = range
    }

    func willChangeContent(in range: NSRange) {
        tsClient.willChangeContent(in: range)
    }

    func didChangeContent(_ textContentManager: NSTextContentManager, in range: NSRange, delta: Int, limit: Int) {
        guard let string = textContentManager.attributedString(in: nil)?.string else { return }
        tsClient.didChangeContent(
            in: range, delta: delta, limit: limit,
            readHandler: Parser.readFunction(for: string),
            completionHandler: {}
        )
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
            guard let url = language.highlightQueryURL,
                  let query = try? SwiftTreeSitter.Language(language: language.parser).query(contentsOf: url)
            else { return nil }
            cache[key] = query
            return query
        }
    }

    /// Compiles every language off the main thread so the first open is instant too.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            for language in TreeSitterLanguage.allCases { _ = query(for: language) }
        }
    }
}

/// Colors go on as TextKit 2 rendering attributes, which only redraw. Fonts are
/// real text-storage edits that force relayout, so they're applied only where a
/// token's font differs from the editor's (e.g. medium keywords), batched into
/// one editing transaction per run loop pass. Setting a font on every token made
/// scrolling into unhighlighted text stutter.
@MainActor
private final class HighlightTextInterface: TextSystemInterface {
    typealias StyleProvider = (Neon.Token) -> (color: NSColor, font: NSFont)?

    private let textView: STTextView
    private let style: StyleProvider
    private var pendingFonts: [(range: NSRange, font: NSFont)] = []
    private var isFlushScheduled = false

    init(textView: STTextView, style: @escaping StyleProvider) {
        self.textView = textView
        self.style = style
    }

    private var storage: NSTextStorage? {
        (textView.textContentManager as? NSTextContentStorage)?.textStorage
    }

    func clearStyle(in range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= length,
              let textRange = NSTextRange(range, in: textView.textContentManager)
        else { return }
        textView.textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)

        pendingFonts.removeAll { NSIntersectionRange($0.range, range).length == $0.range.length }
        let base = textView.font
        storage?.enumerateAttribute(.font, in: range) { value, subrange, _ in
            if let font = value as? NSFont, font != base { queueFont(base, for: subrange) }
        }
    }

    func applyStyle(to token: Neon.Token) {
        // Stale tokens can outlive an edit; empty ones crash TextKit.
        guard token.range.length > 0, NSMaxRange(token.range) <= length,
              let (color, font) = style(token),
              let textRange = NSTextRange(token.range, in: textView.textContentManager)
        else { return }

        textView.textLayoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
        if font !== textView.font { queueFont(font, for: token.range) }
    }

    private func queueFont(_ font: NSFont, for range: NSRange) {
        pendingFonts.append((range, font))
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushFonts() }
    }

    private func flushFonts() {
        isFlushScheduled = false
        let edits = pendingFonts
        pendingFonts.removeAll()
        guard let storage, !edits.isEmpty else { return }
        let length = storage.length
        textView.textContentManager.performEditingTransaction {
            for edit in edits where NSMaxRange(edit.range) <= length {
                storage.addAttribute(.font, value: edit.font, range: edit.range)
            }
        }
        textView.needsLayout = true
    }

    var length: Int {
        textView.textContentManager.length
    }

    var visibleRange: NSRange {
        guard let viewportRange = textView.textLayoutManager.textViewportLayoutController.viewportRange else {
            return .zero
        }
        return NSRange(viewportRange, provider: textView.textContentManager)
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
