import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI
@_spi(Plugins) import STTextView

struct FindOptions: Hashable, Sendable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}

/// The matching behind Find in File; Find in Project has its own copy (plugins don't share code).
enum FindMatching {
    static let limit = 10_000
    /// `\b` and lookbehinds see the text around a range searched from the middle.
    static let bounds: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]

    static func regex(_ query: String, options: FindOptions) -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        return try? NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
    }

    /// Empty matches (`a*`) are skipped: nothing to show or replace.
    static func ranges(of regex: NSRegularExpression, in text: NSString, limit: Int = limit) -> (ranges: [NSRange], isTruncated: Bool) {
        var ranges: [NSRange] = []
        var isTruncated = false
        regex.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { result, _, stop in
            guard let range = result?.range, range.length > 0 else { return }
            guard ranges.count < limit else {
                isTruncated = true
                stop.pointee = true
                return
            }
            ranges.append(range)
        }
        return (ranges, isTruncated)
    }

    /// `$1` and friends only mean something in regex mode.
    static func template(for replacement: String, options: FindOptions) -> String {
        options.regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    /// What `range` (a match of `regex`) becomes; nil when it no longer matches there.
    static func replacement(for range: NSRange, regex: NSRegularExpression, template: String, in text: NSString) -> String? {
        let tail = NSRange(location: range.location, length: text.length - range.location)
        guard let result = regex.firstMatch(in: text as String, options: bounds, range: tail), result.range == range else { return nil }
        return regex.replacementString(for: result, in: text as String, offset: 0, template: template)
    }

    /// The text from the first match to the end of the last, every match replaced, and how many.
    static func replaceAll(in text: NSString, regex: NSRegularExpression, template: String) -> (span: NSRange, text: String, count: Int)? {
        let output = NSMutableString()
        var first: Int?
        var last = 0
        var count = 0
        regex.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { result, _, _ in
            guard let result, result.range.length > 0 else { return }
            if first == nil {
                first = result.range.location
            } else {
                output.append(text.substring(with: NSRange(location: last, length: result.range.location - last)))
            }
            output.append(regex.replacementString(for: result, in: text as String, offset: 0, template: template))
            last = NSMaxRange(result.range)
            count += 1
        }
        guard let first else { return nil }
        return (NSRange(location: first, length: last - first), output as String, count)
    }

    /// The match after the selection (or at a caret), wrapping around.
    static func next(after selection: NSRange, in ranges: [NSRange]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        let from = NSMaxRange(selection)
        return ranges.firstIndex { $0.location >= from } ?? 0
    }

    /// The match before the selection, wrapping around.
    static func previous(before selection: NSRange, in ranges: [NSRange]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        return ranges.lastIndex { NSMaxRange($0) <= selection.location && $0 != selection } ?? ranges.count - 1
    }
}

@MainActor @Observable
final class FindModel {
    enum Field: Hashable { case query, replacement }

    var query = "" { didSet { if query != oldValue { onChange() } } }
    var replacement = ""
    var options = FindOptions() { didSet { if options != oldValue { onChange() } } }
    var isReplaceShown = false
    var matchCount = 0
    /// 0-based; nil while the caret isn't on a match.
    var current: Int?
    var isTruncated = false
    var isInvalid = false
    /// After Replace All, until the search changes.
    var replacedCount: Int?
    private(set) var focusRequest: (field: Field, serial: Int) = (.query, 0)

    @ObservationIgnored var onChange: () -> Void = {}

    func focus(_ field: Field) {
        focusRequest = (field, focusRequest.serial + 1)
    }
}

/// Find in File (⌘F): a Liquid Glass panel floating over the editor's top
/// right corner, matches filled behind the text and marked on the overview
/// ruler (D227). Replaces NSTextFinder's bar, which couldn't take the theme or glass.
@MainActor
final class FindController {
    weak var textView: STTextView?
    weak var scrollView: EditorScrollView?
    let geometry: DiagnosticsController
    let model = FindModel()
    /// Lines with a match, for the overview ruler; empty while the panel is closed.
    var onMatchesChange: ((IndexSet) -> Void)?
    private(set) var isVisible = false
    /// The scroll view holds it; the panel holds this controller.
    private(set) weak var panel: NSView?
    private var matches: [NSRange] = []
    private var regex: NSRegularExpression?
    /// Where typing searches from: the caret when the panel opened or the user last moved it.
    private var searchStart = 0
    /// The selection find made, to tell it from one the user made.
    private var selected: NSRange?
    private var isStale = true
    private var refresh: Task<Void, Never>?
    private let overlays = OverlaySet()
    private var isLayoutScheduled = false

