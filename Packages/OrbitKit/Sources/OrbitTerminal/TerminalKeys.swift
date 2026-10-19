import AppKit

/// The editing keys every Mac terminal has (D155), which SwiftTerm leaves out
/// while ⌥ types characters (`optionAsMetaKey` is off for accented letters):
/// sent as the readline / zsh bindings shells, Claude Code and Codex know.
enum TerminalKeys {
    enum Action: Equatable {
        case send([UInt8])
        /// ⌘K: scrollback and screen, then ⌃L so the shell redraws its prompt.
        case clear
        case scrollToTop, scrollToBottom
    }

    // Key codes, so they work in any keyboard layout.
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    static let delete: UInt16 = 51, forwardDelete: UInt16 = 117, enter: UInt16 = 36, keypadEnter: UInt16 = 76, k: UInt16 = 40

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Action? {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        switch (keyCode, modifiers) {
        case (left, .option): return .send([0x1B, 0x62])           // ESC b: word back
        case (right, .option): return .send([0x1B, 0x66])          // ESC f: word forward
        case (left, .command): return .send([0x01])                // ⌃A: line start
        case (right, .command): return .send([0x05])               // ⌃E: line end
        case (delete, .option): return .send([0x1B, 0x7F])         // ESC DEL: delete word back
        case (forwardDelete, .option): return .send([0x1B, 0x64])  // ESC d: delete word forward
        case (delete, .command): return .send([0x15])              // ⌃U: delete to line start
        case (forwardDelete, .command): return .send([0x0B])       // ⌃K: delete to line end
        case (enter, .shift), (keypadEnter, .shift), (enter, .option):
            return .send([0x1B, 0x0D])                             // ESC CR: a new line in agents' prompts
        case (k, .command): return .clear
        case (up, .command): return .scrollToTop
        case (down, .command): return .scrollToBottom
        default: return nil
        }
    }
}
