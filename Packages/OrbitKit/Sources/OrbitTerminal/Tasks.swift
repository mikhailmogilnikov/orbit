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
    /// The package it belongs to in a monorepo, relative to the project ("" for the project's own).
    var directory = ""

    var id: String { "\(source):\(name)" }
}

enum ProjectTasks {
    /// The project's own tasks, then each workspace package's scripts (D138).
    static func find(in root: URL) -> [ProjectTask] {
        var tasks = tasks(in: root)
        let json = try? String(contentsOf: root.appendingPathComponent("package.json"), encoding: .utf8)
        let pnpm = try? String(contentsOf: root.appendingPathComponent("pnpm-workspace.yaml"), encoding: .utf8)
        let patterns = workspacePatterns(packageJSON: json, pnpmWorkspace: pnpm)
        guard !patterns.isEmpty else { return tasks }
        let runner = packageManager(json: json ?? "") { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        for directory in packageDirectories(patterns, in: root) {
            guard let text = try? String(contentsOf: root.appendingPathComponent(directory).appendingPathComponent("package.json"), encoding: .utf8) else { continue }
            tasks += packageScripts(text, runner: runner).map { task in
                var task = task
                task.source = "\(directory)/package.json"
                task.directory = directory
                return task
            }
        }
        return tasks
    }

    /// npm / Yarn / Bun `workspaces` (a list, or `{"packages": […]}`) and pnpm's `packages:`.
    static func workspacePatterns(packageJSON: String?, pnpmWorkspace: String?) -> [String] {
        var patterns: [String] = []
        if let packageJSON, let object = try? JSONSerialization.jsonObject(with: Data(packageJSON.utf8)) as? [String: Any] {
            if let list = object["workspaces"] as? [String] { patterns += list }
            if let nested = object["workspaces"] as? [String: Any], let list = nested["packages"] as? [String] { patterns += list }
        }
        if let pnpmWorkspace {
            var inPackages = false
            for line in pnpmWorkspace.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("-") {
                    inPackages = trimmed.hasPrefix("packages:")
                    continue
                }
                guard inPackages, trimmed.hasPrefix("-") else { continue }
                let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if !value.isEmpty { patterns.append(value) }
            }
        }
        return patterns
    }

    /// Folders with a package.json the patterns match, relative and sorted;
    /// `*` is one folder, `**` any depth (up to four), `!` excludes.
    static func packageDirectories(_ patterns: [String], in root: URL) -> [String] {
        let manager = FileManager.default
        func children(_ relative: String) -> [String] {
            let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
            let names = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
            return names.filter { name in
                guard !name.hasPrefix("."), name != "node_modules" else { return false }
                var isDirectory: ObjCBool = false
                return manager.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .map { relative.isEmpty ? $0 : "\(relative)/\($0)" }
        }
        func expand(_ segments: ArraySlice<String>, from relative: String, depth: Int) -> [String] {
            guard let segment = segments.first else { return [relative] }
            let rest = segments.dropFirst()
            switch segment {
            case "**":
                guard depth < 4 else { return expand(rest, from: relative, depth: depth) }
                return expand(rest, from: relative, depth: depth) + children(relative).flatMap { expand(segments, from: $0, depth: depth + 1) }
            case let wildcard where wildcard.contains("*"):
                let parts = wildcard.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
                return children(relative).filter { path in
                    let name = (path as NSString).lastPathComponent
                    return name.hasPrefix(parts.first ?? "") && name.hasSuffix(parts.last ?? "")
                }
                .flatMap { expand(rest, from: $0, depth: depth) }
            default:
                return expand(rest, from: relative.isEmpty ? segment : "\(relative)/\(segment)", depth: depth)
            }
        }
        func matches(_ pattern: String) -> Set<String> {
            let segments = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init).filter { $0 != "." }
            return Set(expand(segments[...], from: "", depth: 0).filter { !$0.isEmpty })
        }
        var included = Set<String>()
        for pattern in patterns where !pattern.hasPrefix("!") { included.formUnion(matches(pattern)) }
        for pattern in patterns where pattern.hasPrefix("!") { included.subtract(matches(String(pattern.dropFirst()))) }
        return included
            .filter { manager.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("package.json").path) }
            .sorted()
    }

    /// The tasks of one folder.
    static func tasks(in root: URL) -> [ProjectTask] {
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
