#if DEBUG
import Foundation
import OrbitAPI

/// The terminal's part of a stress run (D244): commands typed into the
/// user's shell, a flood of output, and sessions opened and closed.
@MainActor
enum TerminalStress {
    static func register(_ context: PluginContext, store: TerminalStore) {
        let commands = [
            "echo stress; ls -la", "printf 'ünïcödé 👩‍👩‍👧 שלום\\n'", "seq 1 20000", "git status", "printf '\\e[31mred\\e[0m \\e[1mbold\\e[0m\\n'",
            "touch made-in-terminal.txt", "sleep 3 &", "exit",
        ]
        context.stress.add(StressStep("terminal.command", weight: 2) { run in
            if store.selected == nil || run.chance(0.2) { run.run("terminal.new") }
            await run.settle()
            if let command = run.pick(commands) { store.selected?.type(command + "\n") }
        })
        // A Makefile's targets are the project's tasks: one slow, one quick, one failing.
        context.stress.addFile("Makefile", "slow:\n\tsleep 4\nquick:\n\techo done\nfail:\n\texit 3\n")
        context.stress.add(StressStep("terminal.task", weight: 1) { run in
            // The slow one while none runs, so a run shows the running-task item.
            let tasks = ProjectTasks.find(in: run.project)
            guard let task = store.runningTasks.isEmpty ? tasks.first(where: { $0.name == "slow" }) ?? run.pick(tasks) : run.pick(tasks) else { return }
            store.run(task)
            try? await Task.sleep(for: .milliseconds(300))
        })
        context.stress.add(StressStep("terminal.interrupt", weight: 1) { run in
            if store.selected == nil { run.run("terminal.new") }
            await run.settle()
            store.selected?.type("yes stress | head -n 200000\n")
            await run.settle()
            store.selected?.interrupt()
        })
    }
}
#endif
