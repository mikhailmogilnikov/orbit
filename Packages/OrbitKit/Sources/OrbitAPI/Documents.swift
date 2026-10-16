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
    /// The load failed in a way another encoding might fix.
    public private(set) var canReopenWithEncoding = false
    /// Encoding and line endings on disk; changing it makes the buffer dirty.
    public var format: TextFileFormat = .default
    private var savedFormat: TextFileFormat = .default

    public nonisolated var id: URL { url }
    public var isDirty: Bool { text != savedText || format != savedFormat }

    init(url: URL) {
        self.url = url
        text = ""
        savedText = ""
        load()
    }

    private func load(as encoding: String.Encoding? = nil) {
        do {
            let (contents, format) = encoding == nil
                ? try TextFile.read(url)
                : try TextFile.decode(Data(contentsOf: url), as: encoding)
            text = contents
            savedText = contents
            self.format = format
            savedFormat = format
            existsOnDisk = true
            loadError = nil
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            existsOnDisk = true
            loadError = TextFile.message(for: error)
            // UTF-16 without a BOM looks binary; a legacy encoding may be a wrong guess.
            canReopenWithEncoding = error as? TextFile.ReadError == .binary || error as? TextFile.ReadError == .undecodable
        }
    }

    /// The file read again as another encoding (when the guess was wrong); unsaved edits are dropped.
    public func reopen(as encoding: String.Encoding) {
        load(as: encoding)
        diskConflict = nil
    }

    var onSave: ((URL) -> Void)?

    public func save() throws {
        try TextFile.encode(text, as: format).write(to: url, options: .atomic)
        onSave?(url)
        savedText = text
        savedFormat = format
        diskConflict = nil
        existsOnDisk = true
        isDeletedOnDisk = false
    }

    /// Replaces both buffer and disk contents (used by agents and review actions).
    public func replaceAndSave(_ newText: String) throws {
        text = TextFile.normalized(newText)
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
        guard let disk = try? TextFile.decode(Data(contentsOf: url), as: savedFormat.encoding).text else { return }
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
    /// A buffer was saved (settings files reload).
    var onSave: ((URL) -> Void)?

    init() {}

    public func document(for url: URL) -> TextDocument {
        let url = url.standardizedFileURL
        if let existing = open[url] { return existing }
        let document = TextDocument(url: url)
        document.onSave = { [weak self] in self?.onSave?($0) }
        open[url] = document
        return document
    }

    public func existingDocument(for url: URL) -> TextDocument? { open[url.standardizedFileURL] }

    /// Buffer contents if open (including unsaved edits), otherwise disk.
    public func currentText(of url: URL) -> String? {
        if let document = open[url.standardizedFileURL] { return document.text }
        return try? TextFile.read(url).text
    }

    /// Writes through the open buffer when there is one so views stay in sync.
    public func write(_ text: String, to url: URL) throws {
        let url = url.standardizedFileURL
        if let document = open[url] {
            try document.replaceAndSave(text)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A file that's there keeps its encoding and line endings.
            try TextFile.encode(text, as: TextFile.format(of: url) ?? .default).write(to: url, options: .atomic)
            onSave?(url)
        }
    }

    public var dirtyDocuments: [TextDocument] { open.values.filter(\.isDirty) }

    /// Files moved on disk: their buffers open under the new paths, unsaved
    /// edits carried over (a document's URL is fixed, so it's a new one).
    func relocate(_ target: (URL) -> URL?) {
        for (url, old) in open {
            guard let moved = target(url) else { continue }
            open[url] = nil
            guard old.isDirty else { continue }
            document(for: moved).text = old.text
        }
    }

    func close(_ url: URL) { open[url.standardizedFileURL] = nil }
    func close(where isClosed: (URL) -> Bool) { open = open.filter { !isClosed($0.key) } }
    func closeAll() { open.removeAll() }

    public func syncWithDisk() {
        for document in open.values { document.syncWithDisk() }
    }
}
