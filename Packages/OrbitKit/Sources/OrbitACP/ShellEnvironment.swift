import Foundation
import Synchronization

/// GUI apps launched from Finder/Dock don't inherit the user's shell PATH,
/// so `npx`, `node`, `claude` etc. are invisible. We ask the login shell once.
public enum ShellEnvironment {
    private static let marker = "__ORBIT_ENV_\(UUID().uuidString)__"

    /// One login shell for the whole app: every window's plugins ask (D101).
    private static let cached = Mutex<Task<[String: String], Never>?>(nil)

    public static func resolve() async -> [String: String] {
        let task = cached.withLock { cached in
            if let cached { return cached }
            let task = Task.detached(priority: .userInitiated) { load() }
            cached = task
            return task
        }
        return await task.value
    }

    private static func load() -> [String: String] {
        var fallback = ProcessInfo.processInfo.environment
        let shell = fallback["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '\(marker)'; /usr/bin/env -0; printf '\(marker)'"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return withDefaultPath(fallback) }

        // A misbehaving rc file must never hang the app: kill the shell after 5s,
        // which closes the pipe and unblocks the read below.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()

        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return withDefaultPath(fallback) }
        for entry in parts[1].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            fallback[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return withDefaultPath(fallback)
    }

    /// Variables a host agent (e.g. Orbit launched from inside Claude Code) sets
    /// for its own session. Passing them on would make our agents think they
    /// run nested inside that session.
    private static func isHostAgentVariable(_ key: String) -> Bool {
        key == "CLAUDECODE" || key == "AI_AGENT" || key.hasPrefix("CLAUDE_CODE_")
            || key.hasPrefix("CLAUDE_AGENT_SDK") || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT"
            || key == "BAGGAGE"
    }

    /// The app's own environment minus anything a host agent session leaked into it;
    /// for child login shells, which set PATH and the rest up themselves.
    public static func withoutHostAgentVariables(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let launchedByHostAgent = env["CLAUDECODE"] != nil
        var env = env.filter { !isHostAgentVariable($0.key) }
        if launchedByHostAgent {
            // The host's session credentials, not the user's own configuration.
            for key in ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL"] { env[key] = nil }
        }
        return env
    }

    private static func withDefaultPath(_ env: [String: String]) -> [String: String] {
        var env = withoutHostAgentVariables(env)
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in extras where !path.contains(extra) { path.append(extra) }
        env["PATH"] = path.joined(separator: ":")
        return env
    }
}
