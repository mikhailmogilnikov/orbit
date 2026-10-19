import AppKit
import OrbitAPI
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
    /// Git change bars at the leading edge.
    var changeMarkers = LineMarkers() {
        didSet { if changeMarkers != oldValue { needsDisplay = true } }
    }
    /// Header lines of foldable regions, true when folded (D79). Open ones show
    /// their chevron only while the pointer is over the gutter, as in VS Code.
    var folds: [Int: Bool] = [:] {
        didSet { if folds != oldValue { needsDisplay = true } }
    }
    var onToggleFold: ((Int) -> Void)?
    /// Who changed each line (D135), in a column left of the numbers; nil hides it.
    var blame: [LineBlame]? {
        didSet {
            guard blame != oldValue else { return }
            if (blame == nil) != (oldValue == nil) { reloadLineStarts() } else { needsDisplay = true }
        }
    }
    /// A click on a line's blame: show its commit.
    var onBlameClick: ((LineBlame) -> Void)?
    /// Images lines refer to (D146), drawn small in a column of their own.
    var images: [Int: URL] = [:] {
        didSet {
            guard images != oldValue else { return }
            thumbnails.clear()
            if images.isEmpty != oldValue.isEmpty { reloadLineStarts() } else { needsDisplay = true }
        }
    }
    var onImageClick: ((URL) -> Void)?
    private lazy var thumbnails: ThumbnailCache = {
        let cache = ThumbnailCache()
        cache.onLoad = { [weak self] in self?.needsDisplay = true }
        return cache
    }()
    private var imageColumn: CGFloat { images.isEmpty ? 0 : Self.imageWidth }
    private static let imageWidth: CGFloat = 20
    private var imagePopover: NSPopover?
    private var popoverLine: Int?
    private var blameColumn: CGFloat { blame == nil ? 0 : Self.blameWidth }
    private static let blameWidth: CGFloat = 210
    private let blameFont = NSFont.systemFont(ofSize: 10.5)
    private var isPointerInside = false
    private var trackingArea: NSTrackingArea?

    struct Colors {
        var background: NSColor = .textBackgroundColor
        var number: NSColor = .tertiaryLabelColor
        var currentNumber: NSColor = .secondaryLabelColor
        var added: NSColor = .systemGreen
        var modified: NSColor = .systemBlue
        var deleted: NSColor = .systemRed
    }

    var colors = Colors() {
        didSet { needsDisplay = true }
    }

    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let leadingPadding: CGFloat = 12
    private let trailingPadding: CGFloat = 4
    private static let foldColumn: CGFloat = 14
    /// Where numbers end on the right; sticky headers draw theirs there too.
    var numberTrailingEdge: CGFloat { ruleThickness - Self.foldColumn - trailingPadding }

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
            // Posted synchronously on the main thread, while `editedMask` is still set.
            // Attribute-only edits (highlight fonts, inline diff gaps) leave lines alone.
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
            ) { [weak self] notification in
                let edited = (notification.object as? NSTextStorage)?.editedMask.contains(.editedCharacters) ?? true
                guard edited else { return }
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
        let thickness = ceil(CGFloat(digits) * digitWidth + leadingPadding + trailingPadding + Self.foldColumn + blameColumn + imageColumn)
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
        colors.background.setFill()
        dirtyRect.intersection(bounds).fill()

        guard let textView else { return }
        let manager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        guard let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let documentStart = manager.documentRange.location
        let content = textView.contentFrame
        let currentLine = line(at: textView.textSelection.location)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.number]
        let currentAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.currentNumber]

        func drawNumber(_ index: Int, baseline: CGFloat) {
            let point = convert(NSPoint(x: 0, y: baseline), from: textView)
            guard point.y + font.descender < dirtyRect.maxY + 20, point.y - font.ascender > dirtyRect.minY - 20 else { return }
            let label = "\(index + 1)" as NSString
            let style = index == currentLine ? currentAttributes : attributes
            let width = label.size(withAttributes: style).width
            label.draw(at: NSPoint(x: ruleThickness - Self.foldColumn - trailingPadding - width, y: point.y - font.ascender), withAttributes: style)
            if let folded = folds[index], folded || isPointerInside {
                drawChevron(folded: folded, centerY: point.y - font.ascender + font.capHeight / 2 + (font.ascender - font.capHeight))
            }
        }

        var firstVisibleLine: Int?
        if blame != nil {
            NSColor.separatorColor.setFill()
            NSRect(x: blameColumn - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).intersection(bounds).fill()
        }
        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            let start = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let index = line(at: start)
            let frame = fragment.layoutFragmentFrame
            if !changeMarkers.isEmpty, let first = fragment.textLineFragments.first {
                // The line's own text, not the inline-diff gap above it.
                let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 || $0 === first }
                let top = convert(NSPoint(x: 0, y: content.minY + frame.minY + first.typographicBounds.minY), from: textView).y
                let bottom = convert(NSPoint(x: 0, y: content.minY + frame.minY + (lines.last ?? first).typographicBounds.maxY), from: textView).y
                drawMarker(for: index, top: top, bottom: bottom)
                // A deletion at the very end shows below the last line.
                if index == lineStarts.count - 1, changeMarkers.deletedAbove.contains(lineStarts.count) {
                    drawDeletion(at: bottom)
                }
            }
            if let blame, index < blame.count, let first = fragment.textLineFragments.first {
                let top = convert(NSPoint(x: 0, y: content.minY + frame.minY + first.typographicBounds.minY), from: textView).y
                let height = first.typographicBounds.height
                // A run of lines from one commit names it once, on its first line.
                let startsRun = index == 0 || index - 1 >= blame.count || blame[index - 1].hash != blame[index].hash || index == firstVisibleLine
                drawBlame(blame[index], top: top, height: height, label: startsRun)
            }
            if let url = images[index], let first = fragment.textLineFragments.first {
                let top = convert(NSPoint(x: 0, y: content.minY + frame.minY + first.typographicBounds.minY), from: textView).y
                drawThumbnail(url, in: thumbnailRect(top: top, height: first.typographicBounds.height))
            }
            if firstVisibleLine == nil { firstVisibleLine = index }
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

    private func thumbnailRect(top: CGFloat, height: CGFloat) -> NSRect {
        let side = min(16, max(10, height))
        return NSRect(x: markerX + Self.markerWidth + 3, y: top + (height - side) / 2, width: side, height: side)
    }

    /// Fit into a rounded square; a hairline keeps a white image visible on white.
    private func drawThumbnail(_ url: URL, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        guard let image = thumbnails.image(for: url), image.size.width > 0, image.size.height > 0 else {
            colors.number.withAlphaComponent(0.15).setFill()
            path.fill()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(
            in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()
        colors.number.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    /// An age bar (strong for this week, faint for last year), then "Author · 3mo".
    private func drawBlame(_ line: LineBlame, top: CGFloat, height: CGFloat, label: Bool) {
        let age = Date().timeIntervalSince(line.date)
        let freshness = line.isCommitted ? max(0.12, 1 - min(1, age / (365 * 86_400))) : 1
        (line.isCommitted ? colors.modified : colors.added).withAlphaComponent(0.75 * freshness).setFill()
        NSRect(x: 2, y: top, width: 2, height: height).fill()
        guard label else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let when = line.isCommitted ? Self.shortAge(age) : ""
        let whenAttributes: [NSAttributedString.Key: Any] = [.font: blameFont, .foregroundColor: colors.number]
        let whenWidth = (when as NSString).size(withAttributes: whenAttributes).width
        let right = blameColumn - 8
        let y = top + (height - blameFont.ascender + blameFont.descender) / 2
        (when as NSString).draw(at: NSPoint(x: right - whenWidth, y: y), withAttributes: whenAttributes)
        let name = line.isCommitted ? line.author : "Not committed"
        (name as NSString).draw(
            with: NSRect(x: 9, y: y, width: max(0, right - whenWidth - 15), height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: blameFont, .foregroundColor: colors.currentNumber, .paragraphStyle: style]
        )
    }

    /// "now", "5m", "3h", "2d", "4w", "3mo", "2y".
    nonisolated static func shortAge(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60), hours = minutes / 60, days = hours / 24
        if minutes < 1 { return "now" }
        if hours < 1 { return "\(minutes)m" }
        if days < 1 { return "\(hours)h" }
        if days < 14 { return "\(days)d" }
        if days < 60 { return "\(days / 7)w" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }

    private func drawChevron(folded: Bool, centerY: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [folded ? colors.currentNumber : colors.number]))
        guard let image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let x = ruleThickness - Self.foldColumn + (Self.foldColumn - size.width) / 2 - 2
        image.draw(in: NSRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        if !folds.isEmpty { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        if !folds.isEmpty { needsDisplay = true }
        closeImagePopover()
    }

    /// Over a thumbnail: the image bigger, beside the gutter.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let line = imageLine(at: point), let url = images[line] else { return closeImagePopover() }
        guard popoverLine != line else { return }
        closeImagePopover()
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0,
              let rect = imageRect(forLine: line) else { return }
        let scale = min(1, 240 / image.size.width, 240 / image.size.height)
        let size = NSSize(width: max(24, image.size.width * scale), height: max(24, image.size.height * scale))
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [view, label])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.animates = false
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxX)
        imagePopover = popover
        popoverLine = line
    }

    private func closeImagePopover() {
        imagePopover?.close()
        imagePopover = nil
        popoverLine = nil
    }

    private func imageLine(at point: NSPoint) -> Int? {
        guard !images.isEmpty, point.x >= markerX, point.x < markerX + Self.markerWidth + imageColumn,
              let line = line(atRulerY: point.y), images[line] != nil else { return nil }
        return line
    }

    private func imageRect(forLine line: Int) -> NSRect? {
        guard let textView, line < lineStarts.count,
              let location = textView.textContentManager.location(textView.textLayoutManager.documentRange.location, offsetBy: lineStarts[line]),
              let fragment = textView.textLayoutManager.textLayoutFragment(for: location),
              let first = fragment.textLineFragments.first else { return nil }
        let frame = fragment.layoutFragmentFrame
        let top = convert(NSPoint(x: 0, y: textView.contentFrame.minY + frame.minY + first.typographicBounds.minY), from: textView).y
        return thumbnailRect(top: top, height: first.typographicBounds.height)
    }

    /// A click on a line with a chevron folds or unfolds its region.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < blameColumn, let blame, let line = line(atRulerY: point.y), line < blame.count, blame[line].isCommitted {
            onBlameClick?(blame[line])
            return
        }
        if let line = imageLine(at: point), let url = images[line] {
            closeImagePopover()
            onImageClick?(url)
            return
        }
        guard let line = line(atRulerY: point.y), folds[line] != nil else {
            super.mouseDown(with: event)
            return
        }
        onToggleFold?(line)
    }

    /// The line drawn at a height in the ruler, among those laid out.
    private func line(atRulerY y: CGFloat) -> Int? {
        guard let textView else { return nil }
        let manager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        guard let viewport = manager.textViewportLayoutController.viewportRange else { return nil }
        let documentStart = manager.documentRange.location
        let content = textView.contentFrame
        var found: Int?
        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            guard let first = fragment.textLineFragments.first else { return true }
            let frame = fragment.layoutFragmentFrame
            let top = convert(NSPoint(x: 0, y: content.minY + frame.minY + first.typographicBounds.minY), from: textView).y
            let bottom = convert(NSPoint(x: 0, y: content.minY + frame.maxY), from: textView).y
            if y >= top - 1, y < bottom {
                found = line(at: contentManager.offset(from: documentStart, to: fragment.rangeInElement.location))
                return false
            }
            return true
        }
        return found
    }

    private var markerX: CGFloat { blameColumn + 3 }
    private static let markerWidth: CGFloat = 3

    private func drawMarker(for line: Int, top: CGFloat, bottom: CGFloat) {
        let color: NSColor? = changeMarkers.added.contains(line) ? colors.added
            : changeMarkers.modified.contains(line) ? colors.modified
            : nil
        if let color {
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: markerX, y: top, width: Self.markerWidth, height: max(2, bottom - top)), xRadius: 1, yRadius: 1).fill()
        }
        if changeMarkers.deletedAbove.contains(line) { drawDeletion(at: top) }
    }

    /// A small red wedge on the boundary where lines were removed.
    private func drawDeletion(at y: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: markerX - 1, y: y - 4))
        path.line(to: NSPoint(x: markerX + 5, y: y))
        path.line(to: NSPoint(x: markerX - 1, y: y + 4))
        path.close()
        colors.deleted.withAlphaComponent(0.85).setFill()
        path.fill()
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
