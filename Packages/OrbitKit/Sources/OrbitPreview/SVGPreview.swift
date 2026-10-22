import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// An SVG drawn as it's edited, unsaved changes included (D145). While the
/// text doesn't parse (mid-edit), the last picture that did stays, marked.
struct SVGPreview: View {
    let url: URL
    let workspace: Workspace
    let showSourceHelp: String
    let showSource: () -> Void
    @State private var lastGood: NSImage?
    @State private var background = Backdrop.checkerboard
    @Environment(\.colorScheme) private var appScheme

    enum Backdrop: String, CaseIterable {
        case checkerboard = "Checkerboard", light = "Light", dark = "Dark"

        /// The controls over the picture follow the backdrop, not the app: dark
        /// glass and white text are unreadable over a light checkerboard.
        var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    }

    var body: some View {
        let text = workspace.documents.existingDocument(for: url)?.text
            ?? { _ = workspace.fileSystemGeneration; return try? String(contentsOf: url, encoding: .utf8) }()
            ?? ""
        let image = Self.image(text)
        let controlsScheme = image ?? lastGood == nil ? appScheme : background.colorScheme
        Group {
            if let shown = image ?? lastGood {
                ImageViewer(image: shown, upscales: true)
                    .background(backdrop)
            } else {
                EmptyStateView("Can't Draw This SVG", systemImage: "photo", message: "The file isn't a valid SVG image yet.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button(action: showSource) {
                Label("Show Source", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(.glass)
            .help(showSourceHelp)
            .padding(10)
            .environment(\.colorScheme, controlsScheme)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                if image == nil, lastGood != nil {
                    Label("Not valid SVG: showing the last good version", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if let image {
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .foregroundStyle(.secondary)
                }
                Picker("Background", selection: $background) {
                    ForEach(Backdrop.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                .help("What's behind the image's transparent parts")
            }
            .font(.orbit(.caption).monospacedDigit())
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .padding(10)
            .environment(\.colorScheme, controlsScheme)
        }
        .onChange(of: image) { _, new in
            if let new { lastGood = new }
        }
        .onAppear { if let image { lastGood = image } }
    }

    @ViewBuilder
    private var backdrop: some View {
        switch background {
        case .checkerboard: Checkerboard()
        case .light: Color.white
        case .dark: Color.black
        }
    }

    static func image(_ text: String) -> NSImage? {
        guard text.contains("<svg"), let image = NSImage(data: Data(text.utf8)), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }
}

/// Grey squares, as image editors show transparency.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.96)))
            var path = Path()
            for row in 0..<Int(ceil(size.height / side)) {
                for column in 0..<Int(ceil(size.width / side)) where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side))
                }
            }
            context.fill(path, with: .color(Color(white: 0.86)))
        }
    }
}
