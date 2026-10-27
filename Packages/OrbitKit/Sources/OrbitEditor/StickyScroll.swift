import AppKit
import OrbitAPI
@_spi(Plugins) import STTextView

/// Sticky scroll (D82), as in VS Code and Zed: the first lines of the scopes
/// the top of the view is inside (a class, its method) stay pinned above the
/// text, so you always see where you are. Scopes are the folding regions
/// (the server's, else indentation). The pinned lines are drawn by one view
/// over the editor and its gutter, with the highlighter's colors; nothing in
/// the text changes, and it's recomputed only when the view scrolls or the regions change.
@MainActor
final class StickyScrollController {
    weak var textView: STTextView?
    weak var ruler: LineNumberRuler?
    let geometry: DiagnosticsController
    let folding: FoldingController
    let palette: SyntaxPalette
    /// Their room is in the copied text (a kern); the labels are drawn here too.
    weak var inlayHints: InlayHintController?
    /// Clicking a pinned line goes to it.
    var onReveal: ((Int) -> Void)?

    var isEnabled = true {
        didSet { if isEnabled != oldValue { update() } }
    }

    struct Colors: Equatable {
        var background: NSColor = .textBackgroundColor
        var number: NSColor = .tertiaryLabelColor
        var text: NSColor = .textColor
        var separator: NSColor = .separatorColor
    }

    var colors = Colors() {
        didSet { if colors != oldValue { view?.needsDisplay = true } }
    }

    static let maxLines = 5
    private var view: StickyHeaderView?
    private var isUpdateScheduled = false

    init(geometry: DiagnosticsController, folding: FoldingController, palette: SyntaxPalette) {
        self.geometry = geometry
        self.folding = folding
        self.palette = palette
    }

