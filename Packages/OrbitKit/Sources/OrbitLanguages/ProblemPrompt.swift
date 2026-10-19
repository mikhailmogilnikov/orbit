import Foundation
import OrbitAPI

/// Problems written up for an agent (D147): where, what the tool said, and
/// the code around it, so it can start fixing without looking first.
enum ProblemPrompt {
    static let context = 3
    static let limit = 30

    static func text(for files: [FileProblems], root: URL?, text: (URL) -> String?) -> String {
        let all = files.flatMap { file in file.diagnostics.map { (file.url, $0) } }
        var parts = [all.count == 1 ? "Fix this problem:" : "Fix these \(all.count) problems:"]
        for file in files {
            let lines = text(file.url).map(LineDiff.lines) ?? []
            let path = root.map { file.url.path.replacingOccurrences(of: $0.path + "/", with: "") } ?? file.url.path
            for problem in file.diagnostics.prefix(limit) {
                let line = problem.range.start.line
                let severity = problem.severity == .error ? "error" : problem.severity == .warning ? "warning" : "note"
                var part = "`\(path):\(line + 1):\(problem.range.start.character + 1)` \(severity)"
                    + (problem.source.map { " (\($0))" } ?? "") + ": \(problem.message)"
                if !lines.isEmpty, line < lines.count {
                    let range = max(0, line - context)...min(lines.count - 1, line + context)
                    let code = range.map { "\($0 + 1)\($0 == line ? ">" : " ") \(lines[$0])" }.joined(separator: "\n")
                    part += "\n```\n\(code)\n```"
                }
                parts.append(part)
            }
        }
        if all.count > limit * files.count { parts.append("(More problems not listed; fix these first.)") }
        return parts.joined(separator: "\n\n")
    }
}
