import AppKit
import OrbitKit
import SwiftUI
import WebKit

/// ⌃Tab (D99): while ⌃ is held, Tab walks the open tabs from the most
/// recently shown (⇧ walks back); letting go of ⌃ shows the picked one.
@MainActor
@Observable
final class TabSwitcher {
    static let shared = TabSwitcher()

    private(set) var tabs: [EditorTab] = []
    private(set) var selected = 0
    var isShown: Bool { !tabs.isEmpty }
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var mouseMonitor: Any?
    /// The window it's shown in (D101).
    private(set) weak var workspace: Workspace?

    /// Also takes ⌃- and ⌃⇧- here: a menu shortcut with ⇧ on "-" reads as "_" and doesn't match.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let handled = MainActor.assumeIsolated { TabSwitcher.shared.handle(event) }
            return handled ? nil : event
        }
        // A mouse's side buttons go back and forward, as in Xcode and VS Code (D255).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            let handled = MainActor.assumeIsolated { TabSwitcher.shared.handleSideButton(event) }
            return handled ? nil : event
        }
    }

    private func handleSideButton(_ event: NSEvent) -> Bool {
        guard event.buttonNumber == 3 || event.buttonNumber == 4,
              let window = event.window, let workspace = ProjectWindows.shared.host(for: window)?.workspace else { return false }
        let back = event.buttonNumber == 3
        // The browser pane's own history first.
        var view = window.contentView?.hitTest(event.locationInWindow)
        while let current = view {
            if let web = current as? WKWebView, back ? web.canGoBack : web.canGoForward {
                if back { web.goBack() } else { web.goForward() }
                return true
            }
            view = current.superview
        }
        if back { workspace.goBack() } else { workspace.goForward() }
        return true
    }

    private static let tabKey: UInt16 = 48, minusKey: UInt16 = 27, escapeKey: UInt16 = 53

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Every key passes through here: only ⌃ combinations (or an open switcher) go on.
        // Its window closed while it was up.
        if isShown, workspace == nil { tabs = [] }
        guard isShown || flags.contains(.control) else { return false }
        guard let workspace = isShown ? workspace : ProjectWindows.shared.host(for: event.window)?.workspace else { return false }
        if event.type == .flagsChanged {
            if isShown, !flags.contains(.control) { commit() }
            return false
        }
        let control = flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option)
        switch event.keyCode {
        case Self.tabKey where control:
            step(flags.contains(.shift) ? -1 : 1, in: workspace)
            return true
        case Self.minusKey where control && !isShown:
            if flags.contains(.shift) { workspace.goForward() } else { workspace.goBack() }
            return true
        case Self.escapeKey where isShown:
            tabs = []
            return true
        default:
            return isShown
        }
    }

    private func step(_ offset: Int, in workspace: Workspace) {
        if !isShown {
            let recent = workspace.recentTabs
            guard recent.count > 1 else { return }
            self.workspace = workspace
            tabs = recent
            selected = 0
        }
        selected = ((selected + offset) % tabs.count + tabs.count) % tabs.count
    }

    func pick(_ index: Int) {
        selected = index
        commit()
    }

    private func commit() {
        let tab = tabs[safe: selected]
        tabs = []
        if let tab { workspace?.open(tab) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct TabSwitcherOverlay: View {
    let workspace: Workspace
    @State private var switcher = TabSwitcher.shared

    var body: some View {
        if switcher.isShown, switcher.workspace === workspace {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(switcher.tabs.prefix(12).enumerated()), id: \.element.id) { index, tab in
                    row(tab, isSelected: index == switcher.selected)
                        .onTapGesture { switcher.pick(index) }
                }
            }
            .padding(6)
            .frame(width: 440)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.panelCorner))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .transition(.opacity)
        }
    }

    private func row(_ tab: EditorTab, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if tab.kind == EditorTab.fileKind, let url = tab.url {
                    FileIconView(url: url, size: 16)
                } else {
                    Image(systemName: tab.systemImage)
                }
            }
            .frame(width: 18)
            .foregroundStyle(isSelected ? .primary : .secondary)
            Text(tab.title)
                .lineLimit(1)
                .layoutPriority(1)
            if let url = tab.url {
                Text((workspace.relativePath(url) as NSString).deletingLastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .orbitFont(.control)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Theme.selectedFill : .clear, in: .capsule)
        .contentShape(.rect)
    }
}
