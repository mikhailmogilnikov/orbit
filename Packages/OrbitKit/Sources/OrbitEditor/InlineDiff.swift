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
    /// Review notes for the agent (D125); nil without an agent to send them to.
    var onSaveComment: ((ReviewComment) -> Void)?
    var onRemoveComment: ((ReviewComment.ID) -> Void)?
    var url: URL?
    /// Merge conflict blocks in the text (D134), and what resolves one.
    private(set) var conflicts: [MergeConflict] = []
    var onResolveConflict: ((MergeConflict, MergeConflicts.Choice) -> Void)?

    private(set) var hunks: [DiffHunk] = []
    /// The file's notes with the lines they're on now.
    private(set) var comments: [(comment: ReviewComment, lines: ClosedRange<Int>)] = []
    private var commentsSignature: Int?
    private var commentPopover: NSPopover?
    /// Note popovers and their delegates, kept until they finished closing
    /// (a popover holds its delegate weakly; one replaced mid-close still saves).
    private var openPopovers: [ObjectIdentifier: (popover: NSPopover, delegate: CommentPopoverDelegate)] = [:]
    private var lineStarts: [Int] = [0]
    private var lineHeight: CGFloat = 16
    private var appliedSignature: Int?
    let overlays = OverlaySet()
    private var isApplying = false

    /// The color theme's version-control colors (system green/red without one).
    struct Colors: Equatable {
        var added: NSColor = .systemGreen
        var deleted: NSColor = .systemRed
    }

    /// Set by the editor on every theme or light/dark switch; repaints what's shown.
    var colors = Colors() {
        didSet {
            guard colors != oldValue else { return }
            layoutOverlays()
        }
    }

    // MARK: Updating

    /// Applies the current hunks and notes. Cheap when nothing changed.
    func update(hunks: [DiffHunk], comments: [ReviewComment], revision: Int) {
        var hasher = Hasher()
        hasher.combine(hunks)
        hasher.combine(revision)
        let signature = hasher.finalize()
        hasher.combine(comments)
        let withComments = hasher.finalize()
        guard signature != appliedSignature || withComments != commentsSignature else { return }
        commentsSignature = withComments
        if !comments.isEmpty, let text = textView?.text {
            let lines = LineDiff.lines(text)
            self.comments = comments.map { ($0, $0.located(in: lines)) }
        } else {
            self.comments = []
        }
        if signature != appliedSignature {
            appliedSignature = signature
            self.hunks = hunks
            let text = textView?.text ?? ""
            conflicts = MergeConflicts.hasMarkers(text) ? MergeConflicts.find(in: LineDiff.lines(text)) : []
            applySpacing()
        }
        layoutOverlays()
    }

    /// Call after the text view's whole string was replaced (attributes reset).
    func invalidate() {
        appliedSignature = nil
        commentsSignature = nil
    }

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
        defer { overlays.commit() }
        guard !hunks.isEmpty || !comments.isEmpty || !conflicts.isEmpty else { return }

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
                    let color = colors.added
                    overlays.place("added", hunk.id, color, frame: rect, in: textView, below: true) {
                        ChangeBackgroundView(frame: rect, color: color)
                    }
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
                        let lines = removedLinesByHunk[hunk.id] ?? []
                        let color = colors.deleted, font = textView.font, lineHeight = lineHeight, inset = textX - content.minX
                        overlays.place("removed", hunk.id, lines, color, font, lineHeight, inset, frame: rect, in: textView, below: true) {
                            let ghost = RemovedLinesView(frame: rect)
                            ghost.color = color
                            ghost.lines = lines
                            ghost.font = font
                            ghost.lineHeight = lineHeight
                            ghost.textInset = inset
                            return ghost
                        }
                    }
                    top = min(top, gapTop)
                    bottom = max(bottom, gapTop + gap)
                }
            }

            guard top != .greatestFiniteMagnitude, visible.contains(CGPoint(x: visible.midX, y: bottom)) else { continue }
            let note = comment(for: hunk)
            let commentText = onSaveComment == nil ? nil : (note?.text ?? "")
            let key: [AnyHashable] = ["actions", hunk, commentText]
            let actions = overlays.view(for: key) ?? NSHostingView(rootView: HunkActions(
                comment: commentText,
                keep: { [weak self] in self?.onKeep?(hunk) },
                revert: { [weak self] in self?.onRevert?(hunk) },
                editComment: { [weak self] in
                    guard let self else { return }
                    editComment(note ?? newComment(on: hunk), anchor: commentAnchor(anchorLines(of: hunk), hunk: hunk))
                }
            ))
            let size = actions.frame.size == .zero ? actions.fittingSize : actions.frame.size
            let anchorX = textView.visibleRect.maxX - size.width - 12
            // Bottom-right corner of the block, hanging just below it like Cursor.
            let frame = CGRect(x: anchorX, y: bottom, width: size.width, height: size.height)
            overlays.place(key, frame: frame, in: textView) { actions }
        }

        layoutConflicts(visible: visible, width: width, contentX: content.minX)

        // Notes away from any change block (kept since, or on plain code) hang off their first line.
        for (comment, lines) in comments where !hunks.contains(where: { anchorLines(of: $0).overlaps(lines) }) {
            guard let line = lineRect(lines.lowerBound), line.intersects(visible) else { continue }
            let key: [AnyHashable] = ["note", comment]
            let chip = overlays.view(for: key) ?? NSHostingView(rootView: CommentChip(text: comment.text) { [weak self] in
                guard let self else { return }
                editComment(comment, anchor: commentAnchor(lines, hunk: nil))
            })
            let size = chip.frame.size == .zero ? chip.fittingSize : chip.frame.size
            let frame = CGRect(x: textView.visibleRect.maxX - size.width - 12, y: line.midY - size.height / 2, width: size.width, height: size.height)
            overlays.place(key, frame: frame, in: textView) { chip }
        }
    }

    // MARK: Review notes

    /// The lines a block's note is anchored to: its new lines, or the line
    /// after a deletion.
    private func anchorLines(of hunk: DiffHunk) -> ClosedRange<Int> {
        hunk.added > 0
            ? hunk.newRange.lowerBound...(hunk.newRange.upperBound - 1)
            : hunk.newRange.lowerBound...hunk.newRange.lowerBound
    }

    private func comment(for hunk: DiffHunk) -> ReviewComment? {
        let anchor = anchorLines(of: hunk)
        return comments.first { $0.lines.overlaps(anchor) }?.comment
    }

    private func newComment(on hunk: DiffHunk) -> ReviewComment {
        let anchor = anchorLines(of: hunk)
        let removed = hunk.lines.filter { $0.kind == .removed }.map(\.text).joined(separator: "\n")
        return ReviewComment(url: url ?? URL(fileURLWithPath: "/"), lines: anchor, code: code(anchor), removed: removed)
    }

    private func code(_ lines: ClosedRange<Int>) -> String {
        let all = LineDiff.lines(textView?.text ?? "")
        guard lines.lowerBound < all.count else { return "" }
        return all[lines.lowerBound...min(lines.upperBound, all.count - 1)].joined(separator: "\n")
    }

    /// ⌥⌘/: the note of the block or note at these lines, else a new one on them.
    func comment(on lines: ClosedRange<Int>) {
        guard onSaveComment != nil, textView != nil else { return }
        let existing = comments.first { $0.lines.overlaps(lines) }?.comment
        let hunk = hunks.first { anchorLines(of: $0).overlaps(lines) }
        let note = existing ?? hunk.map(newComment(on:))
            ?? ReviewComment(url: url ?? URL(fileURLWithPath: "/"), lines: lines, code: code(lines))
        editComment(note, anchor: commentAnchor(hunk.map(anchorLines(of:)) ?? lines, hunk: hunk))
    }

    /// The note opens above the first line of its block, where the eye is, not by
    /// the buttons at the side.
    private func commentAnchor(_ lines: ClosedRange<Int>, hunk: DiffHunk?) -> CGRect {
        guard let textView else { return .zero }
        guard var line = lineRect(lines.lowerBound) else {
            let visible = textView.visibleRect
            return CGRect(x: visible.midX, y: visible.midY, width: 1, height: 1)
        }
        // The removed lines are drawn in a gap above the block.
        if let hunk, hunk.removed > 0 { line.origin.y -= CGFloat(hunk.removed) * lineHeight }
        // Scrolled to only when out of sight, and never past the end of the text.
        var visible = textView.visibleRect
        if line.minY < visible.minY || line.maxY > visible.maxY {
            textView.scrollToVisible(CGRect(x: visible.minX, y: line.minY - 120, width: 1, height: line.height + 180)
                .intersection(textView.bounds))
            visible = textView.visibleRect
        }
        let width = max(1, min(line.width, 240))
        let x = min(max(line.minX, visible.minX + 8), max(visible.minX + 8, visible.maxX - width - 8))
        return CGRect(x: x, y: line.minY, width: width, height: line.height)
    }

    private func editComment(_ comment: ReviewComment, anchor: CGRect) {
        guard let textView, textView.window != nil else { return }
        commentPopover?.close()
        let draft = CommentDraft(text: comment.text)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ReviewCommentEditor(
            initialText: comment.text,
            isNew: comment.text.isEmpty,
            onChange: { draft.text = $0 },
            finish: { [weak popover] outcome in
                draft.outcome = outcome
                popover?.close()
            }
        ).tint(Theme.controlTint))
        // Clicking away keeps what was written, like Xcode's notes; Cancel and Esc don't.
        let key = ObjectIdentifier(popover)
        let delegate = CommentPopoverDelegate { [weak self] in
            guard let self else { return }
            openPopovers[key] = nil
            if commentPopover.map(ObjectIdentifier.init) == key { commentPopover = nil }
            switch draft.outcome {
            case .cancel: break
            case .delete: onRemoveComment?(comment.id)
            case .save:
                var saved = comment
                saved.text = draft.text
                // An empty note that was never saved needs no removal.
                if !saved.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !comment.text.isEmpty {
                    onSaveComment?(saved)
                }
            }
        }
        openPopovers[key] = (popover, delegate)
        popover.delegate = delegate
        commentPopover = popover
        // Its size before it's shown: without it AppKit placed it for a default
        // 320-pt square, which didn't fit over the block and went to the window's top.
        if let size = popover.contentViewController?.view.fittingSize { popover.contentSize = size }
        // The text view is flipped: .minY is the top.
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .minY)
    }

    func closeComment() { commentPopover?.close() }

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
    func lineRect(_ line: Int) -> CGRect? {
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
    private let bar = NSView()

    var color: NSColor {
        didSet { applyColor() }
    }

    init(frame: CGRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
        wantsLayer = true
        bar.frame = CGRect(x: 0, y: 0, width: 3, height: frame.height)
        bar.wantsLayer = true
        bar.autoresizingMask = [.height]
        addSubview(bar)
        applyColor()
    }

    private func applyColor() {
        layer?.backgroundColor = color.withAlphaComponent(0.13).cgColor
        bar.layer?.backgroundColor = color.withAlphaComponent(0.7).cgColor
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
    var color: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.12).setFill()
        bounds.fill()
        color.withAlphaComponent(0.7).setFill()
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

/// A floating glass capsule under the block (D213): the keys live in the tooltips.
struct HunkActions: View {
    /// The block's note (empty: none yet); nil hides the button.
    let comment: String?
    let keep: () -> Void
    let revert: () -> Void
    let editComment: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let comment {
                Button(action: editComment) {
                    if comment.isEmpty {
                        Image(systemName: "text.bubble").foregroundStyle(.secondary)
                    } else {
                        Label(comment, systemImage: "text.bubble.fill")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 180, alignment: .leading)
                    }
                }
                .help(comment.isEmpty ? "Comment for Agent (⌥⌘/)" : comment)
            }
            Button("Undo", action: revert)
                .foregroundStyle(.secondary)
                .help("Undo Change (⌥⌘⌫)")
            Button(action: keep) { Text("Keep").fontWeight(.semibold) }
                .help("Keep Change (⌥⌘↩)")
        }
        .buttonStyle(HunkActionStyle())
        .orbitFont(.caption, weight: .medium)
        .padding(2)
        .glassEffect(.regular, in: .capsule)
    }
}

