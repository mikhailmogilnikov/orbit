import AppKit
import OrbitAPI
@_spi(Plugins) import STTextView

/// Code folding (D79). Regions come from the language server, or from
/// indentation when it has none (as VS Code and Zed do). A folded region's
/// lines stay in the text: the content storage's delegate skips their
/// paragraphs, so TextKit 2 neither lays them out nor lets the caret in.
/// A fold is kept as the characters it hides, so edits elsewhere just move it.
@MainActor
final class FoldingController: NSObject, NSTextContentStorageDelegate {
    weak var textView: STTextView?
    weak var ruler: LineNumberRuler?
    /// Shares the squiggles' text geometry (line starts, rects).
    let geometry: DiagnosticsController
    weak var languages: LanguageIntelligence?
    var url: URL? {
        didSet { if let url, url != oldValue { pendingRestore = FoldMemory.headers(for: url) } }
    }
    /// Headers folded when the file was last open, folded again once their regions are known.
    private var pendingRestore: Set<Int> = []
    private var savedHeaders: Set<Int>?
    /// Remembered folds were folded again (the view may want to scroll back to where it was).
    var onRestore: (() -> Void)?

    struct Colors: Equatable {
        var text: NSColor = .secondaryLabelColor
        var background: NSColor = .clear
        /// Fills the animation's snapshots where the editor itself is see-through.
        var editor: NSColor = .textBackgroundColor
    }

    var colors = Colors() {
        didSet { if colors != oldValue { setNeedsLayout() } }
    }

    /// Foldable regions: last hidden line by header line.
    private var regions: [Int: Int] = [:] {
        didSet { if regions != oldValue { onRegionsChange?() } }
    }
    /// The scopes sticky headers and the breadcrumb bar follow (D82).
    var foldableRegions: [Int: Int] { regions }
    var onRegionsChange: (() -> Void)?
    /// What each fold hides: from the start of the line after its header to the end of its last line.
    private var folds: [NSRange] = []
    private var hidden = IndexSet()
    private var lineCount = 1
    private var request: Task<Void, Never>?
    private let overlays = OverlaySet()
    private var isLayoutScheduled = false

    init(geometry: DiagnosticsController) {
        self.geometry = geometry
    }

    // MARK: Regions

