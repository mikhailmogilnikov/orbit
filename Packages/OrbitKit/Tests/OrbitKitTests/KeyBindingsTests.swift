import SwiftUI
import Testing
@testable import OrbitAPI
import OrbitKit

@MainActor
@Suite struct KeyBindingsTests {
    @Test func shortcutsRoundTripThroughTheirStoredNames() {
        let shortcuts = [
            KeyboardShortcut("k", modifiers: [.command, .shift]),
            KeyboardShortcut(.upArrow, modifiers: .option),
            KeyboardShortcut(.space, modifiers: .control),
            KeyboardShortcut("+", modifiers: .command),
            KeyboardShortcut("[", modifiers: [.command, .option]),
        ]
        for shortcut in shortcuts {
            #expect(KeyBindings.decode(KeyBindings.encode(shortcut)) == shortcut)
        }
        #expect(KeyBindings.encode(shortcuts[0]) == "shift+cmd+k")
        #expect(KeyBindings.decode("hyper+k") == nil)
    }

    @Test func keysComeFromTheLayoutOrTheirPosition() {
        // QWERTY / Dvorak: what the key types.
        #expect(KeyPositions.key(keyCode: 2, characters: "d") == "d")
        #expect(KeyPositions.key(keyCode: 2, characters: "e") == "e")
        // Russian: the ANSI position.
        #expect(KeyPositions.key(keyCode: 2, characters: "в") == "d")
        #expect(KeyPositions.key(keyCode: 126, characters: nil) == .upArrow)
    }

    @Test func aCommandsDefaultsStayWithoutCustomization() {
        let command = OrbitCommand(id: "test.untouched.\(UUID())", title: "T", category: "Test",
                                   shortcut: KeyboardShortcut("t", modifiers: .command)) {}
        #expect(command.shortcut == KeyboardShortcut("t", modifiers: .command))
        #expect(command.editorShortcut == nil)
    }
}

/// Two commands on one key: only the first in the menu bar ever runs.
@MainActor
@Suite struct ShortcutConflictTests {
    @Test func noTwoBuiltinCommandsShareAKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-keys-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = PluginHost(plugins: BuiltinPlugins.all, root: root)
        defer { host.shutdown() }
        try await Task.sleep(for: .milliseconds(200))
        let commands = host.commands.all
        #expect(commands.count > 50)
        var owners: [String: [String]] = [:]
        for command in commands {
            if let key = command.defaultShortcut { owners[KeyBindings.encode(key), default: []].append(command.id) }
        }
        // An editor-only key is taken by a menu item with the same key first.
        for command in commands {
            if let key = command.defaultEditorShortcut, let menu = owners[KeyBindings.encode(key)] {
                Issue.record("\(command.id)'s editor key \(KeyBindings.encode(key)) is also \(menu)")
            }
        }
        for (key, ids) in owners where ids.count > 1 {
            Issue.record("\(key): \(ids.sorted())")
        }
    }
}
