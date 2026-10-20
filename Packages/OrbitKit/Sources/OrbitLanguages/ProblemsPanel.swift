import OrbitAPI
import OrbitUI
import SwiftUI

/// Every error and warning the language servers report, by file: open
/// files and the ones the agent changed (D75); a click opens the spot (D59).
struct ProblemsPanel: View {
    let manager: LanguageManager
    let workspace: Workspace
    /// Hands problems to a new chat (D147); nil without the Agents plugin.
    var fix: (([FileProblems]) -> Void)?
    @State private var collapsed: Set<URL> = []

    var body: some View {
        let problems = manager.problems
        if problems.isEmpty {
            PanelEmptyState("No Problems", message: "Errors and warnings from open files, agent changes and tasks show up here.")
        } else {
            List {
                ForEach(problems) { file in
                    Section(isExpanded: FileGroupHeader.expansion(of: file.url, in: $collapsed)) {
                        ForEach(Array(file.diagnostics.enumerated()), id: \.offset) { _, problem in
                            ProblemRow(problem: problem, fix: fix.map { fix in { fix([FileProblems(url: file.url, diagnostics: [problem])]) } }) {
                                workspace.openFile(file.url, line: problem.range.start.line)
                            }
                            // Under the file's icon, without lines between, like Xcode's issues.
                            .padding(.leading, FileGroupHeader.rowIndent)
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                if let fix {
                                    Button("Fix with Agent") { fix([FileProblems(url: file.url, diagnostics: [problem])]) }
                                    Button("Fix All in “\(file.url.lastPathComponent)” with Agent") { fix([file]) }
                                    Button("Fix All Errors with Agent") { fix(problems.compactMap(Self.errorsOnly)) }
                                    Divider()
                                }
                                Button("Copy Message") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(problem.message, forType: .string)
                                }
                            }
                        }
                    } header: {
                        FileGroupHeader(url: file.url, count: file.diagnostics.count, tint: Self.tint(for: file),
                                        workspace: workspace, collapsed: $collapsed)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

extension ProblemsPanel {
    /// The file's count takes the color of its worst problem.
    static func tint(for file: FileProblems) -> Color {
        let severities = file.diagnostics.map(\.severity)
        if severities.contains(.error) { return .red }
        return severities.contains(.warning) ? .yellow : .blue
    }

    static func errorsOnly(_ file: FileProblems) -> FileProblems? {
        let errors = file.diagnostics.filter { $0.severity == .error }
        return errors.isEmpty ? nil : FileProblems(url: file.url, diagnostics: errors)
    }
}

private struct ProblemRow: View {
    let problem: Diagnostic
    let fix: (() -> Void)?
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .orbitFont(.caption)
                // Servers put the cause after a blank line ("Error in svelte.config.js\n\n…");
                // without collapsing it the two visible lines show only the headline.
                Text(problem.message.split(whereSeparator: \.isNewline).joined(separator: "\n"))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(problem.message)
                if let source = problem.source {
                    Text(source)
                        .foregroundStyle(.tertiary)
                }
                Text("\(problem.range.start.line + 1):\(problem.range.start.character + 1)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let fix {
                    Button(action: fix) {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.borderless)
                    .help("Fix with Agent")
                    .opacity(isHovered ? 1 : 0)
                }
            }
            .orbitFont(.body)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var symbol: String {
        switch problem.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information, .hint: "info.circle.fill"
        }
    }

    private var color: Color {
        switch problem.severity {
        case .error: .red
        case .warning: .yellow
        case .information, .hint: .blue
        }
    }
}

/// A file's header in Problems and References, like a file in Xcode's issue
/// navigator: chevron, icon, name, folder, and a count badge (D172). A click
/// anywhere on it folds the file's rows.
struct FileGroupHeader: View {
    /// Rows start under the file's icon: past the chevron and its gap.
    static let rowIndent: CGFloat = 16

    let url: URL
    let count: Int
    var tint: Color?
    let workspace: Workspace
    @Binding var collapsed: Set<URL>

    var body: some View {
        let isExpanded = !collapsed.contains(url)
        HStack(spacing: 6) {
            DisclosureChevron(isExpanded: isExpanded)
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            FileIconView(url: url, size: 13)
            Text(url.lastPathComponent)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            Text(workspace.relativePath(url.deletingLastPathComponent()))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Badge(count: count, tint: tint)
            Spacer(minLength: 0)
        }
        .orbitFont(.caption)
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(.snappy(duration: 0.2)) { Self.expansion(of: url, in: $collapsed).wrappedValue.toggle() }
        }
    }

    static func expansion(of url: URL, in collapsed: Binding<Set<URL>>) -> Binding<Bool> {
        Binding {
            !collapsed.wrappedValue.contains(url)
        } set: { isExpanded in
            if isExpanded { collapsed.wrappedValue.remove(url) } else { collapsed.wrappedValue.insert(url) }
        }
    }
}
