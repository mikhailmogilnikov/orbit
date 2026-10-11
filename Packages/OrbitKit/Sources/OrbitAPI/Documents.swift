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
            existsOnDisk = true
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
        diskConflict = nil
        existsOnDisk = true
        isDeletedOnDisk = false
    }

    /// Replaces both buffer and disk contents (used by agents and review actions).
    public func replaceAndSave(_ newText: String) throws {
        text = newText
        try save()
    }

    /// The file's new contents when it changed on disk under unsaved edits and
    /// the two couldn't be merged; the editor asks which version to keep.
    public private(set) var diskConflict: String?

    /// Picks up changes made on disk by agents, git or other apps. A clean
    /// buffer reloads; unsaved edits get the change merged in when it touches
    /// other lines, otherwise `diskConflict` is set.
    /// The file was removed (or moved) on disk while open; saving puts it back.
    public private(set) var isDeletedOnDisk = false
    /// A buffer for a file that was never written isn't "deleted".
    private var existsOnDisk = false

    public func syncWithDisk() {
        guard loadError == nil else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            isDeletedOnDisk = existsOnDisk
            return
        }
        isDeletedOnDisk = false
        existsOnDisk = true
        guard let disk = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard disk != savedText else {
            diskConflict = nil
            return
        }
        if isDirty, disk != text {
            guard let merged = LineDiff.merge(base: savedText, mine: text, theirs: disk) else {
                diskConflict = disk
                return
            }
            text = merged
        } else {
            text = disk
        }
        savedText = disk
        diskConflict = nil
    }

    /// Resolves a conflict in favor of the buffer by writing it over the disk.
    public func keepMine() throws {
        try save()
        diskConflict = nil
    }

    /// Resolves a conflict by dropping unsaved edits for the disk version.
    public func useDiskVersion() {
        guard let disk = diskConflict else { return }
        text = disk
        savedText = disk
        diskConflict = nil
    }

    /// Takes one block of the disk version (a hunk of buffer → disk) into the buffer.
    public func takeFromDisk(_ hunk: DiffHunk) {
        guard let disk = diskConflict else { return }
        text = LineDiff.keep(hunk, current: disk, baseline: text)
        if text == disk {
            savedText = disk
            diskConflict = nil
        }
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

    public func syncWithDisk() {
        for document in open.values { document.syncWithDisk() }
    }
}
