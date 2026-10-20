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
    /// Activation order: a plugin after the ones it requires (D194), each
    /// right after its parent so Settings lists it under that one. Otherwise
    /// plugins only talk through services, so order only affects where
    /// contributions appear when they share the same `order`.
    @MainActor
    public static let all: [any OrbitPlugin.Type] = [
        ExplorerPlugin.self,
        SearchPlugin.self,
        ReviewPlugin.self,
        GitPlugin.self,
        GitLensPlugin.self,
        LanguagesPlugin.self,
        EditorPlugin.self,
        PreviewPlugin.self,
        BrowserPlugin.self,
        TerminalPlugin.self,
        AgentsPlugin.self,
    ]
}
