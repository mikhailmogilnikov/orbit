@_exported import OrbitAPI
@_exported import OrbitUI
import OrbitAgents
import OrbitEditor
import OrbitExplorer
import OrbitGit
import OrbitLanguages
import OrbitPreview
import OrbitReview
import OrbitSearch
import OrbitTerminal

public enum BuiltinPlugins {
    /// Activation order. Plugins only talk through services, so order only
    /// affects where contributions appear when they share the same `order`.
    @MainActor
    public static let all: [any OrbitPlugin.Type] = [
        ExplorerPlugin.self,
        SearchPlugin.self,
        ReviewPlugin.self,
        GitPlugin.self,
        LanguagesPlugin.self,
        EditorPlugin.self,
        PreviewPlugin.self,
        TerminalPlugin.self,
        AgentsPlugin.self,
    ]
}
