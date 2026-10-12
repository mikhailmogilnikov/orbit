import AppKit
import OrbitAPI
import SwiftUI

/// A file or folder icon from the picked icon theme, or an SF Symbol when
/// there is none (or it has no icon for this file).
public struct FileIconView: View {
    let url: URL
    let isFolder: Bool
    let isExpanded: Bool
    /// Theme icons are pictures, not glyphs: they need a size the font can't give them.
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(url: URL, isFolder: Bool = false, isExpanded: Bool = false, size: CGFloat = 15) {
        self.url = url
        self.isFolder = isFolder
        self.isExpanded = isExpanded
        self.size = size
    }

    public var body: some View {
        if let image = themedImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: isFolder ? "folder" : FileIcon.systemImage(for: url))
        }
    }

    private var themedImage: NSImage? {
        let extensions = Extensions.shared
        _ = extensions.revision
        guard let theme = extensions.iconTheme(dark: colorScheme == .dark) else { return nil }
        let name = url.lastPathComponent
        let icon = isFolder ? theme.icon(forFolderNamed: name, expanded: isExpanded) : theme.icon(forFileNamed: name)
        return icon.flatMap(IconImageCache.image)
    }
}

@MainActor
private enum IconImageCache {
    private static var images: [URL: NSImage] = [:]
    private static var missing: Set<URL> = []
    private static var observer: NSObjectProtocol?

    static func image(at url: URL) -> NSImage? {
        if observer == nil {
            // Icon files may have been edited: drop the cache when extensions reload.
            observer = NotificationCenter.default.addObserver(forName: Extensions.themeDidChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    images.removeAll()
                    missing.removeAll()
                }
            }
        }
        if let image = images[url] { return image }
        guard !missing.contains(url) else { return nil }
        guard let image = NSImage(contentsOf: url) else {
            missing.insert(url)
            return nil
        }
        images[url] = image
        return image
    }
}
