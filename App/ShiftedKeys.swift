import AppKit
import OrbitKit
import SwiftUI

/// A menu shortcut with ⇧ on a symbol key never matches: ⇧] arrives as "}",
/// ⇧` as "~". Such keys (⇧⌘], ⇧⌘[, ⌃⇧`, or one the user picked) are matched
/// here by the key itself, before the menus.
@MainActor
final class ShiftedKeys {
    static let shared = ShiftedKeys()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { ShiftedKeys.shared.handle(event) }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.contains(.shift), flags != .shift, KeyPositions.special[event.keyCode] == nil,
              let key = KeyPositions.key(keyCode: event.keyCode, characters: event.characters(byApplyingModifiers: [])),
              !key.character.isLetter,
              let commands = ProjectWindows.shared.host(for: event.window)?.commands,
              let command = commands.all.first(where: { $0.shortcut.map { Self.flags(of: $0) == flags && $0.key == key } == true })
        else { return false }
        if command.isEnabled() { command.run() } else { NSSound.beep() }
        return true
    }

    private static func flags(of shortcut: KeyboardShortcut) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}
