import SwiftUI

extension Theme {
    /// The window's top row (editor tabs, agent tabs), centered on the traffic lights.
    public static let topBarHeight: CGFloat = 42
}

/// One tab of a tab row: the editor's and the agents' look the same.
public struct TabChip<Icon: View>: View {
    let title: String
    let isActive: Bool
    /// A dot after the title (unsaved edits).
    let isDirty: Bool
    /// A preview tab's title is italic, as in VS Code (D94).
    let isPreview: Bool
    let icon: Icon
    let onSelect: () -> Void
    /// Nil for a tab that can't be closed: no close button.
    let onClose: (() -> Void)?
    @State private var isHovering = false
    @State private var isCloseHovering = false

    public init(
        _ title: String,
        isActive: Bool,
        isDirty: Bool = false,
        isPreview: Bool = false,
        onSelect: @escaping () -> Void,
        onClose: (() -> Void)?,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.isActive = isActive
        self.isDirty = isDirty
        self.isPreview = isPreview
        self.icon = icon()
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        let canClose = onClose != nil
        HStack(spacing: 6) {
            // As in Xcode 26, the icon turns into the close button under the pointer.
            ZStack {
                if let onClose, isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.orbit(.glyph, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(isCloseHovering ? Theme.activeFill : .clear, in: .circle)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .onHover { isCloseHovering = $0 }
                    .help("Close Tab (⌘W)")
                    .transition(.opacity)
                } else {
                    icon
                        .font(.orbit(.micro))
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 16, minHeight: 16)
            Text(title)
                .font(.orbit(.body, weight: isActive ? .medium : .regular))
                .italic(isPreview)
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
            if isDirty {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
        .padding(.leading, canClose ? 6 : 10)
        .padding(.trailing, 10)
        .frame(height: 26)
        .background {
            if isActive {
                // The current tab is a raised piece of glass, like Safari 26's.
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: Theme.corner, style: .continuous))
            } else if isHovering {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.hoverFill)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.snappy(duration: 0.2), value: isActive)
    }
}

/// Soft edges for a horizontally scrolling tab row.
public struct TabRowFade: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content.mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 10)
            }
        }
    }
}

/// An icon button of the top row (command palette, new chat…).
public struct TopBarButton: View {
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
                .font(.orbit(.control, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

extension View {
    /// Keeps the active tab of a scrolling tab row in view: on appear (a restored
    /// tab may be far right) and whenever another one becomes active.
    public func scrollsToActiveTab<ID: Hashable>(_ id: ID?, in proxy: ScrollViewProxy) -> some View {
        onChange(of: id, initial: true) { old, new in
            guard let new else { return }
            // A just-opened tab isn't laid out yet; scroll on the next runloop pass.
            DispatchQueue.main.async {
                if old == new {
                    proxy.scrollTo(new)
                } else {
                    withAnimation(.snappy) { proxy.scrollTo(new) }
                }
            }
        }
    }
}
