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
        case wordWrap, highlightCurrentLine, formatOnSave, inlayHints, stickyScroll, pathBar, indentGuides, blame, imageThumbnails, autoClose
        case semanticHighlighting, codeLens, formatOnType

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
            // A new key: D135's column was off by default, the line's blame is on (D187).
            case .blame: "showsInlineBlame"
            case .imageThumbnails: "showsImageThumbnails"
            case .autoClose: "closesBrackets"
            case .semanticHighlighting: "semanticHighlighting"
            case .codeLens: "showsCodeLenses"
            case .formatOnType: "formatsOnType"
            }
        }

        var defaultValue: Bool { self != .wordWrap && self != .formatOnSave && self != .formatOnType }
        var fileKey: String { "editor.\(rawValue)" }
    }

    enum AutoSave: String, CaseIterable, Identifiable {
        case off, afterDelay, onFocusChange
        nonisolated var id: String { rawValue }

        var title: String {
            switch self {
            case .off: "Off"
            case .afterDelay: "After a Second"
            case .onFocusChange: "When Switching Away"
            }
        }
    }

    /// D180.
    var autoSave: AutoSave { didSet { settings.set(autoSave.rawValue, for: "autoSave") } }

    private var chosen: [Option: Bool]
    @ObservationIgnored private let settings: PluginSettings
    @ObservationIgnored let project: ProjectSettings
    /// For "Turn On for This Project" (D183).
    @ObservationIgnored let workspace: Workspace

    init(settings: PluginSettings, workspace: Workspace) {
        self.settings = settings
        self.workspace = workspace
        project = workspace.settings
        autoSave = settings.string("autoSave").flatMap(AutoSave.init) ?? .off
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
    var formatsOnType: Bool { get { self[.formatOnType] } set { self[.formatOnType] = newValue } }
    var showsInlayHints: Bool { get { self[.inlayHints] } set { self[.inlayHints] = newValue } }
    var showsStickyScroll: Bool { get { self[.stickyScroll] } set { self[.stickyScroll] = newValue } }
    var showsBreadcrumbs: Bool { get { self[.pathBar] } set { self[.pathBar] = newValue } }
    var showsIndentGuides: Bool { get { self[.indentGuides] } set { self[.indentGuides] = newValue } }
    /// Who last changed the caret's line, after its end (D187).
    var showsBlame: Bool { get { self[.blame] } set { self[.blame] = newValue } }
    var showsImageThumbnails: Bool { get { self[.imageThumbnails] } set { self[.imageThumbnails] = newValue } }
    var semanticHighlighting: Bool { get { self[.semanticHighlighting] } set { self[.semanticHighlighting] = newValue } }
    var showsCodeLenses: Bool { get { self[.codeLens] } set { self[.codeLens] = newValue } }
}

/// A toggle that says so, and can't be flipped, when a settings file decides it.
struct OptionToggle<Label: View>: View {
    @Bindable var options: EditorOptions
    let option: EditorOptions.Option
    @ViewBuilder let label: () -> Label

