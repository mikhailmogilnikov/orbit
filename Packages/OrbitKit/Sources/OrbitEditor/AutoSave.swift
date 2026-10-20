import AppKit
import OrbitAPI

/// Settings → Editor → Auto Save (D180): a second after typing stops, or when
/// Orbit or the tab loses focus. Plain saves: formatting on save would move
/// text under the caret. A file changed on disk too is left for its banner.
@MainActor
final class AutoSaver {
    private let workspace: Workspace
    private let options: EditorOptions
    private var pending: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init(workspace: Workspace, options: EditorOptions) {
        self.workspace = workspace
        self.options = options
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusChanged() }
        }
        watchEdits()
        watchTabs()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pending?.cancel()
    }

    private func watchEdits() {
        guard !workspace.isClosed else { return }
        withObservationTracking {
            _ = workspace.documents.dirtyDocuments.map(\.text)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.watchEdits()
                self?.edited()
            }
        }
    }

    private func watchTabs() {
        guard !workspace.isClosed else { return }
        withObservationTracking {
            _ = workspace.activeTab?.id
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.watchTabs()
                self?.focusChanged()
            }
        }
    }

    private func edited() {
        pending?.cancel()
        guard options.autoSave == .afterDelay else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveAll()
        }
    }

    private func focusChanged() {
        if options.autoSave == .onFocusChange { saveAll() }
    }

    private func saveAll() {
        guard !workspace.isClosed else { return }
        for document in workspace.documents.dirtyDocuments where document.diskConflict == nil {
            document.syncWithDisk()
            guard document.diskConflict == nil, document.isDirty else { continue }
            try? document.save()
        }
    }
}
