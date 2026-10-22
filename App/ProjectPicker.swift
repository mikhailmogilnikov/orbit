import AppKit
import OrbitKit
import SwiftUI

/// A window without a folder (D101), laid out like Xcode 26's welcome window
/// (D160): Orbit and what to do on the left, recent projects in a full-height
/// column on the right.
struct ProjectPicker: View {
    let host: PluginHost
    @State private var isCloning = false
    @State private var selection: URL?

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        let recent = RecentFolders.shared.existing
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer()
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                Text("Orbit")
                    .orbitFont(.display, weight: .bold)
                    .padding(.top, 10)
                Text("Version \(version)")
                    .orbitFont(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.bottom, 40)
                VStack(spacing: 4) {
                    WelcomeAction(title: "Open Folder…", subtitle: "A project on this Mac", systemImage: "folder", shortcut: "⌘O") {
                        host.workspace.presentOpenFolderPanel()
                    }
                    WelcomeAction(title: "Clone Repository…", subtitle: "Copy a Git repository and open it", systemImage: "arrow.down.to.line") {
                        isCloning = true
                    }
                }
                .frame(maxWidth: 300)
                Spacer()
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .ignoresSafeArea()

            // Full height, like a sidebar: the window is the welcome window, no card in it.
            RecentProjectsList(recent: recent, selection: $selection) { host.workspace.requestOpenFolder($0) }
                .frame(width: 360)
                .ignoresSafeArea(.container, edges: .top)
        }
        .themedWindowBackground()
        .sheet(isPresented: $isCloning) {
            CloneRepositorySheet { host.workspace.requestOpenFolder($0) }
        }
    }
}

/// An action row on the welcome window: a tile, what it does, its keys.
private struct WelcomeAction: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .orbitFont(.title, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Theme.activeFill, in: .rect(cornerRadius: Theme.corner, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .orbitFont(.control, weight: .semibold)
                    Text(subtitle)
                        .orbitFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let shortcut { KeyCaps(shortcut) }
            }
            .padding(8)
            .background(isHovering ? Theme.hoverFill : .clear, in: .rect(cornerRadius: Theme.largeCorner, style: .continuous))
            // Rounded like the hover fill: with keyboard navigation on, the
            // focus ring takes this shape (it was a square around the row).
            .contentShape(.rect(cornerRadius: Theme.largeCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Recent projects as a list: click selects, double-click or Return opens,
/// right-click shows it in Finder or forgets it, as in Xcode.
private struct RecentProjectsList: View {
    let recent: [URL]
    @Binding var selection: URL?
    let open: (URL) -> Void

    var body: some View {
        Group {
            if recent.isEmpty {
                EmptyStateView("No Recent Projects", systemImage: "clock", message: "Folders you open show up here.")
            } else {
                List(recent, id: \.self, selection: $selection) { folder in
                    RecentProjectRow(folder: folder)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .safeAreaPadding(.top, 16)
                .contextMenu(forSelectionType: URL.self) { folders in
                    if let folder = folders.first {
                        Button("Open") { open(folder) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        Divider()
                        Button("Remove from Recent Projects") { RecentFolders.shared.remove(folder) }
                    }
                } primaryAction: { folders in
                    if let folder = folders.first { open(folder) }
                }
            }
        }
        .background(Theme.subtleFill)
    }
}

private struct RecentProjectRow: View {
    let folder: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.lastPathComponent)
                    .orbitFont(.control, weight: .semibold)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let branch = Self.branch(of: folder) {
                        Image(systemName: "arrow.triangle.branch")
                            .orbitFont(.micro)
                        Text(branch)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text("·")
                    }
                    Text((folder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .orbitFont(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .help((folder.path as NSString).abbreviatingWithTildeInPath)
    }

    /// The checked-out branch from .git/HEAD: one small read, no git process.
    private static func branch(of folder: URL) -> String? {
        let head = folder.appendingPathComponent(".git/HEAD")
        guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: refs/heads/") else { return nil }
        return String(line.dropFirst("ref: refs/heads/".count))
    }
}

/// `git clone` into a folder the user picks, then opens the copy.
private struct CloneRepositorySheet: View {
    let opened: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isRunning = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone Repository")
                .orbitFont(.control, weight: .bold)
            TextField("Repository URL", text: $address, prompt: Text("https://github.com/owner/repo.git"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
                .disabled(isRunning)
                .onSubmit(clone)
            if let failure {
                Text(failure)
                    .orbitFont(.body)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack {
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text("Cloning…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clone…", action: clone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
            }
        }
        .padding(20)
    }

    private func clone() {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Clone Here"
        panel.message = "Choose where to put the repository."
        guard panel.runSheetModal() == .OK, let parent = panel.url else { return }
        let name = URL(string: address)?.deletingPathExtension().lastPathComponent
            ?? (address as NSString).lastPathComponent.replacingOccurrences(of: ".git", with: "")
        let destination = parent.appendingPathComponent(name.isEmpty ? "repository" : name)
        isRunning = true
        failure = nil
        Task {
            let result = await Self.run(["clone", address, destination.path])
            isRunning = false
            if let result {
                failure = result
            } else {
                dismiss()
                opened(destination)
            }
        }
    }

    /// nil when git succeeded, else what it said.
    private static func run(_ arguments: [String]) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            // No prompt nobody can answer: a private repo fails with git's message.
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "git clone failed." : message
        }.value
    }
}
