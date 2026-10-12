import AppKit
import OrbitAPI
import OrbitUI
@_spi(Plugins) import STTextView
import SwiftUI

/// Cursor-style inline review inside the editor:
/// - added lines get a green full-width background,
/// - removed lines are drawn as red "ghost" lines in a gap opened above the
///   change (paragraph spacing, so the real text never contains them),
/// - each change block gets floating Keep / Undo buttons.
@MainActor
final class InlineDiffController {
    weak var textView: STTextView?
    var onKeep: ((DiffHunk) -> Void)?
    var onRevert: ((DiffHunk) -> Void)?

    private(set) var hunks: [DiffHunk] = []
    private var lineStarts: [Int] = [0]
    private var lineHeight: CGFloat = 16
    private var appliedSignature: Int?
    private var overlays: [NSView] = []
    private var isApplying = false

    // MARK: Updating

    /// Applies the current hunks. Cheap when nothing changed.
    func update(hunks: [DiffHunk], revision: Int) {
        var hasher = Hasher()
        hasher.combine(hunks)
        hasher.combine(revision)
        let signature = hasher.finalize()
        guard signature != appliedSignature else { return }
        appliedSignature = signature
        self.hunks = hunks
        applySpacing()
        layoutOverlays()
    }

    /// Call after the text view's whole string was replaced (attributes reset).
    func invalidate() { appliedSignature = nil }

    /// Index of the change block at or after `line`.
    func hunk(near line: Int) -> DiffHunk? {
        hunks.first { line <= max($0.newRange.upperBound - 1, $0.newRange.lowerBound) } ?? hunks.last
    }

    // MARK: Gaps for removed lines

    private var storage: NSTextStorage? {
        (textView?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    private func applySpacing() {
        guard let textView, let storage else { return }
        isApplying = true
        defer { isApplying = false }

        let text = storage.string as NSString
        lineStarts = Self.lineStarts(of: text)
        lineHeight = measureLineHeight()

        // Find paragraphs we decorated previously.
        var stale: [NSRange] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let style = value as? NSParagraphStyle, style.paragraphSpacingBefore > 0 || style.paragraphSpacing > 0 {
                stale.append(range)
            }
        }

        let base = textView.defaultParagraphStyle
        textView.textContentManager.performEditingTransaction {
            for range in stale {
                storage.addAttribute(.paragraphStyle, value: base, range: range)
            }
            for hunk in hunks where hunk.removed > 0 {
                let gap = CGFloat(hunk.removed) * lineHeight
                let style = base.mutableCopy() as! NSMutableParagraphStyle
                if let range = paragraphRange(line: hunk.newRange.lowerBound, in: text) {
                    style.paragraphSpacingBefore = gap
                    storage.addAttribute(.paragraphStyle, value: style, range: range)
                } else if let last = lastParagraphRange(in: text) {
                    // Removal at the very end: open the gap below the last line.
                    style.paragraphSpacing = gap
                    storage.addAttribute(.paragraphStyle, value: style, range: last)
                }
            }
        }
        textView.needsLayout = true
    }

    /// Range of a line's paragraph, or nil for the empty line after a trailing newline.
    private func paragraphRange(line: Int, in text: NSString) -> NSRange? {
        guard line < lineStarts.count else { return nil }
        let start = lineStarts[line]
        guard start < text.length else { return nil }
        return text.paragraphRange(for: NSRange(location: start, length: 0))
    }

    private func lastParagraphRange(in text: NSString) -> NSRange? {
        guard text.length > 0 else { return nil }
        return text.paragraphRange(for: NSRange(location: text.length - 1, length: 0))
    }

    private func measureLineHeight() -> CGFloat {
        guard let textView else { return 16 }
        let documentStart = textView.textLayoutManager.documentRange.location
        if let fragment = textView.textLayoutManager.textLayoutFragment(for: documentStart),
           let line = fragment.textLineFragments.first, line.typographicBounds.height > 0 {
            return line.typographicBounds.height
        }
        let font = textView.font
        return ceil(font.ascender - font.descender + font.leading)
    }

    static func lineStarts(of text: NSString) -> [Int] {
        LineStarts.of(text)
    }

    // MARK: Overlays

    /// Rebuilds overlay views for blocks in (or near) the viewport.
    func layoutOverlays() {
        guard !isApplying, let textView else { return }
        for view in overlays { view.removeFromSuperview() }
        overlays.removeAll()
        guard !hunks.isEmpty else { return }

        let content = textView.contentFrame
        let width = max(textView.bounds.width, content.maxX) - content.minX
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -400)
        let removedLinesByHunk = Dictionary(uniqueKeysWithValues: hunks.map { hunk in
            (hunk.id, hunk.lines.filter { $0.kind == .removed }.map(\.text))
        })

        for hunk in hunks {
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            var textX = content.minX + 5

            if hunk.added > 0,
               let first = lineRect(hunk.newRange.lowerBound),
               let last = lineRect(hunk.newRange.upperBound - 1) {
                let rect = CGRect(x: content.minX, y: first.minY, width: width, height: last.maxY - first.minY)
                textX = first.minX
                if rect.intersects(visible) {
                    add(ChangeBackgroundView(frame: rect, kind: .added), below: true)
                }
                top = min(top, rect.minY)
                bottom = max(bottom, rect.maxY)
            }

            if hunk.removed > 0 {
                let gap = CGFloat(hunk.removed) * lineHeight
                let gapTop: CGFloat?
                if let line = lineRect(hunk.newRange.lowerBound), paragraphExists(hunk.newRange.lowerBound) {
                    gapTop = line.minY - gap
                    textX = line.minX
                } else if let lastLine = lineStarts.lastIndex(where: { $0 < (storage?.length ?? 0) }),
                          let last = lineRect(lastLine) {
                    // The gap was opened below the last real paragraph.
                    gapTop = last.maxY
                } else {
                    gapTop = nil
                }
                if let gapTop {
                    let rect = CGRect(x: content.minX, y: gapTop, width: width, height: gap)
                    if rect.intersects(visible) {
                        let ghost = RemovedLinesView(frame: rect)
                        ghost.lines = removedLinesByHunk[hunk.id] ?? []
                        ghost.font = textView.font
                        ghost.lineHeight = lineHeight
                        ghost.textInset = textX - content.minX
                        add(ghost, below: true)
                    }
                    top = min(top, gapTop)
                    bottom = max(bottom, gapTop + gap)
                }
            }

            guard top != .greatestFiniteMagnitude, visible.contains(CGPoint(x: visible.midX, y: bottom)) else { continue }
            let actions = NSHostingView(rootView: HunkActions(
                keep: { [weak self] in self?.onKeep?(hunk) },
                revert: { [weak self] in self?.onRevert?(hunk) }
            ))
            let size = actions.fittingSize
            let anchorX = textView.visibleRect.maxX - size.width - 12
            // Bottom-right corner of the block, hanging just below it like Cursor.
            actions.frame = CGRect(x: anchorX, y: bottom, width: size.width, height: size.height)
            add(actions, below: false)
        }
    }