struct HunkActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCapsule(isPressed: configuration.isPressed) { configuration.label }
    }
}

private struct HoverCapsule<Label: View>: View {
    let isPressed: Bool
    @ViewBuilder let label: Label
    @State private var isHovering = false

    var body: some View {
        label
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isPressed ? Theme.activeFill : isHovering ? Theme.hoverFill : .clear, in: .capsule)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
    }
}

/// A note away from any change block, at the end of its line.
struct CommentChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: "text.bubble.fill")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .leading)
        }
        .buttonStyle(HunkActionStyle())
        .orbitFont(.caption, weight: .medium)
        .padding(2)
        .glassEffect(.regular, in: .capsule)
        .help(text)
    }
}

private final class CommentPopoverDelegate: NSObject, NSPopoverDelegate {
    let onClose: @MainActor () -> Void
    init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }
    func popoverDidClose(_ notification: Notification) { onClose() }
}

@MainActor
private final class CommentDraft {
    var text: String
    var outcome = ReviewCommentEditor.Outcome.save
    init(text: String) { self.text = text }
}

/// The popover a note is written in.
struct ReviewCommentEditor: View {
    enum Outcome { case save, cancel, delete }

    let isNew: Bool
    let onChange: (String) -> Void
    let finish: (Outcome) -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(initialText: String, isNew: Bool, onChange: @escaping (String) -> Void, finish: @escaping (Outcome) -> Void) {
        self.isNew = isNew
        self.onChange = onChange
        self.finish = finish
        _text = State(initialValue: initialText)
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Comment for the agent", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .orbitFont(.body)
                .lineLimit(3...10)
                .focused($isFocused)
                .onSubmit { if !isEmpty { finish(.save) } }
                .onExitCommand { finish(.cancel) }
                .onChange(of: text) { _, new in onChange(new) }
            HStack(spacing: 8) {
                if !isNew {
                    Button("Delete", role: .destructive) { finish(.delete) }
                        .buttonStyle(.glass)
                }
                Text("Sent with the others from the chat")
                    .orbitFont(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel") { finish(.cancel) }
                    .buttonStyle(.glass)
                Button(isNew ? "Add" : "Save") { finish(.save) }
                    .buttonStyle(.glassProminent)
                    .disabled(isEmpty && isNew)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }
}

