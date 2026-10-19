import Foundation

/// A note on a few lines of code for the agent, written while reviewing its
/// changes; notes go to the chat together, as one message (D125).
public struct ReviewComment: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var url: URL
    /// 0-based lines it's about, as they were when it was written.
    public var lines: ClosedRange<Int>
    /// Those lines' text then: finds them again after edits above them and
    /// shows the agent what the note is about.
    public var code: String
    /// Lines the agent removed there, for a note on a deletion.
    public var removed: String
    public var text: String

    public init(id: UUID = UUID(), url: URL, lines: ClosedRange<Int>, code: String, removed: String = "", text: String = "") {
        self.id = id
        self.url = url.standardizedFileURL
        self.lines = lines
        self.code = code
        self.removed = removed
        self.text = text
    }

    /// The lines it's about in `fileLines` now: the written code nearest its
    /// old place, or the old place when the code is gone (clamped to the file).
    public func located(in fileLines: [String]) -> ClosedRange<Int> {
        let last = max(0, fileLines.count - 1)
        let fallback = min(lines.lowerBound, last)...min(lines.upperBound, last)
        let wanted = LineDiff.lines(code)
        guard !code.isEmpty, wanted.count <= fileLines.count else { return fallback }
        if fileLines.indices.contains(lines.lowerBound), lines.lowerBound + wanted.count <= fileLines.count,
           Array(fileLines[lines.lowerBound..<lines.lowerBound + wanted.count]) == wanted {
            return lines.lowerBound...(lines.lowerBound + wanted.count - 1)
        }
        var best: Int?
        for start in 0...(fileLines.count - wanted.count) where fileLines[start] == wanted[0] {
            guard Array(fileLines[start..<start + wanted.count]) == wanted else { continue }
            if best.map({ abs($0 - lines.lowerBound) > abs(start - lines.lowerBound) }) ?? true { best = start }
        }
        guard let best else { return fallback }
        return best...(best + wanted.count - 1)
    }
}

/// Review notes of the window's chats, implemented by the Agents plugin;
/// the editor adds them on agent changes and shows them in place.
@MainActor
public protocol ReviewComments: AnyObject {
    /// Not sent yet, in the order they were written.
    var comments: [ReviewComment] { get }
    /// Adds or replaces (same id); empty text removes it.
    func save(_ comment: ReviewComment)
    func remove(_ id: ReviewComment.ID)
}
