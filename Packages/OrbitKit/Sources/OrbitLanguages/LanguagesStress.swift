#if DEBUG
import OrbitAPI

/// The language servers' part of a stress run (D244): servers start for the
/// project's files when installed; installing them downloads from Mason, so
/// it stays out (a fake server comes with phase 2).
@MainActor
enum LanguagesStress {
    static func register(_ context: PluginContext) {
        context.stress.exempt(StressCoverage.source(.languageServers), because: "installs servers from the network (Mason)")
    }
}
#endif
