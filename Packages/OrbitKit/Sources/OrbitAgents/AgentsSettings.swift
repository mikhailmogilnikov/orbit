import AppKit
import OrbitUI
import SwiftUI

/// Installed agents, the ACP registry to install more from (D52), defaults.
struct AgentsSettingsPane: View {
    @Bindable var store: AgentStore
    private var registry: AgentRegistry { store.registry }

    var body: some View {
        let installed = Set(store.providers.map(\.id))
        let available = registry.agents.filter { !installed.contains($0.id) }
        SettingsForm {
            if let preferred = store.preferredProvider {
                Section {
                    let project = store.workspace.settings
                    Picker(selection: Binding(
                        get: { preferred.id },
                        set: { store.preferredProviderID = $0 }
                    )) {
                        ForEach(store.availableProviders) { provider in
                            AgentLabel(title: provider.name, provider: provider).tag(provider.id)
                        }
                    } label: {
                        Text("Default agent")
                        if store.projectProvider != nil, let origin = project.origin(of: "agents.default") {
                            Text("Set by \(origin) (\"agents.default\")").foregroundStyle(.orange)
                        } else if let wanted = project.string("agents.default") {
                            Text("“\(wanted)” in settings.json isn't an installed agent").foregroundStyle(.orange)
                        } else {
                            Text("Also writes commit messages. Starting another agent makes it the default.")
                        }
                    }
                    .disabled(store.projectProvider != nil)
                    let isolatedOrigin = project.bool("agents.isolated") != nil ? project.origin(of: "agents.isolated") : nil
                    Toggle(isOn: $store.isolatedByDefault) {
                        Text("Work in an isolated copy")
                        Text("The agent edits its own copy of the project; Apply brings its changes back for review.")
                        if let isolatedOrigin {
                            Text("Set by \(isolatedOrigin) (\"agents.isolated\")").foregroundStyle(.orange)
                        }
                    }
                    .disabled(isolatedOrigin != nil)
                    Toggle(isOn: $store.keepsAwake) {
                        Text("Keep the Mac awake while an agent works")
                        Text("Stops idle sleep during a turn. Closing the lid still puts it to sleep.")
                    }
                } header: {
                    Text("New Chats")
                }
            }

            Section {
                if store.providers.isEmpty {
                    Text("No agents yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.providers) { provider in
                    InstalledAgentRow(store: store, provider: provider)
                }
            } header: {
                Text("Installed")
            }

            Section {
                SettingsLink("Get More Agents", trailing: registry.isLoading && available.isEmpty ? nil : "\(available.count)") {
                    RegistryAgentsPage(store: store)
                } label: {
                    SettingsLabel("Get More Agents", subtitle: "From the ACP registry, the list Zed and JetBrains IDEs use", systemImage: "arrow.down.circle.fill", tint: .blue)
                }
                SettingsLink("Custom Agent") {
                    CustomAgentPage()
                } label: {
                    SettingsLabel("Add a Custom Agent", subtitle: "Any program that speaks the Agent Client Protocol", systemImage: "terminal.fill", tint: .gray)
                }
            }
        }
        .task {
            // Hand-edited manifests show up without a restart.
            store.reloadProviders()
            await registry.refresh()
        }
    }
}

/// Agents in the registry that aren't installed yet.
private struct RegistryAgentsPage: View {
    let store: AgentStore
    @State private var query = ""
    private var registry: AgentRegistry { store.registry }

    var body: some View {
        let installed = Set(store.providers.map(\.id))
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        let available = registry.agents.filter { agent in
            !installed.contains(agent.id) && (query.isEmpty
                || agent.name.lowercased().contains(query)
                || (agent.description ?? "").lowercased().contains(query)
                || (agent.authors ?? []).joined(separator: " ").lowercased().contains(query))
        }
        SettingsForm {
            Section {
                SettingsSearchField("Search agents", text: $query)
            }
            Section {
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
                        } else if !query.isEmpty {
                            Text("No agents match “\(query)”.").foregroundStyle(.secondary)
                        } else {
                            Text("Every agent in the registry is installed.").foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(available) { agent in
                    RegistryAgentRow(store: store, agent: agent)
                }
            } footer: {
                Text("From the ACP registry, the list Zed and JetBrains IDEs use. Downloaded agents live in ~/.orbit/agents.")
            }
        }
        .task { await registry.refresh() }
    }
}

/// How to add an agent by hand: a JSON file in ~/.orbit/agents.
private struct CustomAgentPage: View {
    var body: some View {
        SettingsForm {
            Section {
                Text("""
                {
                  "id": "my-agent",
                  "name": "My Agent",
                  "command": { "executable": "my-agent", "arguments": ["--acp"], "environment": {} }
                }
                """)
                .font(.orbit(.code))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
                LabeledContent {
                    Button("Open Agents Folder") {
                        let directory = AgentProvider.configDirectory
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(directory)
                    }
                } label: {
                    Text("~/.orbit/agents")
                        .font(.orbit(.body, design: .monospaced))
                }
            } header: {
                Text("A JSON File per Agent")
            } footer: {
                Text("Any agent that speaks the Agent Client Protocol can be added this way. It shows up in Installed right away.")
            }
        }
    }
}

/// Notifications for agents working while Orbit is in the background.
struct NotificationSettingsPane: View {
    @Bindable var store: AgentStore