    func refresh(after delay: Duration = .zero) {
        request?.cancel()
        request = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, let string = geometry.string else { return }
            let length = geometry.length
            var found: [FoldingRange]?
            if let languages, let url { found = await languages.foldingRanges(in: url) }
            guard !Task.isCancelled, length == geometry.length else { return }
            if found?.isEmpty ?? true {
                let text = string as String
                found = await Task.detached(priority: .utility) { Self.indentationRanges(in: text as NSString) }.value
                guard !Task.isCancelled, length == geometry.length else { return }
            }
            show(found ?? [])
        }
    }

    private func show(_ ranges: [FoldingRange]) {
        let starts = geometry.lineStarts
        lineCount = starts.count
        var regions: [Int: Int] = [:]
        // Several regions on one line: the outermost wins, as in VS Code.
        for range in ranges where range.startLine >= 0 && range.endLine > range.startLine && range.endLine < starts.count {
            regions[range.startLine] = max(regions[range.startLine] ?? 0, range.endLine)
        }
        if let string = geometry.string { Self.dropRoot(from: &regions, in: string, starts: starts) }
        self.regions = regions
        // A fold whose header no longer starts a region opens; one that does takes its new end.
        let old = folds
        folds = old.compactMap { fold in
            let header = SourcePosition(offset: fold.location - 1, in: starts).line
            guard let end = regions[header] else { return nil }
            return hiddenRange(header: header, end: end, starts: starts)
        }
        for header in pendingRestore {
            guard let end = regions[header], let range = hiddenRange(header: header, end: end, starts: starts) else { continue }
            pendingRestore.remove(header)
            if !folds.contains(range) { folds.append(range) }
        }
        if folds.count > old.count { onRestore?() }
        if folds != old { moveCaretOutOfFolds() }
        if folds != old { foldsDidChange() } else { updateRuler() }
    }

    /// A region around the whole file (a JSON document's braces, `<html>`)
    /// would fold everything into one line: it gets no chevron. It starts on
    /// the first line with text and ends on the last or the one before (its closing bracket).
    nonisolated static func dropRoot(from regions: inout [Int: Int], in text: NSString, starts: [Int]) {
        func hasText(_ line: Int) -> Bool {
            let end = line + 1 < starts.count ? starts[line + 1] : text.length
            return !text.substring(with: NSRange(location: starts[line], length: end - starts[line]))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let first = starts.indices.first(where: hasText), let last = starts.indices.last(where: hasText),
              let end = regions[first], end >= last - 1 else { return }
        regions[first] = nil
    }

    /// Regions by indentation: a line opens one when the lines below it are
    /// indented deeper; it ends at the last of them that isn't blank, so a
    /// closing brace at the header's level stays visible.
    nonisolated static func indentationRanges(in text: NSString, tabWidth: Int = 4) -> [FoldingRange] {
        let starts = SourcePosition.lineStarts(of: text)
        var ranges: [FoldingRange] = []
        var open: [(line: Int, indent: Int)] = []
        var lastText = -1
        for line in starts.indices {
            let end = line + 1 < starts.count ? starts[line + 1] : text.length
            var indent = 0, index = starts[line]
            var blank = true
            while index < end {
                let character = text.character(at: index)
                if character == 0x20 { indent += 1 } else if character == 0x09 { indent += tabWidth - indent % tabWidth } else {
                    blank = character == 0x0A || character == 0x0D
                    break
                }
                index += 1
            }
            guard !blank else { continue }
            while let top = open.last, top.indent >= indent {
                open.removeLast()
                if lastText > top.line { ranges.append(FoldingRange(startLine: top.line, endLine: lastText)) }
            }
            open.append((line, indent))
            lastText = line
        }
        for top in open where lastText > top.line {
            ranges.append(FoldingRange(startLine: top.line, endLine: lastText))
        }
        return ranges.sorted { $0.startLine < $1.startLine }
    }

    // MARK: Folding

    private func hiddenRange(header: Int, end: Int, starts: [Int]) -> NSRange? {
        guard header + 1 < starts.count else { return nil }
        let lower = starts[header + 1]
        let upper = end + 1 < starts.count ? starts[end + 1] : geometry.length
        return upper > lower ? NSRange(location: lower, length: upper - lower) : nil
    }

    private func header(of fold: NSRange) -> Int {
        SourcePosition(offset: fold.location - 1, in: geometry.lineStarts).line
    }

    func isFolded(line: Int) -> Bool {
        folds.contains { header(of: $0) == line }
    }

    /// Folds or unfolds the region a gutter chevron belongs to.
    func toggle(line: Int) {
        if let fold = folds.first(where: { header(of: $0) == line }) {
            animate(fold, folding: false) {
                folds.removeAll { header(of: $0) == line }
                foldsDidChange(around: fold)
            }
        } else if let end = regions[line], let range = hiddenRange(header: line, end: end, starts: geometry.lineStarts) {
            add(range)
        }
    }

    /// The innermost open region around the caret.
    func foldAtCaret() {
        guard let textView else { return }
        let line = SourcePosition(offset: textView.textSelection.location, in: geometry.lineStarts).line
        let candidates = regions.filter { $0.key <= line && line <= $0.value && !isFolded(line: $0.key) }
        guard let (start, end) = candidates.max(by: { $0.key < $1.key }),
              let range = hiddenRange(header: start, end: end, starts: geometry.lineStarts) else {
            NSSound.beep()
            return
        }
        add(range)
    }

    /// The fold on the caret's line.
    func unfoldAtCaret() {
        guard let textView else { return }
        let line = SourcePosition(offset: textView.textSelection.location, in: geometry.lineStarts).line
        guard isFolded(line: line) else {
            NSSound.beep()
            return
        }
        toggle(line: line)
    }

    func foldAll() {
        pendingRestore.removeAll()
        let starts = geometry.lineStarts
        let all = regions.compactMap { hiddenRange(header: $0.key, end: $0.value, starts: starts) }
        guard !all.isEmpty else {
            NSSound.beep()
            return
        }
        for range in all where !folds.contains(range) { folds.append(range) }
        moveCaretOutOfFolds()
        foldsDidChange()
    }

    func unfoldAll() {
        pendingRestore.removeAll()
        guard !folds.isEmpty else { return }
        folds.removeAll()
        foldsDidChange()
    }

    private func add(_ range: NSRange) {
        animate(range, folding: true) {
            folds.append(range)
            moveCaretOutOfFolds()
            foldsDidChange(around: range)
        }
    }

    /// A caret inside what's about to hide goes to the end of the fold's header.
    private func moveCaretOutOfFolds() {
        guard let textView else { return }
        let caret = textView.textSelection.location
        let outer = folds.filter { $0.location <= caret && caret < NSMaxRange($0) }.min { $0.location < $1.location }
        if let outer { textView.textSelection = NSRange(location: outer.location - 1, length: 0) }
    }

    /// The caret got into a fold (go to line, search, undo): open it.
    func revealCaret() {
        guard let textView, !folds.isEmpty else { return }
        let selection = textView.textSelection
        let opened = folds.filter { fold in
            NSLocationInRange(selection.location, fold) || (selection.length > 0 && NSIntersectionRange(selection, fold).length > 0)
        }
        guard !opened.isEmpty else { return }
        folds.removeAll { opened.contains($0) }
        foldsDidChange()
    }

    // MARK: Edits

    /// Folds move with the text; one the edit reaches into opens.
    func textDidChange(_ edit: TextEdit) {
        pendingRestore.removeAll()
        let touched = folds.filter { NSMaxRange(edit.range) >= $0.location && edit.range.location < NSMaxRange($0) }
        folds = folds.filter { !touched.contains($0) }.map { NSRange(location: edit.map($0.location), length: $0.length) }
        // Regions shift by the lines the edit added or removed until the next refresh.
        let starts = geometry.lineStarts
        let delta = starts.count - lineCount
        lineCount = starts.count
        if delta != 0 {
            let line = SourcePosition(offset: edit.range.location, in: starts).line
            var moved: [Int: Int] = [:]
            for (start, end) in regions {
                if start > line { moved[start + delta] = end + delta } else if end < line { moved[start] = end } else if end + delta > start { moved[start] = end + delta }
            }
            regions = moved
        }
        if !touched.isEmpty { foldsDidChange() } else {
            rebuildHidden()
            updateRuler()
        }
        refresh(after: .milliseconds(400))
    }

    /// The whole text was replaced (an agent edit, a reload): folds follow
    /// their lines through a line diff, as in VS Code; one with changed lines
    /// inside opens, so the agent's edits are never hidden.
    func textWasReplaced(old: NSString) {
        regions.removeAll()
        let starts = geometry.lineStarts
        lineCount = starts.count
        if !folds.isEmpty, let new = geometry.string {
            let oldStarts = SourcePosition.lineStarts(of: old)
            let blocks = LineDiff.changeBlocks(oldLines: LineDiff.lines(old as String), newLines: LineDiff.lines(new as String))
            let previous = folds
            folds = previous.compactMap { fold in
                let header = SourcePosition(offset: fold.location - 1, in: oldStarts).line
                let end = SourcePosition(offset: max(fold.location, NSMaxRange(fold) - 1), in: oldStarts).line
                guard let shift = Self.shift(header: header, end: end, through: blocks) else { return nil }
                return hiddenRange(header: header + shift, end: end + shift, starts: starts)
            }
            foldsDidChange()
        } else {
            updateRuler()
        }
        refresh(after: .milliseconds(300))
    }

    /// How far a fold's lines move through an edit's change blocks; nil when one lands on them.
    nonisolated static func shift(header: Int, end: Int, through blocks: [(old: Range<Int>, new: Range<Int>)]) -> Int? {
        var shift = 0
        for block in blocks {
            // Lines added right after the last folded one would join the region when it refreshes.
            let hits = block.old.isEmpty
                ? header < block.old.lowerBound && block.old.lowerBound <= end + 1
                : block.old.lowerBound <= end && block.old.upperBound > header
            if hits { return nil }
            if block.old.lowerBound <= header { shift += block.new.count - block.old.count }
        }
        return shift
    }

    // MARK: Hiding

    private func rebuildHidden() {
        var hidden = IndexSet()
        for fold in folds { hidden.insert(integersIn: fold.location..<NSMaxRange(fold)) }
        self.hidden = hidden
    }

    /// `around`: the one fold that changed; only its lines are laid out
    /// again, so the estimated layout of the rest stays where it was.
    private func foldsDidChange(around fold: NSRange? = nil) {
        rebuildHidden()
        updateRuler()
        guard let textView else { return }
        let manager = textView.textLayoutManager
        let content = textView.textContentManager
        if let fold, let start = content.location(content.documentRange.location, offsetBy: max(0, fold.location - 1)),
           let end = content.location(content.documentRange.location, offsetBy: min(NSMaxRange(fold), geometry.length)),
           let range = NSTextRange(location: start, end: end) {
            manager.invalidateLayout(for: range)
        } else {
            manager.invalidateLayout(for: manager.documentRange)
        }
        textView.needsLayout = true
        textView.needsDisplay = true
        setNeedsLayout()
    }

    private func updateRuler() {
        var markers: [Int: Bool] = [:]
        for start in regions.keys { markers[start] = false }
        let headers = Set(folds.map(header(of:)))
        for header in headers { markers[header] = true }
        ruler?.folds = markers
        if let url, headers != savedHeaders, pendingRestore.isEmpty || !headers.isEmpty {
            savedHeaders = headers
            FoldMemory.save(headers, for: url)
        }
    }

    nonisolated func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement, options: NSTextContentManager.EnumerationOptions = []) -> Bool {
        guard let range = textElement.elementRange else { return true }
        let offset = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
        return MainActor.assumeIsolated { !hidden.contains(offset) }
    }

    // MARK: Animation

    private var animation: NSView?

    /// Xcode's fold: the header stays put, the text below slides up over the
    /// region (or down to uncover it). The real text changes at once; what
    /// moves is a snapshot of the visible area cut into layers the GPU
    /// animates, so a fold costs one bitmap of the screen and no layout per
    /// frame. When the view can't keep the header in place (folding near the
    /// end of the file, where it can't scroll that far) everything above
    /// moves with it to where it really lands.
    private func animate(_ fold: NSRange, folding: Bool, change: () -> Void) {
        pendingRestore.removeAll()
        animation?.removeFromSuperview()
        animation = nil
        guard let textView, let scrollView = textView.enclosingScrollView, textView.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let oldHeader = fragmentFrame(at: fold.location - 1)?.maxY else {
            change()
            keepHeader(of: fold, at: nil)
            return
        }
        let oldVisible = textView.visibleRect
        guard oldHeader >= oldVisible.minY, oldHeader < oldVisible.maxY - 1 else {
            change()
            return
        }
        let oldBelow = folding ? lineTop(at: NSMaxRange(fold), within: oldVisible) : oldHeader
        let area = scrollView.convert(oldVisible, from: textView)
        let rect = NSRect(x: 0, y: area.minY, width: scrollView.bounds.width, height: area.height).integral
        guard rect.height > 0, let rep = scrollView.bitmapImageRepForCachingDisplay(in: rect) else {
            change()
            return
        }
        scrollView.cacheDisplay(in: rect, to: rep)
        change()
        keepHeader(of: fold, at: (oldHeader, oldVisible))
        guard let image = rep.cgImage else { return }
        let newVisible = textView.visibleRect
        let newHeader = fragmentFrame(at: fold.location - 1)?.maxY ?? oldHeader

        // Screen terms, from the overlay's top: where the header's bottom was, and how far it moved.
        let split = oldHeader - oldVisible.minY
        let shift = (newHeader - newVisible.minY) - split
        let height = rect.height
        let hiddenHeight = min(height - split, oldBelow - oldHeader)
        let revealed = folding ? 0 : min(height, lineTop(at: NSMaxRange(fold), within: newVisible) - newHeader)
        guard hiddenHeight > 0.5 || revealed > 0.5 || abs(shift) > 0.5 else { return }

        // In the window before the animations go in: Core Animation ends
        // animations on layers outside a window at once (and ran the cleanup).
        let overlay = AnimationOverlay(frame: rect)
        scrollView.addSubview(overlay, positioned: .above, relativeTo: nil)
        animation = overlay
        let scale = CGFloat(image.height) / height
        // The overlay's layer counts from the bottom; `part` and `move` think in screen terms.
        func part(_ top: CGFloat, _ partHeight: CGFloat) -> CALayer? {
            guard partHeight > 0.5 else { return nil }
            let layer = CALayer()
            layer.frame = CGRect(x: 0, y: height - top - partHeight, width: rect.width, height: partHeight)
            layer.backgroundColor = colors.editor.cgColor
            layer.contents = image.cropping(to: CGRect(x: 0, y: (top * scale).rounded(), width: CGFloat(image.width), height: (partHeight * scale).rounded()))
            layer.contentsGravity = .resize
            return layer
        }
        let root = overlay.layer!
        let duration = 0.22
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        func move(_ layer: CALayer?, down offset: CGFloat) {
            guard let layer else { return }
            root.addSublayer(layer)
            guard abs(offset) > 0.5 else { return }
            let animation = CABasicAnimation(keyPath: "position.y")
            animation.fromValue = layer.position.y
            animation.toValue = layer.position.y - offset
            animation.duration = duration
            animation.timingFunction = timing
            layer.position.y -= offset
            layer.add(animation, forKey: "move")
        }
        func fade(_ layer: CALayer?, from: Float, to: Float) {
            guard let layer else { return }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = timing
            layer.opacity = to
            layer.add(animation, forKey: "fade")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if folding {
            // The region fades under the text below, which slides up to the header.
            let hidden = part(split, hiddenHeight)
            move(hidden, down: shift)
            fade(hidden, from: 1, to: 0)
            move(part(split + hiddenHeight, height - split - hiddenHeight), down: shift - hiddenHeight)
        } else {
            // The text below slides down, uncovering the region's real lines as they fade in.
            if revealed > 0.5 {
                let cover = CALayer()
                cover.frame = CGRect(x: 0, y: height - (split + shift) - revealed, width: rect.width, height: revealed)
                cover.backgroundColor = colors.editor.cgColor
                root.addSublayer(cover)
                fade(cover, from: 1, to: 0)
            }
            move(part(split, height - split), down: shift + max(0, revealed))
        }
        move(part(0, split), down: shift)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak overlay] in
            overlay?.removeFromSuperview()
            if let self, self.animation === overlay { self.animation = nil }
        }
    }

    /// Lays the change out and scrolls so the header is where it was on
    /// screen: TextKit 2 re-estimates the text above the viewport, which
    /// otherwise made the view jump.
    private func keepHeader(of fold: NSRange, at old: (header: CGFloat, visible: CGRect)?) {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        scrollView.layoutSubtreeIfNeeded()
        guard let old, let header = fragmentFrame(at: fold.location - 1)?.maxY else { return }
        let target = old.visible.minY + (header - old.header)
        guard abs(target - textView.visibleRect.minY) > 0.5 else { return }
        textView.scroll(NSPoint(x: old.visible.minX, y: target))
        scrollView.layoutSubtreeIfNeeded()
    }

    /// A paragraph's frame in text-view coordinates, if it's laid out.
    private func fragmentFrame(at offset: Int) -> CGRect? {
        guard let textView, offset >= 0, offset <= geometry.length else { return nil }
        let content = textView.textContentManager
        guard let location = content.location(content.documentRange.location, offsetBy: offset),
              let fragment = textView.textLayoutManager.textLayoutFragment(for: location) else { return nil }
        return fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textView.contentFrame.minY)
    }

    /// Where the line at an offset starts on screen; the bottom of the visible
    /// rect when it lies past the viewport (not laying out text off screen to find out).
    private func lineTop(at offset: Int, within visible: CGRect) -> CGFloat {
        guard let textView, offset < geometry.length,
              let viewport = textView.textLayoutManager.textViewportLayoutController.viewportRange else { return visible.maxY }
        let end = textView.textContentManager.offset(from: textView.textContentManager.documentRange.location, to: viewport.endLocation)
        guard offset < end, let frame = fragmentFrame(at: offset) else { return visible.maxY }
        return min(frame.minY, visible.maxY)
    }

    // MARK: The "⋯" after a folded header

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
        guard let textView, let string = geometry.string else { return }
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -200)
        let font = NSFont(descriptor: textView.font.fontDescriptor, size: (textView.font.pointSize * 0.88).rounded()) ?? textView.font
        for fold in folds {
            // The header's last character; an empty header line has none, use its line break.
            let lineEnd = fold.location - 1
            let starts = geometry.lineStarts
            let lineStart = starts[SourcePosition(offset: lineEnd, in: starts).line]
            let anchor = lineEnd > lineStart ? NSRange(location: lineEnd - 1, length: 1) : NSRange(location: lineEnd, length: 1)
            guard NSMaxRange(anchor) <= string.length, let rect = geometry.rects(for: anchor).first, rect.intersects(visible) else { continue }
            let x = lineEnd > lineStart ? rect.maxX + 4 : rect.minX
            let width = ceil(("⋯" as NSString).size(withAttributes: [.font: font]).width) + 12
            let frame = CGRect(x: x, y: rect.minY + 1, width: width, height: max(rect.height - 2, 1)).integral
            let colors = colors
            overlays.place(fold, font, colors.text, colors.background, frame: frame, in: textView) {
                let view = FoldPlaceholderView(frame: frame, font: font, colors: colors)
                view.onClick = { [weak self] in
                    guard let self, folds.contains(fold) else { return }
                    animate(fold, folding: false) {
                        folds.removeAll { $0 == fold }
                        foldsDidChange(around: fold)
                    }
                }
                return view
            }
        }
    }
}

