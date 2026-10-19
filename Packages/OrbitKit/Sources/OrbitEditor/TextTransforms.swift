import AppKit
import OrbitAPI

/// Sort and dedupe lines, change case and naming style (D151). Line commands
/// work on the selected lines, or the whole file with nothing selected; case
/// commands on each selection, or the word at each caret.
enum TextTransforms {
    enum Case: CaseIterable {
        case upper, lower, title, camel, pascal, snake, kebab, constant

        var title: String {
            switch self {
            case .upper: "UPPERCASE"
            case .lower: "lowercase"
            case .title: "Title Case"
            case .camel: "camelCase"
            case .pascal: "PascalCase"
            case .snake: "snake_case"
            case .kebab: "kebab-case"
            case .constant: "CONSTANT_CASE"
            }
        }

        var id: String {
            switch self {
            case .upper: "upper"
            case .lower: "lower"
            case .title: "title"
            case .camel: "camel"
            case .pascal: "pascal"
            case .snake: "snake"
            case .kebab: "kebab"
            case .constant: "constant"
            }
        }
    }

    enum LineOperation { case sortAscending, sortDescending, removeDuplicates, reverse }

    static func lines(_ text: NSString, selections: [NSRange], _ operation: LineOperation) -> LineEditing.Edit? {
        let starts = LineStarts.of(text)
        let selected = selections.contains { $0.length > 0 }
        let first: Int, last: Int
        if selected, let low = selections.map(\.location).min(), let high = selections.map(NSMaxRange).max() {
            first = line(of: low, starts)
            var end = line(of: high, starts)
            if end > first, starts[end] == high { end -= 1 }
            last = end
        } else {
            first = 0
            last = starts.count - 1
        }
        let from = starts[first]
        let to = last + 1 < starts.count ? starts[last + 1] - 1 : text.length
        let block = text.substring(with: NSRange(location: from, length: to - from))
        var lines = block.components(separatedBy: "\n")
        // A file's final newline isn't a line to sort.
        let trailingEmpty = !selected && lines.last == ""
        if trailingEmpty { lines.removeLast() }
        switch operation {
        case .sortAscending: lines.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        case .sortDescending: lines.sort { $0.localizedStandardCompare($1) == .orderedDescending }
        case .removeDuplicates:
            var seen = Set<String>()
            lines = lines.filter { seen.insert($0).inserted }
        case .reverse: lines.reverse()
        }
        if trailingEmpty { lines.append("") }
        let replacement = lines.joined(separator: "\n")
        guard replacement != block else { return nil }
        let length = (replacement as NSString).length - (trailingEmpty ? 1 : 0)
        return LineEditing.Edit(
            range: NSRange(location: from, length: to - from), replacement: replacement,
            selections: [NSRange(location: from, length: selected ? max(0, length) : 0)]
        )
    }

    static func changeCase(_ text: NSString, selections: [NSRange], to style: Case) -> LineEditing.Edit? {
        let ranges = selections.map { $0.length > 0 ? $0 : word(at: $0.location, in: text) }.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        guard let low = ranges.first?.location, let high = ranges.map(NSMaxRange).max() else { return nil }
        var result = ""
        var cursor = low
        var selected: [NSRange] = []
        for range in ranges where range.location >= cursor {
            result += text.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let converted = convert(text.substring(with: range), to: style)
            selected.append(NSRange(location: low + (result as NSString).length, length: (converted as NSString).length))
            result += converted
            cursor = NSMaxRange(range)
        }
        result += text.substring(with: NSRange(location: cursor, length: high - cursor))
        let range = NSRange(location: low, length: high - low)
        guard result != text.substring(with: range) else { return nil }
        return LineEditing.Edit(range: range, replacement: result, selections: selected)
    }

    static func convert(_ text: String, to style: Case) -> String {
        switch style {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return text.split(separator: " ", omittingEmptySubsequences: false).map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        default: break
        }
        // Keep what's around the name: `  myName,` → `  my_name,`.
        let leading = text.prefix { !$0.isLetter && !$0.isNumber }
        let trailing = String(text.dropFirst(leading.count).reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
        let core = String(text.dropFirst(leading.count).dropLast(trailing.count))
        let words = Self.words(core)
        guard !words.isEmpty else { return text }
        let joined: String
        switch style {
        case .camel: joined = words[0].lowercased() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
        case .pascal: joined = words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
        case .snake: joined = words.map { $0.lowercased() }.joined(separator: "_")
        case .kebab: joined = words.map { $0.lowercased() }.joined(separator: "-")
        case .constant: joined = words.map { $0.uppercased() }.joined(separator: "_")
        default: joined = core
        }
        return leading + joined + trailing
    }

    /// `HTTPServer_url-path2` → HTTP, Server, url, path2.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if let previous = current.last {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let lowerToUpper = previous.isLowercase && character.isUppercase
                // The last capital of an acronym starts the next word: HTTPServer.
                let acronymEnd = previous.isUppercase && character.isUppercase && (next?.isLowercase ?? false)
                if lowerToUpper || acronymEnd {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func line(of offset: Int, _ starts: [Int]) -> Int {
        starts.lastIndex { $0 <= offset } ?? 0
    }

    private static func word(at offset: Int, in text: NSString) -> NSRange {
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < text.length, let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
        var start = offset, end = offset
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}

extension CodeEditor.Coordinator {
    func transformLines(_ operation: TextTransforms.LineOperation) { apply { TextTransforms.lines($0, selections: $1, operation) } }
    func changeCase(_ style: TextTransforms.Case) { apply { TextTransforms.changeCase($0, selections: $1, to: style) } }

    private func apply(_ make: (NSString, [NSRange]) -> LineEditing.Edit?) {
        guard let textView, let edit = make(textView.documentText, textView.selectionRanges) else { return NSSound.beep() }
        textView.apply(edit)
    }
}
