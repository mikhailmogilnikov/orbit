import Foundation
@testable import OrbitTerminal
import Testing

@Suite struct ProjectTaskTests {
    @Test func packageScriptsKeepFileOrderAndPickTheLockfilesTool() {
        let json = #"{"name": "x", "scripts": {"dev": "vite", "build": "vite build", "lint": "eslint ."}}"#
        #expect(ProjectTasks.packageScripts(json, runner: "pnpm").map(\.command) == ["pnpm run dev", "pnpm run build", "pnpm run lint"])
        #expect(ProjectTasks.packageManager(json: json) { $0 == "yarn.lock" } == "yarn")
        #expect(ProjectTasks.packageManager(json: #"{"packageManager": "pnpm@9.1.0"}"#) { _ in false } == "pnpm")
        #expect(ProjectTasks.packageManager(json: json) { _ in false } == "npm")
    }

    @Test func makeTargetsSkipVariablesPatternsAndFiles() {
        let makefile = """
        CC := clang
        PREFIX ?= /usr/local
        .PHONY: build test
        build: deps ## Build the app
        \tswift build
        test:
        \tswift test
        %.o: %.c
        main.o: main.c
        a b: c
        build: more
        """
        let targets = ProjectTasks.makeTargets(makefile)
        #expect(targets.map(\.name) == ["build", "test"])
        #expect(targets.first?.detail == "Build the app")
    }

    @Test func customTasksInBothForms() {
        #expect(ProjectTasks.custom(#"{"tasks": {"serve": "python3 -m http.server"}}"#).map(\.command) == ["python3 -m http.server"])
        #expect(ProjectTasks.custom(#"{"tasks": [{"name": "up", "command": "docker compose up"}]}"#).map(\.name) == ["up"])
    }

    @Test func findsTasksInAProjectFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"scripts": {"dev": "next dev"}}"#.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("bun.lock"), atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.0".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let commands = ProjectTasks.find(in: root).map(\.command)
        #expect(commands == ["bun run dev", "swift build", "swift test", "swift run"])
    }
}
