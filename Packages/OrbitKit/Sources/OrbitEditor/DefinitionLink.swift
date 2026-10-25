import AppKit
import OrbitAPI
@_spi(Plugins) import STTextView

/// With ⌘ held, the symbol under the pointer is underlined like a link when
/// the server knows its definition, and the pointer turns into a hand: the
/// ⌘-click is seen before it's made, as in VS Code (D67).
@MainActor
final class DefinitionLinkController {
    weak var textView: STTextView?
    let geometry: DiagnosticsController
    weak var languages: LanguageIntelligence?
    var url: URL?
    /// Text-view coordinates of the pointer, nil while it's outside.
    var pointer: NSPoint?
    var characterOffset: (NSPoint) -> Int? = { _ in nil }

    private var range: NSRange?
    private var underline: NSView?
    private var request: Task<Void, Never>?

    init(geometry: DiagnosticsController) {
        self.geometry = geometry
    }

    var isShown: Bool { underline != nil }

    /// On a pointer move or a modifier change.
    func update(modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard modifiers.intersection([.command, .control, .option, .shift]) == .command,
              let pointer, let languages, let url, languages.server(for: url) != nil,
              let offset = characterOffset(pointer), let word = wordRange(at: offset) else {
            clear()
            return
        }
        if word == range {
            if underline != nil { NSCursor.pointingHand.set() }
            return
        }
        clear()
        range = word
        let position = SourcePosition(offset: offset, in: geometry.lineStarts)
        request = Task { [weak self] in
            let found = await languages.definition(at: position, in: url)
            guard let self, !Task.isCancelled, self.range == word, !found.isEmpty else { return }
            self.show(word)
        }
    }

    func clear() {
        request?.cancel()
        request = nil
        range = nil
        guard let underline else { return }
        underline.removeFromSuperview()
        self.underline = nil
        NSCursor.iBeam.set()
    }

    private func show(_ word: NSRange) {
        guard let textView, let rect = geometry.rects(for: word).first else { return }
        let view = LinkUnderline(frame: NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 1))
        textView.addSubview(view)
        underline = view
        NSCursor.pointingHand.set()
    }

    private func wordRange(at offset: Int) -> NSRange? {
        guard let string = geometry.string, offset < string.length, Self.isWord(string.character(at: offset)) else { return nil }
        var start = offset, end = offset + 1
        while start > 0, Self.isWord(string.character(at: start - 1)) { start -= 1 }
        while end < string.length, Self.isWord(string.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isWord(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
    }
}

private final class LinkUnderline: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.linkColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.linkColor.cgColor
        }
    }
}
