import AppKit
import OrbitKit
import SwiftUI

/// A window without a folder, as in Cursor (D101): open or clone a project,
/// or pick a recent one.
struct ProjectPicker: View {
    let host: PluginHost
    @State private var showsAll = false
    @State private var isCloning = false

    private static let shownRecent = 6

    var body: some View {
        let recent = RecentFolders.shared.existing
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orbit")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Open a project to start working with agents.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                PickerCard(title: "Open Folder", systemImage: "folder", shortcut: "⌘O") {
                    host.workspace.presentOpenFolderPanel()
                }
                PickerCard(title: "Clone Repository", systemImage: "arrow.down.circle", shortcut: nil) {
                    isCloning = true
                }
            }

            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Recent Projects")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if recent.count > Self.shownRecent {
                            Button(showsAll ? "Show Less" : "Show All (\(recent.count))") { showsAll.toggle() }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.horizontal, 10)
                    VStack(spacing: 0) {
                        ForEach(showsAll ? recent : Array(recent.prefix(Self.shownRecent)), id: \.self) { folder in
                            RecentProjectRow(folder: folder) { host.workspace.requestOpenFolder(folder) }
                        }
                    }
                }
            }
        }
        .frame(width: 520)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedWindowBackground()
        .sheet(isPresented: $isCloning) {
            CloneRepositorySheet { host.workspace.requestOpenFolder($0) }
        }
    }
}

private struct PickerCard: View {
    let title: String
    let systemImage: String
    let shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    if let shortcut { KeyCaps(shortcut) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtleFill.opacity(isHovering ? 2.5 : 1.5), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RecentProjectRow: View {
    let folder: URL
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text(folder.lastPathComponent)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                Text((folder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if isHovering {
                    Button {
                        RecentFolders.shared.remove(folder)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Recent Projects")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isHovering ? AnyShapeStyle(Theme.subtleFill.opacity(2)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help((folder.path as NSString).abbreviatingWithTildeInPath)
        .onHover { isHovering = $0 }
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
                .font(.headline)
            TextField("Repository URL", text: $address, prompt: Text("https://github.com/owner/repo.git"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
                .disabled(isRunning)
                .onSubmit(clone)
            if let failure {
                Text(failure)
                    .font(.callout)
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
        guard panel.runModal() == .OK, let parent = panel.url else { return }
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
