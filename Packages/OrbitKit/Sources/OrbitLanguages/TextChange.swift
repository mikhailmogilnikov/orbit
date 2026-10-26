import Foundation
import OrbitAPI

/// The one edit that turns `old` into `new`: the differing middle between
/// their common prefix and suffix. Sent as an incremental change, so a
/// keystroke costs a few bytes instead of the whole file. Compared byte by
/// byte in UTF-8: copying both texts to UTF-16 arrays took a tenth of each
/// keystroke in a long file.
struct TextChange: Equatable {
    var range: SourceRange
    var text: String

    init(range: SourceRange, text: String) {
        self.range = range
        self.text = text
    }

    /// Nil when the texts are equal.
    init?(from old: String, to new: String) {
        var old = old, new = new
        let found: TextChange? = old.withUTF8 { a in
            new.withUTF8 { b in
                guard a.count != b.count || (a.count > 0 && memcmp(a.baseAddress!, b.baseAddress!, a.count) != 0) else { return nil }
                func continues(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }
                let shorter = min(a.count, b.count)
                var prefix = 0
                while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
                // Whole characters only: servers would see half of one.
                while prefix > 0, (prefix < a.count && continues(a[prefix])) || (prefix < b.count && continues(b[prefix])) { prefix -= 1 }
                var suffix = 0
                while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
                while suffix > 0, continues(a[a.count - suffix]) { suffix -= 1 }
                let start = Self.position(of: prefix, in: a)
                let end = Self.position(of: a.count - suffix, in: a, from: start, at: prefix)
                return TextChange(range: SourceRange(start: start, end: end), text: String(decoding: b[prefix..<(b.count - suffix)], as: UTF8.self))
            }
        }
        guard let found else { return nil }
        self = found
    }

    /// A UTF-8 offset as a line and a UTF-16 column, what servers count in.
    private static func position(of offset: Int, in bytes: UnsafeBufferPointer<UInt8>, from base: SourcePosition = SourcePosition(line: 0, character: 0), at baseOffset: Int = 0) -> SourcePosition {
        var line = base.line, character = base.character
        for index in baseOffset..<offset {
            let byte = bytes[index]
            if byte == 0x0A {
                line += 1
                character = 0
            } else if byte & 0xC0 != 0x80 {
                // A four-byte character is a surrogate pair in UTF-16.
                character += byte >= 0xF0 ? 2 : 1
            }
        }
        return SourcePosition(line: line, character: character)
    }
}
