import AppKit
import OrbitAPI
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
                            ProjectOverrideNote(key: "agents.default", origin: origin)
                        } else if let wanted = project.string("agents.default") {
                            Text("“\(wanted)” in settings.json isn't an installed agent").foregroundStyle(.orange)
                        } else {
                            Text("Also writes commit messages. Starting another agent makes it the default.")
                        }
                    }
                    .disabled(store.projectProvider != nil)
                    .projectSetting("agents.default", in: store.workspace, choices: store.availableProviders.map { ("Use \($0.name)", .string($0.id)) })
                    .settingsItem("defaultAgent")
                    let isolatedOrigin = project.bool("agents.isolated") != nil ? project.origin(of: "agents.isolated") : nil
                    Toggle(isOn: $store.isolatedByDefault) {
                        Text("Work in an isolated copy")
                        Text("The agent edits its own copy of the project; Apply brings its changes back for review.")
                        if let isolatedOrigin {
                            ProjectOverrideNote(key: "agents.isolated", origin: isolatedOrigin)
                        }
                    }
                    .disabled(isolatedOrigin != nil)
                    .projectSetting("agents.isolated", in: store.workspace)
                    .settingsItem("isolated")
                    Toggle(isOn: $store.keepsAwake) {
                        Text("Keep the Mac awake while an agent works")
                        Text("Stops idle sleep during a turn. Closing the lid still puts it to sleep.")
                    }
                    .settingsItem("keepAwake")
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
                        .settingsItem(provider.id)
                }
            } header: {
                Text("Installed")
            }

            Section {
                // Installing lives in Settings → Extensions with everything else (D192).
                Button {
                    store.ui.showExtensions(.agents)
                } label: {
                    HStack(spacing: 8) {
                        SettingsLabel("Get More Agents", subtitle: "From the ACP registry, in Extensions", systemImage: "arrow.down.circle.fill", tint: .blue)
                        Spacer(minLength: 8)
                        if !(registry.isLoading && available.isEmpty) {
                            Text("\(available.count)").foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.up.forward")
                            .orbitFont(.caption, weight: .semibold)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .settingsItem("getMore")
                SettingsLink("Custom Agent") {
                    CustomAgentPage()
                } label: {
                    SettingsLabel("Add a Custom Agent", subtitle: "Any program that speaks the Agent Client Protocol", systemImage: "terminal.fill", tint: .gray)
                }
                .settingsItem("custom")
            }
        }
        .task {
            // Hand-edited manifests show up without a restart.
            store.reloadProviders()
            await registry.refresh()
        }
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
                .orbitFont(.code)
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
                        .orbitFont(.body, design: .monospaced)
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
                .settingsItem("notify")
                Toggle(isOn: $store.playsSound) {
                    Text("Play a sound when an agent finishes")
                    Text("When there's no notification to make one.")
                }
                .settingsItem("sound")
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
                            .orbitFont(.caption, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(server.isProject ? "Project" : "Global")
                        .orbitFont(.micro)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            ForEach(loaded.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .orbitFont(.micro)
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
                Text(".orbit/settings.json").orbitFont(.caption, design: .monospaced)
            }
            .settingsItem("projectServers")
            LabeledContent {
                Button("Edit…") { edit(MCPServer.userFile) }
            } label: {
                Text("Global servers")
                Text("~/.orbit/settings.json").orbitFont(.caption, design: .monospaced)
            }
            .settingsItem("globalServers")
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

/// An installed agent: a row that opens its page (D179), with what new chats
/// start with under its name.
private struct InstalledAgentRow: View {
    let store: AgentStore
    let provider: AgentProvider

    var body: some View {
        let registry = store.registry
        SettingsLink(provider.name, trailing: nil) {
            AgentSettingsPage(store: store, provider: provider)
        } label: {
            HStack(spacing: 10) {
                AgentTile(provider: provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                    if store.missing.contains(provider.id) {
                        Text("Not found on this Mac")
                            .orbitFont(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(summary)
                            .orbitFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if registry.busy.contains(provider.id) {
                    ProgressView().controlSize(.small)
                } else if registry.hasUpdate(provider) {
                    Badge("Update", tint: Theme.accent)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// "Opus · Plan" — the defaults picked for it, else its version.
    private var summary: String {
        let picked = AgentStore.defaultCategories.compactMap { category -> String? in
            guard let value = store.defaultValue(category, for: provider) else { return nil }
            return store.knownOption(category, of: provider)?.choices.first { $0.value == value }?.name
        }
        if !picked.isEmpty { return picked.joined(separator: " · ") }
        return provider.registry.map { "Version \($0.version)" } ?? "Custom agent"
    }
}

/// The agent's icon on a quiet tile, as installed agents show in lists.
struct AgentTile: View {
    let provider: AgentProvider
    let size: CGFloat

    var body: some View {
        AgentIcon(provider: provider, size: size * 0.54)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Theme.activeFill, in: .rect(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// One agent's page (D179): what its new chats start with, then about it,
/// updating and removing it.
struct AgentSettingsPage: View {
    @Bindable var store: AgentStore
    let provider: AgentProvider

    var body: some View {
        let registry = store.registry
        let isMissing = store.missing.contains(provider.id)
        SettingsForm {
            Section {
                HStack(spacing: 12) {
                    AgentTile(provider: provider, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                            .orbitFont(.control, weight: .semibold)
                        Text(provider.registry?.description ?? provider.extensionName.map { "From the \($0) extension." } ?? "A custom agent from ~/.orbit/agents.")
                            .orbitFont(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }

            Section {
                ForEach(AgentStore.defaultCategories, id: \.self) { category in
                    DefaultOptionPicker(store: store, provider: provider, category: category)
                }
            } header: {
                Text("New Chats")
            } footer: {
                Text(store.knownOption("model", of: provider) == nil
                    ? "\(provider.name) tells Orbit its models and modes when a chat starts; start one to pick them here."
                    : "A model or effort picked in a chat becomes the default here too. The permission mode only changes here, so a new chat never starts in a mode you used once.")
            }

            Section {
                LabeledContent("Version", value: provider.registry?.version ?? "Custom")
                LabeledContent {
                    Text(([provider.command.executable] + provider.command.arguments).joined(separator: " "))
                        .orbitFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } label: {
                    Text("Command")
                }
                if isMissing {
                    Label(provider.requirement.map { "Needs \($0) — install it, then restart Orbit." } ?? "Its command isn't found.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if let hint = provider.loginHint {
                    LabeledContent("Signing in") {
                        Text(hint).foregroundStyle(.secondary)
                    }
                }
                if let failure = registry.failures[provider.id] {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("About")
            }

            Section {
                if registry.busy.contains(provider.id) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working…").foregroundStyle(.secondary)
                    }
                } else {
                    if registry.hasUpdate(provider), let agent = registry.agent(for: provider) {
                        LabeledContent {
                            Button("Update") { Task { await store.install(agent) } }
                                .buttonStyle(.glassProminent)
                        } label: {
                            Text("Version \(agent.version) is available")
                        }
                    }
                    if provider.registry == nil {
                        LabeledContent {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([AgentProvider.manifestFile(for: provider.id)])
                            }
                        } label: {
                            Text("Manifest")
                            Text("~/.orbit/agents/\(provider.id).json")
                                .orbitFont(.caption, design: .monospaced)
                        }
                    }
                    if let extensionName = provider.extensionName {
                        LabeledContent("Comes with", value: extensionName)
                    } else {
                        LabeledContent {
                            Button("Uninstall…", role: .destructive) { uninstall() }
                        } label: {
                            Text("Uninstall \(provider.name)")
                            Text("Its chats stay in the history.")
                        }
                    }
                }
            }
        }
    }

    private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall \(provider.name)?"
        alert.informativeText = "Orbit removes its copy of the agent. You can install it again from Get More Agents."
        alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runSheetModal() == .alertFirstButtonReturn else { return }
        store.uninstall(provider)
    }
}

/// Model, effort or mode for new chats: the agent's default or one of its choices.
private struct DefaultOptionPicker: View {
    let store: AgentStore
    let provider: AgentProvider
    let category: String

    var body: some View {
        let option = store.knownOption(category, of: provider)
        let value = store.defaultValue(category, for: provider)
        let picked = option?.choices.first { $0.value == value }
        if let option, !option.choices.isEmpty {
            Picker(selection: Binding(
                get: { picked?.value },
                set: { store.setDefault($0, category, for: provider) }
            )) {
                Text("\(provider.name)'s default").tag(String?.none)
                Divider()
                ForEach(Array(option.choices.enumerated()), id: \.element.value) { index, choice in
                    Label(choice.name, systemImage: OptionIcons.icon(for: choice, at: index, in: option) ?? OptionIcons.icon(for: option))
                        .tag(Optional(choice.value))
                }
            } label: {
                Label(title, systemImage: OptionIcons.icon(for: option))
                if let note = note(picked) {
                    Text(note)
                }
            }
            .settingsItem("\(provider.id).\(category)")
        } else if category == "model" {
            LabeledContent {
                Text("After the first chat")
                    .foregroundStyle(.tertiary)
            } label: {
                Label(title, systemImage: "cpu")
            }
        }
    }

    private var title: String {
        switch category {
        case "model": "Model"
        case "thought_level": "Reasoning effort"
        default: "Permissions"
        }
    }

    /// The choice's own description; a warning for modes that skip asking.
    private func note(_ choice: ConfigOption.Choice?) -> AttributedString? {
        guard let choice else { return nil }
        let name = (choice.value + " " + choice.name).lowercased()
        if category == "mode", name.contains("bypass") || name.contains("yolo") || name.contains("full") {
            var warning = AttributedString("Every new chat edits files and runs commands without asking.")
            warning.foregroundColor = .orange
            return warning
        }
        return choice.description.map { AttributedString($0) }
    }
}

/// Agents in Settings → Extensions (D192): installed ones open their page,
/// the ACP registry's others install from there.
final class AgentExtensionSource: ExtensionSource {
    let store: AgentStore
    init(store: AgentStore) { self.store = store }

    var kind: ExtensionKind { .agents }
    var catalogName: String { "From the ACP registry, the list Zed and JetBrains IDEs use. Downloaded agents live in ~/.orbit/agents." }
    var isLoading: Bool { store.registry.isLoading }
    var loadError: String? { store.registry.loadError }
    func refresh() async {
        store.reloadProviders()
        await store.registry.refresh()
    }

    var installed: [ExtensionItem] {
        let store = store
        let registry = store.registry
        return store.providers.map { provider in
            var item = ExtensionItem(
                id: "agent:" + provider.id, name: provider.name,
                summary: provider.registry?.description ?? provider.extensionName.map { "From the \($0) extension" } ?? "A custom agent from ~/.orbit/agents",
                detail: provider.registry?.version, keywords: ["agent", "acp", provider.id] + (provider.extensionName.map { [$0] } ?? []),
                isInstalled: true
            ) {
                AgentTile(provider: provider, size: 28)
            }
            item.isBusy = registry.busy.contains(provider.id)
            item.failure = registry.failures[provider.id]
            if store.missing.contains(provider.id) {
                item.warning = provider.requirement.map { "Needs \($0)" } ?? "Not found on this Mac"
            }
            if registry.hasUpdate(provider), let agent = registry.agent(for: provider) {
                item.latestVersion = agent.version
                item.update = { await store.install(agent) }
            }
            item.page = { AnyView(AgentSettingsPage(store: store, provider: provider)) }
            return item
        }
    }

    func available(matching query: String) -> [ExtensionItem] {
        let store = store
        let installed = Set(store.providers.map(\.id))
        return store.registry.agents.filter { !installed.contains($0.id) }.map { agent in
            var item = ExtensionItem(
                id: "agent:" + agent.id, name: agent.name,
                summary: agent.description ?? "", detail: agent.version,
                keywords: ["agent", "acp"] + (agent.authors ?? []),
                isInstalled: false
            ) {
                RegistryAgentIcon(agent: agent, size: 15)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.activeFill, in: .rect(cornerRadius: Theme.smallCorner, style: .continuous))
            }
            item.isBusy = store.registry.busy.contains(agent.id)
            item.failure = store.registry.failures[agent.id]
            item.install = { await store.install(agent) }
            return item
        }
        .filter { $0.matches(query) }
    }
}
