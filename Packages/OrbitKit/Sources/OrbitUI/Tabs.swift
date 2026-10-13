import SwiftUI

extension Theme {
    /// The window's top row (editor tabs, agent tabs), centered on the traffic lights.
    public static let topBarHeight: CGFloat = 42
}

/// One tab of a tab row: the editor's and the agents' look the same.
public struct TabChip<Icon: View>: View {
    let title: String
    let isActive: Bool
    /// A dot in place of the close button while not hovered (unsaved edits).
    let isDirty: Bool
    let icon: Icon
    let onSelect: () -> Void
    /// Nil for a tab that can't be closed: no close button.
    let onClose: (() -> Void)?
    @State private var isHovering = false

    public init(
        _ title: String,
        isActive: Bool,
        isDirty: Bool = false,
        onSelect: @escaping () -> Void,
        onClose: (() -> Void)?,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.isActive = isActive
        self.isDirty = isDirty
        self.icon = icon()
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 6) {
            icon
                .font(.system(size: 10.5))
            Text(title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
            ZStack {
                if let onClose, isHovering || (isActive && !isDirty) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab (⌘W)")
                } else if isDirty {
                    Circle().fill(.secondary).frame(width: 6, height: 6)
                }
            }
            .frame(width: onClose == nil && !isDirty ? 0 : 14)
        }
        .padding(.leading, 10)
        .padding(.trailing, onClose == nil && !isDirty ? 4 : 6)
        .frame(height: 26)
        .background(isActive ? AnyShapeStyle(Theme.subtleFill.opacity(2)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
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
                .font(.system(size: 13, weight: .medium))
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
