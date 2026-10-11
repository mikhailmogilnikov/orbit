import AppKit
import SwiftUI
import Neon
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
    let theme: STPluginNeon.Theme
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
        SyntaxHighlightCoordinator(textView: context.textView, theme: theme, language: language)
    }
}

@MainActor
final class SyntaxHighlightCoordinator {
    private var highlighter: Neon.Highlighter?
    private let language: TreeSitterLanguage
    private let tsLanguage: SwiftTreeSitter.Language
    private let tsClient: TreeSitterClient
    private var prevViewportRange: NSTextRange?

    init(textView: STTextView, theme: STPluginNeon.Theme, language: TreeSitterLanguage) {
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

        // Theme fonts only vary the weight; map them onto two editor-sized fonts so
        // most tokens use the editor's own font object and need no font edit.
        let base = textView.font
        let medium = NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .medium)
        let interface = HighlightTextInterface(textView: textView) { token in
            let name = TokenName(token.name)
            guard let color = theme.color(forToken: name) ?? theme.color(forToken: "plain") else { return nil }
            let isHeavy = theme.font(forToken: name).map(HighlightTextInterface.isHeavy) ?? false
            return (color, isHeavy ? medium : base)
        }
        highlighter = Neon.Highlighter(textInterface: interface, tokenProvider: tokenProvider(textContentManager: textView.textContentManager))
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
            if let font = value as? NSFont, Self.isHeavy(font) { queueFont(base, for: subrange) }
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

    nonisolated static func isHeavy(_ font: NSFont) -> Bool {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = traits?[.weight] as? CGFloat ?? 0
        return weight > NSFont.Weight.regular.rawValue + 0.01
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
        let theme = STPluginNeon.Theme.default
        return captures.compactMap { name, range in
            guard range.length > 0, let color = theme.color(forToken: TokenName(name)) else { return nil }
            return SyntaxSpan(range: range, color: Color(nsColor: color))
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
