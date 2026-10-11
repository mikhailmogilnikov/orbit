import OrbitAPI

/// A project path with its bytes pre-lowercased, so fuzzy matching tens of
/// thousands of paths per keystroke stays well under a frame.
struct IndexedPath: Sendable {
    let path: String
    let bytes: [UInt8]
    let lowered: [UInt8]
    /// Byte (and, for ASCII, character) offset where the file name starts.
    let nameStart: Int
    let isASCII: Bool

    init(_ path: String) {
        self.path = path
        bytes = Array(path.utf8)
        lowered = bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        nameStart = (bytes.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
        isASCII = bytes.allSatisfy { $0 < 128 }
    }
}

enum PathMatcher {
    /// Same scoring as `FuzzyMatch.match`, over ASCII bytes in `range` of the path.
    /// Positions are relative to `range.lowerBound`.
    static func match(_ needle: [UInt8], in entry: IndexedPath, from start: Int) -> FuzzyMatch.Result? {
        let lowered = entry.lowered, bytes = entry.bytes
        let count = lowered.count
        var score = 0
        var positions: [Int] = []
        positions.reserveCapacity(needle.count)
        var index = start
        for character in needle {
            while index < count, lowered[index] != character { index += 1 }
            guard index < count else { return nil }
            if let previous = positions.last, previous + 1 == index - start { score += 5 }
            if index == start || isBoundary(bytes[index - 1], before: bytes[index]) { score += 3 }
            score += 1
            positions.append(index - start)
            index += 1
        }
        return FuzzyMatch.Result(score: score - (count - start) / 20, positions: positions)
    }

    private static func isBoundary(_ previous: UInt8, before current: UInt8) -> Bool {
        switch previous {
        case UInt8(ascii: " "), UInt8(ascii: ":"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "/"), UInt8(ascii: "."):
            true
        default:
            (97...122).contains(previous) && (65...90).contains(current)
        }
    }

    static func needle(_ query: String) -> [UInt8]? {
        let lowered = query.lowercased().filter { $0 != " " }
        let bytes = Array(lowered.utf8)
        return bytes.allSatisfy { $0 < 128 } ? bytes : nil
    }
}
