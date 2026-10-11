import Foundation
import Observation

/// An open text buffer. Agents read unsaved edits through it, so what the
/// agent sees is what the user sees.
@MainActor
@Observable
public final class TextDocument: Identifiable {
    public let url: URL
    public var text: String {
        didSet { if text != oldValue { revision += 1 } }
    }
    public private(set) var savedText: String
    /// Increments on every change; views use it to detect external edits cheaply.
    public private(set) var revision = 0
    public private(set) var loadError: String?

    public nonisolated var id: URL { url }
    public var isDirty: Bool { text != savedText }

    init(url: URL) {
        self.url = url
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            text = contents
            savedText = contents
        } catch {
            text = ""
            savedText = ""
            loadError = FileManager.default.fileExists(atPath: url.path)
                ? "This file can't be shown as UTF-8 text."
                : nil
        }
    }

    public func save() throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        savedText = text
    }

    /// Replaces both buffer and disk contents (used by agents and review actions).
    public func replaceAndSave(_ newText: String) throws {
        text = newText
        try save()
    }

    func reloadFromDiskIfClean() {
        guard !isDirty, let contents = try? String(contentsOf: url, encoding: .utf8), contents != savedText else { return }
        savedText = contents
        text = contents
    }
}

@MainActor
@Observable
public final class DocumentStore {
    public private(set) var open: [URL: TextDocument] = [:]

    init() {}

    public func document(for url: URL) -> TextDocument {
        let url = url.standardizedFileURL
        if let existing = open[url] { return existing }
        let document = TextDocument(url: url)
        open[url] = document
        return document
    }

    public func existingDocument(for url: URL) -> TextDocument? { open[url.standardizedFileURL] }

    /// Buffer contents if open (including unsaved edits), otherwise disk.
    public func currentText(of url: URL) -> String? {
        if let document = open[url.standardizedFileURL] { return document.text }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Writes through the open buffer when there is one so views stay in sync.
    public func write(_ text: String, to url: URL) throws {
        let url = url.standardizedFileURL
        if let document = open[url] {
            try document.replaceAndSave(text)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public var dirtyDocuments: [TextDocument] { open.values.filter(\.isDirty) }

    func close(_ url: URL) { open[url.standardizedFileURL] = nil }
    func closeAll() { open.removeAll() }

    func reloadCleanDocumentsFromDisk() {
        for document in open.values { document.reloadFromDiskIfClean() }
    }
}