    /// Coalesced: scrolling and layout both ask, once per run loop turn is enough.
    func setNeedsUpdate() {
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isUpdateScheduled = false
            self?.update()
        }
    }

    func update() {
        guard isEnabled, let textView, let scrollView = textView.enclosingScrollView,
              let storage = (textView.textContentManager as? NSTextContentStorage)?.textStorage,
              let lineHeight = lineHeight() else {
            hide()
            return
        }
        let visible = textView.visibleRect
        let regions = folding.foldableRegions
        guard visible.minY > 0, !regions.isEmpty else {
            hide()
            return
        }
        let string = storage.string as NSString
        let starts = geometry.lineStarts

        // The scopes around the first line below the pinned ones; more pinned lines push that line down, so repeat until it settles.
        var chain: [(start: Int, end: Int)] = []
        for _ in 0...Self.maxLines {
            guard let top = line(atY: visible.minY + CGFloat(chain.count) * lineHeight + 1) else { break }
            let found = regions.filter { $0.key < top && top <= $0.value && !isComment(line: $0.key, in: string, starts: starts) }
                .sorted { $0.key < $1.key }
                .suffix(Self.maxLines)
                .map { (start: $0.key, end: $0.value) }
            if found.map(\.start) == chain.map(\.start) { break }
            chain = Array(found)
        }
        guard !chain.isEmpty else {
            hide()
            return
        }

        // A scope about to end pushes its line (and the ones under it) up, out of the way.
        var rows: [StickyHeaderView.Row] = []
        var previous = -lineHeight
        for (index, scope) in chain.enumerated() {
            var y = CGFloat(index) * lineHeight
            if let end = lineBottom(scope.end) { y = min(y, end - visible.minY - lineHeight) }
            y = min(y, previous + lineHeight)
            previous = y
            guard y > -lineHeight + 0.5 else { continue }
            let (text, hints) = attributedLine(scope.start, in: storage, starts: starts)
            rows.append(StickyHeaderView.Row(line: scope.start, y: y, text: text, hints: hints))
        }
        guard let last = rows.last else {
            hide()
            return
        }

        let height = ceil(last.y + lineHeight)
        let origin = scrollView.convert(NSPoint(x: 0, y: visible.minY), from: textView)
        let frame = NSRect(x: 0, y: origin.y, width: scrollView.bounds.width, height: height)
        let view = self.view ?? StickyHeaderView()
        if view.superview !== scrollView {
            view.onClick = { [weak self] line in self?.onReveal?(line) }
            scrollView.addSubview(view, positioned: .above, relativeTo: scrollView.contentView)
            self.view = view
        }
        let textX = scrollView.convert(NSPoint(x: textView.contentFrame.minX + textView.textContainer.lineFragmentPadding, y: 0), from: textView).x
        view.configure(
            frame: frame, rows: rows, lineHeight: lineHeight, textX: textX,
            gutterWidth: ruler?.ruleThickness ?? 0, numberEdge: ruler?.numberTrailingEdge ?? 0,
            numberFont: ruler?.font ?? .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            baselineOffset: baselineOffset() ?? lineHeight * 0.75, colors: colors,
            hintFont: inlayHints?.labelFont ?? .monospacedSystemFont(ofSize: 11, weight: .regular),
            hintColors: inlayHints?.colors ?? InlayHintController.Colors()
        )
    }

    private func hide() {
        view?.removeFromSuperview()
        view = nil
    }

    // MARK: Geometry

    /// A line's height, from any line laid out.
    private func lineHeight() -> CGFloat? {
        guard let textView, let viewport = textView.textLayoutManager.textViewportLayoutController.viewportRange,
              let fragment = textView.textLayoutManager.textLayoutFragment(for: viewport.location),
              let line = fragment.textLineFragments.first else { return nil }
        return line.typographicBounds.height
    }

    /// From a line's top to its text's baseline.
    private func baselineOffset() -> CGFloat? {
        guard let textView, let viewport = textView.textLayoutManager.textViewportLayoutController.viewportRange,
              let line = textView.textLayoutManager.textLayoutFragment(for: viewport.location)?.textLineFragments.first else { return nil }
        return line.glyphOrigin.y
    }

    private func line(atY y: CGFloat) -> Int? {
        guard let textView else { return nil }
        let manager = textView.textLayoutManager
        guard let fragment = manager.textLayoutFragment(for: CGPoint(x: 0, y: y - textView.contentFrame.minY)) else { return nil }
        let offset = textView.textContentManager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
        return SourcePosition(offset: offset, in: geometry.lineStarts).line
    }

    /// The bottom of a line in text-view coordinates, if it's in the viewport (only then can it push anything).
    private func lineBottom(_ line: Int) -> CGFloat? {
        guard let textView else { return nil }
        let starts = geometry.lineStarts
        guard line < starts.count,
              let viewport = textView.textLayoutManager.textViewportLayoutController.viewportRange else { return nil }
        let content = textView.textContentManager
        let documentStart = content.documentRange.location
        guard content.offset(from: documentStart, to: viewport.location) <= starts[line],
              content.offset(from: documentStart, to: viewport.endLocation) > starts[line],
              let location = content.location(documentStart, offsetBy: starts[line]),
              let fragment = textView.textLayoutManager.textLayoutFragment(for: location) else { return nil }
        return fragment.layoutFragmentFrame.maxY + textView.contentFrame.minY
    }

    /// Doc comments fold too, but a comment isn't where you are. A line the
    /// text no longer has (the regions lag an undone paste of thousands of
    /// lines, D250) isn't pinned either.
    private func isComment(line: Int, in string: NSString, starts: [Int]) -> Bool {
        guard line >= 0, line < starts.count, starts[line] <= string.length else { return true }
        let range = string.lineRange(for: NSRange(location: starts[line], length: 0))
        let text = string.substring(with: range).trimmingCharacters(in: .whitespaces)
        return ["/*", "//", "*", "#", "<!--", "\"\"\"", "'''", "--"].contains { text.hasPrefix($0) }
    }

    private func attributedLine(_ line: Int, in storage: NSTextStorage, starts: [Int]) -> (NSAttributedString, [StickyHeaderView.Hint]) {
        let string = storage.string as NSString
        var range = string.lineRange(for: NSRange(location: starts[line], length: 0))
        while range.length > 0, [0x0A, 0x0D].contains(string.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let whole = NSRange(location: 0, length: text.length)
        text.removeAttribute(.paragraphStyle, range: whole)
        text.addAttribute(.foregroundColor, value: colors.text, range: whole)
        for run in palette.colors?(range) ?? [] {
            let local = NSRange(location: run.range.location - range.location, length: run.range.length)
            text.addAttribute(.foregroundColor, value: run.color, range: local)
            if let font = run.font { text.addAttribute(.font, value: font, range: local) }
        }
        let rooms = inlayHints?.rooms(in: range) ?? []
        guard !rooms.isEmpty else { return (text, []) }
        // The room starts where the carrier's glyph ends. Measured with that kern
        // removed: CoreText puts the offset after a kerned character in the middle of its kern.
        let hints = rooms.flatMap { room in
            let local = room.carrier - range.location
            let measured = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: 0, length: local + 1)))
            measured.removeAttribute(.kern, range: NSRange(location: local, length: 1))
            let start = CTLineGetOffsetForStringIndex(CTLineCreateWithAttributedString(measured), local + 1, nil)
            return room.labels.map { StickyHeaderView.Hint(text: $0.text, x: start + $0.x, width: $0.width) }
        }
        return (text, hints)
    }
}

