import AppKit
import OrbitAPI
import SwiftUI

/// Design tokens shared by all plugins so the app reads as one system.
public enum Theme {
    public static let codeFont = Font.system(size: 12, design: .monospaced)
    public static let corner: CGFloat = 10
    public static let smallCorner: CGFloat = 6

    // Version-control colors come from the color theme (both variants, so they
    // follow light/dark); reading them in a body re-renders on a theme switch.
    @MainActor public static var added: Color { themed(\.added, .systemGreen) }
    @MainActor public static var removed: Color { themed(\.deleted, .systemRed) }
    @MainActor public static var modified: Color { themed(\.modified, .systemOrange) }
    @MainActor public static var renamed: Color { themed(\.renamed, .systemBlue) }
    @MainActor public static var conflict: Color { themed(\.conflict, .systemRed) }
    @MainActor public static var addedBackground: Color { added.opacity(0.14) }
    @MainActor public static var removedBackground: Color { removed.opacity(0.13) }
    @MainActor public static var addedGutter: Color { added.opacity(0.22) }
    @MainActor public static var removedGutter: Color { removed.opacity(0.2) }

    /// The app's tint (D97): the color theme's accent, else the text color,
    /// never the system blue. The window sets it as `.tint`, so `.tint` and
    /// prominent buttons follow; use it instead of `Color.accentColor`.
    @MainActor public static var accent: Color { Color(nsColor: accentNSColor) }
    @MainActor public static var accentNSColor: NSColor {
        let extensions = Extensions.shared
        let light = extensions.colorTheme(dark: false).accent?.nsColor ?? .labelColor
        let dark = extensions.colorTheme(dark: true).accent?.nsColor ?? .labelColor
        return .dynamic(light: light, dark: dark)
    }

    public static let subtleFill = Color.primary.opacity(0.045)
    public static let hairline = Color.primary.opacity(0.08)

    /// Behind the terminal, so the padding around it matches.
    @MainActor public static var terminalBackground: Color {
        themed({ $0.terminalBackground ?? $0.editorBackground }, .textBackgroundColor)
    }

    @MainActor private static func themed(_ key: (ColorTheme) -> ThemeColor?, _ fallback: NSColor) -> Color {
        let extensions = Extensions.shared
        let light = key(extensions.colorTheme(dark: false))?.nsColor ?? fallback
        let dark = key(extensions.colorTheme(dark: true))?.nsColor ?? fallback
        return Color(nsColor: .dynamic(light: light, dark: dark))
    }
}

/// The color theme's editor background under the whole window, as in Xcode 26:
/// the editor sits on it and the glass sidebar and inspector float over it and
/// pick up its tint, so the chrome follows the theme without being painted.
private struct ThemedWindow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let color = Extensions.shared.colorTheme(dark: colorScheme == .dark).editorBackground?.nsColor
        content
            .background {
                if let color { Color(nsColor: color).ignoresSafeArea() }
            }
            .background(WindowBackground(color: color))
    }
}

/// The window's own background, seen wherever no view draws (around the
/// floating sidebar and inspector, the title bar area).
private struct WindowBackground: NSViewRepresentable {
    let color: NSColor?

    func makeNSView(context: Context) -> WindowBackgroundView { WindowBackgroundView() }

    func updateNSView(_ view: WindowBackgroundView, context: Context) {
        view.color = color
    }

    final class WindowBackgroundView: NSView {
        var color: NSColor? {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        // Deferred out of the SwiftUI update and only on a real change: touching
        // the window during layout re-lays out the split view (layout loop crash).
        private func apply() {
            let color = color ?? .windowBackgroundColor
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, window.backgroundColor != color else { return }
                window.backgroundColor = color
            }
        }
    }
}

/// A native surface fill that steps aside when the theme colors the window,
/// so the theme background (set by `themedWindowBackground`) shows through.
private struct NativeSurface: ViewModifier {
    let style: AnyShapeStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isThemed = Extensions.shared.colorTheme(dark: colorScheme == .dark).editorBackground != nil
        content.background(isThemed ? AnyShapeStyle(.clear) : style)
    }
}

extension View {
    public func themedWindowBackground() -> some View {
        modifier(ThemedWindow())
    }

    public func nativeSurface(_ style: some ShapeStyle) -> some View {
        modifier(NativeSurface(style: AnyShapeStyle(style)))
    }
}

extension ThemeColor {
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    public var color: Color { Color(nsColor: nsColor) }
}

extension NSColor {
    /// Resolves to `light` or `dark` by the appearance it's drawn in.
    public static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

extension FileChangeKind {
    /// Decoration color, shared by the explorer and the Source Control panel.
    @MainActor public var color: Color {
        switch self {
        case .added, .untracked: Theme.added
        case .renamed: Theme.renamed
        case .modified: Theme.modified
        case .deleted: Theme.removed
        case .conflicted: Theme.conflict
        }
    }
}

public struct DiffStatBadge: View {
    let added: Int
    let removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }

    public var body: some View {
        HStack(spacing: 4) {
            if added > 0 { Text("+\(added)").foregroundStyle(Theme.added) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Theme.removed) }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .monospacedDigit()
    }
}

/// Small, quiet icon button used across panels.
public struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    public init(_ systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

public struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String?

    public init(_ title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
