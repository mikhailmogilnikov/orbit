import OrbitKit
import SwiftUI

struct SettingsView: View {
    let host: PluginHost

    var body: some View {
        TabView {
            Tab("Plugins", systemImage: "puzzlepiece.extension") {
                PluginsSettings(host: host)
            }
            Tab("Agents", systemImage: "sparkles") {
                AgentsSettings()
            }
        }
        .frame(width: 560, height: 420)
    }
}

struct PluginsSettings: View {
    let host: PluginHost

    var body: some View {
        Form {
            Section {
                ForEach(host.entries) { entry in
                    Toggle(isOn: Binding(
                        get: { entry.isEnabled },
                        set: { host.setEnabled($0, pluginID: entry.id) }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.manifest.name)
                                Text(entry.manifest.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: entry.manifest.systemImage)
                        }
                    }
                }
            } footer: {
                if host.needsRestart {
                    Text("Restart Orbit to apply plugin changes.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AgentsSettings: View {
    private var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".orbit/agents", isDirectory: true)
    }

    var body: some View {
        Form {
            Section("Custom agents") {
                Text("Any ACP-compatible agent can be added with a JSON file in `~/.orbit/agents/`. No code needed.")
                    .foregroundStyle(.secondary)
                Text("""
                {
                  "id": "gemini",
                  "name": "Gemini CLI",
                  "command": { "executable": "gemini", "arguments": ["--acp"], "environment": {} }
                }
                """)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                Button("Open Agents Folder") {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(directory)
                }
            }
        }
        .formStyle(.grouped)
    }
}
