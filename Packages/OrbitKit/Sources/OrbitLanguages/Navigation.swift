import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

// Find References, Go to Symbol in File / in Project (D62).

/// The last Find References: every use of a symbol, by file, with its line.
@MainActor
@Observable
final class ReferencesModel {
    struct Reference: Identifiable {
        let id: Int
        let location: SourceLocation
        /// The line, leading whitespace trimmed.
        let preview: String
        /// The symbol inside `preview` (UTF-16).
        let match: NSRange
    }

    struct File: Identifiable {
        let url: URL
        let references: [Reference]
        var id: URL { url }
    }

    private(set) var symbol: String?
    private(set) var files: [File] = []
    private(set) var isSearching = false
    /// The row opened last, to keep it marked.
    var opened: Int?
    @ObservationIgnored private var search: Task<Void, Never>?

    var count: Int { files.reduce(0) { $0 + $1.references.count } }

    func find(at caret: SourceLocation, languages: LanguageIntelligence, workspace: Workspace) {
        search?.cancel()
        isSearching = true
        opened = nil
        search = Task {
            let found = await Self.load(at: caret, languages: languages, workspace: workspace)
            guard !Task.isCancelled else { return }
            symbol = found.symbol
            files = found.files
            isSearching = false
        }
    }

    /// The uses of the symbol at `caret` with their lines: the caret's file
    /// first, then by path. Open files as edited, others from disk.
    static func load(at caret: SourceLocation, languages: LanguageIntelligence, workspace: Workspace) async -> (symbol: String?, files: [File]) {
        let locations = await languages.references(at: caret.range.start, in: caret.url)
        let urls = Set(locations.map(\.url))
        var texts: [URL: String] = [:]
        for url in urls {
            if let document = workspace.documents.existingDocument(for: url) { texts[url] = document.text }
        }
        let unread = urls.filter { texts[$0] == nil }
        let read = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: unread.compactMap { url in (try? TextFile.read(url).text).map { (url, $0) } })
        }.value
        texts.merge(read) { current, _ in current }

        let start = caret.url.standardizedFileURL
        var files = files(locations, texts: texts)
        files.sort { ($0.url.standardizedFileURL == start ? 0 : 1, $0.url.path) < ($1.url.standardizedFileURL == start ? 0 : 1, $1.url.path) }
        let atCaret = locations.first { $0.url.standardizedFileURL == start && $0.range.contains(caret.range.start) } ?? locations.first
        let symbol = atCaret.flatMap { location in texts[location.url].map { text(in: location.range, of: $0) } }
        return (symbol, files)
    }

    private static func files(_ locations: [SourceLocation], texts: [URL: String]) -> [File] {
        var id = 0
        return Dictionary(grouping: locations, by: \.url).map { url, locations in
            let string = texts[url].map { $0 as NSString }
            let starts = string.map { SourcePosition.lineStarts(of: $0) } ?? []
            let references = Set(locations).sorted { $0.range.start < $1.range.start }.map { location in
                id += 1
                guard let string else { return Reference(id: id, location: location, preview: "", match: NSRange()) }
                let line = location.range.start.line
                let lineStart = line < starts.count ? starts[line] : string.length
                let lineEnd = line + 1 < starts.count ? starts[line + 1] : string.length
                var lineText = string.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart)) as NSString
                let indent = lineText.length - ((lineText as String).drop { $0 == " " || $0 == "\t" } as Substring).utf16.count
                lineText = lineText.substring(from: indent).trimmingCharacters(in: .newlines) as NSString
                let range = location.range.nsRange(in: starts, length: string.length)
                let match = NSIntersectionRange(
                    NSRange(location: range.location - lineStart - indent, length: range.length),
                    NSRange(location: 0, length: lineText.length)
                )
                return Reference(id: id, location: location, preview: lineText as String, match: match)
            }
            return File(url: url, references: references)
        }
    }

    private static func text(in range: SourceRange, of text: String) -> String {
        let string = text as NSString
        return string.substring(with: range.nsRange(in: SourcePosition.lineStarts(of: string), length: string.length))
    }
}

