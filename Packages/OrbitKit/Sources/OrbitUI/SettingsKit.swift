import OrbitAPI
import SwiftUI

// Building blocks for Settings panes, so every plugin's pane looks like one
// page of System Settings (D158): a header card with the pane's tile, grouped
// sections, rows that open a page of their own, back and forward.

/// A white symbol on a colored rounded square, like System Settings' icons.
public struct SettingsTile: View {
    let systemImage: String
    let tint: Color
    let size: CGFloat

    public init(_ systemImage: String, tint: Color, size: CGFloat = 20) {
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: systemImage)
                    // Sized from the tile like a glyph in an app icon, not UI text.
                    .font(.system(size: size * 0.54, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.monochrome)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// What the shell tells a pane about itself, for its header card.
public struct SettingsPaneInfo: Sendable {
    public let title: String
    public let systemImage: String
    public let tint: Color
    public let summary: String?

    public init(title: String, systemImage: String, tint: Color, summary: String?) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.summary = summary
    }
}

extension EnvironmentValues {
    /// Set on a pane's first page only; pages opened from it have no header card.
    @Entry public var settingsPaneInfo: SettingsPaneInfo?
}

/// Where Settings is: the pane, the pages opened inside it, and the history
/// the back and forward buttons walk.
@MainActor
@Observable
public final class SettingsNavigator {
    public struct Page: Identifiable {
        public let id = UUID()
        public let title: String
        let view: AnyView
    }

    struct Location {
        var pane: String
        var pages: [Page] = []
    }

    private var history: [Location] = []
    private var index = -1

    public init() {}

    private var location: Location? { history.indices.contains(index) ? history[index] : nil }
    public var pane: String? { location?.pane }
    public var page: Page? { location?.pages.last }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < history.count - 1 }

    public var pageView: AnyView? { page?.view }

    /// A pane's first page; nothing happens when it's already showing.
    public func show(_ pane: String) {
        guard location?.pane != pane || location?.pages.isEmpty == false else { return }
        go(to: Location(pane: pane))
    }

    /// A page inside the current pane (a row's "›").
    public func push<V: View>(_ title: String, @ViewBuilder _ view: () -> V) {
        guard var next = location else { return }
        next.pages.append(Page(title: title, view: AnyView(view())))
        go(to: next)
    }

    public func back() { if canGoBack { index -= 1 } }
    public func forward() { if canGoForward { index += 1 } }

    private func go(to location: Location) {
        history.removeSubrange((index + 1)...)
        history.append(location)
        // Enough to walk back through a visit, not a log of every click.
        if history.count > 50 { history.removeFirst(history.count - 50) }
        index = history.count - 1
    }
}

/// A pane's page: the header card (on its first page), then its sections.
public struct SettingsForm<Content: View>: View {
    @Environment(\.settingsPaneInfo) private var info
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        Form {
            if let info {
                Section {
                    SettingsHeaderCard(info: info)
                }
            }
            content
        }
        .formStyle(.grouped)
    }
}

/// The pane's tile, name and what it's for, as the first card of the page.
struct SettingsHeaderCard: View {
    let info: SettingsPaneInfo

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsTile(info.systemImage, tint: info.tint, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.orbit(.control, weight: .semibold))
                if let summary = info.summary {
                    Text(summary)
                        .font(.orbit(.body))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// A row with a small tile in front, as in System Settings' lists.
public struct SettingsLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color

    public init(_ title: String, subtitle: String? = nil, systemImage: String, tint: Color) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 10) {
            SettingsTile(systemImage, tint: tint, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.orbit(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A row that opens a page of its own ("›"), with Back to return.
public struct SettingsLink<Label: View, Destination: View>: View {
    @Environment(SettingsNavigator.self) private var navigator: SettingsNavigator?
    let title: String
    let label: Label
    let trailing: String?
    let destination: () -> Destination

    /// `title` names the page in the top bar; `trailing` is a quiet value before the "›" ("3 installed").
    public init(_ title: String, trailing: String? = nil, @ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: () -> Label) {
        self.title = title
        self.trailing = trailing
        self.destination = destination
        self.label = label()
    }

    public var body: some View {
        Button {
            navigator?.push(title, destination)
        } label: {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.orbit(.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

extension SettingsLink where Label == Text {
    public init(_ title: String, trailing: String? = nil, @ViewBuilder destination: @escaping () -> Destination) {
        self.init(title, trailing: trailing, destination: destination) { Text(title) }
    }
}

/// A filter row at the top of a long list (shortcuts, the agent registry).
public struct SettingsSearchField: View {
    @Binding var text: String
    let prompt: String

    public init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .labelsHidden()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
    }
}
