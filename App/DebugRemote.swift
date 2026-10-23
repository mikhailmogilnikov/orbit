#if DEBUG
import AppKit
import OrbitKit

/// Debug builds only: drives the app from a shell (e.g. over SSH into a VM)
/// for checking the UI on another macOS without clicking by hand. Lines
/// written to /tmp/orbit-remote-<bundle id> run in order; answers go to the
/// same path plus `-out.txt`. Off unless turned on for the machine:
/// `defaults write dev.orbit.app orbit.debugRemote -bool true`.
///
///     run <command id>        click <x> <y>   (points, key window, top-left)
///     key [cmd+][shift+]<key> type <text>     appearance system|light|dark
///     list                    windows         focus <title>   close   size <w> <h>
///     ping                    open <file>     (scripts/stress.sh, D243)
///
/// With `orbit.debugRemoteBackground` set too it stays out of the way of
/// whoever uses the Mac (D243): never activated, its windows behind the
/// others, keys and text sent to the editor without a key window. (The
/// stress script's copy is an LSUIElement too: no Dock icon, not in front at launch.)
@MainActor
final class DebugRemote {
    static let shared = DebugRemote()
    private static let inbox = "/tmp/orbit-remote-" + (Bundle.main.bundleIdentifier ?? "orbit")
    private static let outbox = inbox + "-out.txt"
    private var timer: Timer?
    private let inBackground = UserDefaults.standard.bool(forKey: "orbit.debugRemoteBackground")
    private var sentBack: Set<Int> = []

    func start() {
        guard timer == nil, UserDefaults.standard.bool(forKey: "orbit.debugRemote") else { return }
        // Often: a script waits on each answer (`make stress` sends hundreds).
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { DebugRemote.shared.poll() }
        }
        // Common modes: it also runs while an alert or a menu is up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        if inBackground { sendWindowsBack() }
        // /tmp is everyone's: only a file this user wrote is taken.
        guard let owner = (try? FileManager.default.attributesOfItem(atPath: Self.inbox))?[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let text = try? String(contentsOfFile: Self.inbox, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: Self.inbox)
        for line in text.split(separator: "\n") {
            perform(String(line).trimmingCharacters(in: .whitespaces))
        }
    }

