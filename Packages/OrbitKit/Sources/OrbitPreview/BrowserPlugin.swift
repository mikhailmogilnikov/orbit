import OrbitAPI
import SwiftUI

/// Web pages in editor tabs, a dev server's localhost first (D143); its own
/// plugin since D194, beside Preview in the same module.
public final class BrowserPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.browser",
        name: "Browser",
        summary: "Web pages in editor tabs, for the localhost your tasks print.",
        systemImage: "globe",
        tint: .blue
    )

    private var browser: BrowserStore?

    public init() {}

    public func deactivate() {
        browser?.closeAll()
    }

    public func activate(_ context: PluginContext) {
        let store = BrowserStore(workspace: context.workspace)
        browser = store
        let services = context.services
        context.services.register(WebPreviewing.self, store)
        context.ui.addEditorProvider(EditorProvider(id: "preview.browser", accepts: { $0.kind == BrowserStore.kind }) { tab in
            if let page = store.page(for: tab) {
                BrowserView(page: page, store: store).id(tab.id)
            }
        })
        let ui = context.ui
        context.commands.register(OrbitCommand(
            id: "preview.browser",
            title: "Open Browser…",
            category: "View",
            systemImage: "globe"
        ) {
            let servers = services.resolve(LocalServers.self)?.localURLs ?? []
            ui.presentQuickPick(QuickPick(id: "browser", placeholder: "Address, e.g. localhost:3000") { query in
                var urls: [URL] = []
                if let typed = BrowserPage.address(query) { urls.append(typed) }
                for url in servers + store.recent + [URL(string: "http://localhost:3000")!] where !urls.contains(url) {
                    guard query.isEmpty || url.absoluteString.localizedCaseInsensitiveContains(query) else { continue }
                    urls.append(url)
                }
                return urls.map { url in
                    QuickPickItem(
                        id: url.absoluteString, title: AttributedString(url.absoluteString),
                        subtitle: servers.contains(url) ? "Printed by a running task" : nil,
                        systemImage: servers.contains(url) ? "play.circle" : "globe"
                    ) { store.openBrowser(url) }
                }
            })
        })
    }

}
