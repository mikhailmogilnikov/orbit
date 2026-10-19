import OrbitAPI
import OrbitUI
import SwiftUI

/// The editor's own options; the font size is shared (`Preferences`).
/// `.orbit/settings.json` wins over what's picked here (D108).
@MainActor
@Observable
final class EditorOptions {
    /// The options a settings file can set, by their key in the "editor" section.
    enum Option: String, CaseIterable {
        case wordWrap, highlightCurrentLine, formatOnSave, inlayHints, stickyScroll, pathBar, indentGuides, blame, imageThumbnails

        /// Their names in Orbit's own defaults (older than the file).
        var storageKey: String {
            switch self {
            case .wordWrap: "wrapsLines"
            case .highlightCurrentLine: "highlightsCurrentLine"
            case .formatOnSave: "formatsOnSave"
            case .inlayHints: "showsInlayHints"
            case .stickyScroll: "showsStickyScroll"
            case .pathBar: "showsBreadcrumbs"
            case .indentGuides: "showsIndentGuides"
            case .blame: "showsBlame"
            case .imageThumbnails: "showsImageThumbnails"
            }
        }

        var defaultValue: Bool { self != .wordWrap && self != .formatOnSave && self != .blame }
        var fileKey: String { "editor.\(rawValue)" }
    }

    private var chosen: [Option: Bool]
    @ObservationIgnored private let settings: PluginSettings
    @ObservationIgnored let project: ProjectSettings

    init(settings: PluginSettings, project: ProjectSettings) {
        self.settings = settings
        self.project = project
        chosen = Dictionary(uniqueKeysWithValues: Option.allCases.map { ($0, settings.bool($0.storageKey, default: $0.defaultValue)) })
    }

    subscript(option: Option) -> Bool {
        get { project.bool(option.fileKey) ?? chosen[option] ?? option.defaultValue }
        set {
            chosen[option] = newValue
            settings.set(newValue, for: option.storageKey)
        }
    }

    /// ".orbit/settings.json" when that file decides the option.
    func origin(of option: Option) -> String? {
        project.bool(option.fileKey) != nil ? project.origin(of: option.fileKey) : nil
    }

    var wrapsLines: Bool { get { self[.wordWrap] } set { self[.wordWrap] = newValue } }
    var highlightsCurrentLine: Bool { get { self[.highlightCurrentLine] } set { self[.highlightCurrentLine] = newValue } }
    var formatsOnSave: Bool { get { self[.formatOnSave] } set { self[.formatOnSave] = newValue } }
    var showsInlayHints: Bool { get { self[.inlayHints] } set { self[.inlayHints] = newValue } }
    var showsStickyScroll: Bool { get { self[.stickyScroll] } set { self[.stickyScroll] = newValue } }
    var showsBreadcrumbs: Bool { get { self[.pathBar] } set { self[.pathBar] = newValue } }
    var showsIndentGuides: Bool { get { self[.indentGuides] } set { self[.indentGuides] = newValue } }
    /// Who changed each line, beside the line numbers (D135).
    var showsBlame: Bool { get { self[.blame] } set { self[.blame] = newValue } }
    var showsImageThumbnails: Bool { get { self[.imageThumbnails] } set { self[.imageThumbnails] = newValue } }
}

/// A toggle that says so, and can't be flipped, when a settings file decides it.
struct OptionToggle<Label: View>: View {
    @Bindable var options: EditorOptions
    let option: EditorOptions.Option
    @ViewBuilder let label: () -> Label

    var body: some View {
        let origin = options.origin(of: option)
        Toggle(isOn: Binding(get: { options[option] }, set: { options[option] = $0 })) {
            label()
            if let origin {
                Text("Set by \(origin) (\"\(option.fileKey)\")")
                    .foregroundStyle(.orange)
            }
        }
        .disabled(origin != nil)
    }
}

struct EditorSettingsPane: View {
    @Bindable var options: EditorOptions
    @Bindable var preferences = Preferences.shared

    var body: some View {
        SettingsForm {
            if !options.project.problems.isEmpty {
                Section {
                    ForEach(options.project.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                LabeledContent("Size") {
                    FontSizeControl(size: $preferences.codeFontSize, reset: Preferences.defaultCodeFontSize)
                }
                Text("let orbit = \"Hello, agents\"")
                    .font(.system(size: preferences.codeFontSize, design: .monospaced))
                    .lineLimit(1)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
                Toggle("Terminal uses the same size", isOn: Binding(
                    get: { preferences.terminalFontSize == nil },
                    set: { preferences.terminalFontSize = $0 ? nil : preferences.codeFontSize }
                ))
                if let size = preferences.terminalFontSize {
                    LabeledContent("Terminal size") {
                        FontSizeControl(size: Binding(get: { size }, set: { preferences.terminalFontSize = $0 }), reset: preferences.codeFontSize)
                    }
                }
            } header: {
                Text("Font")
            } footer: {
                Text("Also used by diffs. ⌘= ⌘- ⌘0 change it from anywhere.")
            }
            Section("Text") {
                OptionToggle(options: options, option: .wordWrap) { Text("Wrap long lines") }
                OptionToggle(options: options, option: .highlightCurrentLine) { Text("Highlight the current line") }
                OptionToggle(options: options, option: .indentGuides) { Text("Indent guides") }
            }
            Section("Beside the Line Numbers") {
                OptionToggle(options: options, option: .blame) {
                    Text("Blame")
                    Text("Who changed each line and when; click one for its commit. ⌥⌘B")
                }
                OptionToggle(options: options, option: .imageThumbnails) {
                    Text("Images and colors")
                    Text("Thumbnails of images a line refers to, swatches of the colors it spells out.")
                }
            }
            Section("Reading Code") {
                OptionToggle(options: options, option: .inlayHints) {
                    Text("Inlay hints")
                    Text("Types and parameter names from the language server, drawn in the code.")
                }
                OptionToggle(options: options, option: .stickyScroll) {
                    Text("Sticky scroll")
                    Text("The class and function you're scrolling through stay pinned at the top.")
                }
                OptionToggle(options: options, option: .pathBar) {
                    Text("Path bar")
                    Text("The file's folders and the symbol at the caret, above the editor.")
                }
            }
            Section {
                OptionToggle(options: options, option: .formatOnSave) {
                    Text("Format on save")
                    Text("With the project's formatter (Prettier, Biome, Ruff…), else the language server. ⌃⇧I formats any time.")
                }
            } header: {
                Text("Saving")
            } footer: {
                Text("A project's .orbit/settings.json can set any of these: \"editor\": { \"wordWrap\": true }.")
            }
        }
    }
}

/// A slider in points, its value, and a reset.
private struct FontSizeControl: View {
    @Binding var size: Double
    let reset: Double

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $size, in: Preferences.codeFontSizes, step: 0.5)
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
