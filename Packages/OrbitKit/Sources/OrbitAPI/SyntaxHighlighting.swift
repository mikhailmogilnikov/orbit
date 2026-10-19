import Foundation
import SwiftUI

/// A colored stretch of code.
public struct SyntaxSpan: Sendable, Hashable {
    /// UTF-16 range in the highlighted text.
    public var range: NSRange
    public var color: Color

    public init(range: NSRange, color: Color) {
        self.range = range
        self.color = color
    }
}

/// Syntax colors for code shown outside the editor (diffs, previews), in the
/// editor's theme. Implemented by the Editor plugin.
@MainActor
public protocol SyntaxHighlighting: AnyObject {
    /// Spans for `text` read as the language of `url`'s extension; empty when unknown.
    func highlight(_ text: String, as url: URL) async -> [SyntaxSpan]
    /// Spans for `text` in the language a code fence names ("swift", "bash"); empty when unknown.
    func highlight(_ text: String, language: String) async -> [SyntaxSpan]
}
