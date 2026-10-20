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

    /// An option search pointed at: its row scrolls into view and lights up (D177).
    public struct Highlight: Equatable {
        public let item: String
        let token = UUID()
    }

    private var history: [Location] = []
    private var index = -1
    public private(set) var highlight: Highlight?

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

    /// The pane's first page, with one of its options pointed out.
    public func reveal(_ item: String, in pane: String) {
        show(pane)
        highlight = Highlight(item: item)
    }

    public func back() {
        guard canGoBack else { return }
        highlight = nil
        index -= 1
    }

    public func forward() {
        guard canGoForward else { return }
        highlight = nil
        index += 1
    }

    private func go(to location: Location) {
        highlight = nil
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
    @Environment(SettingsNavigator.self) private var navigator: SettingsNavigator?
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollViewReader { proxy in
            Form {
                if let info {
                    Section {
                        SettingsHeaderCard(info: info)
                    }
                }
                content
            }
            .formStyle(.grouped)
            .task(id: navigator?.highlight) {
                guard let item = navigator?.highlight?.item else { return }
                // A pane that just opened has no rows to scroll to before its first layout.
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.smooth) { proxy.scrollTo(SettingsItemMarker.scrollID(item), anchor: .center) }
            }
        }
    }
}

extension View {
    /// Marks a row as the option `id` of the pane's `SettingsItem`s, so
    /// search can scroll to it and light it up (D177).
    public func settingsItem(_ id: String) -> some View {
        modifier(SettingsItemMarker(id: id))
    }
}

/// Lights up like System Settings' found option: two quick pulses, then a fade.
struct SettingsItemMarker: ViewModifier {
    let id: String
    @Environment(SettingsNavigator.self) private var navigator: SettingsNavigator?
    @State private var isLit = false

    static func scrollID(_ item: String) -> String { "settings.item.\(item)" }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
                    .fill(Theme.matchFill)
                    // Out to the row's edges: the form insets its content.
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
                    .opacity(isLit ? 1 : 0)
            }
            .id(Self.scrollID(id))
            .task(id: navigator?.highlight) {
                guard navigator?.highlight?.item == id else {
                    isLit = false
                    return
                }
                // After the scroll has brought the row in.
                try? await Task.sleep(for: .milliseconds(280))
                for hold in [0.35, 1.4] {
                    withAnimation(.easeOut(duration: 0.18)) { isLit = true }
                    try? await Task.sleep(for: .seconds(hold))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: hold > 1 ? 0.7 : 0.25)) { isLit = false }
                    try? await Task.sleep(for: .seconds(0.3))
                    guard !Task.isCancelled else { return }
                }
            }
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
                    .orbitFont(.control, weight: .semibold)
                if let summary = info.summary {
                    Text(summary)
                        .orbitFont(.body)
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
                        .orbitFont(.caption)
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
                    .orbitFont(.caption, weight: .semibold)
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

/// A slider in points, its value, and a reset.
public struct FontSizeControl: View {
    @Binding var size: Double
    let reset: Double
    let range: ClosedRange<Double>

    public init(size: Binding<Double>, reset: Double, range: ClosedRange<Double> = Preferences.codeFontSizes) {
        _size = size
        self.reset = reset
        self.range = range
    }

    public var body: some View {
        HStack(spacing: 10) {
            Slider(value: $size, in: range, step: 0.5)
                .frame(width: 160)
            Text(size.formatted(.number.precision(.fractionLength(0...1))) + " pt")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 48, alignment: .trailing)
            Button {
                size = reset
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(size == reset)
            .help("Reset to \(reset.formatted(.number.precision(.fractionLength(0...1)))) pt")
        }
    }
}

/// Under an option a project's settings file decides (D179): a "Project" badge
/// and the key, so it reads as overridden rather than broken.
public struct ProjectOverrideNote: View {
    let key: String
    let origin: String

    public init(key: String, origin: String) {
        self.key = key
        self.origin = origin
    }

    public var body: some View {
        HStack(spacing: 5) {
            Badge("Project", tint: .orange)
            Text("\"\(key)\" in \(origin)")
                .orbitFont(.caption, design: .monospaced)
                .foregroundStyle(.secondary)
        }
        .help(origin == ProjectSettings.projectPath
            ? "This project's \(origin) sets it. Right-click to remove it from the project."
            : "\(origin) sets it for every project. Right-click to set it for this project instead.")
    }
}

extension View {
    /// Right-click sets the option for this project in `.orbit/settings.json`,
    /// or takes it out of the file again (D183).
    public func projectSetting(_ key: String, in workspace: Workspace, choices: [(title: String, value: ProjectSettings.Value)]) -> some View {
        contextMenu {
            if workspace.root != nil {
                if workspace.settings.projectSets(key) {
                    Button("Remove from This Project") { ProjectSettingWriter.write(key, nil, in: workspace) }
                } else {
                    ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                        Button("\(choice.title) for This Project") { ProjectSettingWriter.write(key, choice.value, in: workspace) }
                    }
                }
            }
        }
    }

    /// A switch's "Turn On / Turn Off for This Project".
    public func projectSetting(_ key: String, in workspace: Workspace) -> some View {
        projectSetting(key, in: workspace, choices: [("Turn On", .bool(true)), ("Turn Off", .bool(false))])
    }
}

@MainActor
public enum ProjectSettingWriter {
    public static func write(_ key: String, _ value: ProjectSettings.Value?, in workspace: Workspace) {
        do {
            try workspace.setProjectSetting(key, value)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change \(ProjectSettings.projectPath)"
            alert.informativeText = error.localizedDescription
            _ = alert.runSheetModal()
        }
    }
}
