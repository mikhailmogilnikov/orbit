import Foundation

/// Changes one value of a settings file in its text (D183), so the rest keeps
/// its order, spacing and indentation; JSONSerialization would rewrite it all.
public enum JSONTextEdit {
    /// Sets `key` — "name" or "section.name", also when the file spells it
    /// "section.name" at the top — to `literal` (JSON text), or removes it when
    /// nil. Nil when the text isn't a JSON object.
    public static func set(_ key: String, to literal: String?, in text: String) -> String? {
        var bytes = Array(text.utf8)
        if bytes.allSatisfy(isSpace) {
            guard literal != nil else { return text }
            bytes = Array("{\n}\n".utf8)
        }
        var scanner = Scanner(bytes: bytes)
        guard let root = scanner.document() else { return nil }
        let path = key.split(separator: ".", maxSplits: 1).map(String.init)

        if let member = root.member(key) {
            return result(edit(bytes, object: root, member: member, literal: literal))
        }
        if path.count == 2, let section = root.member(path[0]), let object = section.value.object {
            if let member = object.member(path[1]) {
                return result(edit(bytes, object: object, member: member, literal: literal))
            }
            guard let literal else { return text }
            return result(insert(bytes, into: object, key: path[1], literal: literal))
        }
        guard let literal else { return text }
        if path.count == 2 {
            let indent = innerIndent(bytes, root) + "  "
            let nested = "{\n\(indent)\(quoted(path[1])): \(literal)\n\(innerIndent(bytes, root))}"
            return result(insert(bytes, into: root, key: path[0], literal: nested))
        }
        return result(insert(bytes, into: root, key: key, literal: literal))
    }

    /// A JSON string literal.
    public static func quoted(_ string: String) -> String {
        let data = (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    private static func result(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    private static func edit(_ bytes: [UInt8], object: Object, member: Member, literal: String?) -> [UInt8] {
        var bytes = bytes
        if let literal {
            bytes.replaceSubrange(member.value.range, with: Array(literal.utf8))
            return bytes
        }
        guard let index = object.members.firstIndex(where: { $0.keyStart == member.keyStart }) else { return bytes }
        if object.members.count == 1 {
            // The object's last member: it's left empty, `{}`.
            bytes.replaceSubrange((object.open + 1)..<object.close, with: [])
        } else if index + 1 < object.members.count {
            bytes.replaceSubrange(member.keyStart..<object.members[index + 1].keyStart, with: [])
        } else {
            bytes.replaceSubrange(object.members[index - 1].value.range.upperBound..<member.value.range.upperBound, with: [])
        }
        return bytes
    }

    private static func insert(_ bytes: [UInt8], into object: Object, key: String, literal: String) -> [UInt8] {
        var bytes = bytes
        let entry = "\(quoted(key)): \(literal)"
        if let last = object.members.last {
            let first = object.members[0]
            // `{ "a": 1 }` stays on one line.
            let inline = !bytes[object.open..<first.keyStart].contains(newline)
            let text = inline ? ", \(entry)" : ",\n\(lineIndent(bytes, at: first.keyStart))\(entry)"
            bytes.insert(contentsOf: Array(text.utf8), at: last.value.range.upperBound)
        } else {
            let own = lineIndent(bytes, at: object.open)
            bytes.replaceSubrange((object.open + 1)..<object.close, with: Array("\n\(own)  \(entry)\n\(own)".utf8))
        }
        return bytes
    }

    /// The indentation of the object's members (its own plus two spaces when it has none).
    private static func innerIndent(_ bytes: [UInt8], _ object: Object) -> String {
        object.members.first.map { lineIndent(bytes, at: $0.keyStart) } ?? lineIndent(bytes, at: object.open) + "  "
    }

    private static func lineIndent(_ bytes: [UInt8], at index: Int) -> String {
        var start = index
        while start > 0, bytes[start - 1] != newline { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end] == space || bytes[end] == tab { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), newline = UInt8(ascii: "\n")
    private static func isSpace(_ byte: UInt8) -> Bool { byte == space || byte == tab || byte == newline || byte == UInt8(ascii: "\r") }

    struct Value {
        let range: Range<Int>
        let object: Object?
    }

    struct Member {
        let key: String
        let keyStart: Int
        let value: Value
    }

    struct Object {
        let open: Int
        let close: Int
        let members: [Member]

        /// The last one, as JSON parsers take it.
        func member(_ key: String) -> Member? { members.last { $0.key == key } }
    }

    /// Ranges of a strict JSON text: enough to find a member and its value.
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func document() -> Object? {
            skipSpace()
            guard let value = value(), let object = value.object else { return nil }
            skipSpace()
            return index == bytes.count ? object : nil
        }

        private mutating func value() -> Value? {
            skipSpace()
            let start = index
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                guard let object = object() else { return nil }
                return Value(range: start..<index, object: object)
            case UInt8(ascii: "["):
                index += 1
                skipSpace()
                if peek(UInt8(ascii: "]")) { index += 1; return Value(range: start..<index, object: nil) }
                while true {
                    guard value() != nil else { return nil }
                    skipSpace()
                    if peek(UInt8(ascii: ",")) { index += 1; continue }
                    guard peek(UInt8(ascii: "]")) else { return nil }
                    index += 1
                    return Value(range: start..<index, object: nil)
                }
            case UInt8(ascii: "\""):
                guard string() != nil else { return nil }
                return Value(range: start..<index, object: nil)
            default:
                // Numbers, true, false, null.
                while index < bytes.count, !JSONTextEdit.isSpace(bytes[index]), !",]}".utf8.contains(bytes[index]) { index += 1 }
                return index > start ? Value(range: start..<index, object: nil) : nil
            }
        }

        private mutating func object() -> Object? {
            let open = index
            index += 1
            var members: [Member] = []
            skipSpace()
            if peek(UInt8(ascii: "}")) {
                index += 1
                return Object(open: open, close: index - 1, members: [])
            }
            while true {
                skipSpace()
                let keyStart = index
                guard peek(UInt8(ascii: "\"")), let key = string() else { return nil }
                skipSpace()
                guard peek(UInt8(ascii: ":")) else { return nil }
                index += 1
                guard let value = value() else { return nil }
                members.append(Member(key: key, keyStart: keyStart, value: value))
                skipSpace()
                if peek(UInt8(ascii: ",")) { index += 1; continue }
                guard peek(UInt8(ascii: "}")) else { return nil }
                index += 1
                return Object(open: open, close: index - 1, members: members)
            }
        }

        private mutating func string() -> String? {
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    return (try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])))
                default: index += 1
                }
            }
            return nil
        }

        private func peek(_ byte: UInt8) -> Bool { index < bytes.count && bytes[index] == byte }

        private mutating func skipSpace() {
            while index < bytes.count, JSONTextEdit.isSpace(bytes[index]) { index += 1 }
        }
    }
}