    struct Colors: Equatable {
        var match: NSColor = .clear
        var current: NSColor = .clear
    }

    var colors = Colors() {
        didSet { if colors != oldValue { setNeedsLayout() } }
    }

    init(geometry: DiagnosticsController) {
        self.geometry = geometry
        model.onChange = { [weak self] in self?.searchChanged() }
    }

    func perform(_ action: NSTextFinder.Action) {
        switch action {
        case .showFindInterface: show(replace: false)
        case .showReplaceInterface: show(replace: true)
        case .nextMatch: step(forward: true)
        case .previousMatch: step(forward: false)
        case .setSearchString: useSelection()
        case .hideFindInterface: hide()
        case .replace, .replaceAndFind: replace()
        case .replaceAll: replaceAll()
        default: NSSound.beep()
        }
    }

    func show(replace: Bool) {
        guard let textView else { return }
        let selection = textView.textSelection
        // A new selection seeds the search, as in Xcode: one line, not too long.
        if selection.length > 0, selection.length <= 500, selection != selected {
            let text = textView.documentText.substring(with: selection)
            if !text.contains(where: \.isNewline) { model.query = text }
        }
        if !isVisible {
            isVisible = true
            searchStart = selection.location
            attachPanel()
            search(selects: true)
        }
        if replace { model.isReplaceShown = true }
        model.focus(replace ? .replacement : .query)
    }

    func hide(focusingEditor: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        refresh?.cancel()
        panel?.removeFromSuperview()
        panel = nil
        overlays.removeAll()
        onMatchesChange?([])
        if focusingEditor, let textView { textView.window?.makeFirstResponder(textView) }
    }

    /// ⌘E: the selection becomes what's searched for, without opening the panel.
    func useSelection() {
        guard let textView, textView.textSelection.length > 0 else { return NSSound.beep() }
        searchStart = textView.textSelection.location
        model.query = textView.documentText.substring(with: textView.textSelection)
        selected = textView.textSelection
    }

    /// ⌘G / ⇧⌘G and the panel's arrows; with nothing to look for, they open the panel.
    func step(forward: Bool) {
        guard let textView, !model.query.isEmpty else { return show(replace: false) }
        if isStale || !isVisible { search(selects: false) }
        let selection = textView.textSelection
        guard let index = forward ? FindMatching.next(after: selection, in: matches) : FindMatching.previous(before: selection, in: matches) else {
            return NSSound.beep()
        }
        select(index)
    }

    func replace() {
        guard let textView, let regex, let index = model.current, matches.indices.contains(index),
              textView.textSelection == matches[index] else { return step(forward: true) }
        let range = matches[index]
        let template = FindMatching.template(for: model.replacement, options: model.options)
        guard let replacement = FindMatching.replacement(for: range, regex: regex, template: template, in: textView.documentText) else {
            return search(selects: true)
        }
        textView.breakUndoCoalescing()
        textView.insertText(replacement, replacementRange: range)
        textView.breakUndoCoalescing()
        searchStart = range.location + replacement.utf16.count
        search(selects: true)
    }

    /// One edit from the first match to the last: a single undo, and one pass
    /// for the highlighter and the change markers.
    func replaceAll() {
        guard let textView, let regex else { return NSSound.beep() }
        let template = FindMatching.template(for: model.replacement, options: model.options)
        guard let result = FindMatching.replaceAll(in: textView.documentText, regex: regex, template: template) else { return NSSound.beep() }
        textView.breakUndoCoalescing()
        textView.insertText(result.text, replacementRange: result.span)
        textView.breakUndoCoalescing()
        textView.textSelection = NSRange(location: result.span.location, length: 0)
        searchStart = result.span.location
        search(selects: false)
        model.replacedCount = result.count
    }

