import AppKit
import ImageIO
import OrbitAPI

/// Images the code refers to (`import logo from './logo.png'`, `src="/hero.webp"`,
/// `url(bg.svg)`), shown as thumbnails beside the line numbers (D146).
enum ImageReferences {
    nonisolated(unsafe) static let pattern = /(?<path>[\w.@~\/%+-]*[\w-]\.(?i:png|jpe?g|gif|webp|svg|ico|bmp|avif|heic|tiff?))(?=[\s'"`)\],;?#]|$)/

    /// Line (0-based) → the existing image file its first reference names.
    nonisolated static func find(in text: String, file: URL, root: URL?) -> [Int: URL] {
        var result: [Int: URL] = [:]
        var resolved: [String: URL?] = [:]
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(20_000).enumerated() {
            guard line.count < 2000, line.contains("."), result.count < 500 else { continue }
            for match in line.matches(of: pattern) {
                let path = String(match.path)
                // Web addresses aren't fetched.
                guard !path.hasPrefix("//"), !line[..<match.range.lowerBound].hasSuffix(":") else { continue }
                let url = resolved[path] ?? resolve(path, file: file, root: root)
                resolved[path] = url
                if let url {
                    result[index] = url
                    break
                }
            }
        }
        return result
    }

    /// Relative to the file, then the project and the folders web projects serve
    /// from (`public`, `static`, `src`, `assets`); `/x` is the site's root, `@/x` and `~/x` its `src`.
    nonisolated static func resolve(_ path: String, file: URL, root: URL?) -> URL? {
        let folder = file.deletingLastPathComponent()
        var candidates: [URL] = []
        func under(_ base: URL?, _ relative: String, _ subfolders: [String]) {
            guard let base else { return }
            for subfolder in subfolders {
                let directory = subfolder.isEmpty ? base : base.appendingPathComponent(subfolder)
                candidates.append(directory.appendingPathComponent(relative))
            }
        }
        if path.hasPrefix("@/") || path.hasPrefix("~/") {
            under(root, String(path.dropFirst(2)), ["src", ""])
        } else if path.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: path))
            under(root, String(path.dropFirst()), ["public", "static", "", "src"])
        } else if path.hasPrefix("./") || path.hasPrefix("../") {
            candidates.append(folder.appendingPathComponent(path))
        } else {
            candidates.append(folder.appendingPathComponent(path))
            under(root, path, ["", "public", "static", "src", "assets"])
        }
        var isDirectory: ObjCBool = false
        return candidates.lazy.map(\.standardizedFileURL).first {
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }
}

/// Small versions of the gutter's images, made off the main actor (a photo
/// can take a while to decode) except SVG, which only AppKit draws.
@MainActor
final class ThumbnailCache {
    private var images: [URL: NSImage] = [:]
    private var loading: Set<URL> = []
    var onLoad: () -> Void = {}

    func image(for url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard loading.insert(url).inserted else { return nil }
        if url.pathExtension.lowercased() == "svg" {
            images[url] = NSImage(contentsOf: url) ?? NSImage()
            loading.remove(url)
            return images[url]
        }
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) { Self.thumbnail(of: url) }.value
            guard let self else { return }
            images[url] = image.map { NSImage(cgImage: $0.image, size: .zero) } ?? NSImage()
            loading.remove(url)
            onLoad()
        }
        return nil
    }

    func clear() { images = [:] }

    private struct Thumbnail: @unchecked Sendable { let image: CGImage }

    private nonisolated static func thumbnail(of url: URL) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Thumbnail.init)
    }
}

extension CodeEditor.Coordinator {
    /// After a pause in typing, off the main actor: which lines name an image.
    func scheduleImageReferences(delay: Duration = .milliseconds(400)) {
        imagesTask?.cancel()
        guard showsImageThumbnails, let textView else {
            ruler?.images = [:]
            return
        }
        let text = textView.text ?? ""
        let file = document.url, root = imageRoot
        imagesTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let images = await Task.detached(priority: .utility) { ImageReferences.find(in: text, file: file, root: root) }.value
            guard !Task.isCancelled else { return }
            self?.ruler?.images = images
        }
    }
}
