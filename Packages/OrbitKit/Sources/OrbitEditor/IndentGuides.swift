import AppKit
import OrbitAPI
@_spi(Plugins) import STTextView

/// Thin vertical lines at each indentation level of the visible lines, as in
/// VS Code and Xcode. Blank lines take the shallower of their neighbors, so
/// a block's guides run through the empty lines inside it.
@MainActor
final class IndentGuidesController {
    weak var textView: STTextView?
    var color: NSColor = .clear {
        didSet { if color != oldValue { view?.needsDisplay = true } }
    }
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { view?.removeFromSuperview(); view = nil } else { setNeedsLayout() }
        }
    }
    private var view: GuidesView?
    private var isLayoutScheduled = false

    func setNeedsLayout() {
        guard isEnabled, !isLayoutScheduled else { return }
        isLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isLayoutScheduled = false
            self?.layout()
        }
    }

    private func layout() {
        guard isEnabled, let textView else { return }
        let view = view ?? GuidesView(controller: self)
        if view.superview !== textView {
            textView.addSubview(view, positioned: .below, relativeTo: nil)
            self.view = view
        }
        view.frame = textView.visibleRect.insetBy(dx: 0, dy: -40).intersection(textView.bounds)
        view.needsDisplay = true
    }

    /// Indent columns of a line; nil when it's blank.
    nonisolated static func indent(of line: Substring, tabSize: Int) -> Int? {
        var columns = 0
        for character in line {
            switch character {
            case " ": columns += 1
            case "\t": columns += tabSize - columns % tabSize
            case "\n", "\r": return nil
            default: return columns
            }
        }
        return nil
    }

    /// Levels to draw for each line in `lines` (by index), blank lines resolved from neighbors.
    nonisolated static func levels(_ lines: [Substring], tabSize: Int) -> [Int] {
        let indents = lines.map { indent(of: $0, tabSize: tabSize) }
        var levels = [Int](repeating: 0, count: lines.count)
        var previous: Int?
        for index in indents.indices {
            if let indent = indents[index] {
                levels[index] = indent / tabSize
                previous = indent
            } else {
                let next = indents[(index + 1)...].lazy.compactMap(\.self).first
                levels[index] = min(previous ?? 0, next ?? 0) / tabSize
            }
        }
        return levels
    }

    fileprivate func draw(in view: GuidesView, dirtyRect: NSRect) {
        guard let textView = textView as? OrbitTextView else { return }
        let manager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        guard let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let text = textView.documentText
        let tabSize = max(1, textView.indentation.size)
        let space = (" " as NSString).size(withAttributes: [.font: textView.font]).width
        let content = textView.contentFrame
        let originX = content.minX + textView.textContainer.lineFragmentPadding
        let documentStart = manager.documentRange.location

        // The visible lines, plus some after them so blank lines at the bottom know their next indent.
        var fragments: [(range: NSRange, top: CGFloat, bottom: CGFloat)] = []
        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            guard let first = fragment.textLineFragments.first else { return true }
            let start = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let end = contentManager.offset(from: documentStart, to: fragment.rangeInElement.endLocation)
            let frame = fragment.layoutFragmentFrame
            // The line's own text, not an inline-diff gap above it.
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 || $0 === first }
            fragments.append((NSRange(location: start, length: end - start),
                              content.minY + frame.minY + first.typographicBounds.minY,
                              content.minY + frame.minY + (lines.last ?? first).typographicBounds.maxY))
            return true
        }
        guard let last = fragments.last else { return }
        var lines = fragments.map { Substring(text.substring(with: NSIntersectionRange($0.range, NSRange(location: 0, length: text.length)))) }
        // Up to 100 lines past the viewport for blank lines' next indent.
        var offset = NSMaxRange(last.range)
        var lookahead: [Substring] = []
        while offset < text.length, lookahead.count < 100 {
            let range = text.lineRange(for: NSRange(location: offset, length: 0))
            let line = Substring(text.substring(with: range))
            lookahead.append(line)
            offset = NSMaxRange(range)
            if Self.indent(of: line, tabSize: tabSize) != nil { break }
        }
        lines += lookahead
        let levels = Self.levels(lines, tabSize: tabSize)

        color.setFill()
        let scale = view.window?.backingScaleFactor ?? 2
        for (index, fragment) in fragments.enumerated() where levels[index] > 0 {
            let top = view.convert(NSPoint(x: 0, y: fragment.top), from: textView).y
            let bottom = view.convert(NSPoint(x: 0, y: fragment.bottom), from: textView).y
            guard max(top, bottom) >= dirtyRect.minY, min(top, bottom) <= dirtyRect.maxY else { continue }
            for level in 0..<levels[index] {
                let x = view.convert(NSPoint(x: originX + CGFloat(level * tabSize) * space, y: 0), from: textView).x
                // On the pixel grid: a crisp 1-pt line, not a blurred 2-px one.
                let snapped = (x * scale).rounded() / scale
                NSRect(x: snapped, y: min(top, bottom), width: 1, height: abs(bottom - top)).fill()
            }
        }
    }
}

private final class GuidesView: NSView {
    weak var controller: IndentGuidesController?

    init(controller: IndentGuidesController) {
        self.controller = controller
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        controller?.draw(in: self, dirtyRect: dirtyRect.intersection(bounds))
    }
}

struct IndentGuidesPlugin: STPlugin {
    let controller: IndentGuidesController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.setNeedsLayout() }
        }
    }
}
