import OrbitAPI
import SwiftUI

/// The editor's own options; the font size is shared (`Preferences`).
@MainActor
@Observable
final class EditorOptions {
    var wrapsLines: Bool { didSet { settings.set(wrapsLines, for: "wrapsLines") } }
    var highlightsCurrentLine: Bool { didSet { settings.set(highlightsCurrentLine, for: "highlightsCurrentLine") } }
    var formatsOnSave: Bool { didSet { settings.set(formatsOnSave, for: "formatsOnSave") } }
    var showsInlayHints: Bool { didSet { settings.set(showsInlayHints, for: "showsInlayHints") } }
    var showsStickyScroll: Bool { didSet { settings.set(showsStickyScroll, for: "showsStickyScroll") } }
    var showsBreadcrumbs: Bool { didSet { settings.set(showsBreadcrumbs, for: "showsBreadcrumbs") } }

    @ObservationIgnored private let settings: PluginSettings

    init(settings: PluginSettings) {
        self.settings = settings
        wrapsLines = settings.bool("wrapsLines")
        highlightsCurrentLine = settings.bool("highlightsCurrentLine", default: true)
        formatsOnSave = settings.bool("formatsOnSave")
        showsInlayHints = settings.bool("showsInlayHints", default: true)
        showsStickyScroll = settings.bool("showsStickyScroll", default: true)
        showsBreadcrumbs = settings.bool("showsBreadcrumbs", default: true)
    }
}

struct EditorSettingsPane: View {
    @Bindable var options: EditorOptions
    @Bindable var preferences = Preferences.shared

    var body: some View {
        Form {
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
                Toggle("Wrap long lines", isOn: $options.wrapsLines)
                Toggle("Highlight the current line", isOn: $options.highlightsCurrentLine)
                Toggle(isOn: $options.showsInlayHints) {
                    Text("Show inlay hints")
                    Text("Types and parameter names from the language server, drawn in the code.")
                }
                Toggle(isOn: $options.showsStickyScroll) {
                    Text("Sticky scroll")
                    Text("The first lines of the class and function you're scrolling through stay pinned at the top.")
                }
                Toggle(isOn: $options.showsBreadcrumbs) {
                    Text("Show the path bar")
                    Text("The file's folders and the symbol at the caret above the editor; click one for its neighbors.")
                }
            }
            Section {
                Toggle(isOn: $options.formatsOnSave) {
                    Text("Format on save")
                    Text("With the formatter the project is set up with (Prettier, Biome, Ruff…), else the language server. ⌃⇧I formats any time; Settings → Languages shows which one each file type uses.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
