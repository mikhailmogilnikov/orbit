import AppKit
import OrbitAPI
@_spi(Plugins) import STTextView

/// The bracket next to the caret and its partner, outlined as in Xcode.
@MainActor
final class BracketMatchController {
    weak var textView: STTextView?
    let geometry: DiagnosticsController
    var color: NSColor = .clear {
        didSet { if color != oldValue { setNeedsLayout() } }
    }
    private var pair: [NSRange] = []
    private var overlays: [NSView] = []
    private var isLayoutScheduled = false

    init(geometry: DiagnosticsController) {
        self.geometry = geometry
    }

    func caretMoved() {
        guard let textView, !textView.hasMultipleSelections, textView.textSelection.length == 0,
              let pairs = (textView as? OrbitTextView)?.syntaxLanguage?.brackets?.filter({ $0.start.utf16.count == 1 && $0.end.utf16.count == 1 && $0.start != $0.end }),
              !pairs.isEmpty else {
            show([])
            return
        }
        let found = Self.match(around: textView.textSelection.location, in: textView.documentText, pairs: pairs)
        show(found.map { [$0.0, $0.1].map { NSRange(location: $0, length: 1) } } ?? [])
    }

    /// The bracket after the caret first, then the one before it, as Zed;
    /// nesting counts only the same pair. Far partners aren't searched for.
    static func match(around caret: Int, in text: NSString, pairs: [SyntaxLanguage.Bracket], limit: Int = 50_000) -> (Int, Int)? {
        let opens = pairs.map { $0.start.utf16.first! }, closes = pairs.map { $0.end.utf16.first! }
        for offset in [caret, caret - 1] where offset >= 0 && offset < text.length {
            let unit = text.character(at: offset)
            if let index = opens.firstIndex(of: unit) {
                var depth = 0
                for candidate in offset..<min(text.length, offset + limit) {
                    let next = text.character(at: candidate)
                    if next == unit { depth += 1 } else if next == closes[index] { depth -= 1 }
                    if depth == 0 { return (offset, candidate) }
                }
                return nil
            }
            if let index = closes.firstIndex(of: unit) {
                var depth = 0
                for candidate in stride(from: offset, through: max(0, offset - limit), by: -1) {
                    let next = text.character(at: candidate)
                    if next == unit { depth += 1 } else if next == opens[index] { depth -= 1 }
                    if depth == 0 { return (candidate, offset) }
                }
                return nil
            }
        }
        return nil
    }

    private func show(_ ranges: [NSRange]) {
        guard ranges != pair else { return }
        pair = ranges
        setNeedsLayout()
    }

    func setNeedsLayout() {
        guard !isLayoutScheduled else { return }
        isLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isLayoutScheduled = false
            self?.layoutOverlays()
        }
    }

    private func layoutOverlays() {
        for view in overlays { view.removeFromSuperview() }
        overlays.removeAll()
        guard let textView, !pair.isEmpty else { return }
        let visible = textView.visibleRect
        for range in pair where NSMaxRange(range) <= geometry.length {
            for rect in geometry.rects(for: range) where rect.intersects(visible) {
                let view = OutlineView(frame: rect.insetBy(dx: -0.5, dy: 0.5))
                view.layer?.borderColor = color.cgColor
                textView.addSubview(view, positioned: .below, relativeTo: nil)
                overlays.append(view)
            }
        }
    }
}

private final class OutlineView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct BracketMatchPlugin: STPlugin {
    let controller: BracketMatchController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.setNeedsLayout() }
        }
    }
}