    func textDidChange() {
        guard !model.query.isEmpty else { return }
        isStale = true
        guard isVisible else { return }
        refresh?.cancel()
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, isVisible else { return }
            let replaced = model.replacedCount
            search(selects: false)
            model.replacedCount = replaced
        }
    }

    func selectionDidChange() {
        guard let textView, textView.textSelection != selected else { return }
        selected = nil
        searchStart = textView.textSelection.location
        let current = matches.firstIndex(of: textView.textSelection)
        if model.current != current { model.current = current }
        setNeedsLayout()
    }

    private func searchChanged() {
        model.replacedCount = nil
        isStale = true
        if isVisible { search(selects: true) }
    }

    /// Finds every match; with `selects`, the first one from `searchStart` is selected and scrolled to.
    private func search(selects: Bool) {
        guard let textView else { return }
        isStale = false
        regex = FindMatching.regex(model.query, options: model.options)
        model.isInvalid = regex == nil && !model.query.isEmpty
        let text = textView.documentText
        (matches, model.isTruncated) = regex.map { FindMatching.ranges(of: $0, in: text) } ?? ([], false)
        model.matchCount = matches.count
        if selects, let index = matches.firstIndex(where: { $0.location >= searchStart }) ?? (matches.isEmpty ? nil : 0) {
            select(index)
        } else {
            model.current = matches.firstIndex(of: textView.textSelection)
        }
        if isVisible {
            let starts = geometry.lineStarts
            onMatchesChange?(IndexSet(matches.map { SourcePosition(offset: $0.location, in: starts).line }))
        }
        setNeedsLayout()
    }

    private func select(_ index: Int) {
        guard let textView else { return }
        let range = matches[index]
        model.current = index
        selected = range
        searchStart = range.location
        textView.textSelection = range
        scrollIntoView(range)
        setNeedsLayout()
    }

    /// Visible, and not under the panel: a match that would be is brought to a third of the way down.
    private func scrollIntoView(_ range: NSRange) {
        guard let textView else { return }
        textView.scrollRangeToVisible(range)
        guard let rect = geometry.rects(for: range).first else { return }
        let visible = textView.visibleRect
        let covered = (panel?.frame.height ?? 0) + 12
        if rect.minY < visible.minY + covered || rect.maxY > visible.maxY {
            textView.scroll(NSPoint(x: visible.minX, y: max(0, rect.minY - visible.height / 3)))
        }
    }

    private func attachPanel() {
        guard let scrollView, panel == nil else { return }
        let host = FindPanelHost(rootView: FindPanel(model: model, controller: self))
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        scrollView.addSubview(host)
        panel = host
        scrollView.tile()
    }

    /// The replace row came or went: the panel's frame follows.
    func panelSizeDidChange() {
        DispatchQueue.main.async { [weak self] in self?.scrollView?.tile() }
    }

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
        guard isVisible, let textView, !matches.isEmpty else { return }
        let manager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        guard let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let start = manager.documentRange.location
        let lower = contentManager.offset(from: start, to: viewport.location)
        let upper = contentManager.offset(from: start, to: viewport.endLocation)
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -200)
        let first = matches.firstIndex { NSMaxRange($0) > lower } ?? matches.count
        for index in first..<matches.count {
            let range = matches[index]
            guard range.location < upper else { break }
            let isCurrent = index == model.current
            for rect in geometry.rects(for: range) where rect.intersects(visible) {
                let frame = rect.insetBy(dx: -1, dy: 0)
                let colors = colors
                // The current match is selected, and the selection covers what's behind the
                // text: its ring goes over the text instead.
                overlays.place(frame, isCurrent, colors.match, colors.current, frame: frame, in: textView, below: !isCurrent) {
                    let view = MatchView(frame: frame)
                    view.layer?.backgroundColor = (isCurrent ? colors.current.withAlphaComponent(0.25) : colors.match).cgColor
                    if isCurrent {
                        view.layer?.borderColor = colors.current.cgColor
                        view.layer?.borderWidth = 1.5
                    }
                    return view
                }
            }
        }
    }
}

private final class MatchView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Sized by the scroll view's `tile()`; re-tiles once SwiftUI knows its height.
final class FindPanelHost: NSHostingView<FindPanel> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = superview as? NSScrollView, frame.height != intrinsicContentSize.height else { return }
            scrollView.tile()
        }
    }
}

struct FindPlugin: STPlugin {
    let controller: FindController

    func setUp(context: any Context) {
        let controller = controller
        context.events.onDidLayoutViewport { _ in
            MainActor.assumeIsolated { controller.setNeedsLayout() }
        }
    }
}

struct FindPanel: View {
    static let maxWidth: CGFloat = 440
    /// Room around the glass for its shadow.
    static let margin: CGFloat = 4

