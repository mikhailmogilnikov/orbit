import AppKit
import OrbitAPI
import OrbitUI
@_spi(Plugins) import STTextView
import SwiftUI

/// Squiggles under errors and warnings from the language server (D54). Like the
/// inline diff, only diagnostics in the viewport get a (small) view; nothing
/// touches the text storage, so the text doesn't relayout.
@MainActor
final class DiagnosticsController {
    weak var textView: STTextView?
    private(set) var diagnostics: [Diagnostic] = []
    /// Tagged unnecessary or deprecated (D78), hints included: faded or struck
    /// through, and their messages show on hover.
    private var tagged: [Diagnostic] = []
    /// What the server sent last: the shown ones move with edits (D202) and
    /// mustn't be put back where they were by the same set coming again.
    private var received: [Diagnostic] = []
    /// The unnecessary code's text, for the highlighter to fade.
    var onFadedChange: ((IndexSet) -> Void)?
    private let overlays = OverlaySet()
    private var cachedLineStarts: [Int]?
    private var isLayoutScheduled = false

    struct Colors: Equatable {
        var error: NSColor = .systemRed
        var warning: NSColor = .systemYellow
        var info: NSColor = .systemBlue
        /// The strike through deprecated code.
        var strike: NSColor = .secondaryLabelColor

        func color(for severity: Diagnostic.Severity) -> NSColor {
            switch severity {
            case .error: error
            case .warning: warning
            case .information, .hint: info
            }
        }
    }

    var colors = Colors() {
        didSet { if colors != oldValue { setNeedsLayout() } }
    }

