import OrbitUI
import SwiftUI

/// The composer's single button for model, effort, mode and the agent itself
/// (like Cursor): the label sums them up, a popover changes them.
struct SessionOptionsButton: View {
    let session: AgentSession
    let store: AgentStore
    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 5) {
                AgentIcon(provider: session.provider, size: 12)
                    .foregroundStyle(.secondary)
                Text(model?.currentName ?? session.provider.name)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                if !details.isEmpty {
                    Text(details)
                        .foregroundStyle(.secondary)
                }
                if session.status == .starting {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "chevron.down")
                    .orbitFont(.glyph, weight: .bold)
                    .foregroundStyle(.tertiary)
            }
            .orbitFont(.caption, weight: .medium)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(isHovering || isPresented ? Theme.hoverFill : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            SessionOptionsPopover(session: session, store: store) { isPresented = false }
        }
        .help("Model and agent settings")
    }

    private var model: ConfigOption? { session.configOptions.first { $0.category == "model" } }

    /// Only the reasoning level and, when it's on, Fast: "Opus 5 High Fast".
    private var details: String {
        var parts: [String] = []
        if let effort = session.configOptions.first(where: { $0.category == "thought_level" }) { parts.append(effort.currentName) }
        if session.configOptions.contains(where: { $0.isFastMode && $0.isOn }) { parts.append("Fast") }
        return parts.joined(separator: " ")
    }
}

/// Pages: the settings list, one setting's choices, and the models of every agent.
struct SessionOptionsPopover: View {
    let session: AgentSession
    let store: AgentStore
    let dismiss: () -> Void

    private enum Page: Hashable {
        case main
        case option(String)
        case models
    }

    @State private var page = Page.main

    var body: some View {
        Group {
            switch page {
            case .main:
                mainPage
            case .option(let id):
                if let option = session.configOptions.first(where: { $0.id == id }) {
                    OptionChoicesPage(option: option, back: { page = .main }) { value in
                        store.choose(value, for: option, in: session)
                        dismiss()
                    }
                }
            case .models:
                ModelsPage(session: session, store: store, back: { page = .main }, dismiss: dismiss)
            }
        }
        .frame(width: 300)
        .padding(6)
        // The popover would inherit the composer's secondary style.
        .foregroundStyle(.primary)
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 1) {
            let others = session.configOptions.filter { $0.category != "model" }
            ForEach(others) { option in
                if option.isToggle {
                    ToggleRow(icon: OptionIcons.icon(for: option), title: option.name, detail: option.description, isOn: Binding(
                        get: { option.isOn },
                        set: { on in
                            if let value = option.choices.first(where: { ConfigOption.onValues.contains($0.value.lowercased()) == on })?.value {
                                store.choose(value, for: option, in: session)
                            }
                        }
                    ))
                } else {
                    OptionsRow(icon: OptionIcons.icon(for: option), title: option.name, value: option.currentName, accessory: .chevron) {
                        page = .option(option.id)
                    }
                }
            }
            if session.status == .starting, session.configOptions.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting \(session.provider.name)…")
                        .foregroundStyle(.secondary)
                }
                .orbitFont(.control)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            if !others.isEmpty || session.status == .starting {
                Divider().padding(.vertical, 4)
            }
            let model = session.configOptions.first { $0.category == "model" }
            OptionsRow(icon: "cpu", title: "Model", value: model?.currentName ?? session.provider.name, accessory: .chevron) {
                page = .models
            }
        }
    }
}

private struct OptionChoicesPage: View {
    let option: ConfigOption
    let back: () -> Void
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PageHeader(title: option.name, back: back)
            FittingScrollView(maxHeight: 380) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(option.choices.enumerated()), id: \.element.value) { index, choice in
                        OptionsRow(
                            icon: OptionIcons.icon(for: choice, at: index, in: option),
                            title: choice.name,
                            detail: choice.description,
                            accessory: choice.value == option.currentValue ? .check : .none
                        ) {
                            choose(choice.value)
                        }
                    }
                }
            }
        }
    }
}

/// Models grouped by agent; picking another agent's model switches the chat to it.
private struct ModelsPage: View {
    let session: AgentSession
    let store: AgentStore
    let back: () -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private struct Group: Identifiable {
        let provider: AgentProvider
        let choices: [ConfigOption.Choice]
        /// Nil for an agent whose models aren't known yet: it's picked as a whole.
        let option: ConfigOption?
        var id: String { provider.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .orbitFont(.caption, weight: .semibold)
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Image(systemName: "magnifyingglass")
                    .orbitFont(.caption)
                    .foregroundStyle(.tertiary)
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .orbitFont(.control)
                    .focused($isSearchFocused)
                    .onSubmit(pickFirst)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            Divider().padding(.vertical, 4)
            FittingScrollView(maxHeight: 400) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(groups) { group in
                        groupView(group)
                    }
                    if groups.isEmpty {
                        Text("No models match “\(query)”")
                            .orbitFont(.control)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
        }
        .onAppear { isSearchFocused = true }
    }

    @ViewBuilder private func groupView(_ group: Group) -> some View {
        let isCurrent = group.provider.id == session.provider.id
        HStack(spacing: 6) {
            Text(group.provider.name)
            if !isCurrent, !session.isEmptyChat {
                Text("· new chat")
                    .foregroundStyle(.tertiary)
            }
        }
        .orbitFont(.caption, weight: .semibold)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, group.id == groups.first?.id ? 2 : 10)
        .padding(.bottom, 3)
        if group.option == nil {
            OptionsRow(icon: nil, provider: group.provider, title: "Default model", detail: "Models show up once \(group.provider.name) has started", accessory: .none) {
                pick(nil, in: group)
            }
        }
        ForEach(group.choices, id: \.value) { choice in
            OptionsRow(
                icon: nil,
                provider: group.provider,
                title: choice.name,
                detail: choice.description,
                accessory: isCurrent && choice.value == currentModel?.currentValue ? .check : .none
            ) {
                pick(choice.value, in: group)
            }
        }
    }