    @Bindable var model: FindModel
    let controller: FindController
    @FocusState private var focus: FindModel.Field?

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            Button {
                model.isReplaceShown.toggle()
                focus = model.isReplaceShown ? .replacement : .query
            } label: {
                DisclosureChevron(isExpanded: model.isReplaceShown)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(model.isReplaceShown ? "Hide Replace" : "Show Replace (⌥⌘F)")
            .accessibilityLabel(model.isReplaceShown ? "Hide Replace" : "Show Replace")

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    FindField(systemImage: "magnifyingglass", placeholder: "Find", text: $model.query, field: .query, focus: $focus, isInvalid: model.isInvalid) {
                        counter
                        FindOptionToggle(label: "Aa", help: "Match Case", isOn: $model.options.caseSensitive)
                        FindOptionToggle(label: "ab", help: "Match Whole Word", underline: true, isOn: $model.options.wholeWord)
                        FindOptionToggle(label: ".*", help: "Use Regular Expression", isOn: $model.options.regex)
                    }
                    .onSubmit { controller.step(forward: true) }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        controller.step(forward: false)
                        return .handled
                    }
                    HStack(spacing: 0) {
                        FindIconButton(systemImage: "chevron.up", help: "Find Previous (⇧⌘G)", isEnabled: model.matchCount > 0) {
                            controller.step(forward: false)
                        }
                        FindIconButton(systemImage: "chevron.down", help: "Find Next (⌘G)", isEnabled: model.matchCount > 0) {
                            controller.step(forward: true)
                        }
                        FindIconButton(systemImage: "xmark", help: "Done (Esc)") { controller.hide() }
                    }
                    .frame(width: Self.trailingWidth, alignment: .trailing)
                }
                if model.isReplaceShown {
                    HStack(spacing: 6) {
                        FindField(systemImage: "arrow.2.squarepath", placeholder: "Replace", text: $model.replacement, field: .replacement, focus: $focus) {}
                            .onSubmit { controller.replace() }
                        HStack(spacing: 2) {
                            Button("Replace") { controller.replace() }
                                .help("Replace and Find Next (↩)")
                            Button("All") { controller.replaceAll() }
                                .help("Replace All")
                        }
                        .buttonStyle(HunkActionStyle())
                        .orbitFont(.caption, weight: .medium)
                        .disabled(model.matchCount == 0)
                        .frame(width: Self.trailingWidth, alignment: .trailing)
                    }
                }
            }
        }
        .onExitCommand { controller.hide() }
        .padding(6)
        // Clear glass let the code under it read through the field; the tint keeps the query legible.
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)), in: .rect(cornerRadius: Theme.largeCorner))
        .padding(Self.margin)
        .onAppear {
            focus = model.focusRequest.field
            controller.panelSizeDidChange()
        }
        .onChange(of: model.isReplaceShown) { controller.panelSizeDidChange() }
        .onChange(of: model.focusRequest.serial) { focus = model.focusRequest.field }
    }

    private static let trailingWidth: CGFloat = 100

    @ViewBuilder
    private var counter: some View {
        let text: String? = if model.query.isEmpty {
            nil
        } else if let replaced = model.replacedCount {
            "\(replaced) replaced"
        } else if model.isInvalid {
            "Invalid"
        } else if model.matchCount == 0 {
            "No results"
        } else if let current = model.current {
            "\(current + 1) of \(model.matchCount)\(model.isTruncated ? "+" : "")"
        } else {
            "\(model.matchCount)\(model.isTruncated ? "+" : "") found"
        }
        if let text {
            Text(text)
                .orbitFont(.caption)
                .monospacedDigit()
                .foregroundStyle(model.isInvalid ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 4)
        }
    }
}

private struct FindField<Accessories: View>: View {
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    let field: FindModel.Field
    var focus: FocusState<FindModel.Field?>.Binding
    var isInvalid = false
    @ViewBuilder var accessories: Accessories

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused(focus, equals: field)
            HStack(spacing: 1) { accessories }
        }
        .orbitFont(.body)
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .frame(height: 26)
        .background(Theme.subtleFill, in: .capsule)
        .overlay(
            Capsule()
                .strokeBorder(isInvalid ? AnyShapeStyle(.red.opacity(0.6)) : AnyShapeStyle(Theme.hairline))
        )
    }
}

private struct FindOptionToggle: View {
    let label: String
    let help: String
    var underline = false
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .orbitFont(.caption, weight: .semibold, design: .monospaced)
                .underline(underline)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 20)
                .background(isOn ? Theme.selectedFill : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct FindIconButton: View {
    let systemImage: String
    let help: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .orbitFont(.caption, weight: .semibold)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 26, height: 26)
                .background(isHovering && isEnabled ? Theme.hoverFill : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(String(help.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces))
    }
}
