import OrbitAPI
import SwiftUI

/// Design tokens shared by all plugins so the app reads as one system.
public enum Theme {
    public static let codeFont = Font.system(size: 12, design: .monospaced)
    public static let corner: CGFloat = 10
    public static let smallCorner: CGFloat = 6

    public static let added = Color.green
    public static let removed = Color.red
    public static let addedBackground = Color.green.opacity(0.14)
    public static let removedBackground = Color.red.opacity(0.13)
    public static let addedGutter = Color.green.opacity(0.22)
    public static let removedGutter = Color.red.opacity(0.2)
    public static let modified = Color.orange

    public static let subtleFill = Color.primary.opacity(0.045)
    public static let hairline = Color.primary.opacity(0.08)
}

extension FileChangeKind {
    /// Decoration color, shared by the explorer and the Source Control panel.
    public var color: Color {
        switch self {
        case .added, .untracked: Theme.added
        case .renamed: .blue
        case .modified: Theme.modified
        case .deleted, .conflicted: Theme.removed
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
