import OrbitAPI
import SwiftUI

/// Encoding and line endings of the active file, shown only when they aren't
/// UTF-8 and LF (nearly every file is): the menu converts or reopens it.
struct FileFormatStatus: View {
    let workspace: Workspace

    var body: some View {
        if let document = EditorPlugin.activeDocument(workspace), !document.format.isDefault {
            let format = document.format
            Menu {
                FileFormatMenu(document: document)
            } label: {
                Text([
                    format.encoding != .utf8 || format.hasBOM ? format.encodingName : nil,
                    format.lineEnding != .lf ? format.lineEnding.rawValue : nil,
                ].compactMap(\.self).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Encoding and line endings of this file on disk; saving keeps them")
        }
    }
}

struct FileFormatMenu: View {
    let document: TextDocument

    var body: some View {
        if document.loadError == nil {
            Picker("Line Endings", selection: Binding(
                get: { document.format.lineEnding },
                set: { document.format.lineEnding = $0 }
            )) {
                ForEach(TextFileFormat.LineEnding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Menu("Save with Encoding") {
                ForEach(TextFile.encodings, id: \.name) { entry in
                    Button(entry.name) {
                        document.format.encoding = entry.encoding
                        document.format.hasBOM = false
                    }
                }
            }
            if document.format.hasBOM {
                Button("Remove Byte Order Mark") { document.format.hasBOM = false }
            }
        }
        Menu("Reopen with Encoding") {
            ForEach(TextFile.encodings, id: \.name) { entry in
                Button(entry.name) { document.reopen(as: entry.encoding) }
            }
        }
        .disabled(document.isDirty)
    }
}
