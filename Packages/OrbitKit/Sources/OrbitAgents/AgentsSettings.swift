import AppKit
import OrbitUI
import SwiftUI

/// Installed agents, the ACP registry to install more from (D52), defaults.
struct AgentsSettingsPane: View {
    @Bindable var store: AgentStore
    private var registry: AgentRegistry { store.registry }

    var body: some View {
        Form {
            if let preferred = store.preferredProvider {
                Section {
                    Picker("Default agent", selection: Binding(
                        get: { preferred.id },
                        set: { store.preferredProviderID = $0 }
                    )) {
                        ForEach(store.availableProviders) { provider in
                            AgentLabel(title: provider.name, provider: provider).tag(provider.id)
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
            }

            Section {
                if store.providers.isEmpty {
                    Text("No agents yet. Install one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.providers) { provider in
                    InstalledAgentRow(store: store, provider: provider)
                }
            } header: {
                Text("Installed")
            }

            Section {
                let installed = Set(store.providers.map(\.id))
                let available = registry.agents.filter { !installed.contains($0.id) }
                if available.isEmpty {
                    HStack {
                        if registry.isLoading {
                            ProgressView().controlSize(.small)
                            Text("Loading the registry…").foregroundStyle(.secondary)
                        } else if let error = registry.loadError {
                            Text("Couldn't load the registry: \(error)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Try Again") { Task { await registry.refresh() } }
                        } else {
                            Text("Every agent in the registry is installed.").foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(available) { agent in
                    RegistryAgentRow(store: store, agent: agent)
                }
            } header: {
                Text("Available")
            } footer: {
                Text("From the ACP registry, the list Zed and JetBrains IDEs use. Downloaded agents live in ~/.orbit/agents.")
            }

            Section {
                Text("Any agent that speaks the Agent Client Protocol can also be added by hand, with a JSON file in `~/.orbit/agents/`:")
                    .foregroundStyle(.secondary)
                Text("""
                {
                  "id": "my-agent",
                  "name": "My Agent",
                  "command": { "executable": "my-agent", "arguments": ["--acp"], "environment": {} }
                }
                """)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
                HStack {
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
        .task {
            // Hand-edited manifests show up without a restart.
            store.reloadProviders()
            await registry.refresh()
        }
    }
}

private struct InstalledAgentRow: View {
    let store: AgentStore
    let provider: AgentProvider

    var body: some View {
        let registry = store.registry
        let isMissing = store.missing.contains(provider.id)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AgentIcon(provider: provider, size: 14)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(provider.name)
                    Text(provider.registry?.version ?? "Custom")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let description = provider.registry?.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(([provider.command.executable] + provider.command.arguments).joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if isMissing {
                    Text(provider.requirement.map { "Needs \($0) — install it, then restart Orbit." } ?? "Its command isn't found.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let hint = provider.loginHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let failure = registry.failures[provider.id] {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            if registry.busy.contains(provider.id) {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    if registry.hasUpdate(provider), let agent = registry.agent(for: provider) {
                        Button("Update to \(agent.version)") { Task { await store.install(agent) } }
                            .buttonStyle(.glassProminent)
                    }
                    Menu {
                        if provider.registry == nil {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([AgentProvider.manifestFile(for: provider.id)])
                            }
                        }
                        Button("Uninstall", role: .destructive) { store.uninstall(provider) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .help(provider.registry == nil ? "Show in Finder, Uninstall" : "Uninstall")
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RegistryAgentRow: View {
    let store: AgentStore
    let agent: RegistryAgent

    var body: some View {
        let registry = store.registry
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RegistryAgentIcon(agent: agent, size: 14)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(agent.name)
                    Text(agent.version)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let description = agent.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(byline)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let failure = registry.failures[agent.id] {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            if registry.busy.contains(agent.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Install") { Task { await store.install(agent) } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var byline: String {
        var parts: [String] = []
        if let authors = agent.authors, !authors.isEmpty { parts.append(authors.joined(separator: ", ")) }
        switch agent.method {
        case .binary: parts.append("downloads the agent")
        case .npx: parts.append("runs with Node.js (npx)")
        case .uvx: parts.append("runs with uv (uvx)")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }
}
