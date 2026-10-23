#if DEBUG
import OrbitAPI

/// The agents' part of a stress run (D244). Starting an agent runs a real CLI
/// with the user's account, so sessions stay out until a fake ACP agent
/// (phase 2); the panel, its Settings and the overview are still covered.
@MainActor
enum AgentsStress {
    static func register(_ context: PluginContext) {
        let stress = context.stress
        let reason = "starts a real agent CLI with the user's account; a fake ACP agent comes with phase 2"
        stress.exempt(StressCoverage.command("agents.new*"), because: reason)
        stress.exempt(StressCoverage.command("agents.newIsolated"), because: reason)
        stress.exempt(StressCoverage.command("agents.sendReviewComments"), because: "needs an agent session (phase 2)")
        stress.exempt(StressCoverage.command("agents.stop"), because: "needs a working agent session (phase 2)")
        stress.exempt(StressCoverage.source(.agents), because: "installs agents from the network registry")
    }
}
#endif
