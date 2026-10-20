import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// Settings → Checkpoints (D185).
struct CheckpointSettingsPane: View {
    @Bindable var retention: CheckpointRetention
    @State private var checkpoints: Int64?
    @State private var copies: Int64?
    @State private var freed: Int64?

    var body: some View {
        SettingsForm {
            Section {
                Picker(selection: $retention.days) {
                    ForEach(CheckpointStorage.choices, id: \.self) { days in
                        Text(CheckpointStorage.title(days)).tag(days)
                    }
                } label: {
                    Text("Keep snapshots")
                    Text("Older ones are removed once a day. A chat can't rewind past a removed snapshot.")
                }
                .settingsItem("keep")
                LabeledContent {
                    HStack(spacing: 8) {
                        if retention.isCleaning { ProgressView().controlSize(.small) }
                        Button("Clean Up Now") { cleanUp() }
                            .disabled(retention.days == nil || retention.isCleaning)
                    }
                } label: {
                    Text("Snapshots")
                    Text(sizeLine)
                }
                .settingsItem("cleanUp")
            } header: {
                Text("Checkpoints")
            } footer: {
                Text("Before each agent turn Orbit snapshots the project into a private git repository, outside the project, so every change shows inline, even ones made through shell commands, and a chat can rewind.")
            }

            Section {
                LabeledContent {
                    Button("Show in Finder") { reveal(IsolatedCopies.storage) }
                } label: {
                    Text("Isolated copies")
                    Text(copies.map { "\(Self.format($0)) on disk" } ?? "Measuring…")
                }
                .settingsItem("copies")
            } footer: {
                Text("Copies of the project for chats that work in isolation. A copy goes away with its chat or when its changes are applied.")
            }
        }
        .task { await measure() }
    }

    private var sizeLine: String {
        guard let checkpoints else { return "Measuring…" }
        let size = "\(Self.format(checkpoints)) for all projects"
        return freed.map { "\(size); \(Self.format($0)) freed" } ?? size
    }

    private func cleanUp() {
        guard let days = retention.days else { return }
        Task {
            freed = await retention.cleanUp(olderThan: days)
            await measure()
        }
    }

    private func measure() async {
        let (checkpoints, copies) = await Task.detached(priority: .utility) {
            (CheckpointStorage.size(of: Checkpoints.storage), CheckpointStorage.size(of: IsolatedCopies.storage))
        }.value
        self.checkpoints = checkpoints
        self.copies = copies
    }

    private func reveal(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
