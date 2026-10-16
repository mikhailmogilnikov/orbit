import AppKit
import OrbitAPI

/// VS Code's overview ruler (D84): a strip under the vertical scroller marking
/// where things are in the whole file — git changes in the left lane, uses of
/// the symbol at the caret in the middle, problems on the right, the caret
/// across. Lines map to the strip's height proportionally; it takes no clicks
/// (the scroller above it does).
final class OverviewRuler: NSView {
    static let width: CGFloat = 12

    struct Colors: Equatable {
        var added: NSColor = .systemGreen
        var modified: NSColor = .systemBlue
        var deleted: NSColor = .systemRed
        var error: NSColor = .systemRed
        var warning: NSColor = .systemYellow
        var info: NSColor = .systemBlue
        var highlight: NSColor = .secondaryLabelColor
        var caret: NSColor = .secondaryLabelColor
    }

    var colors = Colors() { didSet { if colors != oldValue { needsDisplay = true } } }
    var lineCount = 1 { didSet { if lineCount != oldValue { needsDisplay = true } } }
    var changes = LineMarkers() { didSet { if changes != oldValue { needsDisplay = true } } }
    var diagnostics: [Diagnostic] = [] { didSet { if diagnostics != oldValue { needsDisplay = true } } }
    var highlights: [SymbolHighlight] = [] { didSet { if highlights != oldValue { needsDisplay = true } } }
    var caretLine: Int? { didSet { if caretLine != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func y(_ line: Int) -> CGFloat {
        bounds.height * CGFloat(line) / CGFloat(max(lineCount, 1))
    }

    /// A mark over lines `first...last`, at least 2 pt tall.
    private func mark(_ first: Int, _ last: Int, x: CGFloat, width: CGFloat, color: NSColor) {
        let top = y(first), bottom = y(last + 1)
        let height = max(bottom - top, 2)
        color.setFill()
        NSRect(x: x, y: min(top, bounds.height - height), width: width, height: height).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let lane = (bounds.width - 2) / 3
        for range in changes.added.rangeView { mark(range.first!, range.last!, x: 1, width: lane, color: colors.added) }
        for range in changes.modified.rangeView { mark(range.first!, range.last!, x: 1, width: lane, color: colors.modified) }
        for line in changes.deletedAbove {
            colors.deleted.setFill()
            NSRect(x: 1, y: min(max(y(line) - 1, 0), bounds.height - 2), width: lane, height: 2).fill()
        }
        for highlight in highlights {
            mark(highlight.range.start.line, highlight.range.end.line, x: 1 + lane, width: lane, color: colors.highlight)
        }
        // Less severe first, so errors end up on top.
        for diagnostic in diagnostics.sorted(by: { $0.severity < $1.severity }) {
            let color: NSColor = switch diagnostic.severity {
            case .error: colors.error
            case .warning: colors.warning
            case .information, .hint: colors.info
            }
            mark(diagnostic.range.start.line, diagnostic.range.start.line, x: 1 + 2 * lane, width: lane, color: color)
        }
        if let caretLine {
            colors.caret.setFill()
            NSRect(x: 0, y: min(max(y(caretLine), 0), bounds.height - 1.5), width: bounds.width, height: 1.5).fill()
        }
    }
}
