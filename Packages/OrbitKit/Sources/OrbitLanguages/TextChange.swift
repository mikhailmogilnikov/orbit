import Foundation
import OrbitAPI

/// The one edit that turns `old` into `new`: the differing middle between
/// their common prefix and suffix. Sent as an incremental change, so a
/// keystroke costs a few bytes instead of the whole file. O(n) in UTF-16 units.
struct TextChange: Equatable {
    var range: SourceRange
    var text: String

    init(range: SourceRange, text: String) {
        self.range = range
        self.text = text
    }

    /// Nil when the texts are equal.
    init?(from old: String, to new: String) {
        guard old != new else { return nil }
        let a = Array(old.utf16), b = Array(new.utf16)
        let shorter = min(a.count, b.count)
        var prefix = 0
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Don't split a surrogate pair: servers would see half a character.
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }

        let oldEnd = a.count - suffix
        let start = Self.position(of: prefix, in: a)
        let end = Self.position(of: oldEnd, in: a, from: start, at: prefix)
        let inserted = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        self.init(range: SourceRange(start: start, end: end), text: inserted)
    }

    private static func position(of offset: Int, in units: [UTF16.CodeUnit], from base: SourcePosition = SourcePosition(line: 0, character: 0), at baseOffset: Int = 0) -> SourcePosition {
        var line = base.line
        var lineStart = baseOffset - base.character
        var index = baseOffset
        while index < offset {
            if units[index] == 0x0A {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        return SourcePosition(line: line, character: offset - lineStart)
    }
}