    private var currentModel: ConfigOption? { session.configOptions.first { $0.category == "model" } }

    /// The chat's own agent first, live; the others as they last reported.
    private var groups: [Group] {
        let ordered = [session.provider] + store.availableProviders.filter { $0.id != session.provider.id }
        let terms = query.lowercased().split(separator: " ")
        func matches(_ text: String) -> Bool {
            let text = text.lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        return ordered.compactMap { provider in
            let option = provider.id == session.provider.id ? (currentModel ?? store.models[provider.id]) : store.models[provider.id]
            let all = option?.choices ?? []
            let choices = terms.isEmpty || matches(provider.name) ? all : all.filter { matches($0.name) || matches($0.description ?? "") }
            if option == nil {
                return terms.isEmpty || matches(provider.name) ? Group(provider: provider, choices: [], option: nil) : nil
            }
            return choices.isEmpty ? nil : Group(provider: provider, choices: choices, option: option)
        }
    }

    private func pick(_ value: String?, in group: Group) {
        if group.provider.id == session.provider.id {
            if let value, let option = currentModel ?? group.option { store.choose(value, for: option, in: session) }
        } else {
            store.switchAgent(of: session, to: group.provider, model: value)
        }
        dismiss()
    }

    private func pickFirst() {
        guard let group = groups.first else { return }
        pick(group.choices.first?.value, in: group)
    }
}

private struct PageHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: back) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .orbitFont(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(title)
                        .orbitFont(.control, weight: .semibold)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Divider().padding(.vertical, 4)
        }
    }
}

/// A scroll view as tall as its content up to `maxHeight`: in a popover a
/// plain one shrinks to almost nothing.
private struct FittingScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height, 1), maxHeight))
    }
}

/// An on/off option (Fast mode) as a switch, like Cursor's.
private struct ToggleRow: View {
    let icon: String
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .orbitFont(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .orbitFont(.control)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture { isOn.toggle() }
        .help(detail ?? title)
    }
}

struct OptionsRow: View {
    enum Accessory { case none, check, chevron }

    let icon: String?
    /// Shows the agent's logo in place of `icon`.
    var provider: AgentProvider? = nil
    let title: String
    var detail: String? = nil
    var value: String? = nil
    let accessory: Accessory
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let provider {
                    AgentIcon(provider: provider, size: 14)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                } else if let icon {
                    Image(systemName: icon)
                        .orbitFont(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .orbitFont(.control)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .orbitFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .orbitFont(.control)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                switch accessory {
                case .none:
                    EmptyView()
                case .check:
                    Image(systemName: "checkmark")
                        .orbitFont(.caption, weight: .semibold)
                        .foregroundStyle(.tint)
                case .chevron:
                    Image(systemName: "chevron.right")
                        .orbitFont(.micro, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHovering ? Theme.hoverFill : .clear, in: .rect(cornerRadius: Theme.smallCorner))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// SF Symbols for agent settings; ACP only names categories, so choices are
/// recognized by their usual names.
enum OptionIcons {
    static func icon(for option: ConfigOption) -> String {
        if option.isFastMode { return "bolt" }
        return switch option.category {
        case "model": "cpu"
        case "thought_level": "brain"
        case "mode": "lock.shield"
        default: "slider.horizontal.3"
        }
    }

    static func icon(for choice: ConfigOption.Choice, at index: Int, in option: ConfigOption) -> String? {
        switch option.category {
        case "thought_level":
            let levels = ["0", "33", "50", "67", "100"]
            let step = option.choices.count > 1 ? Double(index) / Double(option.choices.count - 1) : 1
            return "gauge.with.dots.needle.\(levels[Int((step * Double(levels.count - 1)).rounded())])percent"
        case "mode":
            let name = (choice.value + " " + choice.name).lowercased()
            if name.contains("plan") { return "list.bullet.clipboard" }
            if name.contains("bypass") || name.contains("full") || name.contains("yolo") { return "exclamationmark.shield" }
            if name.contains("read") { return "eye" }
            if name.contains("accept") || name.contains("edit") || name.contains("auto") { return "pencil.and.outline" }
            return "hand.raised"
        default:
            return nil
        }
    }
}
