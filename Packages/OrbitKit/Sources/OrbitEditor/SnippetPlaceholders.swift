import AppKit
@_spi(Plugins) import STTextView

/// An inserted snippet's placeholders as tokens: a soft box behind each one
/// still to fill, so it's clear what Tab walks through (D202).
@MainActor
final class SnippetPlaceholderController {
    weak var textView: STTextView?
    let geometry: DiagnosticsController
    var color: NSColor = .clear {
        didSet { if color != oldValue { overlays.removeAll(); setNeedsLayout() } }
    }
    var ranges: [NSRange] = [] {
        didSet { if ranges != oldValue { setNeedsLayout() } }
    }
    private let overlays = OverlaySet()
    private var isLayoutScheduled = false

    init(geometry: DiagnosticsController) {
        self.geometry = geometry
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
        defer { overlays.commit() }
        guard let textView, !ranges.isEmpty else { return }
        let visible = textView.visibleRect
        for range in ranges where NSMaxRange(range) <= geometry.length {
            for rect in geometry.rects(for: range) where rect.intersects(visible) {
                let frame = rect.insetBy(dx: -1.5, dy: 0.5), color = color
                overlays.place(frame, color, frame: frame, in: textView, below: true) {
                    PlaceholderView(frame: frame, color: color)
                }
            }
        }
    }
}

private final class PlaceholderView: NSView {
    init(frame: NSRect, color: NSColor) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.backgroundColor = color.withAlphaComponent(color.alphaComponent * 0.5).cgColor
        layer?.borderColor = color.cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct SnippetPlaceholderPlugin: STPlugin {
    let controller: SnippetPlaceholderController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.setNeedsLayout() }
        }
    }
}
