import OrbitAPI
import OrbitUI
import SwiftUI

/// Settings → Terminal (D178).
struct TerminalSettingsPane: View {
    @Bindable var options: TerminalOptions
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        let shells = TerminalOptions.availableShells(including: options.shell)
        SettingsForm {
            Section {
                Picker(selection: $options.shell) {
                    Text("Default (\((TerminalSession.loginShell as NSString).lastPathComponent))").tag(String?.none)
                    Divider()
                    ForEach(shells, id: \.self) { shell in
                        Text(shell).tag(Optional(shell))
                    }
                } label: {
                    Text("Shell")
                    Text("New tabs start it as a login shell, so your profile runs.")
                }
                .settingsItem("shell")
            } header: {
                Text("Shell")
            } footer: {
                Text("The list is /etc/shells; add a shell there to see it here. Agents' commands always run in your login shell.")
            }

            Section("Font") {
                Toggle(isOn: Binding(
                    get: { preferences.terminalFontSize == nil },
                    set: { preferences.terminalFontSize = $0 ? nil : preferences.codeFontSize }
                )) {
                    Text("Same size as the editor")
                    Text("\(preferences.codeFontSize.formatted(.number.precision(.fractionLength(0...1)))) pt, set in Editor.")
                }
                .settingsItem("fontSize")
                if let size = preferences.terminalFontSize {
                    LabeledContent("Size") {
                        FontSizeControl(size: Binding(get: { size }, set: { preferences.terminalFontSize = $0 }), reset: preferences.codeFontSize)
                    }
                }
            }

            Section {
                Picker("Shape", selection: $options.cursor) {
                    ForEach(TerminalOptions.Cursor.allCases) { cursor in
                        Text(cursor.title).tag(cursor)
                    }
                }
                .pickerStyle(.segmented)
                .settingsItem("cursor")
                Toggle("Blink", isOn: $options.cursorBlinks)
                    .settingsItem("cursorBlinks")
            } header: {
                Text("Cursor")
            } footer: {
                Text("Programs like Vim can change it while they run.")
            }

            Section("Keyboard and History") {
                Toggle(isOn: $options.optionAsMeta) {
                    Text("Use Option as Meta key")
                    Text("For Emacs, Vim and shell bindings like ⌥B. When off, Option types special characters (é, ©), as in Terminal. ⌥← ⌥→ ⌥⌫ move and delete by word either way.")
                }
                .settingsItem("optionAsMeta")
                Picker(selection: $options.scrollback) {
                    ForEach(TerminalOptions.scrollbackChoices, id: \.self) { lines in
                        Text("\(lines.formatted()) lines").tag(lines)
                    }
                } label: {
                    Text("Scrollback")
                    Text("How much output each tab keeps to scroll back through. ⌘K clears it.")
                }
                .settingsItem("scrollback")
            }
        }
    }
}
