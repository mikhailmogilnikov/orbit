import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

// Call and type hierarchies (D200).

/// The last Call / Type Hierarchy: the symbol at the caret as the root, its
/// callers (or callees, supertypes, subtypes) a level at a time, asked for
/// when a row opens.
@MainActor
@Observable
final class HierarchyModel {
    struct Node: Identifiable {
        /// Unique in the tree: the same function can appear under several callers.
        let id: Int
        let item: HierarchyItem
        let depth: Int
        /// Nil until asked for.
        var children: [Int]?
        var isLoading = false
    }

    private(set) var kind: HierarchyKind = .calls
    private(set) var direction: HierarchyDirection = .incoming
    private(set) var root: Int?
    private(set) var nodes: [Int: Node] = [:]
    private(set) var expanded: Set<Int> = []
    private(set) var isPreparing = false
    /// The kind asked for last found nothing at the caret.
    private(set) var foundNothing = false
    var selected: Int?
    @ObservationIgnored private var languages: LanguageIntelligence?
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var preparing: Task<Void, Never>?

    /// The rows on screen: the root, then each open node's children, depth first.
    var rows: [Node] {
        guard let root, let node = nodes[root] else { return [] }
        var rows: [Node] = []
        func walk(_ node: Node) {
            rows.append(node)
            guard expanded.contains(node.id) else { return }
            for child in node.children ?? [] { if let child = nodes[child] { walk(child) } }
        }
        walk(node)
        return rows
    }

    func show(_ kind: HierarchyKind, at caret: SourceLocation, languages: LanguageIntelligence) {
        self.languages = languages
        preparing?.cancel()
        isPreparing = true
        preparing = Task {
            let items = await languages.prepareHierarchy(kind, at: caret.range.start, in: caret.url)
            guard !Task.isCancelled else { return }
            isPreparing = false
            self.kind = kind
            nodes.removeAll()
            expanded.removeAll()
            selected = nil
            foundNothing = items.isEmpty
            guard let item = items.first else {
                root = nil
                return
            }
            let id = add(item, depth: 0)
            root = id
            selected = id
            toggle(id)
        }
    }

    /// Callers ⇄ callees (supertypes ⇄ subtypes) of the same root.
    func setDirection(_ direction: HierarchyDirection) {
        guard direction != self.direction else { return }
        self.direction = direction
        guard let root, let item = nodes[root]?.item else { return }
        nodes.removeAll()
        expanded.removeAll()
        let id = add(item, depth: 0)
        self.root = id
        selected = id
        toggle(id)
    }

    func toggle(_ id: Int) {
        guard let node = nodes[id] else { return }
        if expanded.contains(id) {
            expanded.remove(id)
            return
        }
        expanded.insert(id)
        guard node.children == nil, !node.isLoading, let languages else { return }
        nodes[id]?.isLoading = true
        let direction = direction
        Task {
            let items = await languages.hierarchy(direction, of: node.item)
            // Switched direction or started over meanwhile.
            guard nodes[id]?.item == node.item, self.direction == direction else { return }
            let children = items.map { add($0, depth: node.depth + 1) }
            nodes[id]?.children = children
            nodes[id]?.isLoading = false
        }
    }

    func isExpanded(_ id: Int) -> Bool { expanded.contains(id) }

    private func add(_ item: HierarchyItem, depth: Int) -> Int {
        nextID += 1
        nodes[nextID] = Node(id: nextID, item: item, depth: depth)
        return nextID
    }

    var title: String {
        switch (kind, direction) {
        case (.calls, .incoming): "Callers of"
        case (.calls, .outgoing): "Calls from"
        case (.types, .incoming): "Supertypes of"
        case (.types, .outgoing): "Subtypes of"
        }
    }
}

/// The Hierarchy bottom panel: a tree under the symbol, opened a level at a
/// time; a click goes to the function (for calls, to the call in it).
struct HierarchyPanel: View {
    let model: HierarchyModel
    let workspace: Workspace

    var body: some View {
        let rows = model.rows
        if rows.isEmpty {
            if model.isPreparing {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.foundNothing {
                PanelEmptyState("No Hierarchy", message: "The language server found no function or type at the caret, or it can't show hierarchies.")
            } else {
                PanelEmptyState("No Hierarchy", message: "Put the caret on a function and choose Code ▸ Show Call Hierarchy (⌃⇧⌘H), or on a type and choose Show Type Hierarchy.")
            }
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                List {
                    ForEach(rows) { node in
                        HierarchyRow(node: node, model: model, workspace: workspace)
                            .listRowSeparator(.hidden)
                            .listRowBackground(model.selected == node.id ? Theme.selectedFill : Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .opacity(model.isPreparing ? 0.5 : 1)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.title)
                .foregroundStyle(.secondary)
            Text(model.root.flatMap { model.nodes[$0]?.item.name } ?? "symbol")
                .orbitFont(.code, weight: .semibold)
            Spacer()
            if model.isPreparing { ProgressView().controlSize(.mini) }
            Picker("Direction", selection: Binding(get: { model.direction }, set: { model.setDirection($0) })) {
                Text(model.kind == .calls ? "Callers" : "Supertypes").tag(HierarchyDirection.incoming)
                Text(model.kind == .calls ? "Callees" : "Subtypes").tag(HierarchyDirection.outgoing)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .orbitFont(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct HierarchyRow: View {
    let node: HierarchyModel.Node
    let model: HierarchyModel
    let workspace: Workspace

    var body: some View {
        let item = node.item
        HStack(spacing: 6) {
            // A leaf (asked, nothing below) has no chevron, only its room.
            Button {
                withAnimation(.snappy(duration: 0.2)) { model.toggle(node.id) }
            } label: {
                Group {
                    if node.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        DisclosureChevron(isExpanded: model.isExpanded(node.id))
                            .foregroundStyle(.tertiary)
                            .opacity(node.children?.isEmpty == true ? 0 : 1)
                    }
                }
                .frame(width: 12, height: 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(node.children?.isEmpty == true)
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: item.symbolKind.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(item.name)
                        .orbitFont(.code, weight: node.depth == 0 ? .semibold : .regular)
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    if item.callSites.count > 1 {
                        Badge(count: item.callSites.count)
                            .help("\(item.callSites.count) calls")
                    }
                    Text("\(item.location.url.lastPathComponent):\(item.location.range.start.line + 1)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .help(workspace.relativePath(item.location.url))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .orbitFont(.body)
        .padding(.leading, CGFloat(node.depth) * 16)
        .contextMenu {
            if item.callSites.count > 1 {
                ForEach(Array(item.callSites.enumerated()), id: \.offset) { _, site in
                    Button("Call on Line \(site.range.start.line + 1)") { workspace.open(site) }
                }
            }
            Button("Go to \(item.name)") { workspace.open(item.location) }
        }
    }

    /// A caller opens at its call (the root and type rows at their name).
    private func open() {
        let item = node.item
        model.selected = node.id
        workspace.open(model.direction == .incoming ? item.callSites.first ?? item.location : item.location)
    }
}
