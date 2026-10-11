import AppKit
import OrbitUI
import SwiftUI

struct AgentsSettingsPane: View {
    @Bindable var store: AgentStore

    var body: some View {
        Form {
            Section {
                Picker("Default agent", selection: Binding(
                    get: { store.preferredProvider.id },
                    set: { store.preferredProviderID = $0 }
                )) {
                    ForEach(store.providers) { provider in
                        Label(provider.name, systemImage: provider.icon).tag(provider.id)
                    }
                }
                Toggle(isOn: $store.isolatedByDefault) {
                    Text("Start sessions in an isolated copy")
                    Text("The agent works in its own copy of the project; Apply brings its changes back for review.")
                }
            } header: {
                Text("New sessions")
            } footer: {
                Text("The default agent also writes commit messages. Starting another agent makes it the default.")
            }

            Section("Installed agents") {
                ForEach(store.providers) { provider in
                    AgentRow(provider: provider)
                }
            }

            Section {
                Text("Any agent that speaks the Agent Client Protocol can be added with a JSON file in `~/.orbit/agents/`:")
                    .foregroundStyle(.secondary)
                Text("""
                {
                  "id": "gemini",
                  "name": "Gemini CLI",
                  "command": { "executable": "gemini", "arguments": ["--acp"], "environment": {} }
                }
                """)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
                HStack {
                    Text("Restart Orbit after adding one.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Agents Folder") {
                        let directory = AgentProvider.configDirectory
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(directory)
                    }
                }
            } header: {
                Text("Custom agents")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentRow: View {
    let provider: AgentProvider

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: provider.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name)
                Text(([provider.command.executable] + provider.command.arguments).joined(separator: " "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let hint = provider.loginHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
