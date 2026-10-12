import OrbitAPI
import OrbitUI
import SwiftUI

@MainActor
@Observable
final class SearchModel {
    private let workspace: Workspace
    private let files: ProjectFiles

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            replaceFailure = nil
            schedule()
        }
    }
    var options = SearchOptions() { didSet { if options != oldValue { schedule(delay: .zero) } } }
    /// Comma-separated globs, see `PathFilter`. Applied even while the fields are hidden.
    var include = "" { didSet { if include != oldValue { schedule() } } }
    var exclude = "" { didSet { if exclude != oldValue { schedule() } } }
    var areFiltersVisible = false
    var replacement = "" { didSet { if replacement != oldValue, isReplaceVisible { schedule() } } }
    /// Results preview their replacements only while the replace field is shown.
    var isReplaceVisible = false { didSet { if isReplaceVisible != oldValue { schedule(delay: .zero) } } }
    private(set) var result: SearchResult?
    private(set) var error: String?
    private(set) var isSearching = false
    /// Files the last replace couldn't write.
    private(set) var replaceFailure: String?
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
        let include = include, exclude = exclude
        let replacement = isReplaceVisible ? replacement : nil
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
                let pathFilter = PathFilter(include: include, exclude: exclude)
                let searched = pathFilter.isEmpty ? paths : paths.filter(pathFilter.allows)
                do throws(TextSearch.Failure) {
                    return Result<SearchResult, TextSearch.Failure>.success(
                        try await TextSearch.run(query, options: options, root: root, paths: searched, overrides: overrides, replacement: replacement)
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

    var hasFilters: Bool { !include.trimmingCharacters(in: .whitespaces).isEmpty || !exclude.trimmingCharacters(in: .whitespaces).isEmpty }

    var canReplace: Bool { isReplaceVisible && !isSearching && error == nil && !(result?.files.isEmpty ?? true) }

    /// Replaces every match in the given result files (all of them when nil).
    /// Files with unsaved edits are changed in their buffer and left unsaved,
    /// like any other edit; the rest are written to disk.
    func replace(in paths: [String]? = nil) {
        guard canReplace, let result, let root = files.root,
              let regex = try? TextSearch.makeRegex(query, options: options) else { return }
        let template = TextSearch.template(for: replacement, options: options)
        replaceFailure = nil
        var failed: [String] = []
        for path in paths ?? result.files.map(\.path) {
            let url = root.appendingPathComponent(path)
            let document = workspace.documents.existingDocument(for: url)
            guard let text = document?.text ?? TextSearch.readText(url) else { continue }
            let (replaced, count) = TextSearch.replace(in: text, regex: regex, template: template)
            guard count > 0 else { continue }
            if let document, document.isDirty {
                document.text = replaced
            } else {
                do { try workspace.documents.write(replaced, to: url) } catch { failed.append(path) }
            }
        }
        workspace.fileSystemDidChange()
        schedule(delay: .zero)
        if !failed.isEmpty {
            replaceFailure = failed.count == 1 ? "Couldn't write \(failed[0])" : "Couldn't write \(failed.count) files"
        }
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
    @FocusState private var focusedField: SearchFieldKind?
    @State private var handledFocusRequest = 0
    @State private var isConfirmingReplaceAll = false

    var body: some View {
        VStack(spacing: 0) {
            fields
                .padding(.leading, 4)
                .padding(.trailing, 10)
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
        .alert(replaceAllTitle, isPresented: $isConfirmingReplaceAll) {
            Button("Replace", role: .destructive) { model.replace() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files with unsaved changes are edited in the editor; other files are saved to disk.")
        }
    }

    private var replaceAllTitle: String {
        guard let result = model.result else { return "" }
        let files = result.files.count == 1 ? "1 file" : "\(result.files.count) files"
        let matches = result.isTruncated ? "all matches" : result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches"
        let with = model.replacement.isEmpty ? "nothing" : "“\(model.replacement)”"
        return "Replace \(matches) in \(files) with \(with)?"
    }

    private func focusIfRequested() {
        guard model.focusRequest != handledFocusRequest else { return }
        handledFocusRequest = model.focusRequest
        // The panel may have just been revealed; focus once it's in the window.
        DispatchQueue.main.async { focusedField = .search }
    }

    private var fields: some View {
        HStack(alignment: .top, spacing: 2) {
            Button {
                model.isReplaceVisible.toggle()
                if model.isReplaceVisible { focusedField = .replace }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(model.isReplaceVisible ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(model.isReplaceVisible ? "Hide Replace" : "Show Replace")

            VStack(spacing: 5) {
                SearchField(systemImage: "magnifyingglass", placeholder: "Search", text: $model.query, kind: .search, focus: $focusedField) {
                    OptionToggle(label: "Aa", help: "Match Case", isOn: $model.options.caseSensitive)
                    OptionToggle(label: "ab", help: "Match Whole Word", underline: true, isOn: $model.options.wholeWord)
                    OptionToggle(label: ".*", help: "Use Regular Expression", isOn: $model.options.regex)
                    OptionToggle(
                        systemImage: "line.3.horizontal.decrease",
                        help: model.areFiltersVisible ? "Hide Files to Include and Exclude" : "Files to Include and Exclude",
                        isOn: $model.areFiltersVisible,
                        isActive: model.hasFilters
                    )
                }
                .onSubmit { model.schedule(delay: .zero) }
                .onKeyPress(.escape) {
                    model.query = ""
                    return .handled
                }

                if model.isReplaceVisible {
                    SearchField(systemImage: "arrow.2.squarepath", placeholder: "Replace", text: $model.replacement, kind: .replace, focus: $focusedField) {
                        Button { isConfirmingReplaceAll = true } label: {
                            Image(systemName: "text.badge.checkmark")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 22, height: 20)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.canReplace ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .disabled(!model.canReplace)
                        .help("Replace All")
                    }
                    .onSubmit { if model.canReplace { isConfirmingReplaceAll = true } }
                }

                if model.areFiltersVisible {
                    SearchField(systemImage: "folder.badge.plus", placeholder: "Files to include, e.g. *.swift, Sources", text: $model.include, kind: .include, focus: $focusedField) {}
                    SearchField(systemImage: "folder.badge.minus", placeholder: "Files to exclude", text: $model.exclude, kind: .exclude, focus: $focusedField) {}
                }
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let failure = model.error ?? model.replaceFailure
        let text: String? = if let failure {
            failure
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
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
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
                        FileRow(file: file, onReplace: model.canReplace ? { model.replace(in: [file.path]) } : nil)
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

private enum SearchFieldKind: Hashable {
    case search, replace, include, exclude
}

private struct SearchField<Accessories: View>: View {
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    let kind: SearchFieldKind
    var focus: FocusState<SearchFieldKind?>.Binding
    @ViewBuilder var accessories: Accessories

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused(focus, equals: kind)
            HStack(spacing: 1) { accessories }
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
    var label: String?
    var systemImage: String?
    let help: String
    var underline = false
    @Binding var isOn: Bool
    /// Tinted even when off, e.g. filters that still apply while hidden.
    var isActive = false

    init(label: String, help: String, underline: Bool = false, isOn: Binding<Bool>) {
        self.label = label
        self.help = help
        self.underline = underline
        _isOn = isOn
    }

    init(systemImage: String, help: String, isOn: Binding<Bool>, isActive: Bool) {
        self.systemImage = systemImage
        self.help = help
        _isOn = isOn
        self.isActive = isActive
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Text(label ?? "")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .underline(underline)
                }
            }
            .foregroundStyle(isOn || isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
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
    /// Set while replacing: offers "Replace in This File" on hover.
    let onReplace: (() -> Void)?
    @State private var isHovered = false

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
                FileIconView(url: URL(fileURLWithPath: file.path))
            }
            Spacer(minLength: 4)
            if let onReplace, isHovered {
                Button(action: onReplace) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .help("Replace in This File")
            } else {
                Text("\(file.matches.count)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.subtleFill, in: .capsule)
            }
        }
        .onHover { isHovered = $0 }
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

    /// Matches are highlighted; while replacing, each is struck out and followed by its replacement.
    private var highlighted: AttributedString {
        let string = match.preview as NSString
        var text = AttributedString()
        var last = 0
        for (index, range) in match.ranges.enumerated() {
            text += AttributedString(string.substring(with: NSRange(location: last, length: range.location - last)))
            var found = AttributedString(string.substring(with: range))
            found.inlinePresentationIntent = .stronglyEmphasized
            if let replacements = match.replacements, index < replacements.count {
                let replacement = replacements[index]
                found.backgroundColor = Theme.removedGutter
                found.strikethroughStyle = Text.LineStyle(pattern: .solid)
                text += found
                var inserted = AttributedString(replacement.replacingOccurrences(of: "\n", with: "↵"))
                inserted.backgroundColor = Theme.addedGutter
                inserted.inlinePresentationIntent = .stronglyEmphasized
                text += inserted
            } else {
                found.backgroundColor = Color.accentColor.opacity(0.25)
                text += found
            }
            last = NSMaxRange(range)
        }
        text += AttributedString(string.substring(from: last))
        return text
    }
}