    var body: some View {
        SettingsForm {
            Section {
                Toggle(isOn: $store.notifies) {
                    Text("Notify when an agent finishes or needs you")
                    Text("A notification, with Allow and Deny for permission requests, and a count on the Dock icon.")
                }
                Toggle(isOn: $store.playsSound) {
                    Text("Play a sound when an agent finishes")
                    Text("When there's no notification to make one.")
                }
            } footer: {
                Text("Only while Orbit is in the background. macOS can turn Orbit's notifications off in System Settings → Notifications.")
            }
        }
    }
}

/// MCP servers from `.orbit/settings.json` (D86), given to every agent.
struct MCPServersPane: View {
    let store: AgentStore

    var body: some View {
        SettingsForm {
            MCPServersSection(store: store)
        }
    }
}

/// MCP servers from `.orbit/settings.json` (D86), given to every agent.
private struct MCPServersSection: View {
    let store: AgentStore
    @State private var loaded: (servers: [MCPServer], problems: [String]) = ([], [])

    var body: some View {
        Section {
            if loaded.servers.isEmpty && loaded.problems.isEmpty {
                Text("None yet. Add them to a settings file below.").foregroundStyle(.secondary)
            }
            ForEach(loaded.servers) { server in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon(server))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name)
                        Text(server.summary)
                            .font(.orbit(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(server.isProject ? "Project" : "Global")
                        .font(.orbit(.micro))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            ForEach(loaded.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.orbit(.micro))
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Servers")
        } footer: {
            Text("Besides the servers each agent sets up itself (Claude Code's, Codex's own config). Remote (URL) servers reach only agents that support them.")
        }
        .task(id: store.workspace.root) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
        Section {
            LabeledContent {
                Button("Edit…") { edit(store.workspace.root.map(MCPServer.projectFile)) }
                    .disabled(store.workspace.root == nil)
            } label: {
                Text("Project servers")
                Text(".orbit/settings.json").font(.orbit(.caption, design: .monospaced))
            }
            LabeledContent {
                Button("Edit…") { edit(MCPServer.userFile) }
            } label: {
                Text("Global servers")
                Text("~/.orbit/settings.json").font(.orbit(.caption, design: .monospaced))
            }
        } header: {
            Text("Configuration")
        } footer: {
            Text("“mcpServers”, in the format of Claude Code's .mcp.json and Cursor's mcp.json. The project's win over global ones by name.")
        }
    }

    private func reload() {
        loaded = MCPServer.load(project: store.workspace.root)
    }

    private func edit(_ url: URL?) {
        guard let url else { return }
        MCPServer.prepareForEditing(url)
        store.workspace.openFile(url)
    }

    private func icon(_ server: MCPServer) -> String {
        if case .stdio = server.transport { "terminal" } else { "globe" }
    }
}

private struct InstalledAgentRow: View {
    let store: AgentStore
    let provider: AgentProvider

    var body: some View {
        let registry = store.registry
        let isMissing = store.missing.contains(provider.id)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AgentIcon(provider: provider, size: 15)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Theme.activeFill, in: .rect(cornerRadius: Theme.smallCorner, style: .continuous))
                .alignmentGuide(.firstTextBaseline) { $0[.top] + 18 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(provider.name)
                    Text(provider.registry?.version ?? "Custom")
                        .font(.orbit(.micro))
                        .foregroundStyle(.tertiary)
                }
                if let description = provider.registry?.description, !description.isEmpty {
                    Text(description)
                        .font(.orbit(.micro))
                        .foregroundStyle(.secondary)
                } else {
                    Text(([provider.command.executable] + provider.command.arguments).joined(separator: " "))
                        .font(.orbit(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if isMissing {
                    Text(provider.requirement.map { "Needs \($0) — install it, then restart Orbit." } ?? "Its command isn't found.")
                        .font(.orbit(.micro))
                        .foregroundStyle(.orange)
                } else if let hint = provider.loginHint {
                    Text(hint)
                        .font(.orbit(.micro))
                        .foregroundStyle(.tertiary)
                }
                if let failure = registry.failures[provider.id] {
                    Text(failure)
                        .font(.orbit(.micro))
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
            RegistryAgentIcon(agent: agent, size: 15)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Theme.activeFill, in: .rect(cornerRadius: Theme.smallCorner, style: .continuous))
                .alignmentGuide(.firstTextBaseline) { $0[.top] + 18 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(agent.name)
                    Text(agent.version)
                        .font(.orbit(.micro))
                        .foregroundStyle(.tertiary)
                }
                if let description = agent.description, !description.isEmpty {
                    Text(description)
                        .font(.orbit(.micro))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(byline)
                    .font(.orbit(.micro))
                    .foregroundStyle(.tertiary)
                if let failure = registry.failures[agent.id] {
                    Text(failure)
                        .font(.orbit(.micro))
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
