import AppKit
@_spi(Plugins) import STTextView

/// Line numbers drawn in one pass by a scroll-view ruler. Replaces STTextView's
/// gutter, which rebuilt a view per visible line and enumerated every paragraph
/// above the viewport on each layout — scrolling got slower the deeper you went.
/// Here a line's number is a binary search in cached line starts.
@MainActor
final class LineNumberRuler: NSRulerView {
    private weak var textView: STTextView?
    private var lineStarts: [Int] = [0]
    private var storageObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let leadingPadding: CGFloat = 12
    private let trailingPadding: CGFloat = 10

    init(textView: STTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // Views don't clip by default since macOS 14, and the dirty rect can reach past
        // the ruler: without this the background fill painted over the whole editor.
        clipsToBounds = true
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        reloadLineStarts()

        if let storage = (textView.textContentManager as? NSTextContentStorage)?.textStorage {
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadLineStarts() }
            }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    isolated deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    override var isFlipped: Bool { true }

    private func reloadLineStarts() {
        guard let storage = (textView?.textContentManager as? NSTextContentStorage)?.textStorage else { return }
        lineStarts = InlineDiffController.lineStarts(of: storage.string as NSString)
        let digits = max(3, String(lineStarts.count).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + leadingPadding + trailingPadding)
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }
        needsDisplay = true
    }

    /// 0-based line containing a UTF-16 offset.
    private func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()

        guard let textView else { return }
        let manager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        guard let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let documentStart = manager.documentRange.location
        let content = textView.contentFrame
        let currentLine = line(at: textView.textSelection.location)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let currentAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]

        func drawNumber(_ index: Int, baseline: CGFloat) {
            let point = convert(NSPoint(x: 0, y: baseline), from: textView)
            guard point.y + font.descender < dirtyRect.maxY + 20, point.y - font.ascender > dirtyRect.minY - 20 else { return }
            let label = "\(index + 1)" as NSString
            let style = index == currentLine ? currentAttributes : attributes
            let width = label.size(withAttributes: style).width
            label.draw(at: NSPoint(x: ruleThickness - trailingPadding - width, y: point.y - font.ascender), withAttributes: style)
        }

        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            let start = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let index = line(at: start)
            let frame = fragment.layoutFragmentFrame
            for (position, lineFragment) in fragment.textLineFragments.enumerated() {
                // Wrapped continuation lines get no number; the empty line after a final
                // newline (an "extra" fragment with no characters) does.
                let isExtra = lineFragment.characterRange.length == 0 && position > 0
                guard position == 0 || isExtra else { continue }
                let bounds = lineFragment.typographicBounds
                let baseline = content.minY + frame.minY + bounds.minY + lineFragment.glyphOrigin.y
                drawNumber(isExtra ? lineStarts.count - 1 : index, baseline: baseline)
            }
            return true
        }
    }
}

/// Redraws the numbers when the viewport is laid out again (resize, inline diff gaps).
struct LineNumberRulerPlugin: STPlugin {
    let ruler: LineNumberRuler

    func setUp(context: any Context) {
        let ruler = ruler
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { ruler.needsDisplay = true }
        }
    }
}
