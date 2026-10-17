import OrbitAPI
import OrbitUI
import SwiftUI

/// Every error and warning the language servers report, by file: open
/// files and the ones the agent changed (D75); a click opens the spot (D59).
struct ProblemsPanel: View {
    let manager: LanguageManager
    let workspace: Workspace

    var body: some View {
        let problems = manager.problems
        if problems.isEmpty {
            EmptyStateView("No Problems", systemImage: "checkmark.circle", message: "Errors and warnings in open files and files the agent changed show up here.")
        } else {
            List {
                ForEach(problems) { file in
                    Section {
                        ForEach(Array(file.diagnostics.enumerated()), id: \.offset) { _, problem in
                            ProblemRow(problem: problem) {
                                workspace.openFile(file.url, line: problem.range.start.line)
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            FileIconView(url: file.url, size: 13)
                            Text(file.url.lastPathComponent)
                                .fontWeight(.medium)
                            Text(workspace.relativePath(file.url.deletingLastPathComponent()))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text("\(file.diagnostics.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.orbit(.caption))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct ProblemRow: View {
    let problem: Diagnostic
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .font(.orbit(.caption))
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
            }
            .font(.orbit(.body))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
        case .warning: .orange
        case .information, .hint: .blue
        }
    }
}
