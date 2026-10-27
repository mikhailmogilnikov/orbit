import AppKit
import Observation
import OrbitAPI

/// The editors of the tabs shown last, off-screen (D249). Switching back to
/// one puts its text view back as it was, scrolled, laid out and colored,
/// with its undo, instead of building one and laying out and coloring the
/// file again: that was most of a tab switch's 100 ms. One set per window; a
/// closed tab's editor goes, and so do the editors wired to a plugin that's
/// been turned on or off since.
@MainActor
final class KeptEditors {
    private static let limit = 4
    private struct Entry {
        let tab: EditorTab.ID
        let wiring: AnyHashable
        let coordinator: CodeEditor.Coordinator
    }
    /// Most recent first.
    private var entries: [Entry] = []
    private weak var workspace: Workspace?
    /// The services editors are wired to now: the last asked for.
    private var wiring: AnyHashable?

    init(_ context: PluginContext) {
        workspace = context.workspace
        watchTabs(context)
    }

    /// The kept editor of this tab, wired the same and showing this document;
    /// out of the set while it's shown.
    func take(_ tab: EditorTab.ID, wiring: AnyHashable, document: TextDocument) -> CodeEditor.Coordinator? {
        self.wiring = wiring
        release { $0.wiring != wiring }
        guard let index = entries.firstIndex(where: { $0.tab == tab }) else { return nil }
        let coordinator = entries.remove(at: index).coordinator
        // A document closed and opened again is a new one: its old editor showed the old.
        guard coordinator.document === document else {
            Self.release(coordinator)
            return nil
        }
        return coordinator
    }

    func keep(_ coordinator: CodeEditor.Coordinator, tab: EditorTab.ID, wiring: AnyHashable) {
        // Closing the tab took it away: the tabs may have been watched first.
        guard workspace?.allTabs.contains(where: { $0.id == tab }) == true else { return Self.release(coordinator) }
        // Wired to a plugin turned on or off since: SwiftUI may build the new editor before it lets go of this one.
        guard self.wiring == nil || self.wiring == wiring else { return Self.release(coordinator) }
        // The same file on both sides of a split: the one put away last stays.
        release { $0.tab == tab }
        entries.insert(Entry(tab: tab, wiring: wiring, coordinator: coordinator), at: 0)
        while entries.count > Self.limit { Self.release(entries.removeLast().coordinator) }
    }

    func releaseAll() { release { _ in true } }

    private func watchTabs(_ context: PluginContext) {
        guard context.isActive else { return releaseAll() }
        let workspace = context.workspace
        let open = withObservationTracking { Set(workspace.allTabs.map(\.id)) } onChange: { [weak self] in
            Task { @MainActor in self?.watchTabs(context) }
        }
        release { !open.contains($0.tab) }
    }

    private func release(where shouldGo: (Entry) -> Bool) {
        entries.removeAll { entry in
            guard shouldGo(entry) else { return false }
            Self.release(entry.coordinator)
            return true
        }
    }

    private static func release(_ coordinator: CodeEditor.Coordinator) {
        coordinator.stopWork()
        coordinator.detachedView = nil
        OpenEditors.shared.unregister(coordinator)
    }
}