/// "⋯" on a soft capsule; clicking it unfolds.
private final class FoldPlaceholderView: NSView {
    private let label: NSAttributedString
    var onClick: (() -> Void)?

    init(frame: CGRect, font: NSFont, colors: FoldingController.Colors) {
        label = NSAttributedString(string: "⋯", attributes: [.font: font, .foregroundColor: colors.text])
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.backgroundColor = colors.background.cgColor
        toolTip = "Unfold"
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// Re-places the placeholders whenever the viewport is laid out.
struct FoldingPlugin: STPlugin {
    let controller: FoldingController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.setNeedsLayout() }
        }
    }
}

/// Holds the fold animation's layers above the editor and its gutter; clicks go through.
private final class AnimationOverlay: NSView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Folded lines per file, for when it opens again (VS Code and Xcode keep them too).
@MainActor
enum FoldMemory {
    private static let key = "orbit.foldedLines"
    private static let limit = 300

    static func headers(for url: URL) -> Set<Int> {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        return Set(all[url.standardizedFileURL.path] ?? [])
    }

    static func save(_ headers: Set<Int>, for url: URL) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        let path = url.standardizedFileURL.path
        guard Set(all[path] ?? []) != headers else { return }
        all[path] = headers.isEmpty ? nil : headers.sorted()
        var order = UserDefaults.standard.stringArray(forKey: key + ".order") ?? []
        order.removeAll { $0 == path }
        if !headers.isEmpty { order.append(path) }
        while order.count > limit { all[order.removeFirst()] = nil }
        UserDefaults.standard.set(all, forKey: key)
        UserDefaults.standard.set(order, forKey: key + ".order")
    }
}
