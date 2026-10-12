import OrbitKit
import SwiftUI

/// "Select Theme" in a quick pick (⌃⌘T), like Zed's theme selector: moving
/// through the list shows each theme on the real window, Enter keeps it, Esc
/// goes back. Installed themes come first, then Zed's catalog, tried on as
/// the selection reaches them and installed on Enter (D49).
@MainActor
enum ThemeSelector {
    static let pickID = "shell.themes"

    /// The highlighted row's pending download; a newer row cancels it.
    @MainActor
    private final class Session {
        var download: Task<Void, Never>?
    }

    static func show(in host: PluginHost) {
        let extensions = Extensions.shared
        let catalog = ExtensionCatalog.shared
        catalog.loadThemeCatalog()
        // A try-on started in Settings comes back if the selector is cancelled.
        let previous = (extensions.preview, catalog.previewEntry)
        let current = extensions.pickedColorTheme(dark: Preferences.shared.isDark).id
        let session = Session()

        let pick = QuickPick(
            id: pickID,
            placeholder: "Select a theme",
            initialSelection: "theme:\(current)",
            onHighlight: { item in
                session.download?.cancel()
                session.download = nil
                if let id = item.id.dropPrefix("theme:") {
                    guard let theme = extensions.colorThemes.first(where: { $0.id == id }),
                          let owner = extensions.installed.first(where: { $0.id == theme.extensionID }) else { return }
                    var preview = ExtensionPreview(manifest: owner.manifest, directory: owner.directory, colorThemes: [theme], iconThemes: [])
                    preview.colorThemeID = theme.id
                    catalog.show(preview, for: nil)
                } else if let id = item.id.dropPrefix("catalog:"),
                          let entry = catalog.themeCatalog.first(where: { $0.id == id }) {
                    // Arrowing through quickly shouldn't download every row on the way.
                    session.download = Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, let preview = try? await catalog.prepare(entry), !Task.isCancelled else { return }
                        catalog.show(ExtensionCatalog.startingVariant(of: preview), for: entry)
                    }
                }
            },
            onCancel: {
                session.download?.cancel()
                catalog.show(previous.0, for: previous.1)
            },
            items: { query in items(query: query, current: current, session: session) }
        )
        host.ui.presentQuickPick(pick)
    }

    private static func items(query: String, current: String, session: Session) -> [QuickPickItem] {
        let extensions = Extensions.shared
        let catalog = ExtensionCatalog.shared
        let dark = Preferences.shared.isDark
        // The current mode's themes first: those are the ones that show now.
        let themes = extensions.colorThemes.filter { $0.isDark == dark } + extensions.colorThemes.filter { $0.isDark != dark }
        let installedIDs = Set(extensions.installed.map(\.id))

        var rows: [(item: QuickPickItem, score: Int)] = []
        for theme in themes {
            guard let match = FuzzyMatch.match(query, in: theme.name) else { continue }
            let item = QuickPickItem(
                id: "theme:\(theme.id)",
                title: FuzzyMatch.highlighted(theme.name, positions: match.positions),
                subtitle: theme.extensionName,
                systemImage: theme.id == current ? "checkmark" : (theme.isDark ? "moon" : "sun.max"),
                trailing: theme.isDark ? "Dark" : "Light"
            ) {
                session.download?.cancel()
                catalog.endPreview()
                extensions.choose(theme)
            }
            rows.append((item, match.score))
        }
        for entry in catalog.themeCatalog where !installedIDs.contains(entry.id) {
            guard let match = FuzzyMatch.match(query, in: entry.name) else { continue }
            let item = QuickPickItem(
                id: "catalog:\(entry.id)",
                title: FuzzyMatch.highlighted(entry.name, positions: match.positions),
                subtitle: "\(entry.downloadCount.formatted(.number.notation(.compactName))) downloads",
                systemImage: "arrow.down.circle",
                trailing: "Install"
            ) {
                // A late try-on would otherwise land after the install picked the theme.
                session.download?.cancel()
                Task { await catalog.install(entry, pick: true) }
            }
            // Below installed themes that match as well.
            rows.append((item, match.score - 1))
        }
        guard !query.isEmpty else { return rows.map(\.item) }
        return rows.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element.item)
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
