import AppKit
import OrbitUI
import SwiftUI

/// Every language Orbit has a server for: what's installed, from where, and
/// buttons to install, update or remove Orbit's copy (D57).
struct LanguagesSettingsPane: View {
    let manager: LanguageManager

    var body: some View {
        Form {
            Section {
                ForEach(LanguageServerConfig.all.sorted { $0.name < $1.name }, id: \.id) { config in
                    LanguageRow(manager: manager, config: config)
                }
            } header: {
                HStack {
                    Text("Language servers")
                    Spacer()
                    if manager.isLoadingRegistry { ProgressView().controlSize(.mini) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Servers Orbit installs come from the Mason registry and live in ~/.orbit/languages. Ones already on your Mac (Xcode's SourceKit-LSP and clangd, rust-analyzer from rustup…) are used as they are.")
                    if let error = manager.registryError {
                        Text("Couldn't load the registry: \(error)").foregroundStyle(.orange)
                    }
                }
            }

            Section {
                HStack {
                    Text("Servers start with the first file of their language and stop 10 minutes after the last one closes.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Servers") { manager.restart() }
                }
            }
        }
        .formStyle(.grouped)
        .task { await manager.refreshInstalls() }
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
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Group {
                    if let receipt {
                        Text("\(install?.package ?? "") \(receipt.version) · installed by Orbit")
                    } else if let found {
                        Text(found)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if install != nil {
                        Text(["Not installed", install?.needs.map { "needs \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    } else {
                        Text(config.missing)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let failure = manager.installFailures[config.id] {
                    Text(failure)
                        .font(.caption)
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

    private var fileTypes: String {
        (config.languages.keys.sorted().map { ".\($0)" } + config.fileNames.keys.sorted()).joined(separator: " ")
    }
}
