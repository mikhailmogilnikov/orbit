import Foundation
@testable import OrbitAPI
import OrbitKit
import Testing

/// Every feature is in the stress run (D244): `make stress` runs every command,
/// panel, Settings pane and plugin switch on its own, but an editor, an
/// extension source and a plugin's own behavior need its part. A feature
/// without one fails here, before anyone runs the stress.
@MainActor
@Suite(.serialized) struct StressCoverageTests {
    private func withHost(_ body: (PluginHost, URL) async throws -> Void) async throws {
        let saved = UserDefaults.standard.object(forKey: "orbit.disabledPlugins")
        UserDefaults.standard.removeObject(forKey: "orbit.disabledPlugins")
        defer { UserDefaults.standard.set(saved, forKey: "orbit.disabledPlugins") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-stress-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PluginHost(plugins: BuiltinPlugins.all, root: root)
        defer { host.shutdown() }
        try await body(host, root)
    }

    @Test func everyPluginBringsItsPart() async throws {
        try await withHost { host, _ in
            let state = host.stress.state
            var owners = Set(state.steps.compactMap(\.pluginID) + state.checks.compactMap(\.pluginID))
            owners.formUnion(state.files.compactMap(\.owner) + state.preparations.compactMap(\.owner))
            owners.formUnion(state.exemptions.values.compactMap(\.owner))
            for entry in host.entries {
                #expect(owners.contains(entry.id), "\(entry.id) has no stress steps, checks, files or exemptions (D244)")
            }
        }
    }

    @Test func everyEditorAndSourceIsReached() async throws {
        try await withHost { host, root in
            let stress = host.stress
            let covered = Set(stress.steps.flatMap(\.covers))
            let files = stress.state.files.map { root.appendingPathComponent($0.path) }
            for provider in host.ui.editorProviders where StressCoverage.exemption(for: StressCoverage.provider(provider.id), in: stress.exemptions) == nil {
                // A file of the project it shows is reached by opening it.
                let opensAFile = files.contains { provider.accepts(.file($0)) }
                #expect(covered.contains(StressCoverage.provider(provider.id)) || opensAFile,
                        "no step reaches the editor \(provider.id): a step that opens it, with it in `covers`, or an exemption")
            }
            for source in host.ui.extensionSources {
                let key = StressCoverage.source(source.kind)
                #expect(covered.contains(key) || StressCoverage.exemption(for: key, in: stress.exemptions) != nil,
                        "no step reaches the extension source \(source.kind)")
            }
        }
    }

    @Test func exemptionsSayWhyAndStillMatchSomething() async throws {
        try await withHost { host, _ in
            let keys = StressCoverage.keys(in: host)
            for (key, reason) in host.stress.exemptions {
                #expect(reason.count > 10, "the exemption \(key) needs a reason a reviewer can read")
            }
            #expect(StressCoverage.staleExemptions(host.stress.exemptions, keys: keys).isEmpty, "exemptions of features that are gone")
        }
    }

    @Test func stepsAreWellFormedAndTheRegressionsStay() async throws {
        try await withHost { host, _ in
            let steps = host.stress.steps
            #expect(Set(steps.map(\.id)).count == steps.count)
            #expect(steps.allSatisfy { $0.weight > 0 })
            // Each crash a run found is a step every run plays (D243): they don't quietly go.
            let regressions = Set(steps.filter(\.isRegression).map(\.id))
            #expect(regressions.isSuperset(of: ["editor.selectAllThenExpand"]))
        }
    }

    @Test func theProjectIsWritten() async throws {
        try await withHost { host, root in
            let project = root.appendingPathComponent("project")
            try host.stress.makeProject(at: project)
            for file in host.stress.state.files {
                #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(file.path).path), "\(file.path)")
            }
            #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(".git").path), "the project is a repository")
        }
    }
}