/// The pinned lines: numbers in the gutter's place, code where the text is.
final class StickyHeaderView: NSView {
    struct Row {
        var line: Int
        var y: CGFloat
        var text: NSAttributedString
        var hints: [Hint]
    }

    /// An inlay hint's label, from the start of the text.
    struct Hint {
        var text: String
        var x: CGFloat
        var width: CGFloat
    }

    var onClick: ((Int) -> Void)?
    private var rows: [Row] = []
    private var lineHeight: CGFloat = 16
    private var textX: CGFloat = 0
    private var gutterWidth: CGFloat = 0
    private var numberEdge: CGFloat = 0
    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var baselineOffset: CGFloat = 12
    private var colors = StickyScrollController.Colors()
    private var hintFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private var hintColors = InlayHintController.Colors()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(
        frame: NSRect, rows: [Row], lineHeight: CGFloat, textX: CGFloat, gutterWidth: CGFloat,
        numberEdge: CGFloat, numberFont: NSFont, baselineOffset: CGFloat, colors: StickyScrollController.Colors,
        hintFont: NSFont, hintColors: InlayHintController.Colors
    ) {
        if self.frame != frame { self.frame = frame }
        self.rows = rows
        self.lineHeight = lineHeight
        self.textX = textX
        self.gutterWidth = gutterWidth
        self.numberEdge = numberEdge
        self.numberFont = numberFont
        self.baselineOffset = baselineOffset
        self.colors = colors
        self.hintFont = hintFont
        self.hintColors = hintColors
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        colors.background.setFill()
        bounds.fill()
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: colors.number]
        for row in rows {
            let baseline = row.y + baselineOffset
            let number = "\(row.line + 1)" as NSString
            let width = number.size(withAttributes: numberAttributes).width
            number.draw(at: NSPoint(x: numberEdge - width, y: baseline - numberFont.ascender), withAttributes: numberAttributes)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: gutterWidth, y: row.y, width: bounds.width - gutterWidth, height: lineHeight).clip()
            let font = row.text.length > 0 ? row.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
            row.text.draw(at: NSPoint(x: textX, y: baseline - (font?.ascender ?? baselineOffset)))
            drawHints(row)
            NSGraphicsContext.restoreGraphicsState()
        }
        colors.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// Same capsules as `InlayHintView` in the editor.
    private func drawHints(_ row: Row) {
        let attributes: [NSAttributedString.Key: Any] = [.font: hintFont, .foregroundColor: hintColors.text]
        for hint in row.hints {
            let frame = NSRect(x: textX + hint.x, y: row.y + 1, width: hint.width, height: max(lineHeight - 2, 1)).integral
            hintColors.background.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).fill()
            let label = NSAttributedString(string: hint.text, attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: frame.minX + (frame.width - size.width) / 2, y: frame.minY + (frame.height - size.height) / 2))
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = rows.last(where: { $0.y <= point.y }) else { return }
        onClick?(row.line)
    }

    /// Scrolling over the pinned lines scrolls the text.
    override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }
}

/// Updates the pinned lines whenever the viewport is laid out.
struct StickyScrollPlugin: STPlugin {
    let controller: StickyScrollController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.setNeedsUpdate() }
        }
    }
}
