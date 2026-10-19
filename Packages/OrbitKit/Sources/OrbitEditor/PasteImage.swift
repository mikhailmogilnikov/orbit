import AppKit
import OrbitAPI

/// A screenshot or image file pasted into Markdown is saved in `assets/`
/// beside the file and linked (D152): `![](assets/image-2026-10-19-161203.png)`.
enum PastedImages {
    static let markdown: Set<String> = ["md", "markdown", "mdx"]
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "avif"]

    /// Nil when the pasteboard holds text (that pastes as usual) or no image.
    @MainActor
    static func paste(from pasteboard: NSPasteboard, into document: URL, now: Date = Date()) -> String? {
        guard markdown.contains(document.pathExtension.lowercased()) else { return nil }
        let folder = document.deletingLastPathComponent()
        let assets = folder.appendingPathComponent("assets")
        // Image files copied in Finder: linked where they are when inside the folder, else copied in.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter { imageTypes.contains($0.pathExtension.lowercased()) }
            guard !images.isEmpty else { return nil }
            var links: [String] = []
            for url in images {
                let target: URL
                if url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") {
                    target = url.standardizedFileURL
                } else {
                    target = unique(assets.appendingPathComponent(url.lastPathComponent))
                    do {
                        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: target)
                    } catch { continue }
                }
                links.append(link(to: target, from: folder))
            }
            return links.isEmpty ? nil : links.joined(separator: "\n")
        }
        guard pasteboard.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let target = unique(assets.appendingPathComponent("image-\(formatter.string(from: now)).png"))
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try png.write(to: target)
        } catch {
            return nil
        }
        return link(to: target, from: folder)
    }

    static func link(to file: URL, from folder: URL) -> String {
        let relative = String(file.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
        let path = relative.contains(" ") ? "<\(relative)>" : relative
        return "![](\(path))"
    }

    private static func unique(_ url: URL) -> URL {
        var candidate = url
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(number).\(url.pathExtension)")
            number += 1
        }
        return candidate
    }
}

extension CodeEditor.Coordinator {
    func pasteImage(from pasteboard: NSPasteboard) -> String? {
        PastedImages.paste(from: pasteboard, into: document.url)
    }
}
