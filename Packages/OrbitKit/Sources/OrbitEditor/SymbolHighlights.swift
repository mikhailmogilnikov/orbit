import AppKit
import OrbitAPI
@_spi(Plugins) import STTextView

/// Other uses of the symbol under the caret, softly filled behind the text
/// (LSP document highlights, D62). Like squiggles, only the viewport gets views.
@MainActor
final class SymbolHighlightController {
    weak var textView: STTextView?
    /// Shares the squiggles' text geometry (line starts, rects).
    let geometry: DiagnosticsController
    var languages: LanguageIntelligence?
    var url: URL?
    /// The uses shown changed (the overview ruler marks them).
    var onChange: (([SymbolHighlight]) -> Void)?
    private var highlights: [SymbolHighlight] = []
    /// `highlights` as offsets of the current text.
    private var ranges: [NSRange] = []
    private var overlays: [NSView] = []
    private var request: Task<Void, Never>?
    private var isLayoutScheduled = false

    struct Colors: Equatable {
        var read: NSColor = .clear
        var write: NSColor = .clear
    }

    var colors = Colors() {
        didSet { if colors != oldValue { setNeedsLayout() } }
    }

    init(geometry: DiagnosticsController) {
        self.geometry = geometry
    }

    /// The caret settled somewhere: ask again unless it's still on a highlighted use.
    func caretMoved(to selection: NSRange) {
        request?.cancel()
        guard selection.length == 0, let languages, let url else {
            clear()
            return
        }
        if ranges.contains(where: { $0.location <= selection.location && selection.location <= NSMaxRange($0) }) { return }
        let position = SourcePosition(offset: selection.location, in: geometry.lineStarts)
        request = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await languages.highlights(at: position, in: url)
            guard !Task.isCancelled, let self else { return }
            // A lone hit is the symbol itself: nothing to point out.
            show(found.count > 1 ? found : [])
        }
    }

    /// Positions are stale after an edit; the next caret move asks again.
    func textDidChange() {
        request?.cancel()
        clear()
    }

    func clear() {
        guard !highlights.isEmpty || !overlays.isEmpty else { return }
        highlights = []
        ranges = []
        onChange?([])
        for view in overlays { view.removeFromSuperview() }
        overlays.removeAll()
    }

    private func show(_ found: [SymbolHighlight]) {
        highlights = found
        onChange?(found)
        let starts = geometry.lineStarts, length = geometry.length
        ranges = found.map { $0.range.nsRange(in: starts, length: length) }
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
        guard let textView, !ranges.isEmpty else { return }
        let manager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        guard let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let start = manager.documentRange.location
        let lower = contentManager.offset(from: start, to: viewport.location)
        let upper = contentManager.offset(from: start, to: viewport.endLocation)
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -200)
        for (highlight, range) in zip(highlights, ranges) {
            let shown = NSIntersectionRange(range, NSRange(location: lower, length: max(0, upper - lower)))
            guard shown.length > 0 else { continue }
            for rect in geometry.rects(for: shown) where rect.intersects(visible) {
                let view = HighlightView(frame: rect.insetBy(dx: -1, dy: 0))
                view.color = highlight.isWrite ? colors.write : colors.read
                // Under the text (and the caret line), over the background.
                textView.addSubview(view, positioned: .below, relativeTo: nil)
                overlays.append(view)
            }
        }
    }
}

private final class HighlightView: NSView {
    var color: NSColor = .clear {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct SymbolHighlightPlugin: STPlugin {
    let controller: SymbolHighlightController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.setNeedsLayout() }
        }
    }
}
