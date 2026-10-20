import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// Every language Orbit has a server for: what's installed, from where, and
/// buttons to install, update or remove Orbit's copy (D57).
struct LanguagesSettingsPane: View {
    let manager: LanguageManager
    let ui: UIRegistry

    /// Ours, and the imported ones (D65) only once installed or found: hundreds otherwise.
    private var shown: [LanguageServerConfig] { Self.shown(manager) }

    private static func shown(_ manager: LanguageManager) -> [LanguageServerConfig] {
        LanguageServerConfig.all.filter { config in
            !config.isImported || manager.foundOnMachine[config.id] != nil
                || config.install.map { manager.receipts[$0.package] != nil } == true
        }
        .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    var body: some View {
        let shown = shown
        let installed = shown.filter { isAvailable($0) }
        let missing = shown.filter { !isAvailable($0) }
        SettingsForm {
            Section {
                if installed.isEmpty {
                    if manager.isLoadingRegistry {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking for servers…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("None yet. Opening a file installs its language's server when you allow it.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(installed, id: \.id) { config in
                    LanguageRow(manager: manager, config: config)
                        .settingsItem(config.id)
                }
            } header: {
                HStack {
                    Text("Ready")
                    Spacer()
                    if manager.isLoadingRegistry { ProgressView().controlSize(.mini) }
                }
            } footer: {
                if let error = manager.registryError {
                    Text("Couldn't load the registry: \(error)").foregroundStyle(.orange)
                }
            }

            if !missing.isEmpty {
                Section {
                    // Installing lives in Settings → Extensions with everything else (D192).
                    Button {
                        ui.showExtensions(.languageServers)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Get More Language Servers")
                            Spacer(minLength: 8)
                            Text("\(missing.count)").foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.forward")
                                .orbitFont(.caption, weight: .semibold)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .settingsItem("notInstalled")
                }
            }

            Section {
                LabeledContent {
                    Button("Restart Servers") { manager.restart() }
                } label: {
                    Text("Running servers")
                    Text("Each starts with the first file of its language and stops 10 minutes after the last one closes.")
                }
                .settingsItem("restart")
            } footer: {
                Text("Servers already on your Mac (Xcode's SourceKit-LSP and clangd, rust-analyzer from rustup…) are used as they are. Highlighting for languages without a built-in grammar is compiled on the first open of such a file, into ~/.orbit/grammars.")
            }
        }
        .task { await manager.refreshInstalls() }
    }

    /// Installed by Orbit or found on the Mac: what works right now.
    private func isAvailable(_ config: LanguageServerConfig) -> Bool { Self.isAvailable(config, manager) }

    private static func isAvailable(_ config: LanguageServerConfig, _ manager: LanguageManager) -> Bool {
        manager.foundOnMachine[config.id] != nil || config.install.map { manager.receipts[$0.package] != nil } == true
    }

    /// The servers listed under Ready, for the settings search (D177).
    static func ready(_ manager: LanguageManager) -> [LanguageServerConfig] {
        shown(manager).filter { isAvailable($0, manager) }
    }
}

/// What formats which files in the open folder, and where to change it (D61).
struct FormattingSettingsPane: View {
    let manager: LanguageManager

    var body: some View {
        SettingsForm {
            FormattingSection(manager: manager)
        }
    }
}

private struct LanguageRow: View {
    let manager: LanguageManager
    let config: LanguageServerConfig

    var body: some View {
        let install = config.install
        let receipt = install.flatMap { manager.receipts[$0.package] }
        let latest = install.flatMap { manager.latestVersions[$0.package] }
        let found = manager.foundOnMachine[config.id]
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(config.name)
                    Text(fileTypes)
                        .orbitFont(.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(allFileTypes)
                }
                Group {
                    if let receipt {
                        Text("\(install?.package ?? "") \(receipt.version) · installed by Orbit")
                    } else if let found {
                        Text("On your Mac · \((found as NSString).abbreviatingWithTildeInPath)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(found)
                    } else if install != nil {
                        Text(["Not installed", install?.needs.map { "needs \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    } else {
                        Text(config.missing)
                    }
                }
                .orbitFont(.micro)
                .foregroundStyle(.secondary)
                if let failure = manager.installFailures[config.id] {
                    Text(failure)
                        .orbitFont(.micro)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if manager.installing.contains(config.id) {
                ProgressView().controlSize(.small)
            } else if install != nil {
                HStack(spacing: 6) {
                    if let receipt {
                        if let latest, latest != receipt.version {
                            Button("Update to \(latest)") { Task { await manager.install(config.id) } }
                                .buttonStyle(.glassProminent)
                        }
                        Menu {
                            Button("Show in Finder") {
                                if let package = install?.package {
                                    NSWorkspace.shared.activateFileViewerSelecting([manager.installer.directory(for: package)])
                                }
                            }
                            Button("Uninstall", role: .destructive) { manager.uninstall(config.id) }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    } else if found == nil {
                        Button("Install") { Task { await manager.install(config.id) } }
                            .buttonStyle(.glassProminent)
                    }
                }
                .controlSize(.small)
            }
            if receipt != nil || found != nil {
                Toggle("", isOn: Binding(get: { manager.isEnabled(config.id) }, set: { manager.setEnabled($0, server: config.id) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(manager.isEnabled(config.id) ? "Turn \(config.name) off in every project" : "Turn \(config.name) on")
            }
        }
        .padding(.vertical, 2)
    }

    private var fileTypeList: [String] {
        config.languages.keys.sorted().map { ".\($0)" } + config.fileNames.keys.sorted()
    }

    /// The first few; the rest in the tooltip.
    private var fileTypes: String {
        let list = fileTypeList
        let shown = list.prefix(6).joined(separator: " ")
        return list.count > 6 ? "\(shown) +\(list.count - 6)" : shown
    }

    private var allFileTypes: String { fileTypeList.joined(separator: " ") }
}

/// What formats which files in the open folder, and where to change it (D61).
private struct FormattingSection: View {
    let manager: LanguageManager
    @State private var overview = FormattingOverview.empty

    var body: some View {
        Section {
            if overview.rows.isEmpty {
                Text("No formatter configured in this folder: language servers format, indented as .editorconfig or the file itself says.")
                    .foregroundStyle(.secondary)
            }
            ForEach(overview.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.formatter)
                            Text(row.fileTypes)
                                .orbitFont(.micro)
                                .foregroundStyle(.tertiary)
                        }
                        Text(row.source)
                            .orbitFont(.caption, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let warning = row.warning {
                            Text(warning)
                                .orbitFont(.micro)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
            ForEach(overview.problems, id: \.self) { problem in
                Text(problem)
                    .orbitFont(.micro)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("In This Project")
        } footer: {
            Text("⌃⇧I and Format on Save (Editor) use the formatter the project is set up with — \(FormatterPreset.all.map(\.name).joined(separator: ", ")) — found by its config, from the project's node_modules or virtualenv. Other files go to the language server.")
        }
        .task { overview = await manager.formattingOverview() }
        Section {
            LabeledContent {
                Button("Edit…") { manager.editFormatterSettings(project: true) }
                    .disabled(!manager.hasFolder)
            } label: {
                Text("Project formatters")
                Text(".orbit/settings.json").orbitFont(.caption, design: .monospaced)
            }
            .settingsItem("projectFormatters")
            LabeledContent {
                Button("Edit…") { manager.editFormatterSettings(project: false) }
            } label: {
                Text("Global formatters")
                Text("~/.orbit/settings.json").orbitFont(.caption, design: .monospaced)
            }
            .settingsItem("globalFormatters")
        } header: {
            Text("Custom Formatters")
        } footer: {
            Text("Any command that reads the file on stdin and prints it formatted, per file type: \"formatters\": { \"sql\": \"sqlfluff format -\" }. The project's win over global ones.")
        }
    }
}

/// Language servers in Settings → Extensions (D192): the ones that work now
/// with their switch, and Mason's others to install.
final class LanguageExtensionSource: ExtensionSource {
    let manager: LanguageManager
    init(manager: LanguageManager) { self.manager = manager }

    var kind: ExtensionKind { .languageServers }
    var catalogName: String { "From the Mason registry, installed into ~/.orbit/languages. Servers already on your Mac are used as they are." }
    var isLoading: Bool { manager.isLoadingRegistry }
    var loadError: String? { manager.registryError }
    func refresh() async { await manager.refreshInstalls() }

    var installed: [ExtensionItem] {
        LanguagesSettingsPane.ready(manager).map(item)
    }

    /// Orbit's own list when nothing is typed; a query searches every server
    /// imported from nvim-lspconfig too (hundreds).
    func available(matching query: String) -> [ExtensionItem] {
        let ready = Set(LanguagesSettingsPane.ready(manager).map(\.id))
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return LanguageServerConfig.all
            .filter { $0.install != nil && !ready.contains($0.id) && (!trimmed.isEmpty || !$0.isImported) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
            .map(item)
            .filter { $0.matches(trimmed) }
    }

    private func item(_ config: LanguageServerConfig) -> ExtensionItem {
        let manager = manager
        let install = config.install
        let receipt = install.flatMap { manager.receipts[$0.package] }
        let found = manager.foundOnMachine[config.id]
        let fileTypes = config.languages.keys.sorted().map { ".\($0)" } + config.fileNames.keys.sorted()
        let types = fileTypes.prefix(5).joined(separator: " ") + (fileTypes.count > 5 ? " +\(fileTypes.count - 5)" : "")
        let summary: String = if let receipt {
            "\(install?.package ?? "") \(receipt.version) · installed by Orbit"
        } else if let found {
            "On your Mac · \((found as NSString).abbreviatingWithTildeInPath)"
        } else {
            ["Not installed", install?.needs.map { "needs \($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
        var item = ExtensionItem(
            id: "lsp:" + config.id, name: config.name, summary: summary, detail: types,
            keywords: ["language server", "lsp", config.id, install?.package ?? ""] + fileTypes,
            isInstalled: receipt != nil || found != nil
        ) {
            // Installed ones in color, as Settings tiles; the catalog's quiet.
            if receipt != nil || found != nil {
                SettingsTile("curlybraces", tint: .purple, size: 28)
            } else {
                Image(systemName: "curlybraces")
                    .orbitFont(.body, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.activeFill, in: .rect(cornerRadius: Theme.smallCorner, style: .continuous))
            }
        }
        item.isBusy = manager.installing.contains(config.id)
        item.failure = manager.installFailures[config.id]
        if install != nil {
            if receipt == nil, found == nil {
                item.install = { await manager.install(config.id) }
            }
            if let receipt, let latest = install.flatMap({ manager.latestVersions[$0.package] }), latest != receipt.version {
                item.latestVersion = latest
                item.update = { await manager.install(config.id) }
            }
            if receipt != nil, let package = install?.package {
                item.uninstall = { manager.uninstall(config.id) }
                item.folder = manager.installer.directory(for: package)
            }
        }
        if item.isInstalled {
            item.isEnabled = manager.isEnabled(config.id)
            item.setEnabled = { manager.setEnabled($0, server: config.id) }
        }
        return item
    }
}
