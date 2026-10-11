import AppKit
import SwiftUI

/// The Orbit glyph from the app icon, as a template image that takes the
/// current foreground style. Shares its SVG with `App/AppIcon.icon`.
public struct OrbitMark: View {
    @MainActor private static let image: NSImage = {
        let image = Bundle.module.url(forResource: "OrbitMark", withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    public init() {}

    public var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
