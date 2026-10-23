import AppKit

// Alerts and open panels slide down from the window as sheets (D162), as
// macOS does for document windows, instead of a separate dialog in the
// middle of the screen. The caller still waits for the answer: a sheet run in
// its own modal session, so code written for runModal() works unchanged.

extension NSAlert {
    /// A sheet on the key window; a plain dialog when there's no window to hang it on.
    @MainActor
    @discardableResult
    public func runSheetModal() -> NSApplication.ModalResponse {
        if let answer = StressAnswers.alert { return answer(self) }
        guard let window = SheetHost.window else { return runModal() }
        beginSheetModal(for: window) { NSApp.stopModal(withCode: $0) }
        return NSApp.runModal(for: self.window)
    }
}

extension NSSavePanel {
    /// An open or save panel as a sheet on the key window.
    @MainActor
    public func runSheetModal() -> NSApplication.ModalResponse {
        if StressAnswers.alert != nil { return .cancel }
        guard let window = SheetHost.window else { return runModal() }
        beginSheetModal(for: window) { NSApp.stopModal(withCode: $0) }
        return NSApp.runModal(for: self)
    }
}

/// A stress run answers alerts itself, a button picked at random, and
/// cancels open and save panels (D244): their modal session would hold the
/// run's step until someone clicked, and in the background (no key window)
/// they'd be dialogs that bring Orbit to the front.
@MainActor
public enum StressAnswers {
    public static var alert: ((NSAlert) -> NSApplication.ModalResponse)?
}

@MainActor
private enum SheetHost {
    /// The window in front, unless it already shows a sheet (one sheet at a time).
    static var window: NSWindow? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible,
              window.attachedSheet == nil, window.styleMask.contains(.titled) else { return nil }
        return window
    }
}
