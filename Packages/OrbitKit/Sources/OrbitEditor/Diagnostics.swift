import AppKit
import OrbitAPI
import OrbitUI
import STTextView
import SwiftUI

/// Squiggles under errors and warnings from the language server (D54). Like the
/// inline diff, only diagnostics in the viewport get a (small) view; nothing
/// touches the text storage, so the text doesn't relayout.
@MainActor
final class DiagnosticsController {
    weak var textView: STTextView?
    private(set) var diagnostics: [Diagnostic] = []
    private var overlays: [NSView] = []
    private var cachedLineStarts: [Int]?

    struct Colors: Equatable {
        var error: NSColor = .systemRed
        var warning: NSColor = .systemYellow
        var info: NSColor = .systemBlue

        func color(for severity: Diagnostic.Severity) -> NSColor {
            switch severity {
            case .error: error
            case .warning: warning
            case .information, .hint: info
            }
        }
    }

    var colors = Colors() {
        didSet { if colors != oldValue { layoutOverlays() } }
    }

    private var storage: NSTextStorage? {
        (textView?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    /// Hints are suggestions ("unused"), not problems: no squiggle.
    func update(_ diagnostics: [Diagnostic]) {
        let shown = diagnostics.filter { $0.severity != .hint }.sorted { $0.severity < $1.severity }
        guard shown != self.diagnostics else { return }
        self.diagnostics = shown
        layoutOverlays()
    }

    /// The text changed: positions are re-read on the next layout.
    func textDidChange() {
        cachedLineStarts = nil
    }

    var lineStarts: [Int] {
        if let cachedLineStarts { return cachedLineStarts }
        let starts = storage.map { SourcePosition.lineStarts(of: $0.string as NSString) } ?? [0]
        cachedLineStarts = starts
        return starts
    }

    var length: Int { storage?.length ?? 0 }

    /// The diagnostics at a UTF-16 offset, most severe first.
    func diagnostics(at offset: Int) -> [Diagnostic] {
        let starts = lineStarts, length = length
        return diagnostics.reversed().filter {
            let range = Self.visibleRange($0.range.nsRange(in: starts, length: length), in: storage)
            return range.location <= offset && offset <= NSMaxRange(range)
        }
    }

    /// An empty range (a missing `;`) still needs something to underline.
    static func visibleRange(_ range: NSRange, in storage: NSTextStorage?) -> NSRange {
        guard range.length == 0, let string = storage?.string as NSString? else { return range }
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

    /// Rebuilds the squiggles in (or near) the viewport.
    func layoutOverlays() {
        for view in overlays { view.removeFromSuperview() }
        overlays.removeAll()
        guard let textView, !diagnostics.isEmpty else { return }
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -200)
        let starts = lineStarts, length = length
        // Measuring a range off screen would lay it out: skip those by offset first.
        let manager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        var window = 0..<length
        if let viewport = manager.textViewportLayoutController.viewportRange {
            let start = manager.documentRange.location
            let lower = contentManager.offset(from: start, to: viewport.location)
            let upper = contentManager.offset(from: start, to: viewport.endLocation)
            window = max(0, lower - 4000)..<min(length, upper + 4000) + 1
        }
        for diagnostic in diagnostics {
            let range = Self.visibleRange(diagnostic.range.nsRange(in: starts, length: length), in: storage)
            guard window.overlaps(range.location..<(NSMaxRange(range) + 1)) else { continue }
            for rect in rects(for: range) where rect.intersects(visible) {
                let squiggle = SquiggleView(frame: CGRect(x: rect.minX, y: rect.maxY - 3, width: max(rect.width, 6), height: 4))
                squiggle.color = colors.color(for: diagnostic.severity)
                textView.addSubview(squiggle)
                overlays.append(squiggle)
            }
        }
    }
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
            MainActor.assumeIsolated { controller.layoutOverlays() }
        }
    }
}

/// The popover under the pointer: the problems at that spot, then what the
/// language server says about the symbol.
struct HoverCard: View {
    let diagnostics: [Diagnostic]
    let markdown: String?
    let colors: DiagnosticsController.Colors

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.symbol(for: diagnostic.severity))
                        .foregroundStyle(Color(nsColor: colors.color(for: diagnostic.severity)))
                    Text(diagnostic.message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !diagnostics.isEmpty, markdown != nil {
                Divider()
            }
            if let markdown {
                MarkdownText(markdown)
            }
        }
        .padding(12)
        .frame(maxWidth: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 12))
    }

    private static func symbol(for severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information, .hint: "info.circle.fill"
        }
    }
}
