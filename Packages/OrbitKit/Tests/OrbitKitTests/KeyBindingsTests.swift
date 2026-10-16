import SwiftUI
import Testing
@testable import OrbitAPI

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
