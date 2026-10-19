import AppKit
import OrbitKit
import SwiftUI
import UniformTypeIdentifiers

// Drag and drop (D91). Tabs are dragged by our own gesture inside the window
// (`TabDrag`): reorder, move to the other side, split on an editor edge,
// attach to the agent chat. The system drag they used first left the image
// hanging for seconds after a drop and the insertion line behind. Files
// (explorer, Finder) use the system drag: they drop on a tab row, an editor
// or the chat.

// MARK: - Tab drag

/// The tab being dragged, where the pointer is (window coordinates, top-left
/// origin, as SwiftUI's global space) and what a release there would do.
@MainActor
@Observable
final class TabDrag {
    /// One per window (D101): frames are in that window's coordinates.

    enum Target: Equatable {
        case row(EditorGroup.ID, index: Int)
        case editor(EditorDropZone)
        case chat
    }

    private(set) var tab: EditorTab?
    private var group: EditorGroup.ID?
    private(set) var location: CGPoint = .zero
    private(set) var target: Target?

    // Where things are, reported by the views (global frames).
    @ObservationIgnored var rows: [EditorGroup.ID: CGRect] = [:]
    @ObservationIgnored var tabFrames: [EditorGroup.ID: [EditorTab.ID: CGRect]] = [:]
    @ObservationIgnored var editorFrame: CGRect = .zero
    @ObservationIgnored var chatFrame: CGRect?
    /// The Agents plugin, for a tab dropped on the chat.
    @ObservationIgnored var agent: () -> AgentTasks? = { nil }

    func move(_ tab: EditorTab, from group: EditorGroup.ID, to location: CGPoint, workspace: Workspace) {
        self.tab = tab
        self.group = group
        self.location = location
        target = target(at: location, workspace: workspace)
    }

    func drop(workspace: Workspace) {
        defer { tab = nil; group = nil; target = nil }
        guard let tab, let target else { return }
        switch target {
        case .row(let groupID, let index):
            guard let into = workspace.groups.firstIndex(where: { $0.id == groupID }) else { return }
            workspace.place(tab, from: group, into: into, at: index)
        case .editor(let zone):
            zone.apply([(tab, group)], workspace: workspace)
        case .chat:
            if let url = tab.url { agent()?.attachFile(url) }
        }
    }

    /// The x of the insertion line in a row, in global coordinates.
    func insertionX(in groupID: EditorGroup.ID, at index: Int, workspace: Workspace) -> CGFloat? {
        guard let group = workspace.groups.first(where: { $0.id == groupID }), let frames = tabFrames[groupID] else { return nil }
        let ordered = group.tabs.compactMap { frames[$0.id] }
        guard !ordered.isEmpty else { return rows[groupID]?.minX }
        return index < ordered.count ? ordered[index].minX - 1 : ordered[ordered.count - 1].maxX + 1
    }

    private func target(at point: CGPoint, workspace: Workspace) -> Target? {
        for group in workspace.groups {
            guard let row = rows[group.id], row.insetBy(dx: 0, dy: -6).contains(point) else { continue }
            let frames = tabFrames[group.id] ?? [:]
            let ordered = group.tabs.compactMap { tab in frames[tab.id].map { (tab.id, $0) } }
            return .row(group.id, index: ordered.firstIndex { point.x < $0.1.midX } ?? group.tabs.count)
        }
        // Before the editor: its column may run under the inspector.
        if let chatFrame, chatFrame.contains(point) { return tab?.url != nil ? .chat : nil }
        if editorFrame.contains(point) {
            return .editor(EditorDropZone.at(x: point.x - editorFrame.minX, width: editorFrame.width, workspace: workspace))
        }
        return nil
    }
}

/// Makes a tab draggable with `TabDrag`; a click still selects it.
struct TabDragGesture: ViewModifier {
    let tab: EditorTab
    let group: EditorGroup.ID
    let workspace: Workspace
    @Environment(TabDrag.self) private var drag

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { drag.move(tab, from: group, to: $0.location, workspace: workspace) }
                .onEnded { _ in drag.drop(workspace: workspace) }
        )
    }
}

