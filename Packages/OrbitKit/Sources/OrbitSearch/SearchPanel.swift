import OrbitAPI
import OrbitUI
import SwiftUI

@MainActor
@Observable
final class SearchModel {
    private let workspace: Workspace
    private let files: ProjectFiles

    var query = "" { didSet { if query != oldValue { schedule() } } }
    var options = SearchOptions() { didSet { if options != oldValue { schedule(delay: .zero) } } }
    private(set) var result: SearchResult?
    private(set) var error: String?
    private(set) var isSearching = false
    /// Paths of files the user collapsed in the results.
    var collapsed: Set<String> = []
    var selection: String?
    /// Bumped by "Find in Project" to focus the field.
    var focusRequest = 0

    private var task: Task<Void, Never>?
    private var matchesByID: [String: (path: String, line: Int)] = [:]

    init(workspace: Workspace, files: ProjectFiles) {
        self.workspace = workspace
        self.files = files
    }

    /// Searches as you type, after a short pause.
    func schedule(delay: Duration = .milliseconds(250)) {
        task?.cancel()
        let query = query
        guard !query.isEmpty else {
            result = nil
            error = nil
            isSearching = false
            return
        }
        let options = options
        isSearching = true
        task = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            guard let (root, paths) = await files.current() else {
                isSearching = false
                return
            }
            let overrides = unsavedBuffers(root: root)
            let outcome = await Task.detached(priority: .userInitiated) {
                do throws(TextSearch.Failure) {
                    return Result<SearchResult, TextSearch.Failure>.success(
                        try await TextSearch.run(query, options: options, root: root, paths: paths, overrides: overrides)
                    )
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled else { return }
            isSearching = false
            switch outcome {
            case .success(let result):
                apply(result)
                error = nil
            case .failure:
                result = nil
                error = "Invalid regular expression"
            }
        }
    }

    /// Re-runs the current search after files changed on disk (agent edits, saves).
    func refresh() {
        guard !query.isEmpty else { return }
        schedule(delay: .zero)
    }

    func open(_ id: String) {
        guard let match = matchesByID[id], let root = files.root else { return }
        workspace.openFile(root.appendingPathComponent(match.path), line: match.line)
    }

    private func apply(_ result: SearchResult) {
        self.result = result
        matchesByID = [:]
        for file in result.files {
            for match in file.matches { matchesByID[match.id] = (file.path, match.line) }
        }
    }

    /// Unsaved edits are what the user sees, so search them instead of the disk copy.
    private func unsavedBuffers(root: URL) -> [String: String] {
        let rootPath = root.standardizedFileURL.path + "/"
        var buffers: [String: String] = [:]
        for document in workspace.documents.dirtyDocuments {
            let path = document.url.standardizedFileURL.path
            if path.hasPrefix(rootPath) { buffers[String(path.dropFirst(rootPath.count))] = document.text }
        }
        return buffers
    }
}

struct SearchPanel: View {
    @Bindable var model: SearchModel
    let workspace: Workspace
    @FocusState private var isFieldFocused: Bool
    @State private var handledFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            SearchField(model: model, isFocused: $isFieldFocused)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            summary
            results
        }
        .onAppear { focusIfRequested() }
        .onChange(of: model.focusRequest) { focusIfRequested() }
        .onChange(of: workspace.fileSystemGeneration) { model.refresh() }
        .onChange(of: workspace.root) {
            model.collapsed = []
            model.refresh()
        }
    }

    private func focusIfRequested() {
        guard model.focusRequest != handledFocusRequest else { return }
        handledFocusRequest = model.focusRequest
        // The panel may have just been revealed; focus once it's in the window.
        DispatchQueue.main.async { isFieldFocused = true }
    }

    @ViewBuilder
    private var summary: some View {
        let text: String? = if let error = model.error {
            error
        } else if let result = model.result {
            result.files.isEmpty
                ? "No results"
                : "\(result.matchCount)\(result.isTruncated ? "+" : "") result\(result.matchCount == 1 ? "" : "s") in \(result.files.count) file\(result.files.count == 1 ? "" : "s")"
        } else {
            nil
        }
        if let text {
            HStack(spacing: 6) {
                Text(text)
                    .foregroundStyle(model.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                Spacer()
                if model.isSearching { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var results: some View {
        if let result = model.result, !result.files.isEmpty {
            List(selection: Binding(
                get: { model.selection },
                set: { id in
                    model.selection = id
                    if let id { model.open(id) }
                }
            )) {
                ForEach(result.files) { file in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !model.collapsed.contains(file.path) },
                        set: { expanded in
                            if expanded { model.collapsed.remove(file.path) } else { model.collapsed.insert(file.path) }
                        }
                    )) {
                        ForEach(file.matches) { match in
                            MatchRow(match: match)
                                .tag(match.id)
                        }
                    } label: {
                        FileRow(file: file)
                    }
                }
            }
            .listStyle(.sidebar)
        } else if model.query.isEmpty {
            EmptyStateView("Find in Project", systemImage: "magnifyingglass", message: workspace.root == nil ? "Open a folder to search it." : "Search text in all files.")
                .frame(maxHeight: 220)
            Spacer()
        } else {
            Spacer()
        }
    }
}

private struct SearchField: View {
    @Bindable var model: SearchModel
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onSubmit { model.schedule(delay: .zero) }
                .onKeyPress(.escape) {
                    model.query = ""
                    return .handled
                }
            HStack(spacing: 1) {
                OptionToggle(label: "Aa", help: "Match Case", isOn: $model.options.caseSensitive)
                OptionToggle(label: "ab", help: "Match Whole Word", underline: true, isOn: $model.options.wholeWord)
                OptionToggle(label: ".*", help: "Use Regular Expression", isOn: $model.options.regex)
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 26)
        .background(Theme.subtleFill, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))
    }
}

private struct OptionToggle: View {
    let label: String
    let help: String
    var underline = false
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .underline(underline)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 20)
                .background(isOn ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct FileRow: View {
    let file: FileMatches

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Label {
                HStack(spacing: 5) {
                    Text(name)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !folder.isEmpty {
                        Text(folder)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            } icon: {
                Image(systemName: FileIcon.systemImage(for: URL(fileURLWithPath: file.path)))
            }
            Spacer(minLength: 4)
            Text("\(file.matches.count)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.subtleFill, in: .capsule)
        }
        .help(file.path)
    }
}

private struct MatchRow: View {
    let match: SearchMatch

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(match.line + 1)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 22, alignment: .trailing)
            Text(highlighted)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var highlighted: AttributedString {
        var text = AttributedString(match.preview)
        let string = match.preview
        for range in match.ranges {
            guard let swiftRange = Range(range, in: string),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: text),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: text) else { continue }
            text[lower..<upper].backgroundColor = Color.accentColor.opacity(0.25)
            text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}
