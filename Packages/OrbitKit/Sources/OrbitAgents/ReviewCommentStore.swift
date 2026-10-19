import Foundation
import OrbitAPI

/// `ReviewComments`: notes written in the editor wait here until they're
/// sent to a chat together (D125).
@MainActor
@Observable
final class ReviewCommentStore: ReviewComments {
    private(set) var comments: [ReviewComment] = [] {
        didSet { if !isLoading { onChange() } }
    }
    /// Saves them (per project folder, D131).
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var isLoading = false

    /// Another folder's notes, without saving them back.
    func load(_ comments: [ReviewComment]) {
        isLoading = true
        self.comments = comments
        isLoading = false
    }

    func save(_ comment: ReviewComment) {
        var comment = comment
        comment.text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.text.isEmpty else { return remove(comment.id) }
        if let index = comments.firstIndex(where: { $0.id == comment.id }) {
            comments[index] = comment
        } else {
            comments.append(comment)
        }
    }

    func remove(_ id: ReviewComment.ID) {
        comments.removeAll { $0.id == id }
    }

    func removeAll() { comments.removeAll() }
}

/// The message review notes become: each note under the code it's about.
enum ReviewCommentPrompt {
    static func text(for comments: [ReviewComment], root: URL?, fileText: (URL) -> String?) -> String {
        let ordered = comments.sorted { ($0.url.path, $0.lines.lowerBound) < ($1.url.path, $1.lines.lowerBound) }
        var parts = [ordered.count == 1
            ? "Review comment on the code. Please address it:"
            : "Review comments on the code. Please address each one:"]
        for (index, comment) in ordered.enumerated() {
            let path = relativePath(comment.url, root: root)
            let fileLines = fileText(comment.url).map(LineDiff.lines)
            let lines = fileLines.map { comment.located(in: $0) } ?? comment.lines
            let language = comment.url.pathExtension.lowercased()
            var part = "\(index + 1). "
            let code = fileLines.map { Array($0[lines]).joined(separator: "\n") } ?? comment.code
            let place = lines.count == 1 ? "line \(lines.lowerBound + 1)" : "lines \(lines.lowerBound + 1)–\(lines.upperBound + 1)"
            part += "`\(path)` \(place):\n" + fenced(code, language: language)
            if !comment.removed.isEmpty {
                part += "\nLines removed here:\n" + fenced(comment.removed, language: language)
            }
            part += "\n" + comment.text
            parts.append(part)
        }
        return parts.joined(separator: "\n\n")
    }

    static func relativePath(_ url: URL, root: URL?) -> String {
        let path = url.standardizedFileURL.path
        guard let root = root?.standardizedFileURL.path, path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    /// A fence longer than any backtick run inside the code.
    private static func fenced(_ code: String, language: String) -> String {
        var longest = 0, run = 0
        for character in code {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(code)\n\(fence)"
    }
}