    private var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
    }

    private func perform(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        if !inBackground, !NSApp.isActive { NSApp.activate() }
        let argument = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "ping":
            // Answered from the main run loop: a hung or looping main thread doesn't.
            write("pong")
        case "open":
            let file = URL(fileURLWithPath: argument)
            // ProjectWindows activates the app to show it.
            if inBackground, let host = ProjectWindows.shared.activeHost { host.workspace.openFile(file) } else { ProjectWindows.shared.openFile(file) }
        case "run":
            ProjectWindows.shared.activeHost?.commands.run(argument)
        case "list":
            let commands = ProjectWindows.shared.activeHost?.commands.all ?? []
            write(commands.map { "\($0.id)\t\($0.title)" }.sorted().joined(separator: "\n"))
        case "windows":
            write(NSApp.windows.map {
                "\(type(of: $0)) '\($0.title)' visible \($0.isVisible) key \($0.isKeyWindow) frame \(NSStringFromRect($0.frame)) layout \(NSStringFromRect($0.contentLayoutRect)) toolbar \($0.toolbar?.identifier ?? "none") level \($0.level.rawValue) bg \($0.backgroundColor.alphaComponent)"
            }.joined(separator: "\n") + "\n" + NSScreen.screens.map {
                "screen \(NSStringFromRect($0.frame)) visible \(NSStringFromRect($0.visibleFrame)) scale \($0.backingScaleFactor)"
            }.joined(separator: "\n"))
        case "menu":
            // "menu Orbit > About Orbit": presses a menu bar item by its titles.
            var menu = NSApp.mainMenu
            var found: NSMenuItem?
            for title in argument.components(separatedBy: " > ") {
                found = menu?.items.first { $0.title == title }
                menu = found?.submenu
            }
            guard let found, let parent = found.menu else { return write("no menu item: \(argument)") }
            parent.update()
            parent.performActionForItem(at: parent.index(of: found))
        case "focus":
            NSApp.windows.first { $0.title == argument }?.makeKeyAndOrderFront(nil)
        case "move":
            // The real pointer, in the window's points from its top-left: reveals
            // the menu bar in full screen, hovers.
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 2, let window, let screen = window.screen ?? NSScreen.main else { return }
            let global = CGPoint(x: window.frame.minX + numbers[0], y: screen.frame.maxY - (window.frame.maxY - numbers[1]))
            CGWarpMouseCursorPosition(global)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: global, mouseButton: .left)?.post(tap: .cghidEventTap)
        case "reveal":
            // Full screen's title bar strip where the menu bar would slide it.
            for strip in NSApp.windows where "\(type(of: strip))".contains("ToolbarFullScreen") {
                guard let screen = strip.screen ?? NSScreen.main else { continue }
                strip.setFrameOrigin(NSPoint(x: strip.frame.minX, y: screen.frame.maxY - strip.frame.height - (argument == "menu" ? 24 : 0)))
            }
        case "fullscreen":
            window?.toggleFullScreen(nil)
        case "close":
            window?.performClose(nil)
        case "size":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 2, let window, let screen = window.screen else { return }
            let visible = screen.visibleFrame
            let size = NSSize(width: min(numbers[0], visible.width), height: min(numbers[1], visible.height))
            window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        case "shot":
            shoot(to: argument.isEmpty ? "/tmp/orbit-shot.png" : argument)
        case "pick":
            // The view under a point (window, top-left) and everything behind it up to the window.
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 2, let window, let frameView = window.contentView?.superview else { return }
            let point = NSPoint(x: numbers[0], y: window.frame.height - numbers[1])
            var lines: [String] = []
            var view = frameView.hitTest(frameView.convert(point, from: nil))
            while let current = view {
                var line = "\(type(of: current)) opaque \(current.isOpaque) layer \(current.layer.map { "bg \(String(describing: $0.backgroundColor)) opaque \($0.isOpaque)" } ?? "none")"
                if let effect = current as? NSVisualEffectView { line += " effect material \(effect.material.rawValue) state \(effect.state.rawValue)" }
                if let scroll = current as? NSScrollView { line += " drawsBackground \(scroll.drawsBackground) bg \(scroll.backgroundColor)" }
                if let clip = current as? NSClipView { line += " drawsBackground \(clip.drawsBackground)" }
                lines.append(line)
                // Siblings drawn below this one can be the fill too.
                for sibling in current.superview?.subviews ?? [] where sibling !== current && sibling.frame.contains(current.frame.origin) {
                    lines.append("   sibling \(type(of: sibling)) layer \(sibling.layer.map { String(describing: $0.backgroundColor) } ?? "none")\((sibling as? NSVisualEffectView).map { " effect \($0.material.rawValue)" } ?? "")")
                }
                view = current.superview
            }
            write(lines.joined(separator: "\n"))
        case "views":
            // Frames of views whose class name contains the argument (window
            // coordinates, top-left); "*Name" looks in every window, not just the key one.
            let everyWindow = argument.hasPrefix("*")
            let needle = everyWindow ? String(argument.dropFirst()) : argument
            var lines: [String] = []
            func walk(_ view: NSView, _ depth: Int) {
                let name = "\(type(of: view))"
                if name.contains(needle), let window = view.window {
                    let frame = view.convert(view.bounds, to: nil)
                    var line = "\(name) x \(frame.minX) y \(window.frame.height - frame.maxY) w \(frame.width) h \(frame.height) hidden \(view.isHiddenOrHasHiddenAncestor)"
                    if let scroll = view as? NSScrollView {
                        line += " content \(NSStringFromRect(scroll.contentView.frame)) doc \(NSStringFromRect(scroll.documentView?.frame ?? .zero)) insets \(scroll.contentView.contentInsets) hScroller \(scroll.horizontalScroller?.isHidden == false) style \(scroll.scrollerStyle.rawValue)"
                    }
                    lines.append(String(repeating: " ", count: depth) + line)
                }
                for sub in view.subviews { walk(sub, depth + 1) }
            }
            let windows = everyWindow ? NSApp.windows : [window].compactMap { $0 }
            for each in windows {
                guard let root = each.contentView?.superview else { continue }
                if everyWindow { lines.append("# \(type(of: each)) \(NSStringFromRect(each.frame))") }
                walk(root, 0)
            }
            write(lines.joined(separator: "\n"))
        case "viewshot":
            // Without the window server (a locked screen draws nothing): views only, no glass.
            guard let view = window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
            write("viewshot \(argument)")
        case "display":
            let display = CGMainDisplayID()
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
            if let width = Int(argument), let mode = modes.filter({ $0.width == width }).max(by: { $0.pixelWidth < $1.pixelWidth }) {
                CGDisplaySetDisplayMode(display, mode, nil)
            }
            write(modes.map { "\($0.width)x\($0.height) px \($0.pixelWidth)x\($0.pixelHeight)" }.joined(separator: "\n"))
        case "appearance":
            Preferences.shared.appearance = Preferences.Appearance(rawValue: argument) ?? .system
        case "click", "rclick", "dclick":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 2 else { return }
            click(at: NSPoint(x: numbers[0], y: numbers[1]), right: verb == "rclick", count: verb == "dclick" ? 2 : 1)
        case "key":
            if inBackground { sendKey(argument) } else { key(argument) }
        case "type":
            if inBackground {
                (window?.firstResponder as? NSTextInputClient)?.insertText(argument, replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                for character in argument {
                    post(keyCode: 0, characters: String(character), modifiers: [])
                }
            }
        default:
            write("unknown: \(line)")
        }
    }

    /// Each new window once: behind every other app's, so it covers no one's work.
    private func sendWindowsBack() {
        for window in NSApp.windows where window.isVisible && !sentBack.contains(window.windowNumber) {
            sentBack.insert(window.windowNumber)
            window.orderBack(nil)
        }
    }

    /// Without a key window posted keys go nowhere: what they'd do, sent to the
    /// window's first responder (an editing command) or as a menu shortcut.
    private static let editingKeys: [String: Selector] = [
        "return": #selector(NSResponder.insertNewline(_:)), "tab": #selector(NSResponder.insertTab(_:)),
        "shift+tab": #selector(NSResponder.insertBacktab(_:)), "delete": #selector(NSResponder.deleteBackward(_:)),
        "esc": #selector(NSResponder.cancelOperation(_:)),
        "up": #selector(NSResponder.moveUp(_:)), "down": #selector(NSResponder.moveDown(_:)),
        "left": #selector(NSResponder.moveLeft(_:)), "right": #selector(NSResponder.moveRight(_:)),
        "shift+up": #selector(NSResponder.moveUpAndModifySelection(_:)), "shift+down": #selector(NSResponder.moveDownAndModifySelection(_:)),
        "cmd+up": #selector(NSResponder.moveToBeginningOfDocument(_:)), "cmd+down": #selector(NSResponder.moveToEndOfDocument(_:)),
        "cmd+a": #selector(NSResponder.selectAll(_:)),
    ]

    private func sendKey(_ spec: String) {
        guard let window else { return }
        let responder = window.firstResponder ?? window
        if let selector = Self.editingKeys[spec] {
            if !responder.tryToPerform(selector, with: nil) { write("not handled: \(spec)") }
            return
        }
        var modifiers: NSEvent.ModifierFlags = []
        var name = spec
        for (prefix, flag) in [("cmd+", NSEvent.ModifierFlags.command), ("shift+", .shift), ("opt+", .option), ("ctrl+", .control)] {
            while name.hasPrefix(prefix) {
                modifiers.insert(flag)
                name.removeFirst(prefix.count)
            }
        }
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let found = item.submenu.flatMap(find) { return found }
                guard item.keyEquivalent.lowercased() == name.lowercased() else { continue }
                let mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                // "Z" with ⌘ is ⇧⌘Z.
                if mask == modifiers || (item.keyEquivalent != item.keyEquivalent.lowercased() && mask.union(.shift) == modifiers) {
                    return item
                }
            }
            return nil
        }
        guard let item = NSApp.mainMenu.flatMap(find), let action = item.action else { return write("no shortcut: \(spec)") }
        item.menu?.update()
        guard item.isEnabled else { return }
        if let target = item.target {
            NSApp.sendAction(action, to: target, from: item)
        } else if !responder.tryToPerform(action, with: item) {
            write("not handled: \(spec)")
        }
    }

    private typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// The app's own windows on screen, front to back, as the window server
    /// composites them (glass included). The call is gone from the SDK but not
    /// from the system, and an app may capture its own windows without asking.
    private func shoot(to path: String) {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return write("no CGWindowListCreateImage") }
        let create = unsafeBitCast(symbol, to: WindowImage.self)
        let frames = NSApp.windows.filter(\.isVisible).map(\.frame)
        guard let screen = NSScreen.screens.first, var union = frames.first else { return }
        for frame in frames { union = union.union(frame) }
        let bounds = CGRect(x: union.minX, y: screen.frame.height - union.maxY, width: union.width, height: union.height)
        // On-screen windows, best resolution.
        guard let image = create(bounds, 1 << 0, 0, 1 << 3)?.takeRetainedValue() else {
            return write("capture failed")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        write("shot \(path) \(image.width)x\(image.height)")
    }

    private func write(_ text: String) {
        try? (text + "\n").write(toFile: Self.outbox, atomically: true, encoding: .utf8)
    }

    private func click(at topLeft: NSPoint, right: Bool, count: Int) {
        guard let window else { return }
        let point = NSPoint(x: topLeft.x, y: window.frame.height - topLeft.y)
        for click in 1...count {
            for type: NSEvent.EventType in right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: click, pressure: 1
                ) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static let keys: [String: (UInt16, String)] = [
        "esc": (53, "\u{1b}"), "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "),
        "delete": (51, "\u{7f}"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}"),
        "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), ",": (43, ","),
    ]

    private func key(_ spec: String) {
        var modifiers: NSEvent.ModifierFlags = []
        var name = spec
        for (prefix, flag) in [("cmd+", NSEvent.ModifierFlags.command), ("shift+", .shift), ("opt+", .option), ("ctrl+", .control)] {
            while name.hasPrefix(prefix) {
                modifiers.insert(flag)
                name.removeFirst(prefix.count)
            }
        }
        let (code, characters) = Self.keys[name] ?? (0, name)
        post(keyCode: code, characters: characters, modifiers: modifiers)
    }

    private func post(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
        guard let window else { return }
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
}
#endif