/// The dragged tab under the pointer and the line where it would land; over
/// the whole window, drawn from window coordinates.
struct TabDragOverlay: View {
    let workspace: Workspace
    @Environment(TabDrag.self) private var drag

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            if let tab = drag.tab {
                if case .row(let group, let index) = drag.target, let x = drag.insertionX(in: group, at: index, workspace: workspace),
                   let row = drag.rows[group] {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 2, height: 18)
                        .position(x: x - origin.x, y: row.midY - origin.y)
                }
                HStack(spacing: 6) {
                    if tab.kind == EditorTab.fileKind, let url = tab.url {
                        FileIconView(url: url, size: 13)
                    } else {
                        Image(systemName: tab.systemImage).foregroundStyle(.tint)
                    }
                    Text(tab.title)
                        .font(.orbit(.body, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .fixedSize()
                .position(x: drag.location.x - origin.x, y: drag.location.y - origin.y + 4)
                .opacity(drag.target == nil ? 0.6 : 1)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Editor drop zones

/// Where a drop on the editor goes: a side's group, or a new group on an edge.
enum EditorDropZone: Equatable {
    case group(Int)
    case newGroup(Workspace.Side)

    /// Not split: the outer quarters split the editor; split: each side is its group.
    @MainActor
    static func at(x: CGFloat, width: CGFloat, workspace: Workspace) -> EditorDropZone {
        guard width > 0 else { return .group(0) }
        if workspace.isSplit { return .group(x < width * workspace.splitFraction ? 0 : 1) }
        if workspace.allTabs.isEmpty { return .group(0) }
        if x < width * 0.25 { return .newGroup(.leading) }
        if x > width * 0.75 { return .newGroup(.trailing) }
        return .group(0)
    }

    /// The part of the editor the result will take, for the highlight.
    @MainActor
    func rect(width: CGFloat, height: CGFloat, workspace: Workspace) -> CGRect {
        let split = (width * workspace.splitFraction).rounded()
        switch self {
        case .group(let index) where workspace.isSplit:
            return index == 0 ? CGRect(x: 0, y: 0, width: split, height: height) : CGRect(x: split, y: 0, width: width - split, height: height)
        case .group: return CGRect(x: 0, y: 0, width: width, height: height)
        case .newGroup(.leading): return CGRect(x: 0, y: 0, width: width / 2, height: height)
        case .newGroup(.trailing): return CGRect(x: width / 2, y: 0, width: width / 2, height: height)
        }
    }

    /// Opens the tabs there; a tab from a group (`group` set) moves.
    @MainActor
    func apply(_ tabs: [(tab: EditorTab, group: EditorGroup.ID?)], workspace: Workspace) {
        for (index, item) in tabs.enumerated() {
            switch self {
            case .group(let target):
                workspace.place(item.tab, from: item.group, into: min(target, workspace.groups.count - 1))
            case .newGroup(let side):
                if index == 0 {
                    workspace.placeInNewGroup(item.tab, from: item.group, side: side)
                } else {
                    workspace.place(item.tab, from: item.group, into: workspace.focusedGroup)
                }
            }
        }
    }
}

/// Files that can open in the editor (folders can't).
@MainActor
private func openableFiles(_ urls: [URL]) -> [(tab: EditorTab, group: EditorGroup.ID?)] {
    urls.filter { url in
        url.isFileURL && !((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
    }.map { (EditorTab.file($0), nil) }
}

/// Catches file drops over the editor, text views included: an AppKit view
/// above them registered for files. It takes no clicks (`hitTest` is nil;
/// AppKit finds drag destinations by registered types, not by `hitTest`).
struct EditorDropCatcher: NSViewRepresentable {
    let workspace: Workspace
    @Binding var zone: EditorDropZone?

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.workspace = workspace
        view.onZone = { zone = $0 }
    }

    final class CatcherView: NSView {
        var workspace: Workspace?
        var onZone: (EditorDropZone?) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func zone(for info: any NSDraggingInfo) -> EditorDropZone? {
            guard let workspace else { return nil }
            let point = convert(info.draggingLocation, from: nil)
            return EditorDropZone.at(x: point.x, width: bounds.width, workspace: workspace)
        }

        override func draggingEntered(_ info: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(info) }

        override func draggingUpdated(_ info: any NSDraggingInfo) -> NSDragOperation {
            onZone(zone(for: info))
            return .copy
        }

        override func draggingExited(_ info: (any NSDraggingInfo)?) { onZone(nil) }
        override func draggingEnded(_ info: any NSDraggingInfo) { onZone(nil) }

        override func performDragOperation(_ info: any NSDraggingInfo) -> Bool {
            defer { onZone(nil) }
            guard let workspace, let zone = zone(for: info) else { return false }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let files = openableFiles(urls)
            guard !files.isEmpty else { return false }
            zone.apply(files, workspace: workspace)
            return true
        }
    }
}

/// The highlight of the part of the editor a drop will fill.
struct EditorDropHighlight: View {
    let zone: EditorDropZone?
    let workspace: Workspace

    var body: some View {
        GeometryReader { proxy in
            if let zone {
                let rect = zone.rect(width: proxy.size.width, height: proxy.size.height, workspace: workspace).insetBy(dx: 6, dy: 6)
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.dropFill)
                    .strokeBorder(Theme.dropBorder, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .animation(.snappy(duration: 0.15), value: zone)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Files on a tab row

/// Files dropped on a tab row open between the tabs under the pointer.
struct TabRowDropDelegate: DropDelegate {
    let workspace: Workspace
    let group: EditorGroup
    let frames: [EditorTab.ID: CGRect]
    @Binding var insertion: Int?

    private func index(at location: CGPoint) -> Int {
        let ordered = group.tabs.compactMap { tab in frames[tab.id].map { (tab.id, $0) } }
        return ordered.firstIndex { location.x < $0.1.midX } ?? group.tabs.count
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertion = index(at: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { insertion = nil }

    func performDrop(info: DropInfo) -> Bool {
        let position = index(at: info.location)
        insertion = nil
        let providers = info.itemProviders(for: [.fileURL])
        let workspace = workspace, groupID = group.id
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadFileURL() { urls.append(url) }
            }
            for (offset, item) in openableFiles(urls).enumerated() {
                guard let target = workspace.groups.firstIndex(where: { $0.id == groupID }) else { return }
                workspace.place(item.tab, from: nil, into: target, at: position + offset)
            }
        }
        return true
    }
}

extension NSItemProvider {
    @MainActor fileprivate func loadFileURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}

// MARK: - Window dragging

/// Tabs sit in the title bar strip, where a mouse drag moves the window: over
/// a tab it mustn't, so the tab drags instead. The window is made immovable
/// while the pointer is on the tab (the decision is made at mouse-down).
struct KeepsWindowStillWhileHovered: ViewModifier {
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowReader(window: $window))
            .onHover { hovering in
                // Async and only on a real change (window properties, see CLAUDE.md).
                DispatchQueue.main.async {
                    guard let window, window.isMovable == hovering else { return }
                    window.isMovable = !hovering
                }
            }
    }
}

private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = { window = $0 }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: (NSWindow?) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [weak self] in self?.onWindow(window) }
        }
    }
}