    private var storage: NSTextStorage? {
        (textView?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    /// Hints are suggestions ("unused"), not problems: no squiggle.
    func update(_ diagnostics: [Diagnostic]) {
        guard diagnostics != received else { return }
        received = diagnostics
        let shown = diagnostics.filter { $0.severity != .hint }.sorted { $0.severity < $1.severity }
        let tagged = diagnostics.filter { !$0.tags.isEmpty }
        guard shown != self.diagnostics || tagged != self.tagged else { return }
        self.diagnostics = shown
        self.tagged = tagged
        updateFaded()
        setNeedsLayout()
    }

    private func updateFaded() {
        let starts = lineStarts, length = length
        var faded = IndexSet()
        for diagnostic in tagged where diagnostic.tags.contains(.unnecessary) {
            if let range = Range(diagnostic.range.nsRange(in: starts, length: length)) { faded.insert(integersIn: range) }
        }
        onFadedChange?(faded)
    }

    /// Measuring text while TextKit is laying it out (the viewport callback,
    /// mid-edit) can throw inside TextKit: squiggles are placed right after.
    func setNeedsLayout() {
        guard !isLayoutScheduled else { return }
        isLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isLayoutScheduled = false
            self?.layoutOverlays()
        }
    }

    /// The text changed: problems move with the text around them until the
    /// server sends new ones (D202); one the edit was inside stretches or
    /// shrinks with it. Without the edit (a whole new text) they're hidden.
    func textDidChange(_ edit: TextEdit? = nil) {
        let oldStarts = cachedLineStarts
        cachedLineStarts = nil
        guard let edit, let oldStarts, !diagnostics.isEmpty || !tagged.isEmpty else {
            // Old positions no longer match the text; the server sends new ones shortly.
            overlays.removeAll()
            return
        }
        let oldLength = length - edit.delta
        let starts = lineStarts
        func move(_ diagnostic: Diagnostic) -> Diagnostic {
            let range = Self.moved(diagnostic.range.nsRange(in: oldStarts, length: oldLength), by: edit)
            var moved = diagnostic
            moved.range = SourceRange(start: SourcePosition(offset: range.location, in: starts), end: SourcePosition(offset: NSMaxRange(range), in: starts))
            return moved
        }
        diagnostics = diagnostics.map(move)
        tagged = tagged.map(move)
        if tagged.contains(where: { $0.tags.contains(.unnecessary) }) { updateFaded() }
        setNeedsLayout()
    }

    /// A range in the old text, in the new one: after the edit it shifts; one
    /// the edit was inside (or an empty one right at it) stretches over it.
    nonisolated static func moved(_ range: NSRange, by edit: TextEdit) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        let editEnd = NSMaxRange(edit.range), newEnd = edit.range.location + edit.newLength
        if start >= editEnd, !(range.length == 0 && start == edit.range.location) {
            start += edit.delta
            end += edit.delta
        } else if end > edit.range.location || (end == edit.range.location && range.length == 0) {
            start = min(start, newEnd)
            end = end >= editEnd ? end + edit.delta : max(start, newEnd)
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    var lineStarts: [Int] {
        if let cachedLineStarts { return cachedLineStarts }
        let starts = storage.map { SourcePosition.lineStarts(of: $0.string as NSString) } ?? [0]
        cachedLineStarts = starts
        return starts
    }

    var length: Int { storage?.length ?? 0 }

    /// The text as the view holds it, without copying.
    var string: NSString? { storage?.string as NSString? }

    /// The diagnostics at a UTF-16 offset, most severe first.
    func diagnostics(at offset: Int) -> [Diagnostic] {
        let starts = lineStarts, length = length
        let hints = tagged.filter { $0.severity == .hint }
        return (hints + diagnostics.reversed()).filter {
            let range = Self.visibleRange($0.range.nsRange(in: starts, length: length), in: storage)
            return range.location <= offset && offset <= NSMaxRange(range)
        }
    }

    /// An empty range (a missing `;`) still needs something to underline, and so
    /// does one holding just a line break (Python's missing `:` runs from the end of
    /// the line to the start of the next: nothing visible in it, as Zed found).
    static func visibleRange(_ range: NSRange, in storage: NSTextStorage?) -> NSRange {
        guard let string = storage?.string as NSString? else { return range }
        if range.length > 0, NSMaxRange(range) <= string.length,
           string.substring(with: range).allSatisfy(\.isNewline) {
            return visibleRange(NSRange(location: range.location, length: 0), in: storage)
        }
        guard range.length == 0 else { return range }
        if range.location < string.length, string.character(at: range.location) != 0x0A {
            return NSRange(location: range.location, length: 1)
        }
        return range.location > 0 ? NSRange(location: range.location - 1, length: 1) : range
    }

    /// Rects of a text range in text-view coordinates, one per line fragment.
    func rects(for range: NSRange) -> [CGRect] {
        guard let textView, range.length > 0,
              let textRange = NSTextRange(range, in: textView.textContentManager) else { return [] }
        let content = textView.contentFrame
        var rects: [CGRect] = []
        textView.textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: content.minX, dy: content.minY))
            return true
        }
        return rects
    }

    /// Rebuilds the squiggles in the viewport.
    private func layoutOverlays() {
        defer { overlays.commit() }
        let struck = tagged.filter { $0.tags.contains(.deprecated) }
        guard let textView, !diagnostics.isEmpty || !struck.isEmpty else { return }
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -200)
        let starts = lineStarts, length = length
        // Only what's laid out: measuring text off screen would lay it out first.
        let manager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        guard let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let start = manager.documentRange.location
        let lower = contentManager.offset(from: start, to: viewport.location)
        let upper = contentManager.offset(from: start, to: viewport.endLocation)
        let window = NSRange(location: lower, length: max(0, upper - lower))
        for diagnostic in struck {
            let range = NSIntersectionRange(diagnostic.range.nsRange(in: starts, length: length), window)
            guard range.length > 0 else { continue }
            for rect in rects(for: range) where rect.intersects(visible) && rect.width > 0 {
                let frame = CGRect(x: rect.minX, y: rect.midY.rounded(), width: rect.width, height: 1)
                let color = colors.strike
                overlays.place("strike", frame, color, frame: frame, in: textView) {
                    let line = StrikeView(frame: frame)
                    line.layer?.backgroundColor = color.cgColor
                    return line
                }
            }
        }
        for diagnostic in diagnostics {
            var range = Self.visibleRange(diagnostic.range.nsRange(in: starts, length: length), in: storage)
            range = NSIntersectionRange(range, NSRange(location: lower, length: max(0, upper - lower)))
            guard range.length > 0 else { continue }
            for rect in rects(for: range) where rect.intersects(visible) {
                let frame = CGRect(x: rect.minX, y: rect.maxY - 3, width: max(rect.width, 6), height: 4)
                let color = colors.color(for: diagnostic.severity)
                overlays.place("squiggle", frame, color, frame: frame, in: textView) {
                    let squiggle = SquiggleView(frame: frame)
                    squiggle.color = color
                    return squiggle
                }
            }
        }
    }
}

