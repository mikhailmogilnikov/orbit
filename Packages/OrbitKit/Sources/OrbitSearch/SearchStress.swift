#if DEBUG
import Foundation
import OrbitAPI

/// Search's part of a stress run (D244): queries that match everywhere,
/// nowhere and oddly, with filters and the replace field.
@MainActor
enum SearchStress {
    static func register(_ context: PluginContext, model: SearchModel) {
        let queries = ["func", "item", "e", "ünïcödé", "👩‍👩‍👧", "(", "\\d+", "", "line 1", String(repeating: "x", count: 300), "INFO"]
        context.stress.add(StressStep("search.query", weight: 2) { run in
            context.ui.revealSidebarPanel("search")
            model.query = run.pick(queries) ?? "func"
            if run.chance(0.3) { model.include = run.pick(["*.swift", "src/**", "", "*.{ts,tsx}"]) ?? "" }
            if run.chance(0.2) { model.exclude = run.pick(["huge.log", "", "**/deep/**"]) ?? "" }
            if run.chance(0.2) { model.isReplaceVisible.toggle() }
        })
        context.stress.add(StressStep("search.replace", weight: 1) { run in
            context.ui.revealSidebarPanel("search")
            model.isReplaceVisible = true
            model.query = run.pick(["item", "line 1", "Ünïcödé"]) ?? "item"
            model.replacement = run.pick(["", "renamed", "👩‍👩‍👧"]) ?? ""
            try? await Task.sleep(for: .milliseconds(400))
            await run.settle()
            if model.canReplace { model.replace() }
        })
    }
}
#endif
