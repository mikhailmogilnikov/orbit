import Foundation

/// Something to run in the project, found in its own files (D128): package
/// scripts, Make targets, the build tool's usual commands, or a `"tasks"`
/// entry in `.orbit/settings.json`.
struct ProjectTask: Identifiable, Hashable, Sendable {
    var name: String
    var command: String
    /// Where it was found ("package.json", "Makefile", …).
    var source: String
    var detail: String?

    var id: String { "\(source):\(name)" }
}

enum ProjectTasks {
    static func find(in root: URL) -> [ProjectTask] {
        func read(_ name: String) -> String? {
            try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }
        var tasks = custom(read(".orbit/settings.json"))
        if let json = read("package.json") {
            tasks += packageScripts(json, runner: packageManager(json: json, exists: exists))
        }
        if let json = read("deno.json") ?? read("deno.jsonc") {
            tasks += orderedObject(json, key: "tasks").map {
                ProjectTask(name: $0.key, command: "deno task \($0.key)", source: "deno.json", detail: $0.value)
            }
        }
        if let json = read("composer.json") {
            tasks += orderedObject(json, key: "scripts").map {
                ProjectTask(name: $0.key, command: "composer run \($0.key)", source: "composer.json", detail: $0.value)
            }
        }
        for name in ["GNUmakefile", "makefile", "Makefile"] {
            guard let text = read(name) else { continue }
            tasks += makeTargets(text).map { ProjectTask(name: $0.name, command: "make \($0.name)", source: name, detail: $0.detail) }
            break
        }
        if exists("Package.swift") {
            tasks += ["build", "test", "run"].map { ProjectTask(name: $0, command: "swift \($0)", source: "Package.swift") }
        }
        if exists("Cargo.toml") {
            tasks += ["build", "test", "run", "check", "clippy"].map { ProjectTask(name: $0, command: "cargo \($0)", source: "Cargo.toml") }
        }
        if exists("go.mod") {
            tasks += [
                ProjectTask(name: "build", command: "go build ./...", source: "go.mod"),
                ProjectTask(name: "test", command: "go test ./...", source: "go.mod"),
                ProjectTask(name: "vet", command: "go vet ./...", source: "go.mod"),
            ]
        }
        return tasks
    }

    /// The lockfile's tool, else `packageManager` in package.json, else npm.
    static func packageManager(json: String, exists: (String) -> Bool) -> String {
        if exists("bun.lock") || exists("bun.lockb") { return "bun" }
        if exists("pnpm-lock.yaml") { return "pnpm" }
        if exists("yarn.lock") { return "yarn" }
        let declared = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["packageManager"] as? String
        if let declared, let name = declared.split(separator: "@").first, ["bun", "pnpm", "yarn"].contains(String(name)) {
            return String(name)
        }
        return "npm"
    }

    static func packageScripts(_ json: String, runner: String) -> [ProjectTask] {
        orderedObject(json, key: "scripts").map {
            ProjectTask(name: $0.key, command: "\(runner) run \($0.key)", source: "package.json", detail: $0.value)
        }
    }

    /// `"tasks": {"name": "command"}` or `[{"name": …, "command": …}]`.
    static func custom(_ json: String?) -> [ProjectTask] {
        guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        if let list = object["tasks"] as? [[String: Any]] {
            return list.compactMap { entry in
                guard let name = entry["name"] as? String, let command = entry["command"] as? String else { return nil }
                return ProjectTask(name: name, command: command, source: ".orbit/settings.json", detail: command)
            }
        }
        return orderedObject(json, key: "tasks").map {
            ProjectTask(name: $0.key, command: $0.value, source: ".orbit/settings.json", detail: $0.value)
        }
    }

    /// Target names with their `## description`, in file order: no special
    /// (`.PHONY`), pattern (`%`) or variable targets, no `:=` assignments.
    static func makeTargets(_ text: String) -> [(name: String, detail: String?)] {
        var result: [(name: String, detail: String?)] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first, first.isLetter || first.isNumber || first == "_" else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let after = line[line.index(after: colon)...]
            if after.hasPrefix("=") || after.hasPrefix(":=") { continue }
            let head = line[..<colon].trimmingCharacters(in: .whitespaces)
            // Names with a dot or slash are files to build (`main.o`, `dist/app.js`), not tasks.
            guard !head.isEmpty, !head.contains(where: { " \t%$=?+./".contains($0) }) else { continue }
            guard seen.insert(head).inserted else { continue }
            let detail = after.range(of: "##").map { after[$0.upperBound...].trimmingCharacters(in: .whitespaces) }
            result.append((head, detail?.isEmpty == false ? detail : nil))
        }
        return result
    }

    /// An object's string entries in file order (JSONSerialization loses it).
    static func orderedObject(_ json: String, key: String) -> [(key: String, value: String)] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let entries = object[key] as? [String: Any] else { return [] }
        let start = json.range(of: "\"\(key)\"")?.upperBound ?? json.startIndex
        let section = json[start...]
        func position(_ name: String) -> String.Index {
            section.range(of: "\"\(name)\"")?.lowerBound ?? json.endIndex
        }
        return entries.compactMap { name, value in
            if let value = value as? String { return (name, value) }
            // deno.json's long form: {"command": …, "description": …}.
            if let value = value as? [String: Any], let command = value["command"] as? String { return (name, command) }
            return nil
        }
        .sorted { position($0.key) < position($1.key) }
    }
}