/// The line through deprecated code; clicks go to the text under it.
final class StrikeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A wavy underline.
final class SquiggleView: NSView {
    var color: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        let step: CGFloat = 2
        var x = bounds.minX
        var up = true
        path.move(to: NSPoint(x: x, y: bounds.maxY - 1))
        while x < bounds.maxX {
            x += step
            path.line(to: NSPoint(x: min(x, bounds.maxX), y: up ? bounds.minY + 1 : bounds.maxY - 1))
            up.toggle()
        }
        path.lineWidth = 1
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

/// STTextView plugin hook: re-place squiggles whenever the viewport is laid out.
struct DiagnosticsPlugin: STPlugin {
    let controller: DiagnosticsController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.setNeedsLayout() }
        }
    }
}

/// The popover under the pointer: the problems at that spot, then what the
/// language server says about the symbol.
struct HoverCard: View {
    let diagnostics: [Diagnostic]
    let markdown: String?
    let colors: DiagnosticsController.Colors
    var fixes: [CodeAction] = []
    var hasMoreActions = false
    var showsSymbolKeys = false
    var onFix: (CodeAction) -> Void = { _ in }
    var onMoreActions: () -> Void = {}
    var highlight: (@MainActor (_ code: String, _ language: String) async -> [SyntaxSpan])?

    /// Laid out like VS Code's: the problems, a bar of fixes under them, then
    /// what the server says about the symbol, sections split by lines (D68).
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: Self.symbol(for: diagnostic.severity))
                                .foregroundStyle(Color(nsColor: colors.color(for: diagnostic.severity)))
                            Text("\(Text(Self.styled(diagnostic.message)))\(Text(diagnostic.source.map { "  \($0)" } ?? "").foregroundStyle(.tertiary))")
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                if !fixes.isEmpty || hasMoreActions {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(fixes) { fix in
                            Button { onFix(fix) } label: {
                                Label(fix.title, systemImage: fix.isPreferred ? "wand.and.sparkles" : "wrench.adjustable")
                                    .labelStyle(FixLabelStyle())
                            }
                        }
                        if hasMoreActions {
                            Button(action: onMoreActions) {
                                HStack(spacing: 6) {
                                    Text("Quick Fix…")
                                    Text("⇧⌘A").foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.link)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.subtleFill)
                }
            }
            if let markdown {
                if !diagnostics.isEmpty { Divider() }
                MarkdownText(markdown, codeStyle: .plain, highlight: highlight)
                    .padding(10)
            }
            if showsSymbolKeys {
                Divider()
                // What can be done with the symbol, and the keys for it (D67).
                Text("⌘-click  definition   ·   ⇧⌘R  references   ·   ⌃⌘E  rename")
                    .orbitFont(.micro)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
        .frame(maxWidth: 540, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .orbitFont(.body)
    }

    private struct FixLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                configuration.icon.frame(width: 14)
                configuration.title.multilineTextAlignment(.leading)
            }
        }
    }

    /// Names and types in a message set in code type, as Zed does: `'x'` (TypeScript,
    /// Swift, Svelte) and `` `x` `` (Rust). Apostrophes inside words don't count.
    static func styled(_ message: String) -> AttributedString {
        let pattern = #"(?<![\p{L}\p{N}])'([^'\n]+)'(?![\p{L}\p{N}])|`([^`\n]+)`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return AttributedString(message) }
        let text = message as NSString
        var result = AttributedString()
        var last = 0
        for match in regex.matches(in: message, range: NSRange(location: 0, length: text.length)) {
            let inner = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            result += AttributedString(text.substring(with: NSRange(location: last, length: match.range.location - last)))
            var code = AttributedString(text.substring(with: inner))
            code.font = .orbit(.code)
            code.backgroundColor = Theme.subtleFill
            result += code
            last = match.range.location + match.range.length
        }
        result += AttributedString(text.substring(from: last))
        return result
    }

    private static func symbol(for severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information, .hint: "info.circle.fill"
        }
    }
}
