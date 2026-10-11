import AppKit
import OrbitAPI
import OrbitUI
import STPluginNeon
import STTextView
import SwiftUI
import TreeSitterResource

/// SwiftUI bridge around STTextView, bound to a `TextDocument`, with
/// agent changes shown inline.
struct CodeEditor: NSViewRepresentable {
    let document: TextDocument
    var hunks: [DiffHunk] = []
    var onKeep: (DiffHunk) -> Void = { _ in }
    var onRevert: (DiffHunk) -> Void = { _ in }
    /// 0-based line to scroll to once; `onRevealHandled` clears the request.
    var revealLine: Int?
    var onRevealHandled: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = OrbitTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView
        textView.font = .monospacedSystemFont(ofSize: Theme.codeFontSize, weight: .regular)
        // Our own ruler instead of STTextView's gutter (see LineNumberRuler).
        textView.showsLineNumbers = false
        textView.highlightSelectedLine = true
        textView.isHorizontallyResizable = true
        textView.isIncrementalSearchingEnabled = true
        textView.text = document.text
        textView.textDelegate = context.coordinator

        if let language = Language.treeSitter(for: document.url) {
            textView.addPlugin(SyntaxHighlightPlugin(theme: .default, language: language))
        }
        let coordinator = context.coordinator
        coordinator.inlineDiff.textView = textView
        textView.addPlugin(InlineDiffPlugin(controller: coordinator.inlineDiff))

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        textView.addPlugin(LineNumberRulerPlugin(ruler: ruler))
        coordinator.ruler = ruler

        coordinator.textView = textView
        coordinator.syncedRevision = document.revision
        ActiveEditor.shared.coordinator = coordinator
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }

        // Only push text in when it changed outside the view (agent, review, reload).
        if document.revision != coordinator.syncedRevision {
            coordinator.syncedRevision = document.revision
            if textView.text != document.text {
                let selection = textView.textSelection
                coordinator.isApplyingExternalChange = true
                textView.text = document.text
                coordinator.isApplyingExternalChange = false
                let length = (document.text as NSString).length
                textView.textSelection = NSRange(location: min(selection.location, length), length: 0)
                coordinator.inlineDiff.invalidate()
            }
        }

        coordinator.inlineDiff.onKeep = onKeep
        coordinator.inlineDiff.onRevert = onRevert
        coordinator.inlineDiff.update(hunks: hunks, revision: document.revision)

        if let revealLine {
            DispatchQueue.main.async {
                coordinator.reveal(line: revealLine)
                onRevealHandled()
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if ActiveEditor.shared.coordinator === coordinator { ActiveEditor.shared.coordinator = nil }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        let document: TextDocument
        let inlineDiff = InlineDiffController()
        weak var textView: STTextView?
        weak var ruler: LineNumberRuler?
        var syncedRevision = 0
        var isApplyingExternalChange = false

        init(document: TextDocument) {
            self.document = document
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard !isApplyingExternalChange, let textView else { return }
            document.text = textView.text ?? ""
            syncedRevision = document.revision
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            ActiveEditor.shared.coordinator = self
            ruler?.needsDisplay = true
        }

        /// 0-based line of the insertion point.
        var cursorLine: Int {
            guard let textView else { return 0 }
            let text = (textView.text ?? "") as NSString
            let location = min(textView.textSelection.location, text.length)
            var line = 0
            text.enumerateSubstrings(in: NSRange(location: 0, length: location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
                line += 1
            }
            // `byLines` doesn't count a trailing empty line segment.
            if location > 0, text.character(at: location - 1) == 0x0A { return line }
            return max(0, line - 1)
        }

        func reveal(line: Int) {
            guard let textView else { return }
            let text = (textView.text ?? "") as NSString
            let starts = InlineDiffController.lineStarts(of: text)
            let offset = starts[min(max(0, line), starts.count - 1)]
            textView.textSelection = NSRange(location: offset, length: 0)
            // Scroll a few lines past the target so the removed-lines gap above it is visible too.
            let context = starts[min(starts.count - 1, max(0, line + 6))]
            textView.scrollRangeToVisible(NSRange(location: context, length: 0))
            textView.scrollRangeToVisible(NSRange(location: starts[max(0, line - 4)], length: 0))
            textView.window?.makeFirstResponder(textView)
        }

        func revealHunk(after line: Int, forward: Bool) {
            let hunks = inlineDiff.hunks
            guard !hunks.isEmpty else { return }
            let target = forward
                ? hunks.first { $0.newRange.lowerBound > line } ?? hunks.first
                : hunks.last { $0.newRange.lowerBound < line } ?? hunks.last
            if let target { reveal(line: target.newRange.lowerBound) }
        }
    }
}

/// STTextView hardened against invalid input from accessibility clients
/// (VoiceOver, automation): out-of-range selections crash the stock view.
final class OrbitTextView: STTextView {
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        super.setAccessibilitySelectedTextRange(clamped(range))
    }

    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        super.setAccessibilitySelectedTextRanges(ranges?.map { NSValue(range: clamped($0.rangeValue)) })
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let length = textContentManager.length
        let location = range.location == NSNotFound ? length : min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }
}

/// The editor that last had focus, for keyboard commands.
@MainActor
final class ActiveEditor {
    static let shared = ActiveEditor()
    weak var coordinator: CodeEditor.Coordinator?
}

@MainActor
final class EditorSelectionService: EditorSelectionProviding {
    var selection: EditorSelection? {
        guard let coordinator = ActiveEditor.shared.coordinator, let textView = coordinator.textView else { return nil }
        let text = (textView.text ?? "") as NSString
        let range = NSIntersectionRange(textView.textSelection, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return nil }
        let selected = text.substring(with: range)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let starts = InlineDiffController.lineStarts(of: text)
        func line(at offset: Int) -> Int { (starts.lastIndex { $0 <= offset } ?? 0) + 1 }
        // A selection ending right after a newline doesn't include the next line.
        let first = line(at: range.location)
        let last = max(first, line(at: NSMaxRange(range) - 1))
        return EditorSelection(url: coordinator.document.url, text: selected, lines: first...last)
    }
}

enum Language {
    static func treeSitter(for url: URL) -> TreeSitterLanguage? {
        switch url.pathExtension.lowercased() {
        case "swift": .swift
        case "js", "mjs", "cjs", "jsx": .javascript
        case "ts", "mts", "cts", "tsx": .typescript
        case "json", "jsonc": .json
        case "py": .python
        case "rb": .ruby
        case "rs": .rust
        case "go": .go
        case "c", "h": .c
        case "cpp", "cc", "cxx", "hpp", "mm", "m": .cpp
        case "cs": .csharp
        case "java", "kt": .java
        case "php": .php
        case "html", "htm": .html
        case "css", "scss": .css
        case "md", "markdown": .markdown
        case "sh", "bash", "zsh": .bash
        case "sql": .sql
        case "toml": .toml
        case "yml", "yaml": .yaml
        default: nil
        }
    }
}
