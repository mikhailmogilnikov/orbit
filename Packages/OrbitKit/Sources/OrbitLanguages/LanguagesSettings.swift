import AppKit
import OrbitUI
import SwiftUI

/// Every language Orbit has a server for: what's installed, from where, and
/// buttons to install, update or remove Orbit's copy (D57).
struct LanguagesSettingsPane: View {
    let manager: LanguageManager

    /// Ours, and the imported ones (D65) only once installed or found: hundreds otherwise.
    private var shown: [LanguageServerConfig] {
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
                    SettingsLink("Not Installed", trailing: "\(missing.count)") {
                        SettingsForm {
                            Section {
                                ForEach(missing, id: \.id) { config in
                                    LanguageRow(manager: manager, config: config)
                                }
                            } footer: {
                                Text("Orbit installs servers from the Mason registry into ~/.orbit/languages. Other languages get a server from nvim-lspconfig's catalog when you open such a file.")
                            }
                        }
                    } label: {
                        Text("Not Installed")
                    }
                }
            }

            Section {
                LabeledContent {
                    Button("Restart Servers") { manager.restart() }
                } label: {
                    Text("Running servers")
                    Text("Each starts with the first file of its language and stops 10 minutes after the last one closes.")
                }
            } footer: {
                Text("Servers already on your Mac (Xcode's SourceKit-LSP and clangd, rust-analyzer from rustup…) are used as they are. Highlighting for languages without a built-in grammar is compiled on the first open of such a file, into ~/.orbit/grammars.")
            }
        }
        .task { await manager.refreshInstalls() }
    }

    /// Installed by Orbit or found on the Mac: what works right now.
    private func isAvailable(_ config: LanguageServerConfig) -> Bool {
        manager.foundOnMachine[config.id] != nil || config.install.map { manager.receipts[$0.package] != nil } == true
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
                        .font(.orbit(.micro))
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
                .font(.orbit(.micro))
                .foregroundStyle(.secondary)
                if let failure = manager.installFailures[config.id] {
                    Text(failure)
                        .font(.orbit(.micro))
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
                                .font(.orbit(.micro))
                                .foregroundStyle(.tertiary)
                        }
                        Text(row.source)
                            .font(.orbit(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let warning = row.warning {
                            Text(warning)
                                .font(.orbit(.micro))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
            ForEach(overview.problems, id: \.self) { problem in
                Text(problem)
                    .font(.orbit(.micro))
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
                Text(".orbit/settings.json").font(.orbit(.caption, design: .monospaced))
            }
            LabeledContent {
                Button("Edit…") { manager.editFormatterSettings(project: false) }
            } label: {
                Text("Global formatters")
                Text("~/.orbit/settings.json").font(.orbit(.caption, design: .monospaced))
            }
        } header: {
            Text("Custom Formatters")
        } footer: {
            Text("Any command that reads the file on stdin and prints it formatted, per file type: \"formatters\": { \"sql\": \"sqlfluff format -\" }. The project's win over global ones.")
        }
    }
}
