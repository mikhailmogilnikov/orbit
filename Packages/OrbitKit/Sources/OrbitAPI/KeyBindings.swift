import Foundation
import Observation
import SwiftUI

/// The user's own keys for commands, app-wide (every window's registry reads
/// them). Only changes from the defaults are stored.
@MainActor
@Observable
public final class KeyBindings {
    public static let shared = KeyBindings()

    private static let defaultsKey = "orbit.keyBindings"
    /// Command id → key; nil removes the command's key.
    private var overrides: [String: KeyboardShortcut?]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        overrides = stored.compactMapValues { $0.isEmpty ? .some(nil) : Self.decode($0).map(Optional.some) }
    }

    /// `.some(nil)`: the user removed the key; nil: the command's default.
    public func binding(for id: String) -> KeyboardShortcut?? { overrides[id] }

    public func isCustomized(_ id: String) -> Bool { overrides[id] != nil }

    public func set(_ shortcut: KeyboardShortcut?, for id: String) {
        overrides[id] = .some(shortcut)
        save()
    }

    public func reset(_ id: String) {
        overrides[id] = nil
        save()
    }

    public func resetAll() {
        overrides = [:]
        save()
    }

    public var hasCustomizations: Bool { !overrides.isEmpty }

    private func save() {
        UserDefaults.standard.set(overrides.mapValues { $0.map(Self.encode) ?? "" }, forKey: Self.defaultsKey)
    }

    // "cmd+shift+k", "opt+up": readable in `defaults read dev.orbit.app orbit.keyBindings`.
    private static let modifierNames: [(String, EventModifiers)] = [("ctrl", .control), ("opt", .option), ("shift", .shift), ("cmd", .command)]
    private static let keyNames: [(String, KeyEquivalent)] = [
        ("up", .upArrow), ("down", .downArrow), ("left", .leftArrow), ("right", .rightArrow),
        ("return", .return), ("delete", .delete), ("tab", .tab), ("space", .space), ("escape", .escape),
        ("plus", "+"),
    ]

    static func encode(_ shortcut: KeyboardShortcut) -> String {
        let modifiers = modifierNames.filter { shortcut.modifiers.contains($0.1) }.map(\.0)
        let key = keyNames.first { $0.1 == shortcut.key }?.0 ?? String(shortcut.key.character)
        return (modifiers + [key]).joined(separator: "+")
    }

    static func decode(_ string: String) -> KeyboardShortcut? {
        var parts = string.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.popLast(), !name.isEmpty else { return nil }
        var modifiers: EventModifiers = []
        for part in parts {
            guard let modifier = modifierNames.first(where: { $0.0 == part })?.1 else { return nil }
            modifiers.insert(modifier)
        }
        if let key = keyNames.first(where: { $0.0 == name })?.1 { return KeyboardShortcut(key, modifiers: modifiers) }
        guard name.count == 1, let character = name.first else { return nil }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}

/// Keys of key presses. A layout that types Latin letters (QWERTY, Dvorak) is
/// taken as it is; another one (Russian) by key position on an ANSI keyboard,
/// so ⌘В is still ⌘D.
public enum KeyPositions {
    public static let characters: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ]

    public static let special: [UInt16: KeyEquivalent] = [
        36: .return, 48: .tab, 49: .space, 51: .delete, 53: .escape,
        123: .leftArrow, 124: .rightArrow, 125: .downArrow, 126: .upArrow,
    ]

    /// `characters`: what the key types without modifiers (`characters(byApplyingModifiers: [])`).
    public static func key(keyCode: UInt16, characters: String?) -> KeyEquivalent? {
        if let special = special[keyCode] { return special }
        if let typed = characters?.lowercased(), typed.count == 1, let character = typed.first, character.isASCII, !character.isWhitespace {
            return KeyEquivalent(character)
        }
        return self.characters[keyCode].map { KeyEquivalent($0) }
    }
}
