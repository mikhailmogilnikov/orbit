import OrbitAPI
import OrbitUI
import SwiftUI

/// Who last changed the line under the caret, in the status bar.
struct BlameStatus: View {
    let model: GitModel
    let editor: EditorSelectionProviding
    let workspace: Workspace
    @State private var blame: GitBlameLine?

    var body: some View {
        let cursor = editor.cursor
        let revision = cursor.flatMap { workspace.documents.existingDocument(for: $0.url)?.revision } ?? 0
        Group {
            if let blame {
                Label {
                    Text(text(for: blame))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: "person.crop.circle")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360, alignment: .trailing)
                .help(blame.isCommitted ? "\(blame.hash.prefix(8)) · \(blame.author)\n\(blame.summary)" : "This line isn't committed yet")
            }
        }
        .task(id: BlameKey(cursor: cursor, revision: revision, generation: model.baselineGeneration)) {
            // Typing changes the text (and the blame) constantly; wait for a pause.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let cursor, let text = workspace.documents.currentText(of: cursor.url) else {
                blame = nil
                return
            }
            let lines = await model.blame(cursor.url, contents: text)
            guard !Task.isCancelled else { return }
            blame = lines.flatMap { cursor.line < $0.count ? $0[cursor.line] : nil }
        }
    }

    private func text(for blame: GitBlameLine) -> String {
        guard blame.isCommitted else { return "Not committed yet" }
        let when = blame.date.formatted(.relative(presentation: .named))
        return "\(blame.author), \(when) · \(blame.summary)"
    }

    private struct BlameKey: Equatable {
        let cursor: EditorCursor?
        let revision: Int
        let generation: Int
    }
}
