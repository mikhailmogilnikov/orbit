import AppKit
import OrbitAPI

/// A borderless popup that follows the editor window and never takes focus,
/// so typing stays in the text view.
class FloatingPanel: NSPanel {
    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        contentView = background
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Attached to the editor's window, in its light/dark appearance.
    func present(in window: NSWindow?, frame: NSRect) {
        guard let window else { return }
        if appearance != window.effectiveAppearance {
            appearance = window.effectiveAppearance
        }
        var border: CGColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance { border = NSColor.separatorColor.cgColor }
        contentView?.layer?.borderColor = border
        setFrame(Self.fitted(frame, on: window.screen), display: true)
        if parent !== window {
            parent?.removeChildWindow(self)
            window.addChildWindow(self, ordered: .above)
        }
        if !isVisible { orderFront(nil) }
        invalidateShadow()
    }

    func hide() {
        guard isVisible || parent != nil else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    private static func fitted(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
        guard let visible = screen?.visibleFrame else { return frame }
        var frame = frame
        frame.origin.x = min(max(visible.minX + 4, frame.origin.x), visible.maxX - frame.width - 4)
        return frame
    }
}

// MARK: Completion list

final class CompletionPanel: FloatingPanel {
    static let maxRows = 10

    let list = NSTableView()
    private let scroll = NSScrollView()
    private let separator = NSBox()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let keys = NSTextField(labelWithString: "")

    var pattern = FuzzyPattern("")
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet {
            guard font != oldValue else { return }
            boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            characterWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        }
    }
    private var boldFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .bold)
    private var characterWidth: CGFloat = 7.2
    private var rows = 0
    private var width: CGFloat = 360
    private var anchorRect: NSRect = .zero

    private var rowHeight: CGFloat { ceil(font.ascender - font.descender) + 7 }
    private var detailFont: NSFont { .systemFont(ofSize: max(10, font.pointSize - 1)) }

    init() {
        super.init(contentSize: NSSize(width: 360, height: 200))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column)
        list.headerView = nil
        list.style = .plain
        list.backgroundColor = .clear
        list.intercellSpacing = .zero
        list.allowsEmptySelection = false
        list.refusesFirstResponder = true
        list.usesAutomaticRowHeights = false
        list.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        separator.boxType = .separator
        details.font = .systemFont(ofSize: 11)
        details.textColor = .secondaryLabelColor
        details.maximumNumberOfLines = 4
        details.lineBreakMode = .byTruncatingTail
        details.isSelectable = false

        keys.font = .systemFont(ofSize: 10)
        keys.textColor = .tertiaryLabelColor
        keys.stringValue = "↑↓ choose  ·  ↩ or ⇥ insert  ·  ⎋ close"
        keys.lineBreakMode = .byTruncatingTail
        keys.isSelectable = false

        contentView?.addSubview(scroll)
        contentView?.addSubview(separator)
        contentView?.addSubview(details)
        contentView?.addSubview(keys)
    }

    func reload(rows: Int, widthHint: (label: Int, detail: Int)) {
        self.rows = rows
        list.rowHeight = rowHeight
        let detailWidth = CGFloat(widthHint.detail) * detailFont.pointSize * 0.55
        width = min(640, max(320, 30 + CGFloat(widthHint.label) * characterWidth + 24 + min(detailWidth, 260) + 12))
        list.reloadData()
    }

    func select(row: Int) {
        guard row >= 0, row < rows else { return }
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        list.scrollRowToVisible(row)
    }

    /// The selected item's signature and documentation under the list.
    func showDetails(of item: CompletionItem) {
        let documentation = item.documentation.map(Self.plainText) ?? ""
        let text = [item.detail ?? "", documentation].filter { !$0.isEmpty }.joined(separator: "\n")
        if details.stringValue != text {
            details.stringValue = text
            if isVisible { layoutPanel() }
        }
    }

    /// `rect` is the first character being completed, in screen coordinates.
    func show(below rect: NSRect, in window: NSWindow?) {
        anchorRect = rect
        layoutPanel(in: window ?? parent)
    }

    private func layoutPanel(in window: NSWindow? = nil) {
        let listHeight = CGFloat(min(rows, Self.maxRows)) * rowHeight + 8
        let hasDetails = !details.stringValue.isEmpty
        var detailsHeight: CGFloat = 0
        if hasDetails {
            details.preferredMaxLayoutWidth = width - 20
            let fitting = details.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 20, height: 80)).height ?? 14
            detailsHeight = min(ceil(fitting), 64)
        }
        // The keys, so they get learned (D67).
        let footer: CGFloat = 18
        let height = footer + listHeight + (hasDetails ? detailsHeight + 13 : 0)

        details.isHidden = !hasDetails
        separator.isHidden = !hasDetails
        keys.frame = NSRect(x: 10, y: 3, width: width - 20, height: 13)
        details.frame = NSRect(x: 10, y: footer + 4, width: width - 20, height: detailsHeight)
        separator.frame = NSRect(x: 0, y: footer + detailsHeight + 12, width: width, height: 1)
        scroll.frame = NSRect(x: 0, y: footer + (hasDetails ? detailsHeight + 13 : 0), width: width, height: listHeight)
        list.tableColumns.first?.width = width

        // Text in the rows lines up with the word being typed; above the line when there's no room below.
        var origin = NSPoint(x: anchorRect.minX - 30, y: anchorRect.minY - height - 2)
        if let screen = (window ?? parent)?.screen, origin.y < screen.visibleFrame.minY {
            origin.y = anchorRect.maxY + 2
        }
        present(in: window ?? parent, frame: NSRect(origin: origin, size: NSSize(width: width, height: height)))
    }

    func cell(for item: CompletionItem, in tableView: NSTableView) -> NSView {
        let cell = tableView.makeView(withIdentifier: CompletionCell.identifier, owner: nil) as? CompletionCell ?? CompletionCell()
        let style = CompletionKindStyle(item.kind)
        cell.badge.image = style.image
        cell.badge.contentTintColor = style.color

        let label = NSMutableAttributedString(string: item.label, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let match = pattern.match(Array(item.label.utf16)) {
            for position in match.positions where position < label.length {
                label.addAttribute(.font, value: boldFont, range: NSRange(location: position, length: 1))
            }
        }
        if item.isDeprecated {
            label.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: label.length))
        }
        cell.label.attributedStringValue = label
        cell.detail.stringValue = item.detail ?? ""
        cell.detail.font = detailFont
        cell.needsLayout = true
        return cell
    }

    /// Markdown to something readable in one small label.
    static func plainText(_ markdown: String) -> String {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("```") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class CompletionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompletionCell")

    let badge = NSImageView()
    let label = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        badge.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        addSubview(badge)
        addSubview(label)
        addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        badge.frame = NSRect(x: 9, y: (height - 15) / 2, width: 15, height: 15)
        let labelHeight = label.intrinsicContentSize.height
        let detailSize = detail.intrinsicContentSize
        let detailWidth = detail.stringValue.isEmpty ? 0 : min(detailSize.width, bounds.width * 0.45)
        detail.frame = NSRect(x: bounds.maxX - 10 - detailWidth, y: (height - detailSize.height) / 2, width: detailWidth, height: detailSize.height)
        let labelEnd = detailWidth > 0 ? detail.frame.minX - 12 : bounds.maxX - 10
        label.frame = NSRect(x: 30, y: (height - labelHeight) / 2, width: max(0, labelEnd - 30), height: labelHeight)
    }
}

