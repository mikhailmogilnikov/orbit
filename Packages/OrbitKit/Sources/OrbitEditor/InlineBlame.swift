import AppKit
import OrbitAPI
import OrbitUI
@_spi(Plugins) import STTextView
import SwiftUI

/// Who last changed the caret's line, faded after its end, as GitLens does
/// (D187); hovering it shows the commit. Replaces D135's column.
@MainActor
final class InlineBlameController {
    weak var textView: STTextView?
    let geometry: DiagnosticsController
    var color: NSColor = .tertiaryLabelColor {
        didSet { if color != oldValue { setNeedsLayout() } }
    }
    /// Blame of the text as it was when asked; nil when off or not tracked.
    var lines: [LineBlame]? {
        didSet {
            isStale = false
            setNeedsLayout()
        }
    }
    /// Opens what a commit changed in the file.
    var showCommit: (String) -> Void = { _ in }
    /// Where the label is, in text-view coordinates, for the hover card.
    private(set) var frame: CGRect?
    private(set) var shown: LineBlame?
    /// Typing shifts lines until the next blame: hidden meanwhile.
    private var isStale = false
    private var caretLine: Int?
    private let overlays = OverlaySet()
    private var isLayoutScheduled = false

    init(geometry: DiagnosticsController) {
        self.geometry = geometry
    }

    func caretMoved() {
        guard let textView, !textView.hasMultipleSelections, textView.textSelection.length == 0 else {
            caretLine = nil
            return setNeedsLayout()
        }
        let line = SourcePosition(offset: min(textView.textSelection.location, geometry.length), in: geometry.lineStarts).line
        guard line != caretLine else { return }
        caretLine = line
        setNeedsLayout()
    }

    func textDidChange() {
        guard lines != nil, !isStale else { return }
        isStale = true
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

    /// "Author, 3 days ago · summary".
    static func label(for line: LineBlame, now: Date = Date()) -> String {
        guard line.isCommitted else { return "Not committed yet" }
        let when = line.date.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return line.summary.isEmpty ? "\(line.author), \(when)" : "\(line.author), \(when) · \(line.summary)"
    }

    private func layoutOverlays() {
        defer { overlays.commit() }
        frame = nil
        shown = nil
        guard let textView, let lines, !isStale, let line = caretLine, line < lines.count,
              line < geometry.lineStarts.count, let string = geometry.string else { return }
        let starts = geometry.lineStarts
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : string.length
        // After the line's last character; an empty line has only its line break, or nothing.
        let anchor = end > start ? NSRange(location: end - 1, length: 1) : NSRange(location: start, length: 1)
        guard NSMaxRange(anchor) <= string.length, let rect = geometry.rects(for: anchor).last else { return }
        let font = NSFont.systemFont(ofSize: (textView.font.pointSize * 0.92).rounded())
        let x = (end > start ? rect.maxX : rect.minX) + ceil(font.pointSize * 2.5)
        let visible = textView.visibleRect
        let text = Self.label(for: lines[line])
        let width = min(ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2, visible.maxX - x - 12)
        guard width > 40 else { return }
        let labelFrame = CGRect(x: x, y: rect.minY, width: width, height: rect.height).integral
        let color = color
        overlays.place(text, font, color, frame: labelFrame, in: textView) {
            InlineBlameView(frame: labelFrame, text: text, font: font, color: color)
        }
        frame = labelFrame
        shown = lines[line]
    }
}

private final class InlineBlameView: NSView {
    private let label: NSAttributedString

    init(frame: CGRect, text: String, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Clicks and hovers go to the text view, which shows the card.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let height = label.size().height
        label.draw(with: NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

struct InlineBlamePlugin: STPlugin {
    let controller: InlineBlameController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.setNeedsLayout() }
        }
    }
}

/// The commit behind a line, in the editor's hover card.
struct BlameCard: View {
    let line: LineBlame
    let onShowChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.secondary)
                Text(line.isCommitted ? line.author : "You")
                    .orbitFont(.body, weight: .semibold)
                Text(line.isCommitted ? "\(line.date.formatted(.relative(presentation: .named))) · \(line.date.formatted(date: .abbreviated, time: .shortened))" : "Not committed yet")
                    .orbitFont(.body)
                    .foregroundStyle(.secondary)
            }
            if line.isCommitted {
                if !line.summary.isEmpty {
                    Text(line.summary)
                        .orbitFont(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button("Show Changes", action: onShowChanges)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line.hash, forType: .string)
                    } label: {
                        Text(String(line.hash.prefix(8)))
                            .orbitFont(.body, design: .monospaced)
                    }
                    .help("Copy the commit's hash")
                }
                .buttonStyle(.link)
            }
        }
        .padding(10)
        .frame(maxWidth: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
