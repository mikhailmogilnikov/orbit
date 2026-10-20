import Foundation

/// Files that may break when another file changes (D198): its importers,
/// found by the names a module goes by on lines that import something. Cheap
/// and server-free, and it finds users of a removed export, which a server's
/// references can't (the symbol is gone).
enum DependentFiles {
    /// Names other files import `url` by: its stem, or its folder's name for a
    /// folder's entry file (`utils/index.ts`, `pkg/__init__.py`, `mod.rs`).
    static func moduleNames(for url: URL) -> Set<String> {
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent().lastPathComponent
        var names: Set<String> = []
        if entryStems.contains(stem) {
            if !folder.isEmpty, folder != "/" { names.insert(folder) }
        } else if !stem.isEmpty, !programStems.contains(stem) {
            names.insert(stem)
        }
        return names
    }

    private static let entryStems: Set<String> = ["index", "__init__", "mod"]
    /// Run, not imported; as words they'd match everywhere.
    private static let programStems: Set<String> = ["main", "lib"]
    private static let importWords = ["import", "require", "from", "use", "include", "mod", "export"]

    /// Whether `text` imports one of `names`: a line naming it as a whole
    /// word, or as a path's last part, beside an import word.
    static func imports(_ text: String, anyOf names: Set<String>) -> Bool {
        guard !names.isEmpty else { return false }
        for name in names where text.contains(name) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.contains(name) {
                guard containsWord(line, name) else { continue }
                if importWords.contains(where: { containsWord(line, $0) }) { return true }
                // An import block's inner lines (Go, Python's parentheses) are paths alone.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if (trimmed.hasPrefix("\"") || trimmed.hasPrefix("'")) && trimmed.contains("/\(name)") { return true }
            }
        }
        return false
    }

    private static func containsWord(_ line: Substring, _ word: String) -> Bool {
        var searchStart = line.startIndex
        while let found = line.range(of: word, range: searchStart..<line.endIndex) {
            let before = found.lowerBound == line.startIndex ? nil : line[line.index(before: found.lowerBound)]
            let after = found.upperBound == line.endIndex ? nil : line[found.upperBound]
            if !isIdentifier(before), !isIdentifier(after) { return true }
            searchStart = found.upperBound
        }
        return false
    }

    private static func isIdentifier(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    /// The candidates whose text imports any changed file, read off the main actor.
    /// `candidates` pairs each file with the module names it's checked for.
    static func importers(_ candidates: [(url: URL, names: Set<String>)], limit: Int) async -> [URL] {
        await Task.detached(priority: .utility) {
            var found: [URL] = []
            for candidate in candidates {
                guard !Task.isCancelled, found.count < limit else { break }
                guard let size = (try? candidate.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < maxFileSize,
                      let text = try? String(contentsOf: candidate.url, encoding: .utf8) else { continue }
                if imports(text, anyOf: candidate.names) { found.append(candidate.url) }
            }
            return found
        }.value
    }

    /// Generated bundles and data files aren't importers worth checking.
    private static let maxFileSize = 512 * 1024
}
