import OrbitAPI
import SwiftUI

/// The editor's own options; the font size is shared (`Preferences`).
/// `.orbit/settings.json` wins over what's picked here (D108).
@MainActor
@Observable
final class EditorOptions {
    /// The options a settings file can set, by their key in the "editor" section.
    enum Option: String, CaseIterable {
        case wordWrap, highlightCurrentLine, formatOnSave, inlayHints, stickyScroll, pathBar

        /// Their names in Orbit's own defaults (older than the file).
        var storageKey: String {
            switch self {
            case .wordWrap: "wrapsLines"
            case .highlightCurrentLine: "highlightsCurrentLine"
            case .formatOnSave: "formatsOnSave"
            case .inlayHints: "showsInlayHints"
            case .stickyScroll: "showsStickyScroll"
            case .pathBar: "showsBreadcrumbs"
            }
        }

        var defaultValue: Bool { self != .wordWrap && self != .formatOnSave }
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
        Form {
            ForEach(options.project.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Section {
                LabeledContent("Font size") {
                    HStack(spacing: 8) {
                        Slider(value: $preferences.codeFontSize, in: Preferences.codeFontSizes, step: 0.5)
                            .frame(width: 180)
                        Text(preferences.codeFontSize.formatted(.number.precision(.fractionLength(0...1))) + " pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Button("Reset") { preferences.codeFontSize = Preferences.defaultCodeFontSize }
                            .disabled(preferences.codeFontSize == Preferences.defaultCodeFontSize)
                    }
                }
                Text("let orbit = \"Hello, agents\"")
                    .font(.system(size: preferences.codeFontSize, design: .monospaced))
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Font")
            } footer: {
                Text("Also used by the terminal and diffs.")
            }
            Section("Display") {
                OptionToggle(options: options, option: .wordWrap) { Text("Wrap long lines") }
                OptionToggle(options: options, option: .highlightCurrentLine) { Text("Highlight the current line") }
                OptionToggle(options: options, option: .inlayHints) {
                    Text("Show inlay hints")
                    Text("Types and parameter names from the language server, drawn in the code.")
                }
                OptionToggle(options: options, option: .stickyScroll) {
                    Text("Sticky scroll")
                    Text("The first lines of the class and function you're scrolling through stay pinned at the top.")
                }
                OptionToggle(options: options, option: .pathBar) {
                    Text("Show the path bar")
                    Text("The file's folders and the symbol at the caret above the editor; click one for its neighbors.")
                }
            }
            Section {
                OptionToggle(options: options, option: .formatOnSave) {
                    Text("Format on save")
                    Text("With the formatter the project is set up with (Prettier, Biome, Ruff…), else the language server. ⌃⇧I formats any time; Settings → Languages shows which one each file type uses.")
                }
            } footer: {
                Text("A project's .orbit/settings.json (or ~/.orbit/settings.json) can set these per project: \"editor\": { \"wordWrap\": true }. File → Open Project Settings opens it.")
            }
        }
        .formStyle(.grouped)
    }
}
