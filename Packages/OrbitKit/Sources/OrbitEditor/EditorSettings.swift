import OrbitAPI
import SwiftUI

/// The editor's own options; the font size is shared (`Preferences`).
@MainActor
@Observable
final class EditorOptions {
    var wrapsLines: Bool { didSet { settings.set(wrapsLines, for: "wrapsLines") } }
    var highlightsCurrentLine: Bool { didSet { settings.set(highlightsCurrentLine, for: "highlightsCurrentLine") } }

    @ObservationIgnored private let settings: PluginSettings

    init(settings: PluginSettings) {
        self.settings = settings
        wrapsLines = settings.bool("wrapsLines")
        highlightsCurrentLine = settings.bool("highlightsCurrentLine", default: true)
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
            }
        }
        .formStyle(.grouped)
    }
}
