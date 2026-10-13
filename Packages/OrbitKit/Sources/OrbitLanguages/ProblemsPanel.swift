import OrbitAPI
import OrbitUI
import SwiftUI

/// Every error and warning the language servers report for open files,
/// by file; a click opens the spot (D59).
struct ProblemsPanel: View {
    let manager: LanguageManager
    let workspace: Workspace

    var body: some View {
        let problems = manager.problems
        if problems.isEmpty {
            EmptyStateView("No Problems", systemImage: "checkmark.circle", message: "Errors and warnings in open files show up here.")
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
                        .font(.system(size: 11.5))
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
                    .font(.system(size: 11))
                Text(problem.message)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let source = problem.source {
                    Text(source)
                        .foregroundStyle(.tertiary)
                }
                Text("\(problem.range.start.line + 1):\(problem.range.start.character + 1)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 12))
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