    var body: some View {
        let origin = options.origin(of: option)
        // Only the switch is disabled: the row still takes a right-click to change the project's file.
        LabeledContent {
            Toggle("", isOn: Binding(get: { options[option] }, set: { options[option] = $0 }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(origin != nil)
        } label: {
            label()
            if let origin {
                ProjectOverrideNote(key: option.fileKey, origin: origin)
            }
        }
        .contentShape(.rect)
        .projectSetting(option.fileKey, in: options.workspace)
        .settingsItem(option.rawValue)
    }
}

struct EditorSettingsPane: View {
    @Bindable var options: EditorOptions
    var hasBlame: () -> Bool = { true }
    @Bindable var preferences = Preferences.shared
    /// Listed once: asking AppKit for every family on each redraw is slow.
    @State private var families: [String] = []

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
                Picker("Family", selection: $preferences.codeFontFamily) {
                    Text("SF Mono").tag(String?.none)
                    if !families.isEmpty { Divider() }
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(Optional(family))
                    }
                }
                .settingsItem("fontFamily")
                if preferences.codeFontFamily != nil {
                    Toggle(isOn: $preferences.codeLigatures) {
                        Text("Ligatures")
                        Text("-> != => drawn as one sign, in fonts that have them (Fira Code, JetBrains Mono).")
                    }
                    .settingsItem("ligatures")
                }
                Picker("Line height", selection: $preferences.codeLineHeight) {
                    ForEach(Preferences.lineHeights, id: \.self) { height in
                        Text(height == 1 ? "Single" : height.formatted(.number.precision(.fractionLength(1)))).tag(height)
                    }
                }
                .settingsItem("lineHeight")
                LabeledContent("Size") {
                    FontSizeControl(size: $preferences.codeFontSize, reset: Preferences.defaultCodeFontSize)
                }
                .settingsItem("fontSize")
                Text("let orbit = \"Hello, agents\"")
                    .font(Font(preferences.codeFont()))
                    .lineLimit(1)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
            } header: {
                Text("Font")
            } footer: {
                Text("Also used by diffs and, unless it has its own size, the terminal. ⌘= ⌘- ⌘0 change it from anywhere.")
            }
            Section("Text") {
                OptionToggle(options: options, option: .wordWrap) { Text("Wrap long lines") }
                OptionToggle(options: options, option: .highlightCurrentLine) { Text("Highlight the current line") }
                OptionToggle(options: options, option: .indentGuides) { Text("Indent guides") }
                OptionToggle(options: options, option: .autoClose) {
                    Text("Close brackets and quotes")
                    Text("Typing ( [ { \" adds the closing one; typing it again steps over it.")
                }
            }
            Section("Beside the Line Numbers") {
                OptionToggle(options: options, option: .imageThumbnails) {
                    Text("Images and colors")
                    Text("Thumbnails of images a line refers to, swatches of the colors it spells out.")
                }
            }
            Section("Reading Code") {
                // Git Lens draws it (D194); without it there's nothing to switch.
                if hasBlame() {
                    OptionToggle(options: options, option: .blame) {
                        Text("Blame")
                        Text("Who last changed the caret's line and when, faded after its end; hover it for the commit. ⌥⌘B")
                    }
                }
                OptionToggle(options: options, option: .inlayHints) {
                    Text("Inlay hints")
                    Text("Types and parameter names from the language server, drawn in the code.")
                }
                OptionToggle(options: options, option: .semanticHighlighting) {
                    Text("Semantic highlighting")
                    Text("Types, parameters, properties and enum cases colored by what the language server knows them to be.")
                }
                OptionToggle(options: options, option: .codeLens) {
                    Text("Code lens")
                    Text("The language server's notes after a line, like “3 references” or “▶ Run”; click one to run it.")
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
                Picker(selection: $preferences.defaultIndentation.spaces) {
                    Text("Spaces").tag(true)
                    Text("Tabs").tag(false)
                } label: {
                    Text("Indent with")
                }
                .pickerStyle(.segmented)
                .settingsItem("indentation")
                Picker(preferences.defaultIndentation.spaces ? "Width" : "Tab width", selection: $preferences.defaultIndentation.size) {
                    ForEach([2, 3, 4, 8], id: \.self) { size in
                        Text("\(size) columns").tag(size)
                    }
                }
            } header: {
                Text("Indentation")
            } footer: {
                Text("For files nothing else decides: no .editorconfig and no indented lines yet. The status bar shows each file's indentation and changes it.")
            }
            Section {
                Picker(selection: $options.autoSave) {
                    ForEach(EditorOptions.AutoSave.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Auto save")
                    Text(options.autoSave == .onFocusChange
                        ? "When Orbit goes to the background or you switch tabs."
                        : "Without formatting; Format on Save still runs on ⌘S.")
                }
                .settingsItem("autoSave")
                OptionToggle(options: options, option: .formatOnSave) {
                    Text("Format on save")
                    Text("With the project's formatter (Prettier, Biome, Ruff…), else the language server. ⌃⇧I formats any time.")
                }
                OptionToggle(options: options, option: .formatOnType) {
                    Text("Format on type")
                    Text("The language server tidies the line after characters it picks, like “;”, “}” or Return.")
                }
            } header: {
                Text("Saving")
            } footer: {
                Text("A project's .orbit/settings.json can set any of these: \"editor\": { \"wordWrap\": true }.")
            }
        }
        .task { families = Preferences.monospacedFamilies }
    }
}
