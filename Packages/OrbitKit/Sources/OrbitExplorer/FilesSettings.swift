import OrbitAPI
import OrbitUI
import SwiftUI

/// Settings → Files (D178): what the tree shows, and globs hidden everywhere.
struct FilesSettingsPane: View {
    @Bindable private var preferences = Preferences.shared
    @State private var newPattern = ""
    @FocusState private var isAdding: Bool

    var body: some View {
        SettingsForm {
            Section("File Tree") {
                Toggle(isOn: $preferences.showsHiddenFiles) {
                    Text("Show hidden files")
                    Text("Names starting with a dot, like .env and .github.")
                }
                .settingsItem("hidden")
                Toggle(isOn: $preferences.showsIgnoredFiles) {
                    Text("Show git-ignored files")
                    Text("Build output and dependencies, dimmed. Open Quickly and Find in Project skip them either way.")
                }
                .settingsItem("ignored")
            }

            Section {
                ForEach(preferences.excludedFiles, id: \.self) { pattern in
                    LabeledContent {
                        Button {
                            withAnimation(.smooth) { preferences.excludedFiles.removeAll { $0 == pattern } }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Show \(pattern) again")
                    } label: {
                        Text(pattern)
                            .orbitFont(.body, design: .monospaced)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(newPattern.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.green))
                    TextField("Add a pattern", text: $newPattern, prompt: Text("Add a pattern, like *.log or Generated/"))
                        .textFieldStyle(.plain)
                        .orbitFont(.body, design: .monospaced)
                        .labelsHidden()
                        .focused($isAdding)
                        .onSubmit(add)
                    if !newPattern.isEmpty {
                        Button("Add", action: add)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                .settingsItem("excluded")
            } header: {
                Text("Excluded Files")
            } footer: {
                Text("Hidden from the file tree, Open Quickly (⌘P) and Find in Project. *.log matches at any depth, a folder name hides everything in it, a leading / starts at the project's root; several patterns can go on one line, separated by commas.")
            }
        }
    }

    private func add() {
        let patterns = PathFilter.split(newPattern).filter { !preferences.excludedFiles.contains($0) }
        guard !patterns.isEmpty else {
            newPattern = ""
            return
        }
        withAnimation(.smooth) { preferences.excludedFiles += patterns }
        newPattern = ""
        isAdding = true
    }
}
