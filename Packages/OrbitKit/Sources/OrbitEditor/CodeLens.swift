import AppKit
import OrbitAPI
@_spi(Plugins) import STTextView

/// A server's lenses ("3 references", "▶ Run") after the end of their line,
/// faded like the blame (D201): no room is made above the line, so nothing
/// shifts the code or fights the inline diff's gaps. A click runs the lens.
@MainActor
final class CodeLensController {
    weak var textView: STTextView?
    let geometry: DiagnosticsController
    var languages: LanguageIntelligence?
    var url: URL?
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { refresh() } else { lenses = [] }
        }
    }
    struct Colors: Equatable {
        var text: NSColor = .tertiaryLabelColor
        var active: NSColor = .labelColor
    }
    var colors = Colors() {
        didSet { if colors != oldValue { overlays.removeAll(); setNeedsLayout() } }
    }
    /// Why a lens couldn't run, for an alert.
    var onFailure: (String) -> Void = { _ in }

    private var lenses: [CodeLens] = [] {
        didSet { setNeedsLayout() }
    }
    /// Lenses on this line and below moved with an edit: hidden until the server answers again.
    private var staleFrom: Int?
    private var request: Task<Void, Never>?
    private var version = 0
    private let overlays = OverlaySet()
    private var isLayoutScheduled = false

    init(geometry: DiagnosticsController) {
        self.geometry = geometry
    }

    func refresh(after delay: Duration = .zero) {
        request?.cancel()
        guard isEnabled, let languages, let url else { return }
        let version = version
        request = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let found = await languages.codeLenses(in: url)
            guard !Task.isCancelled, let self, self.version == version else { return }
            staleFrom = nil
            lenses = found
        }
    }

    func textDidChange(_ edit: TextEdit) {
        version += 1
        let line = SourcePosition(offset: min(edit.range.location, geometry.length), in: geometry.lineStarts).line
        staleFrom = min(staleFrom ?? line, line)
        setNeedsLayout()
        refresh(after: .milliseconds(800))
    }

    func textWasReplaced() {
        version += 1
        staleFrom = 0
        setNeedsLayout()
        refresh(after: .milliseconds(800))
    }

    private var font: NSFont? {
        textView.map { NSFont.systemFont(ofSize: ($0.font.pointSize * 0.92).rounded()) }
    }

    private func shown(onLine line: Int) -> [CodeLens] {
        guard isEnabled, staleFrom.map({ line < $0 }) ?? true else { return [] }
        return lenses.filter { $0.line == line }
    }

    /// Room the lenses take after a line's end, for the blame to sit after them.
    func width(onLine line: Int) -> CGFloat? {
        let lenses = shown(onLine: line)
        guard !lenses.isEmpty, let font else { return nil }
        return CodeLensView.width(of: lenses.map { CodeLensView.Segment(lens: $0) }, font: font) + ceil(font.pointSize * 2.5)
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
        guard let textView, let font, isEnabled, !lenses.isEmpty, let string = geometry.string,
              let viewport = textView.textLayoutManager.textViewportLayoutController.viewportRange else { return }
        let starts = geometry.lineStarts
        let visible = NSRange(viewport, in: textView.textContentManager)
        let first = SourcePosition(offset: visible.location, in: starts).line
        let last = SourcePosition(offset: min(NSMaxRange(visible), string.length), in: starts).line
        let byLine = Dictionary(grouping: lenses.filter { (first...last).contains($0.line) }, by: \.line)
        let bounds = textView.visibleRect
        for (line, _) in byLine where line < starts.count {
            let lenses = shown(onLine: line)
            guard !lenses.isEmpty else { continue }
            let start = starts[line]
            let end = line + 1 < starts.count ? starts[line + 1] - 1 : string.length
            let anchor = end > start ? NSRange(location: end - 1, length: 1) : NSRange(location: start, length: 1)
            guard NSMaxRange(anchor) <= string.length, let rect = geometry.rects(for: anchor).last else { continue }
            let x = (end > start ? rect.maxX : rect.minX) + ceil(font.pointSize * 2.5)
            let segments = lenses.map { CodeLensView.Segment(lens: $0) }
            let width = min(CodeLensView.width(of: segments, font: font), bounds.maxX - x - 12)
            guard width > 30 else { continue }
            let frame = CGRect(x: x, y: rect.minY, width: width, height: rect.height).integral
            let colors = colors
            overlays.place(line, lenses, font, frame: frame, in: textView) {
                CodeLensView(frame: frame, segments: segments, font: font, colors: colors) { [weak self] lens in
                    self?.run(lens)
                }
            }
        }
    }

    private func run(_ lens: CodeLens) {
        guard let languages, let url else { return }
        Task { [weak self] in
            if let failure = await languages.run(lens, in: url) { self?.onFailure(failure) }
        }
    }
}

/// One line's lenses, separated by dots; the ones that run something are
/// links: the text color and a hand on hover.
private final class CodeLensView: NSView {
    struct Segment {
        let lens: CodeLens
    }

    private let segments: [Segment]
    private let font: NSFont
    private let colors: CodeLensController.Colors
    private let run: (CodeLens) -> Void
    private var hovered: Int?
    private var frames: [CGRect] = []

    init(frame: CGRect, segments: [Segment], font: NSFont, colors: CodeLensController.Colors, run: @escaping (CodeLens) -> Void) {
        self.segments = segments
        self.font = font
        self.colors = colors
        self.run = run
        super.init(frame: frame)
        var x: CGFloat = 0
        for segment in segments {
            let width = ceil((segment.lens.title as NSString).size(withAttributes: [.font: font]).width)
            frames.append(CGRect(x: x, y: 0, width: width, height: frame.height))
            x += width + Self.separatorWidth(font)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func separatorWidth(_ font: NSFont) -> CGFloat {
        ceil((" · " as NSString).size(withAttributes: [.font: font]).width)
    }

    static func width(of segments: [Segment], font: NSFont) -> CGFloat {
        let titles = segments.map { ceil(($0.lens.title as NSString).size(withAttributes: [.font: font]).width) }
        return titles.reduce(0, +) + CGFloat(max(0, segments.count - 1)) * separatorWidth(font) + 2
    }

    private func segment(at point: NSPoint) -> Int? {
        frames.indices.first { frames[$0].contains(point) && segments[$0].lens.isActionable }
    }

    /// Only actionable segments take the mouse; the rest of the strip is the text view's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview.map({ convert(point, from: $0) }), segment(at: local) != nil else { return nil }
        return self
    }

    override func resetCursorRects() {
        for (index, frame) in frames.enumerated() where segments[index].lens.isActionable {
            addCursorRect(frame, cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let index = segment(at: convert(event.locationInWindow, from: nil))
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = segment(at: convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        run(segments[index].lens)
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = font.ascender - font.descender + font.leading
        let y = (bounds.height - height) / 2
        for (index, segment) in segments.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: index == hovered ? colors.active : colors.text,
            ]
            if index == hovered { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            let frame = frames[index]
            (segment.lens.title as NSString).draw(in: CGRect(x: frame.minX, y: y, width: frame.width + 1, height: height), withAttributes: attributes)
            if index < segments.count - 1 {
                (" · " as NSString).draw(at: CGPoint(x: frame.maxX, y: y), withAttributes: [.font: font, .foregroundColor: colors.text])
            }
        }
    }
}

struct CodeLensPlugin: STPlugin {
    let controller: CodeLensController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.setNeedsLayout() }
        }
    }
}