/// The References bottom panel: uses of the symbol, by file; a click opens the spot.
struct ReferencesPanel: View {
    let model: ReferencesModel
    let workspace: Workspace

    var body: some View {
        if model.files.isEmpty {
            if model.isSearching {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.symbol == nil {
                EmptyStateView("No References", systemImage: "arrow.triangle.branch",
                               message: "Put the caret on a symbol and choose Code ▸ Find References (⇧⌃⌘F).")
            } else {
                EmptyStateView("No References", systemImage: "arrow.triangle.branch", message: "The language server found no uses of it. If it's still indexing the project, try again in a moment.")
            }
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                List {
                    ForEach(model.files) { file in
                        Section {
                            ForEach(file.references) { reference in
                                ReferenceRow(reference: reference, isOpened: model.opened == reference.id) {
                                    model.opened = reference.id
                                    workspace.open(reference.location)
                                }
                            }
                        } header: {
                            ReferenceFileHeader(url: file.url, count: file.references.count, workspace: workspace)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .opacity(model.isSearching ? 0.5 : 1)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            let count = model.count, files = model.files.count
            Text("\(count) \(count == 1 ? "reference" : "references") to")
                .foregroundStyle(.secondary)
            Text(model.symbol ?? "symbol")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            Text("in \(files) \(files == 1 ? "file" : "files")")
                .foregroundStyle(.secondary)
            Spacer()
            if model.isSearching { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct ReferenceFileHeader: View {
    let url: URL
    let count: Int
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 6) {
            FileIconView(url: url, size: 13)
            Text(url.lastPathComponent)
                .fontWeight(.medium)
            Text(workspace.relativePath(url.deletingLastPathComponent()))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.subtleFill, in: .capsule)
        }
        .font(.system(size: 11.5))
    }
}

private struct ReferenceRow: View {
    let reference: ReferencesModel.Reference
    let isOpened: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(reference.location.range.start.line + 1)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 26, alignment: .trailing)
                Text(highlighted)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(isOpened ? Theme.accent.opacity(0.12) : Color.clear)
    }

    private var highlighted: AttributedString {
        let string = reference.preview as NSString
        let match = reference.match
        guard match.length > 0, NSMaxRange(match) <= string.length else { return AttributedString(reference.preview) }
        var text = AttributedString(string.substring(to: match.location))
        var found = AttributedString(string.substring(with: match))
        found.inlinePresentationIntent = .stronglyEmphasized
        found.backgroundColor = Theme.accent.opacity(0.25)
        text += found
        text += AttributedString(string.substring(from: NSMaxRange(match)))
        return text
    }
}

// MARK: Go to Symbol

@MainActor
enum SymbolPicks {
    /// ⌥⇧⌘R: the uses of the symbol as a list to jump through, without leaving
    /// the editor for the References panel; the use at the caret is selected.
    static func peekReferences(_ caret: SourceLocation, languages: LanguageIntelligence, workspace: Workspace, ui: UIRegistry) {
        Task {
            let (symbol, files) = await ReferencesModel.load(at: caret, languages: languages, workspace: workspace)
            let references = files.flatMap(\.references)
            guard !references.isEmpty else {
                NSSound.beep()
                return
            }
            let current = references.first { $0.location.url.standardizedFileURL == caret.url.standardizedFileURL && $0.location.range.contains(caret.range.start) }
            let name = symbol.map { "“\($0)”" } ?? "the symbol"
            ui.presentQuickPick(QuickPick(
                id: "languages.peekReferences",
                placeholder: "\(references.count) reference\(references.count == 1 ? "" : "s") to \(name)",
                initialSelection: current.map { String($0.id) }
            ) { query in
                references
                    .filter { query.isEmpty || $0.preview.localizedCaseInsensitiveContains(query) || workspace.relativePath($0.location.url).localizedCaseInsensitiveContains(query) }
                    .map { reference in
                        var title = AttributedString(reference.preview)
                        if let range = Range(reference.match, in: reference.preview),
                           let lower = AttributedString.Index(range.lowerBound, within: title),
                           let upper = AttributedString.Index(range.upperBound, within: title) {
                            title[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                        }
                        return QuickPickItem(
                            id: String(reference.id),
                            title: title,
                            subtitle: workspace.relativePath(reference.location.url),
                            fileURL: reference.location.url,
                            trailing: String(reference.location.range.start.line + 1)
                        ) {
                            workspace.open(reference.location)
                        }
                    }
            })
        }
    }

    /// ⇧⌘O: the active file's outline, in order (nested ones indented); typing filters it.
    static func fileSymbols(_ caret: SourceLocation, languages: LanguageIntelligence, workspace: Workspace, ui: UIRegistry) {
        let url = caret.url
        Task {
            guard let symbols = await languages.symbols(in: url) else {
                NSSound.beep()
                return
            }
            // Start on the symbol the caret is in.
            let current = symbols.indices.last { symbols[$0].location.range.start <= caret.range.start }
            ui.presentQuickPick(QuickPick(
                id: "languages.fileSymbols",
                placeholder: symbols.isEmpty ? "No symbols in \(url.lastPathComponent)" : "Go to symbol in \(url.lastPathComponent)",
                initialSelection: current.map(String.init)
            ) { query in
                let indexed = Array(symbols.enumerated())
                guard !query.isEmpty else {
                    return indexed.map { item($0.element, id: $0.offset, positions: [], indent: true, workspace: workspace) }
                }
                return indexed
                    .compactMap { index, symbol in FuzzyMatch.match(query, in: symbol.name).map { (index, symbol, $0) } }
                    .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
                    .map { item($0.1, id: $0.0, positions: $0.2.positions, indent: false, workspace: workspace) }
            })
        }
    }

    /// ⌘T: symbols across the project from every running server, asked as you type.
    static func projectSymbols(languages: LanguageIntelligence, workspace: Workspace, ui: UIRegistry) {
        let search = ProjectSymbolSearch(languages: languages)
        ui.presentQuickPick(QuickPick(id: "languages.projectSymbols", placeholder: "Go to symbol in project", onCancel: { search.cancel() }) { query in
            search.query(query)
            return search.results
                .compactMap { symbol in FuzzyMatch.match(query, in: symbol.name).map { (symbol, $0) } }
                .sorted { $0.1.score != $1.1.score ? $0.1.score > $1.1.score : $0.0.name.count < $1.0.name.count }
                .enumerated()
                .map { index, match in item(match.0, id: index, positions: match.1.positions, indent: false, showsFile: true, workspace: workspace) }
        })
    }

    private static func item(
        _ symbol: LanguageSymbol, id: Int, positions: [Int], indent: Bool, showsFile: Bool = false, workspace: Workspace
    ) -> QuickPickItem {
        var title = AttributedString(indent ? String(repeating: "    ", count: symbol.depth) : "")
        title += FuzzyMatch.highlighted(symbol.name, positions: positions)
        if let container = symbol.container, !indent {
            var dimmed = AttributedString("  \(container)")
            dimmed.foregroundColor = .secondary
            title += dimmed
        }
        let line = symbol.location.range.start.line + 1
        return QuickPickItem(
            id: String(id),
            title: title,
            subtitle: showsFile ? workspace.relativePath(symbol.location.url) : nil,
            systemImage: symbol.kind.systemImage,
            trailing: showsFile ? nil : String(line)
        ) {
            workspace.open(symbol.location)
        }
    }
}

/// The project search behind ⌘T: a request per pause in typing; the pick
/// re-reads `results` when they arrive.
@MainActor
@Observable
private final class ProjectSymbolSearch {
    private(set) var results: [LanguageSymbol] = []
    @ObservationIgnored private let languages: LanguageIntelligence
    @ObservationIgnored private var asked: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(languages: LanguageIntelligence) {
        self.languages = languages
    }

    /// Called from the pick's `items`, so it must not change `results` right away.
    func query(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard query != asked else { return }
        asked = query
        task?.cancel()
        task = Task { [weak self, languages] in
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 120))
            guard !Task.isCancelled else { return }
            // Servers answer an empty query with nothing or everything; neither helps.
            let found = query.isEmpty ? [] : await languages.projectSymbols(matching: query)
            guard !Task.isCancelled, let self else { return }
            results = found
        }
    }

    func cancel() { task?.cancel() }
}
