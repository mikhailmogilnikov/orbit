import AppKit
import OrbitAPI
import OrbitUI
import PDFKit
import SwiftUI

/// An image (pinch or ⌘-scroll to zoom, double-click toggles fit / actual size) or a PDF.
struct MediaView: View {
    let url: URL
    let workspace: Workspace
    @State private var loaded = LoadedImage()

    var body: some View {
        // Any disk change brings us here, but only a change to this file reloads
        // it: a reload loses the zoom and scroll (and an agent changes files a lot).
        let _ = workspace.fileSystemGeneration
        let stamp = FileStamp(url)
        Group {
            if url.pathExtension.lowercased() == "pdf" {
                PDFViewer(url: url, stamp: stamp)
            } else if let image = loaded.image(at: url, stamp: stamp) {
                ImageViewer(image: image)
                    .overlay(alignment: .bottomTrailing) { info(image) }
            } else {
                EmptyStateView("Can't show this image", systemImage: "photo", message: url.lastPathComponent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func info(_ image: NSImage) -> some View {
        let pixels = image.representations.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.max { $0.width < $1.width }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let dimensions = pixels.map { "\(Int($0.width)) × \(Int($0.height))" }
        return Text([dimensions, size].compactMap(\.self).joined(separator: " · "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .padding(10)
    }
}

/// Modification date and size: what tells a regenerated file from the same one.
private struct FileStamp: Equatable {
    let modified: Date?
    let size: Int?

    init(_ url: URL) {
        // Not `URL.resourceValues`: the URL caches those and would keep answering the old date.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        modified = attributes?[.modificationDate] as? Date
        size = (attributes?[.size] as? NSNumber)?.intValue
    }
}

/// The image as last read, kept while the file is the same.
private final class LoadedImage {
    private var url: URL?
    private var stamp: FileStamp?
    private var image: NSImage?

    func image(at url: URL, stamp: FileStamp) -> NSImage? {
        if url != self.url || stamp != self.stamp {
            self.url = url
            self.stamp = stamp
            image = NSImage(contentsOf: url)
        }
        return image
    }
}

private struct ImageViewer: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> ImageScrollView {
        let view = ImageScrollView()
        view.show(image)
        return view
    }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        if view.imageView.image !== image { view.show(image) }
    }
}

/// Fits the image when it's larger than the view, else shows it at 1× (points
/// from its pixel size and DPI, as Preview does); centered while smaller.
final class ImageScrollView: NSScrollView {
    let imageView = NSImageView()
    private var fitsWhenResized = true

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 32
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        documentView = imageView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: NSImage) {
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        fitsWhenResized = true
        fit()
    }

    private var fittingMagnification: CGFloat {
        let size = imageView.frame.size, bounds = contentSize
        guard size.width > 0, size.height > 0, bounds.width > 0 else { return 1 }
        return min(1, bounds.width / size.width, bounds.height / size.height)
    }

    private func fit() {
        magnification = fittingMagnification
    }

    override func layout() {
        super.layout()
        if fitsWhenResized { fit() }
    }

    override func magnify(with event: NSEvent) {
        fitsWhenResized = false
        super.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        fitsWhenResized = false
        let point = contentView.convert(event.locationInWindow, from: nil)
        setMagnification(magnification * (1 + event.scrollingDeltaY / 100), centeredAt: point)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        let point = contentView.convert(event.locationInWindow, from: nil)
        if abs(magnification - fittingMagnification) < 0.001, fittingMagnification < 1 {
            fitsWhenResized = false
            animator().setMagnification(1, centeredAt: point)
        } else {
            fitsWhenResized = true
            animator().magnification = fittingMagnification
        }
    }
}

/// Keeps a document smaller than the view in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

private struct PDFViewer: NSViewRepresentable {
    let url: URL
    let stamp: FileStamp

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        context.coordinator.loaded = (url, stamp)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let loaded = context.coordinator.loaded, loaded.url != url || loaded.stamp != stamp else { return }
        context.coordinator.loaded = (url, stamp)
        view.document = PDFDocument(url: url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: (url: URL, stamp: FileStamp)?
    }
}
