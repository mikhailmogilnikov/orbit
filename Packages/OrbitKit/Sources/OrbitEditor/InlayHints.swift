import AppKit
import OrbitAPI
@_spi(Plugins) import STTextView

/// Inlay hints from the language server: types and parameter names drawn
/// between characters. The room for a label is a `.kern` on the character
/// before it (a text-storage attribute, like the inline diff's gaps, so
/// nothing enters the text or its undo); the label is a small view in that
/// room, made only for hints in the viewport.
@MainActor
final class InlayHintController {
    weak var textView: STTextView?
    /// Shares the squiggles' text geometry (line starts, rects).
    let geometry: DiagnosticsController
    weak var languages: LanguageIntelligence?
    var url: URL?

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { refresh() } else { clear() }
        }
    }

    struct Colors: Equatable {
        var text: NSColor = .secondaryLabelColor
        var background: NSColor = .clear
    }

    var colors = Colors() {
        didSet { if colors != oldValue { setNeedsLayout() } }
    }

    /// Hints by the offset they sit before, in the server's order.
    private var hints: [Int: [InlayHint]] = [:]
    /// The text the hints were fetched for; scrolling past it fetches more.
    private var covered = IndexSet()
    /// Offsets of the characters carrying our kern, and how much.
    private var kerned: [Int: CGFloat] = [:]
    private let overlays = OverlaySet()
    private var request: Task<Void, Never>?
    private var isFetching = false
    private var isLayoutScheduled = false

    init(geometry: DiagnosticsController) {
        self.geometry = geometry
    }

    private var storage: NSTextStorage? {
        (textView?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    // MARK: Fetching

    /// Asks for the hints around the viewport again (after a pause when typing).
    func refresh(after delay: Duration = .zero) {
        request?.cancel()
        guard isEnabled, let languages, let url else { return }
        isFetching = true
        request = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            defer { isFetching = false }
            guard let range = wantedRange() else { return }
            let starts = geometry.lineStarts, length = geometry.length
            let source = SourceRange(start: SourcePosition(offset: range.location, in: starts), end: SourcePosition(offset: NSMaxRange(range), in: starts))
            let found = await languages.inlayHints(in: source, url: url)
            // An edit while waiting makes the answer stale; the edit asks again.
            guard !Task.isCancelled, length == geometry.length else { return }
            show(found, in: range)
        }
    }

    /// The viewport and a screen above and below it, whole lines.
    private func wantedRange() -> NSRange? {
        guard let textView, let string = geometry.string,
              let viewport = textView.textLayoutManager.textViewportLayoutController.viewportRange else { return nil }
        let visible = NSRange(viewport, in: textView.textContentManager)
        let margin = max(visible.length, 2048)
        let lower = max(0, visible.location - margin)
        let upper = min(string.length, NSMaxRange(visible) + margin)
        return string.lineRange(for: NSRange(location: lower, length: upper - lower))
    }

    private func show(_ found: [InlayHint], in range: NSRange) {
        let starts = geometry.lineStarts, length = geometry.length
        for offset in hints.keys where NSLocationInRange(offset, range) || offset == NSMaxRange(range) {
            hints[offset] = nil
        }
        for hint in found {
            let offset = hint.position.offset(in: starts, length: length)
            guard NSLocationInRange(offset, range) || offset == NSMaxRange(range) else { continue }
            hints[offset, default: []].append(hint)
        }
        covered.insert(integersIn: Range(range) ?? 0..<0)
        applyKerns()
    }

    /// The viewport moved: fetch what it shows if that wasn't covered yet.
    func viewportDidChange() {
        guard isEnabled, let range = wantedRange(), let visible = Range(range) else { return }
        if !isFetching, !covered.contains(integersIn: visible) {
            refresh(after: .milliseconds(100))
        }
        setNeedsLayout()
    }

    // MARK: Edits

    /// The user edited: hints move with the text until fresh ones arrive.
    func textDidChange(_ edit: TextEdit) {
        guard !hints.isEmpty || !kerned.isEmpty else {
            if isEnabled { refresh(after: .milliseconds(500)) }
            return
        }
        let end = NSMaxRange(edit.range)
        var moved: [Int: [InlayHint]] = [:]
        for (offset, list) in hints where !(edit.range.location < offset && offset < end) {
            moved[edit.map(offset), default: []] += list
        }
        hints = moved
        // Characters, unlike the gaps between them, move when text goes in before them.
        var carriers: [Int: CGFloat] = [:]
        for (offset, amount) in kerned where !NSLocationInRange(offset, edit.range) {
            carriers[offset < edit.range.location ? offset : offset + edit.delta] = amount
        }
        kerned = carriers
        // Typed text takes the attributes of the character before it, our kern included.
        stripKern(in: NSRange(location: edit.range.location, length: edit.newLength))
        covered.removeAll()
        applyKerns()
        refresh(after: .milliseconds(500))
    }

    /// The whole text was replaced (an agent edit, a reload): start over.
    func textWasReplaced() {
        hints.removeAll()
        kerned.removeAll()
        covered.removeAll()
        removeOverlays()
        refresh(after: .milliseconds(300))
    }

    /// Labels are measured in the editor's font.
    func fontDidChange() {
        applyKerns()
    }

    func clear() {
        request?.cancel()
        hints.removeAll()
        covered.removeAll()
        applyKerns()
        removeOverlays()
    }

    // MARK: Room in the text

    var labelFont: NSFont {
        let size = textView?.font.pointSize ?? 13
        let font = textView?.font ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return NSFont(descriptor: font.fontDescriptor, size: (size * 0.88).rounded()) ?? font
    }

    private static let inset: CGFloat = 3
    private static let margin: CGFloat = 2
    private static let padding: CGFloat = 3

    /// How wide the labels at one spot are, each with its capsule and margins.
    private func widths(of list: [InlayHint]) -> [CGFloat] {
        let font = labelFont
        return list.map { hint in
            let text = (hint.label as NSString).size(withAttributes: [.font: font]).width
            return ceil(text) + 2 * Self.inset + 2 * Self.margin
                + (hint.paddingLeft ? Self.padding : 0) + (hint.paddingRight ? Self.padding : 0)
        }
    }

    /// The character the room goes after; a hint at a line's start has none.
    private func carrier(of offset: Int, in string: NSString) -> Int? {
        guard offset > 0, offset <= string.length, string.character(at: offset - 1) != 0x0A else { return nil }
        return offset - 1
    }

    /// Makes the kerns match the hints, touching only characters that differ.
    private func applyKerns() {
        guard let textView, let storage, let string = geometry.string else { return }
        var wanted: [Int: CGFloat] = [:]
        if isEnabled {
            for (offset, list) in hints {
                guard let carrier = carrier(of: offset, in: string) else { continue }
                wanted[carrier] = widths(of: list).reduce(0, +)
            }
        }
        let length = storage.length
        let stale = kerned.filter { wanted[$0.key] != $0.value && $0.key < length }
        let new = wanted.filter { kerned[$0.key] != $0.value }
        kerned = wanted
        guard !stale.isEmpty || !new.isEmpty else {
            setNeedsLayout()
            return
        }
        textView.textContentManager.performEditingTransaction {
            storage.beginEditing()
            for offset in stale.keys where wanted[offset] == nil {
                storage.removeAttribute(.kern, range: NSRange(location: offset, length: 1))
            }
            for (offset, amount) in new {
                storage.addAttribute(.kern, value: amount, range: NSRange(location: offset, length: 1))
            }
            storage.endEditing()
        }
        setNeedsLayout()
    }

    private func stripKern(in range: NSRange) {
        guard let textView, let storage, range.length > 0, NSMaxRange(range) <= storage.length else { return }
        var found: [NSRange] = []
        storage.enumerateAttribute(.kern, in: range) { value, subrange, _ in
            if value != nil { found.append(subrange) }
        }
        guard !found.isEmpty else { return }
        textView.textContentManager.performEditingTransaction {
            storage.beginEditing()
            for subrange in found { storage.removeAttribute(.kern, range: subrange) }
            storage.endEditing()
        }
    }

    // MARK: Labels

    func setNeedsLayout() {
        guard !isLayoutScheduled else { return }
        isLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isLayoutScheduled = false
            self?.layoutOverlays()
        }
    }

    private func removeOverlays() {
        overlays.removeAll()
    }

    private func layoutOverlays() {
        defer { overlays.commit() }
        guard let textView, isEnabled, !hints.isEmpty, let string = geometry.string else { return }
        let manager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        guard let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let start = manager.documentRange.location
        let lower = contentManager.offset(from: start, to: viewport.location)
        let upper = contentManager.offset(from: start, to: viewport.endLocation)
        let visible = textView.visibleRect.insetBy(dx: -200, dy: -200)
        let font = labelFont
        for (offset, list) in hints where offset > lower && offset <= upper {
            guard let carrier = carrier(of: offset, in: string), let room = kerned[carrier],
                  let rect = geometry.rects(for: NSRange(location: carrier, length: 1)).first else { continue }
            // TextKit gives the character half the room in its caret rect; the
            // glyph after it is drawn after all of it.
            let x = rect.maxX - room / 2
            guard rect.intersects(visible) || CGRect(x: x, y: rect.minY, width: room, height: rect.height).intersects(visible) else { continue }
            for label in labels(for: list) {
                let frame = CGRect(x: x + label.x, y: rect.minY + 1, width: label.width, height: max(rect.height - 2, 1)).integral
                let colors = colors
                overlays.place(frame, label.text, font, colors.text, colors.background, frame: frame, in: textView) {
                    InlayHintView(frame: frame, label: label.text, font: font, colors: colors)
                }
            }
        }
    }

    /// A label's capsule, from the start of its room.
    struct Label {
        var text: String
        var x: CGFloat
        var width: CGFloat
    }

    private func labels(for list: [InlayHint]) -> [Label] {
        var x: CGFloat = 0
        return zip(list, widths(of: list)).map { hint, width in
            let left = Self.margin + (hint.paddingLeft ? Self.padding : 0)
            let right = Self.margin + (hint.paddingRight ? Self.padding : 0)
            defer { x += width }
            return Label(text: hint.label, x: x + left, width: width - left - right)
        }
    }

    /// The rooms in a range (the character carrying each, its width) with their
    /// labels, for views that draw lines themselves (sticky scroll).
    func rooms(in range: NSRange) -> [(carrier: Int, width: CGFloat, labels: [Label])] {
        guard isEnabled, let string = geometry.string else { return [] }
        return hints.compactMap { offset, list in
            guard let carrier = carrier(of: offset, in: string), NSLocationInRange(carrier, range),
                  let room = kerned[carrier] else { return nil }
            return (carrier, room, labels(for: list))
        }
    }
}

/// One hint's label on a soft capsule.
private final class InlayHintView: NSView {
    private let label: NSAttributedString

    init(frame: CGRect, label: String, font: NSFont, colors: InlayHintController.Colors) {
        self.label = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: colors.text])
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.backgroundColor = colors.background.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// Re-places the labels whenever the viewport is laid out, and fetches hints for new text scrolled into view.
struct InlayHintPlugin: STPlugin {
    let controller: InlayHintController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.viewportDidChange() }
        }
    }
}
