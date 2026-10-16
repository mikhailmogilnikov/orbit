import SwiftUI

/// A row in a quick pick (command palette, Open Quickly, …).
public struct QuickPickItem: Identifiable {
    public let id: String
    public let title: AttributedString
    /// Dimmed text after the title, truncated in the middle (e.g. a folder path).
    public let subtitle: String?
    public let systemImage: String?
    /// Shows this file's icon (from the icon theme) instead of `systemImage`.
    public let fileURL: URL?
    /// Right-aligned hint, e.g. a shortcut.
    public let trailing: String?
    public let run: @MainActor () -> Void

    public init(
        id: String,
        title: AttributedString,
        subtitle: String? = nil,
        systemImage: String? = nil,
        fileURL: URL? = nil,
        trailing: String? = nil,
        run: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.fileURL = fileURL
        self.trailing = trailing
        self.run = run
    }
}

/// A searchable list shown by the shell as a floating overlay. Plugins present
/// one with `UIRegistry.presentQuickPick`; `items` is called on every keystroke.
public struct QuickPick {
    public let id: String
    public let placeholder: String
    public let items: @MainActor (_ query: String) -> [QuickPickItem]
    /// The row to start on (until the user types), e.g. the current theme.
    public var initialSelection: String?
    /// Called with the row the selection moves to, for live previews.
    public var onHighlight: (@MainActor (QuickPickItem) -> Void)?
    /// Called when the pick closes without running a row (Esc, click outside).
    public var onCancel: (@MainActor () -> Void)?

    public init(
        id: String,
        placeholder: String,
        initialSelection: String? = nil,
        onHighlight: (@MainActor (QuickPickItem) -> Void)? = nil,
        onCancel: (@MainActor () -> Void)? = nil,
        items: @escaping @MainActor (_ query: String) -> [QuickPickItem]
    ) {
        self.id = id
        self.placeholder = placeholder
        self.initialSelection = initialSelection
        self.onHighlight = onHighlight
        self.onCancel = onCancel
        self.items = items
    }
}

/// Subsequence matching for pickers: "inldif" matches "InlineDiff.swift".
public enum FuzzyMatch {
    public struct Result: Sendable {
        public let score: Int
        /// Character offsets of the matched characters in the text.
        public let positions: [Int]

        public init(score: Int, positions: [Int]) {
            self.score = score
            self.positions = positions
        }
    }

    /// Consecutive and word-start hits score higher; long texts score slightly lower.
    public static func match(_ query: String, in text: String) -> Result? {
        let needle = Array(query.lowercased()).filter { $0 != " " }
        let haystack = Array(text)
        let lowered = Array(text.lowercased())
        // Lowercasing can change the character count for exotic scripts; offsets must stay valid.
        let chars = lowered.count == haystack.count ? lowered : haystack
        guard !needle.isEmpty else { return Result(score: 0, positions: []) }

        var score = 0
        var positions: [Int] = []
        positions.reserveCapacity(needle.count)
        var index = 0
        for character in needle {
            guard let found = chars[index...].firstIndex(of: character) else { return nil }
            if let previous = positions.last, previous + 1 == found { score += 5 }
            if found == 0 || isBoundary(haystack[found - 1], before: haystack[found]) { score += 3 }
            score += 1
            positions.append(found)
            index = found + 1
        }
        return Result(score: score - chars.count / 20, positions: positions)
    }

    /// Separators and camelCase humps count as word starts.
    private static func isBoundary(_ previous: Character, before current: Character) -> Bool {
        " :-_/.".contains(previous) || (previous.isLowercase && current.isUppercase)
    }

    /// `text` with the matched characters emphasized, for picker rows.
    public static func highlighted(_ text: String, positions: [Int]) -> AttributedString {
        var result = AttributedString()
        let matched = Set(positions)
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result += piece
        }
        return result
    }
}
