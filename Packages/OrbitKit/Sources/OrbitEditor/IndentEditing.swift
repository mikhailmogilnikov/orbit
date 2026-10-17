import AppKit
import OrbitAPI
import SwiftUI
import STTextView

/// Each open file's indentation (D83): `.editorconfig`, else guessed from the
/// file when it opens, else what the user picked in the status bar.
@MainActor
@Observable
final class EditorIndentation {
    static let shared = EditorIndentation()

    private var byURL: [URL: Indentation] = [:]

    func indentation(for url: URL) -> Indentation? {
        byURL[url.standardizedFileURL]
    }

    /// Once per file: a later reopen keeps what was detected or picked.
    func detect(_ url: URL, text: String, root: URL?) -> Indentation {
        if let known = indentation(for: url) { return known }
        let found = Indentation.of(url, text: text, root: root)
        // Not during the view update that asked.
        DispatchQueue.main.async { [self] in
            if byURL[url.standardizedFileURL] == nil { byURL[url.standardizedFileURL] = found }
        }
        return found
    }

    func set(_ indentation: Indentation, for url: URL) {
        byURL[url.standardizedFileURL] = indentation
    }
}

/// Tab, ⇧Tab, Return and Backspace by the file's indentation, as other editors do.
@MainActor
enum IndentEditing {
    private static func text(_ textView: STTextView) -> NSString {
        ((textView.textContentManager as? NSTextContentStorage)?.textStorage?.string ?? textView.text ?? "") as NSString
    }

    /// Draws tabs `size` columns wide; false when they already were.
    @discardableResult
    static func apply(_ indentation: Indentation, to textView: STTextView) -> Bool {
        let style = textView.defaultParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        let space = (" " as NSString).size(withAttributes: [.font: textView.font]).width
        let interval = space * CGFloat(indentation.size)
        guard style.defaultTabInterval != interval || !style.tabStops.isEmpty else { return false }
        style.tabStops = []
        style.defaultTabInterval = interval
        textView.defaultParagraphStyle = style
        return true
    }

    /// Columns from the line's start to `offset`, tabs expanded.
    private static func column(of offset: Int, lineStart: Int, in string: NSString, size: Int) -> Int {
        var column = 0
        for index in lineStart..<offset {
            column = string.character(at: index) == 0x09 ? column + size - column % size : column + 1
        }
        return column
    }

    private static func leadingWhitespace(of line: NSRange, in string: NSString) -> NSRange {
        var end = line.location
        while end < NSMaxRange(line), [0x20, 0x09].contains(string.character(at: end)) { end += 1 }
        return NSRange(location: line.location, length: end - line.location)
    }

    /// Tab: up to the next indent stop, or indents every selected line.
    static func insertTab(in textView: STTextView, indentation: Indentation) {
        let string = text(textView)
        let selection = textView.textSelection
        if selection.length > 0, string.substring(with: selection).contains("\n") {
            shiftLines(in: textView, indentation: indentation, outward: false)
            return
        }
        let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let unit = indentation.spaces
            ? String(repeating: " ", count: indentation.size - column(of: selection.location, lineStart: lineStart, in: string, size: indentation.size) % indentation.size)
            : "\t"
        textView.insertText(unit, replacementRange: selection)
    }

    /// ⇧Tab: one level out on every line the selection touches.
    static func insertBacktab(in textView: STTextView, indentation: Indentation) {
        shiftLines(in: textView, indentation: indentation, outward: true)
    }

