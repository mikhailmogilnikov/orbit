import Foundation

extension URL {
    /// Where a symlink (or a chain of them) ends, even when that's missing;
    /// nil when this isn't a symlink. Links in a loop end on a link.
    public var symlinkTarget: URL? {
        var url = self
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
                return url == self ? nil : url
            }
            url = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        return url
    }

    /// A folder, or a symlink to one (`isDirectoryKey` is false for the link).
    public var isFolderFollowingLinks: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The path with every symlink in it resolved; nil when it doesn't exist.
    /// realpath, not `resolvingSymlinksInPath`: that one turns /private/var back into /var.
    public var realPath: String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// `realPath`, also for a file not created yet: its folder's real path and its name.
    public var realPathOrPlanned: String {
        if let real = realPath { return real }
        let folder = deletingLastPathComponent()
        return (folder.realPath ?? folder.standardizedFileURL.path) + "/" + lastPathComponent
    }
}

extension FileManager {
    /// A folder's entries, also of one opened through a symlink: listing a
    /// link's URL lists nothing. The entries keep paths under the URL given.
    public func entries(of folder: URL, includingPropertiesForKeys keys: [URLResourceKey], options: DirectoryEnumerationOptions = []) -> [URL] {
        guard let target = folder.symlinkTarget else {
            return (try? contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: options)) ?? []
        }
        return ((try? contentsOfDirectory(at: target, includingPropertiesForKeys: keys, options: options)) ?? []).map {
            folder.appending(path: $0.lastPathComponent, directoryHint: $0.hasDirectoryPath ? .isDirectory : .notDirectory)
        }
    }
}