/// A quiet selection that keeps the row's own text colors readable.
final class CompletionRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}

/// Xcode-style letter badges by kind.
@MainActor
struct CompletionKindStyle {
    let image: NSImage?
    let color: NSColor

    init(_ kind: CompletionItem.Kind?) {
        let (symbol, color): (String, NSColor) = switch kind {
        case .method, .constructor: ("m.square.fill", .systemBlue)
        case .function: ("f.square.fill", .systemBlue)
        case .field, .property: ("p.square.fill", .systemTeal)
        case .variable, .value: ("v.square.fill", .systemGreen)
        case .constant: ("k.square.fill", .systemGreen)
        case .`class`: ("c.square.fill", .systemPurple)
        case .`struct`: ("s.square.fill", .systemPurple)
        case .interface: ("i.square.fill", .systemPurple)
        case .`enum`: ("e.square.fill", .systemPurple)
        case .enumMember: ("e.square.fill", .systemOrange)
        case .typeParameter: ("t.square.fill", .systemPurple)
        case .module: ("n.square.fill", .systemGray)
        case .keyword: ("k.square.fill", .systemGray)
        case .snippet: ("curlybraces.square.fill", .systemGray)
        case .file, .reference: ("doc.fill", .systemGray)
        case .folder: ("folder.fill", .systemGray)
        default: ("t.square.fill", .systemGray)
        }
        self.image = Self.images[symbol] ?? Self.load(symbol)
        self.color = color
    }

    private static var images: [String: NSImage] = [:]

    private static func load(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        images[symbol] = image
        return image
    }
}

// MARK: Signature help

final class SignaturePanel: FloatingPanel {
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(contentSize: NSSize(width: 300, height: 30))
        label.isSelectable = false
        label.maximumNumberOfLines = 6
        contentView?.addSubview(label)
    }

    /// `rect` is the caret, in screen coordinates; the panel sits above its line.
    func show(_ help: SignatureHelp, font: NSFont?, above rect: NSRect, in window: NSWindow?) {
        let font = font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let signature = help.signatures[help.activeSignature]
        let active = signature.activeParameter ?? help.activeParameter
        let text = NSMutableAttributedString(
            string: signature.label,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
        if signature.parameters.indices.contains(active) {
            let range = signature.parameters[active]
            if range.length > 0, NSMaxRange(range) <= text.length {
                text.addAttributes([
                    .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                    .foregroundColor: NSColor.labelColor,
                ], range: range)
            }
        }
        if help.signatures.count > 1 {
            text.insert(NSAttributedString(
                string: "\(help.activeSignature + 1)/\(help.signatures.count)  ",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
            ), at: 0)
        }
        if let documentation = signature.documentation.map(CompletionPanel.plainText), !documentation.isEmpty {
            let firstParagraph = documentation.components(separatedBy: "\n\n").first ?? documentation
            text.append(NSAttributedString(
                string: "\n" + firstParagraph,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        label.attributedStringValue = text
        let maxWidth: CGFloat = 600
        label.preferredMaxLayoutWidth = maxWidth
        let size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth, height: 300)) ?? NSSize(width: 200, height: 18)
        let width = ceil(min(size.width, maxWidth)), height = ceil(min(size.height, 300))
        label.frame = NSRect(x: 10, y: 6, width: width, height: height)
        let frame = NSRect(x: rect.minX - 10, y: rect.maxY + 4, width: width + 20, height: height + 12)
        present(in: window, frame: frame)
    }
}