    private static func shiftLines(in textView: STTextView, indentation: Indentation, outward: Bool) {
        let string = text(textView)
        let selection = textView.textSelection
        var lines = string.lineRange(for: selection)
        // A selection ending at a line's start doesn't take that line.
        if selection.length > 0, NSMaxRange(selection) > lines.location, string.character(at: NSMaxRange(selection) - 1) == 0x0A {
            lines.length = NSMaxRange(selection) - lines.location
        }
        var result: [String] = []
        var firstDelta = 0
        for (index, line) in string.substring(with: lines).components(separatedBy: "\n").enumerated() {
            var changed = line
            if outward {
                if line.hasPrefix("\t") {
                    changed.removeFirst()
                } else {
                    changed.removeFirst(min(indentation.size, line.prefix { $0 == " " }.count))
                }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                changed = indentation.unit + line
            }
            if index == 0 { firstDelta = (changed as NSString).length - (line as NSString).length }
            result.append(changed)
        }
        let replacement = result.joined(separator: "\n")
        guard replacement != string.substring(with: lines) else { return }
        textView.breakUndoCoalescing()
        textView.insertText(replacement, replacementRange: lines)
        textView.breakUndoCoalescing()
        let length = (replacement as NSString).length
        textView.textSelection = selection.length == 0
            ? NSRange(location: max(lines.location, selection.location + firstDelta), length: 0)
            : NSRange(location: lines.location, length: length)
    }

    /// Return keeps the line's indentation, one level deeper after an opening
    /// bracket; between a pair (`{|}`) the closing one goes on its own line.
    static func insertNewline(in textView: STTextView, indentation: Indentation) {
        let string = text(textView)
        let selection = textView.textSelection
        let line = string.lineRange(for: NSRange(location: selection.location, length: 0))
        let leading = leadingWhitespace(of: line, in: string)
        let indent = string.substring(with: NSRange(location: leading.location, length: min(leading.length, selection.location - leading.location)))
        let before = string.substring(with: NSRange(location: line.location, length: selection.location - line.location))
            .trimmingCharacters(in: .whitespaces)
        let after = NSMaxRange(selection) < string.length ? string.substring(with: NSRange(location: NSMaxRange(selection), length: 1)) : ""
        let pairs: [Character: String] = ["{": "}", "[": "]", "(": ")"]

        var inserted = "\n" + indent
        var caret: Int?
        if let opener = before.last, let closer = pairs[opener] {
            inserted += indentation.unit
            if after == closer {
                caret = (inserted as NSString).length
                inserted += "\n" + indent
            }
        }
        textView.breakUndoCoalescing()
        textView.insertText(inserted, replacementRange: selection)
        textView.breakUndoCoalescing()
        if let caret { textView.textSelection = NSRange(location: selection.location + caret, length: 0) }
    }

    /// Backspace in a line's leading spaces deletes back to the previous indent stop.
    static func deleteBackward(in textView: STTextView, indentation: Indentation) -> Bool {
        guard indentation.spaces, indentation.size > 1 else { return false }
        let string = text(textView)
        let selection = textView.textSelection
        guard selection.length == 0, selection.location > 0 else { return false }
        let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = NSRange(location: lineStart, length: selection.location - lineStart)
        guard before.length > 0, string.substring(with: before).allSatisfy({ $0 == " " }) else { return false }
        let count = (before.length - 1) % indentation.size + 1
        textView.insertText("", replacementRange: NSRange(location: selection.location - count, length: count))
        return true
    }
}

/// "Spaces: 2" in the status bar; picks the active file's indentation.
struct IndentationStatus: View {
    let workspace: Workspace

    var body: some View {
        if let url = EditorPlugin.activeDocument(workspace)?.url,
           let current = EditorIndentation.shared.indentation(for: url) {
            Menu {
                Picker("Indent Using", selection: Binding(
                    get: { current.spaces },
                    set: { EditorIndentation.shared.set(Indentation(size: current.size, spaces: $0), for: url) }
                )) {
                    Text("Spaces").tag(true)
                    Text("Tabs").tag(false)
                }
                .pickerStyle(.inline)
                Picker(current.spaces ? "Indent Width" : "Tab Width", selection: Binding(
                    get: { current.size },
                    set: { EditorIndentation.shared.set(Indentation(size: $0, spaces: current.spaces), for: url) }
                )) {
                    ForEach([2, 3, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(current.spaces ? "Spaces: \(current.size)" : "Tab Size: \(current.size)")
                    .font(.orbit(.caption))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Indentation of this file: from .editorconfig, else detected from the file")
        }
    }
}
