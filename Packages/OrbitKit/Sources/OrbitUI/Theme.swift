import AppKit
import OrbitAPI
import SwiftUI

/// The app's type scale: every UI text size is one of these (D117), so
/// panels from different plugins line up. Code in the editor and terminal
/// follows the user's font size instead.
public enum TypeScale: CGFloat, Sendable {
    /// Tiny symbols beside text: disclosure chevrons, close ×, path separators.
    case glyph = 8
    /// Badges, key caps, counters, the editor's hunk buttons.
    case micro = 10
    /// Secondary details, section headers, the status bar, bars over the composer.
    case caption = 11
    /// Code shown inside the UI (diffs, search results, Markdown code), monospaced.
    case code = 11.5
    /// List rows, cards, tool calls, tabs.
    case body = 12
    /// Text fields, menus and primary rows.
    case control = 13
    /// Page titles and the palette's query.
    case title = 15
    /// The welcome screens' name.
    case display = 28
}

extension Font {
    /// A size from the type scale; `.code` is monospaced unless a design is given.
    public static func orbit(_ style: TypeScale, weight: Font.Weight = .regular, design: Font.Design? = nil) -> Font {
        .system(size: style.rawValue, weight: weight, design: design ?? (style == .code ? .monospaced : .default))
    }
}

/// Design tokens shared by all plugins so the app reads as one system.
public enum Theme {
    // Corner radii, smallest to largest (D157). A shape inside another
    // takes a smaller step, so the curves stay roughly concentric.
    /// Key caps, inline buttons, thumbnails, the rename field.
    public static let tinyCorner: CGFloat = 4
    /// Rows, tabs, toggles, fields, code blocks, the editor's bars.
    public static let smallCorner: CGFloat = 6
    /// Cards, tool calls, rows in floating panels.
    public static let corner: CGFloat = 10
    /// Big cards, popovers, chat bubbles.
    public static let largeCorner: CGFloat = 14
    /// Floating glass panels: the palette, the tab switcher, the composer.
    public static let panelCorner: CGFloat = 18

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

    // Neutral fills by state (D157); stronger means "more current".
    /// Resting cards, fields, code blocks and quiet badges.
    public static let subtleFill = Color.primary.opacity(0.045)
    /// A row or button under the pointer.
    public static let hoverFill = Color.primary.opacity(0.065)
    /// The current tab, a pressed button, a key cap.
    public static let activeFill = Color.primary.opacity(0.09)
    public static let hairline = Color.primary.opacity(0.08)

    /// The keyboard's row in a list or popover, a toggle that's on.
    @MainActor public static var selectedFill: Color { accent.opacity(0.16) }
    /// Matched text in search results.
    @MainActor public static var matchFill: Color { accent.opacity(0.25) }
    /// A drop target under a drag, with its outline.
    @MainActor public static var dropFill: Color { accent.opacity(0.1) }
    @MainActor public static var dropBorder: Color { accent.opacity(0.6) }

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
            if added > 0 {
                Text("+\(added)")
                    .foregroundStyle(Theme.added)
                    .contentTransition(.numericText(value: Double(added)))
            }
            if removed > 0 {
                Text("−\(removed)")
                    .foregroundStyle(Theme.removed)
                    .contentTransition(.numericText(value: Double(removed)))
            }
        }
        .font(.orbit(.caption, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .animation(.snappy, value: added)
        .animation(.snappy, value: removed)
    }
}

/// A small capsule label: a count, a commit hash, "Staged", a branch.
/// Gray unless tinted; `prominent` marks the current one (the checked-out branch).
public struct Badge<Label: View>: View {
    let tint: Color?
    let prominent: Bool
    let label: Label
    /// A count's value, so a change rolls the digits (D159).
    var value: Double?

    public init(tint: Color? = nil, prominent: Bool = false, @ViewBuilder label: () -> Label) {
        self.tint = tint
        self.prominent = prominent
        self.label = label()
    }

    public var body: some View {
        label
            .font(.orbit(.micro, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(value.map { .numericText(value: $0) } ?? .identity)
            .animation(.snappy, value: value)
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(fill, in: .capsule)
    }

    private var fill: Color {
        guard let tint else { return prominent ? Theme.activeFill : Theme.subtleFill }
        return tint.opacity(prominent ? 0.3 : 0.15)
    }
}

extension Badge where Label == Text {
    public init(_ text: String, tint: Color? = nil, prominent: Bool = false) {
        self.init(tint: tint, prominent: prominent) { Text(text) }
    }

    public init(count: Int, tint: Color? = nil) {
        self.init(count < 1000 ? "\(count)" : "999+", tint: tint)
        value = Double(count)
    }
}

/// The "›" that turns down when its section opens.
public struct DisclosureChevron: View {
    let isExpanded: Bool

    public init(isExpanded: Bool) {
        self.isExpanded = isExpanded
    }

    public var body: some View {
        Image(systemName: "chevron.right")
            .font(.orbit(.glyph, weight: .bold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
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
                .font(.orbit(.body, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// An empty panel: the system's own `ContentUnavailableView` (D159), so it
/// reads like Finder's and Xcode's, with optional buttons under the message.
public struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String?
    let actions: Actions

    public init(_ title: String, systemImage: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    public init(_ title: String, systemImage: String, message: String? = nil) {
        self.init(title, systemImage: systemImage, message: message) { EmptyView() }
    }
}
