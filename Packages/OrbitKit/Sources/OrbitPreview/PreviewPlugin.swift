import OrbitAPI
import SwiftUI

/// Images and PDFs open in a viewer instead of the text editor; Markdown gets
/// a live preview tab (D89).
public final class PreviewPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.preview",
        name: "Preview",
        summary: "View images and PDFs, preview Markdown.",
        systemImage: "eye"
    )

    static let markdownKind = "markdown.preview"
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns", "avif"]
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx", "mdown"]

    public init() {}

    public func activate(_ context: PluginContext) {
        let workspace = context.workspace
        let services = context.services
        let commands = context.commands

        // Above the text editor (priority 0) for files it can't show.
        context.ui.addEditorProvider(EditorProvider(
            id: "preview.media",
            priority: 10,
            accepts: { tab in
                guard tab.kind == EditorTab.fileKind, let ext = tab.url?.pathExtension.lowercased() else { return false }
                return Self.imageExtensions.contains(ext) || ext == "pdf"
            }
        ) { tab in
            MediaView(url: tab.url!, workspace: workspace)
                .id(tab.id)
        })

        context.ui.addEditorProvider(EditorProvider(
            id: "preview.markdown",
            accepts: { $0.kind == Self.markdownKind && $0.url != nil }
        ) { tab in
            MarkdownPreview(url: tab.url!, workspace: workspace, highlighter: services.resolve(SyntaxHighlighting.self))
                .overlay(alignment: .topTrailing) {
                    Button {
                        commands.run("preview.markdown", teaching: true)
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.orbit(.body))
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(.glass)
                    .help(commands.help("preview.markdown", "Show Source"))
                    .padding(10)
                }
                .id(tab.id)
        })

        context.commands.register(OrbitCommand(
            id: "preview.markdown",
            title: "Open Markdown Preview to the Side",
            category: "File",
            systemImage: "eye",
            shortcut: KeyboardShortcut("v", modifiers: [.command, .shift]),
            isEnabled: { Self.markdownURL(workspace) != nil }
        ) {
            guard let url = Self.markdownURL(workspace) else { return }
            let preview = Self.previewTab(for: url)
            if workspace.activeTab?.kind == Self.markdownKind {
                // Back to the source, on whichever side it is.
                workspace.openFile(url)
            } else if workspace.tabs.contains(where: { $0.id == preview.id }) {
                workspace.open(preview)
            } else {
                // Beside the source, which keeps focus for typing (D90).
                workspace.openBeside(preview)
            }
        })
        context.ui.addEditorAction(EditorAction(commandID: "preview.markdown", systemImage: "eye") { url in
            Self.markdownExtensions.contains(url.pathExtension.lowercased())
        })
    }

    /// The active Markdown file, or the file of the active preview (⇧⌘V there goes back to it).
    private static func markdownURL(_ workspace: Workspace) -> URL? {
        guard let tab = workspace.activeTab, let url = tab.url else { return nil }
        if tab.kind == markdownKind { return url }
        return tab.kind == EditorTab.fileKind && markdownExtensions.contains(url.pathExtension.lowercased()) ? url : nil
    }

    static func previewTab(for url: URL) -> EditorTab {
        let url = url.standardizedFileURL
        return EditorTab(id: "preview:\(url.path)", kind: markdownKind, title: "Preview \(url.lastPathComponent)", systemImage: "eye", url: url)
    }
}
