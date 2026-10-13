import AppKit
import SwiftUI

/// The hover card as VS Code shows it: no arrow, above the line, its left
/// edge at the word; below the line when there's no room above (D68).
final class HoverPanel: FloatingPanel {
    private static let maxWidth: CGFloat = 540
    private static let maxHeight: CGFloat = 420

    /// The pointer left the card (and not back to the word): close it.
    var onExit: (() -> Void)?
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var tracking: NSTrackingArea?

    init() {
        super.init(contentSize: NSSize(width: 300, height: 100))
        // Clicked into, it takes keys so its text can be selected and copied.
        becomesKeyOnlyIfNeeded = true
        host.sizingOptions = []
        contentView?.addSubview(host)
    }

    override var canBecomeKey: Bool { true }

    /// `word` is the hovered range's rect in screen coordinates; `area` the
    /// editor's visible rect on screen, which the card stays within vertically.
    func show(_ card: some View, at word: NSRect, within area: NSRect, in window: NSWindow?) {
        // Measured at the max width: text wraps there, short content stays narrow.
        let fitting = NSHostingController(rootView: card).sizeThatFits(in: NSSize(width: Self.maxWidth, height: 10_000))
        let size = NSSize(width: min(ceil(fitting.width), Self.maxWidth), height: min(ceil(fitting.height), Self.maxHeight))
        host.rootView = fitting.height > Self.maxHeight ? AnyView(ScrollView { card }) : AnyView(card)
        host.frame = NSRect(origin: .zero, size: size)
        let gap: CGFloat = 4
        var origin = NSPoint(x: word.minX - 8, y: word.maxY + gap)
        if origin.y + size.height > area.maxY { origin.y = word.minY - gap - size.height }
        present(in: window, frame: NSRect(origin: origin, size: size))

        if let tracking { contentView?.removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        contentView?.addTrackingArea(area)
        tracking = area
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }
}