    private func add(_ view: NSView, below: Bool) {
        guard let textView else { return }
        if below {
            // Under the text content, above the editor background.
            textView.addSubview(view, positioned: .below, relativeTo: nil)
        } else {
            textView.addSubview(view)
        }
        overlays.append(view)
    }

    private func trailingSpacing(of line: Int) -> CGFloat {
        guard let storage, line < lineStarts.count, lineStarts[line] < storage.length else { return 0 }
        let style = storage.attribute(.paragraphStyle, at: lineStarts[line], effectiveRange: nil) as? NSParagraphStyle
        return style?.paragraphSpacing ?? 0
    }

    private func paragraphExists(_ line: Int) -> Bool {
        guard let storage, line < lineStarts.count else { return false }
        return lineStarts[line] < storage.length
    }

    /// Rect of a line's text in text-view coordinates (excluding paragraph gaps).
    private func lineRect(_ line: Int) -> CGRect? {
        guard let textView, let storage, line >= 0, line < lineStarts.count else { return nil }
        // The empty line after a trailing newline has no paragraph: it sits one line below the last.
        if lineStarts[line] >= storage.length, line > 0 {
            guard let previous = lineRect(line - 1) else { return nil }
            return previous.offsetBy(dx: 0, dy: previous.height + trailingSpacing(of: line - 1))
        }
        let manager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        let documentStart = manager.documentRange.location
        guard let location = contentManager.location(documentStart, offsetBy: lineStarts[line]),
              let fragment = manager.textLayoutFragment(for: location) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let content = textView.contentFrame
        let offsetInParagraph = lineStarts[line] - contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
        let lineFragment = fragment.textLineFragments.first { $0.characterRange.contains(offsetInParagraph) }
            ?? fragment.textLineFragments.first
        guard let lineFragment else { return nil }
        let bounds = lineFragment.typographicBounds
        return CGRect(
            x: content.minX + frame.minX + bounds.minX,
            y: content.minY + frame.minY + bounds.minY,
            width: bounds.width,
            height: bounds.height
        )
    }
}

/// STTextView plugin hook: re-place overlays whenever the viewport is laid out.
struct InlineDiffPlugin: STPlugin {
    let controller: InlineDiffController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.layoutOverlays() }
        }
    }
}

// MARK: - Views

final class ChangeBackgroundView: NSView {
    enum Kind { case added }

    init(frame: CGRect, kind: Kind) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.13).cgColor
        let bar = NSView(frame: CGRect(x: 0, y: 0, width: 3, height: frame.height))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.7).cgColor
        bar.autoresizingMask = [.height]
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws removed lines in the gap opened above a change.
final class RemovedLinesView: NSView {
    var lines: [String] = []
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var lineHeight: CGFloat = 16
    var textInset: CGFloat = 5

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.12).setFill()
        bounds.fill()
        NSColor.systemRed.withAlphaComponent(0.7).setFill()
        CGRect(x: 0, y: 0, width: 3, height: bounds.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55),
            .strikethroughStyle: 0,
        ]
        for (index, line) in lines.enumerated() {
            let y = CGFloat(index) * lineHeight
            guard y < bounds.height, CGRect(x: 0, y: y, width: bounds.width, height: lineHeight).intersects(dirtyRect) else { continue }
            let string = NSAttributedString(string: line.replacingOccurrences(of: "\t", with: "    "), attributes: attributes)
            let baselineOffset = (lineHeight - (font.ascender - font.descender)) / 2
            string.draw(at: CGPoint(x: textInset, y: y + max(0, baselineOffset)))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct HunkActions: View {
    let keep: () -> Void
    let revert: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            Button(action: revert) {
                Text("Undo ").foregroundStyle(.primary) + Text("⌥⌘⌫").foregroundStyle(.secondary)
            }
            .help("Revert this change")
            Divider().frame(height: 12)
            Button(action: keep) {
                Text("Keep ").foregroundStyle(.primary) + Text("⌥⌘↩").foregroundStyle(.secondary)
            }
            .help("Keep this change")
        }
        .buttonStyle(HunkActionStyle())
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 2)
        .background(.regularMaterial, in: .rect(bottomLeadingRadius: 6, bottomTrailingRadius: 6))
        .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }
}

struct HunkActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(configuration.isPressed ? Color.primary.opacity(0.12) : .clear, in: .rect(cornerRadius: 4))
            .contentShape(.rect)
    }
}
