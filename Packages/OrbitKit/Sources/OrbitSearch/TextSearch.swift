import Foundation

struct SearchOptions: Hashable, Sendable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}

struct SearchMatch: Identifiable, Hashable, Sendable {
    let id: String
    /// 0-based.
    let line: Int
    /// The line, trimmed and clipped so the first match is visible.
    let preview: String
    /// UTF-16 ranges of the matches inside `preview`.
    let ranges: [NSRange]
    /// What each match becomes, aligned with `ranges`; set while replacing.
    var replacements: [String]?
}

struct FileMatches: Identifiable, Hashable, Sendable {
    let path: String
    let matches: [SearchMatch]
    var id: String { path }
}

struct SearchResult: Sendable {
    var files: [FileMatches] = []
    var matchCount: Int { files.reduce(0) { $0 + $1.matches.count } }
    /// Stopped early at `TextSearch.maxMatches`.
    var isTruncated = false
}

/// In-process project search: no dependency on ripgrep being installed.
/// Files are scanned in parallel; open buffers win over disk contents.
enum TextSearch {
    static let maxMatches = 10_000
    static let maxMatchesPerFile = 500
    static let maxFileSize = 4 << 20
    private static let previewContext = 40
    private static let previewLength = 240

    enum Failure: Error, Equatable {
        case invalidPattern(String)
    }

    static func makeRegex(_ query: String, options: SearchOptions) throws(Failure) -> NSRegularExpression {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        do {
            return try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw .invalidPattern(query)
        }
    }

    static func run(
        _ query: String,
        options: SearchOptions,
        root: URL,
        paths: [String],
        overrides: [String: String] = [:],
        replacement: String? = nil
    ) async throws(Failure) -> SearchResult {
        let regex = try makeRegex(query, options: options)
        let replacementTemplate = replacement.map { template(for: $0, options: options) }
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let chunkSize = max(64, paths.count / (workers * 4) + 1)
        let chunks = stride(from: 0, to: paths.count, by: chunkSize).map { Array(paths[$0..<min($0 + chunkSize, paths.count)]) }

        var files: [FileMatches] = []
        await withTaskGroup(of: [FileMatches].self) { group in
            for chunk in chunks {
                group.addTask {
                    var found: [FileMatches] = []
                    for path in chunk {
                        if Task.isCancelled { break }
                        guard let text = overrides[path] ?? readText(root.appendingPathComponent(path)) else { continue }
                        let matches = search(text, regex: regex, path: path, template: replacementTemplate)
                        if !matches.isEmpty { found.append(FileMatches(path: path, matches: matches)) }
                    }
                    return found
                }
            }
            for await found in group { files += found }
        }

        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var result = SearchResult()
        var total = 0
        for file in files {
            guard total < maxMatches else {
                result.isTruncated = true
                break
            }
            let kept = Array(file.matches.prefix(maxMatches - total))
            if kept.count < file.matches.count { result.isTruncated = true }
            total += kept.count
            result.files.append(FileMatches(path: file.path, matches: kept))
        }
        return result
    }

    /// Skips large and binary files.
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxFileSize,
              !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The replacement as an `NSRegularExpression` template: `$1` and friends
    /// only mean something in regex mode.
    static func template(for replacement: String, options: SearchOptions) -> String {
        options.regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    /// Replaces the same matches search shows (empty ones are skipped).
    static func replace(in text: String, regex: NSRegularExpression, template: String) -> (text: String, count: Int) {
        let string = text as NSString
        let output = NSMutableString()
        var last = 0
        var count = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: string.length)) { result, _, _ in
            guard let result, result.range.length > 0 else { return }
            output.append(string.substring(with: NSRange(location: last, length: result.range.location - last)))
            output.append(regex.replacementString(for: result, in: text, offset: 0, template: template))
            last = NSMaxRange(result.range)
            count += 1
        }
        guard count > 0 else { return (text, 0) }
        output.append(string.substring(from: last))
        return (output as String, count)
    }

    static func search(_ text: String, regex: NSRegularExpression, path: String, template: String? = nil) -> [SearchMatch] {
        let string = text as NSString
        var lineStarts: [Int]?
        var byLine: [(line: Int, matches: [Found])] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: string.length)) { result, _, stop in
            guard let result, result.range.length > 0 else { return }
            let range = result.range
            let found = Found(range: range, replacement: template.map { regex.replacementString(for: result, in: text, offset: 0, template: $0) })
            if lineStarts == nil { lineStarts = Self.lineStarts(of: string) }
            let line = Self.line(containing: range.location, starts: lineStarts!)
            if byLine.last?.line == line {
                byLine[byLine.count - 1].matches.append(found)
            } else {
                if byLine.count >= maxMatchesPerFile { stop.pointee = true; return }
                byLine.append((line, [found]))
            }
        }
        guard let lineStarts else { return [] }
        return byLine.map { entry in
            let start = lineStarts[entry.line]
            var end = entry.line + 1 < lineStarts.count ? lineStarts[entry.line + 1] : string.length
            while end > start, [0x0A, 0x0D].contains(string.character(at: end - 1)) { end -= 1 }
            return preview(of: string, line: entry.line, lineRange: NSRange(location: start, length: end - start), matches: entry.matches, path: path)
        }
    }

    private struct Found {
        let range: NSRange
        let replacement: String?
    }

    private static func preview(of string: NSString, line: Int, lineRange: NSRange, matches: [Found], path: String) -> SearchMatch {
        // Drop indentation, and if the first match sits far right, the text before it.
        var from = lineRange.location
        let lineEnd = NSMaxRange(lineRange)
        while from < lineEnd, [0x20, 0x09].contains(string.character(at: from)) { from += 1 }
        let firstMatch = matches[0].range.location
        var prefix = ""
        if firstMatch - from > previewContext {
            from = firstMatch - previewContext
            // Don't split a surrogate pair.
            if from > 0, UTF16.isTrailSurrogate(string.character(at: from)) { from -= 1 }
            prefix = "…"
        }
        var to = min(lineEnd, from + previewLength)
        if to < lineEnd, to > from, UTF16.isLeadSurrogate(string.character(at: to - 1)) { to -= 1 }
        let text = prefix + string.substring(with: NSRange(location: from, length: to - from))
        let shift = (prefix as NSString).length - from
        var ranges: [NSRange] = []
        var replacements: [String] = []
        for match in matches {
            let clipped = NSIntersectionRange(match.range, NSRange(location: from, length: to - from))
            guard clipped.length > 0 else { continue }
            ranges.append(NSRange(location: clipped.location + shift, length: clipped.length))
            if let replacement = match.replacement { replacements.append(replacement) }
        }
        let isReplacing = matches.contains { $0.replacement != nil }
        return SearchMatch(id: "\(path):\(line)", line: line, preview: text, ranges: ranges, replacements: isReplacing ? replacements : nil)
    }

    static func lineStarts(of string: NSString) -> [Int] {
        var starts = [0]
        let length = string.length
        var index = 0
        while index < length {
            if string.character(at: index) == 0x0A { starts.append(index + 1) }
            index += 1
        }
        return starts
    }

    private static func line(containing location: Int, starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
