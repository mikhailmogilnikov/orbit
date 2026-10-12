import OrbitKit
import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var host: PluginHost

    init() {
        let host = PluginHost(plugins: BuiltinPlugins.all)
        _host = State(initialValue: host)
        AppDelegate.host = host
        host.commands.register(OrbitCommand(
            id: "shell.selectTheme", title: "Select Theme…", category: "Appearance",
            systemImage: "paintpalette", shortcut: KeyboardShortcut("t", modifiers: [.command, .control])
        ) {
            ThemeSelector.show(in: host)
        })
    }

    var body: some Scene {
        Window("Orbit", id: "main") {
            MainWindow(host: host)
                .frame(minWidth: 960, minHeight: 600)
        }
        // Tabs and window buttons live in the content's top row (D42).
        .windowStyle(.hiddenTitleBar)
        .commands { OrbitMenus(host: host) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var host: PluginHost?
    /// Set by the main window; brings it back when a quit is cancelled after
    /// its last window was already closed.
    @MainActor static var reopenMainWindow: (@MainActor () -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let workspace = Self.host?.workspace,
                  !workspace.confirmUnsavedChanges(in: workspace.documents.dirtyDocuments) else { return .terminateNow }
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { Self.reopenMainWindow?() }
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.host?.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Menus are generated from the command registry, so plugin commands get
/// real menu items and shortcuts for free.
struct OrbitMenus: Commands {
    let host: PluginHost
    private static let builtInCategories: Set<String> = ["File", "Agents", "Review", "Git", "Terminal", "Appearance"]

    var body: some Commands {
        // Settings open inside the main window (see SettingsScreen), not as a separate one.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                AppDelegate.reopenMainWindow?()
                host.ui.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            items(in: "File", excluding: ["editor.save", "editor.saveAll", "editor.closeTab"])
        }
        CommandGroup(replacing: .saveItem) {
            items(ids: ["editor.save", "editor.saveAll", "editor.closeTab"])
        }
        CommandGroup(after: .sidebar) {
            Button("Command Palette…") { CommandPalette.toggle(in: host) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            items(ids: ["shell.selectTheme"])
            Divider()
        }
        CommandMenu("Agents") { items(in: "Agents") }
        CommandMenu("Review") { items(in: "Review") }
        CommandMenu("Git") { items(in: "Git") }
        CommandMenu("Terminal") { items(in: "Terminal") }
        CommandMenu("Plugins") {
            ForEach(host.commands.all.filter { !Self.builtInCategories.contains($0.category) }) { command in
                CommandButton(command: command)
            }
        }
    }

    private func items(in category: String, excluding: Set<String> = []) -> some View {
        ForEach(host.commands.all.filter { $0.category == category && !excluding.contains($0.id) }) { command in
            CommandButton(command: command)
        }
    }

    private func items(ids: [String]) -> some View {
        ForEach(ids.compactMap { id in host.commands.all.first { $0.id == id } }) { command in
            CommandButton(command: command)
        }
    }
}

struct CommandButton: View {
    let command: OrbitCommand

    var body: some View {
        let button = Button(command.title, action: command.run)
            .disabled(!command.isEnabled())
        if let shortcut = command.shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}
