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
        let found = Indentation.of(url, text: text, root: root, fallback: Preferences.shared.defaultIndentation)
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

/// Tabs drawn as wide as the file indents; Tab, ⇧Tab, Return and Backspace
/// by its indentation are `CaretEditing`'s (D202).
@MainActor
enum IndentEditing {
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
                    .orbitFont(.caption)
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
