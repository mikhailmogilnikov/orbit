import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// The path bar above the editor (D82), Xcode's jump bar: the file's folders,
/// the file, then the symbols around the caret (`Store › subscribeSelector`).
/// A folder lists its contents, the file its top-level symbols, a symbol its
/// neighbors. Symbols are the server's outline; without one, the lines that
/// open the indented blocks around the caret.
struct PathBarBlock: Sendable {
    var range: FoldingRange
    var title: String
}

struct PathBar<Trailing: View>: View {
    let document: TextDocument
    let workspace: Workspace
    let languages: LanguageIntelligence?
    /// Plugins' buttons for the file (`EditorAction`), at the end.
    @ViewBuilder let trailing: () -> Trailing

    @State private var symbols: [LanguageSymbol] = []
    /// Without an outline: the indented blocks, each with its first line as a name.
    @State private var blocks: [Block] = []

    typealias Block = PathBarBlock

    private var url: URL { document.url }

    private var caretLine: Int? {
        guard let cursor = EditorSelectionService.shared.cursor, cursor.url.standardizedFileURL == url.standardizedFileURL else { return nil }
        return cursor.line
    }

    var body: some View {
        // Scrolls rather than widening the editor when it doesn't fit; the
        // innermost symbol (the end) stays in view.
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                items
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.leading, for: .alignment)
            .defaultScrollAnchor(.trailing, for: .initialOffset)
            .defaultScrollAnchor(.trailing, for: .sizeChanges)
            trailing()
                .padding(.trailing, 6)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        // The hairline takes the bottom point; centered in what's left, the text looked low.
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
        .nativeSurface(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .background(OutlineLoader(document: document, languages: languages, symbols: $symbols, blocks: $blocks))
    }

    private var items: some View {
        HStack(spacing: 3) {
            ForEach(Array(folders.enumerated()), id: \.offset) { index, folder in
                if index > 0 { separator }
                folderMenu(folder)
            }
            if !folders.isEmpty { separator }
            fileMenu
            ForEach(Array(chain.enumerated()), id: \.offset) { _, entry in
                separator
                entry
            }
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    // MARK: Folders and the file

    private var folders: [URL] {
        guard let root = workspace.root?.standardizedFileURL else { return [] }
        var result: [URL] = []
        var folder = url.standardizedFileURL.deletingLastPathComponent()
        while folder.path.hasPrefix(root.path), folder.path != root.path {
            result.insert(folder, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        return result
    }

    /// The folder's contents, read when clicked (not on every redraw);
    /// subfolders open as submenus, like Xcode's jump bar.
    private func folderMenu(_ folder: URL) -> some View {
        Button {
            let workspace = workspace
            FolderMenu.show(folder) { workspace.openFile($0) }
        } label: {
            Text(folder.lastPathComponent).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private var fileMenu: some View {
        let label = HStack(spacing: 4) {
            FileIconView(url: url, size: 13)
            Text(url.lastPathComponent).foregroundStyle(chain.isEmpty ? .primary : .secondary)
        }
        let topLevel = symbols.filter { $0.depth == 0 }
        if topLevel.isEmpty {
            label
        } else {
            symbolMenu(topLevel, label: label)
        }
    }

    // MARK: Symbols around the caret

    private var chain: [AnyView] {
        guard let line = caretLine else { return [] }
        if !symbols.isEmpty {
            let path = symbolPath(at: line)
            return path.enumerated().map { position, index in
                let symbol = symbols[index]
                let label = HStack(spacing: 4) {
                    Image(systemName: symbol.kind.systemImage).foregroundStyle(.secondary)
                    Text(symbol.name).foregroundStyle(position == path.count - 1 ? .primary : .secondary)
                }
                return AnyView(symbolMenu(siblings(of: index), label: label))
            }
        }
        let around = blocks.filter { $0.range.startLine < line && line <= $0.range.endLine }.suffix(4)
        return around.enumerated().map { position, block in
            AnyView(Button {
                workspace.openFile(url, line: block.range.startLine)
            } label: {
                Text(block.title).foregroundStyle(position == around.count - 1 ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .fixedSize())
        }
    }

    /// Indexes of the symbols whose extent holds the line, outermost first.
    private func symbolPath(at line: Int) -> [Int] {
        var path: [Int] = []
        for (index, symbol) in symbols.enumerated() {
            guard let extent = symbol.extent, extent.start.line <= line, line <= extent.end.line else { continue }
            // Parents come before their children: a match deeper than the last one continues the path.
            while let last = path.last, symbols[last].depth >= symbol.depth { path.removeLast() }
            path.append(index)
        }
        return path
    }

    /// The symbols beside one in the outline (same parent, same depth).
    private func siblings(of index: Int) -> [LanguageSymbol] {
        let depth = symbols[index].depth
        var start = index
        while start > 0, symbols[start - 1].depth >= depth { start -= 1 }
        var end = index
        while end + 1 < symbols.count, symbols[end + 1].depth >= depth { end += 1 }
        return symbols[start...end].filter { $0.depth == depth }
    }

    private func symbolMenu(_ items: [LanguageSymbol], label: some View) -> some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, symbol in
                Button {
                    workspace.open(symbol.location)
                } label: {
                    Label(symbol.name, systemImage: symbol.kind.systemImage)
                }
            }
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A block's first line as a name: `func run(_ x: Int) {` → `func run(_ x: Int)`.
    nonisolated static func title(of line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for suffix in ["{", ":", "(", "[", "=>"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text.count > 48 ? String(text.prefix(47)) + "…" : text
    }
}

/// Fetches the outline once typing pauses. A view of its own so the bar
/// itself doesn't redraw on every keystroke (it reads the revision, the bar doesn't).
private struct OutlineLoader: View {
    let document: TextDocument
    let languages: LanguageIntelligence?
    @Binding var symbols: [LanguageSymbol]
    @Binding var blocks: [PathBarBlock]

    private struct Refresh: Equatable {
        var revision: Int
        var server: String?
    }

    var body: some View {
        let url = document.url
        Color.clear
            .task(id: Refresh(revision: document.revision, server: languages?.server(for: url).map { "\($0.state)" })) {
                if !symbols.isEmpty || !blocks.isEmpty { try? await Task.sleep(for: .milliseconds(700)) }
                guard !Task.isCancelled else { return }
                let outline = await languages?.symbols(in: url) ?? []
                guard !Task.isCancelled else { return }
                if outline.contains(where: { $0.extent != nil }) {
                    symbols = outline
                    blocks = []
                } else {
                    let text = document.text
                    let found = await Task.detached(priority: .utility) { () -> [PathBarBlock] in
                        let string = text as NSString
                        let starts = SourcePosition.lineStarts(of: string)
                        return FoldingController.indentationRanges(in: string).map { range in
                            let line = string.lineRange(for: NSRange(location: starts[range.startLine], length: 0))
                            return PathBarBlock(range: range, title: PathBar<EmptyView>.title(of: string.substring(with: line).trimmingCharacters(in: .newlines)))
                        }
                    }.value
                    guard !Task.isCancelled else { return }
                    symbols = []
                    blocks = found
                }
            }
    }
}

/// A folder's contents at the pointer: subfolders first, each a submenu
/// filled only when it opens, so deep trees cost nothing up front.
@MainActor
private final class FolderMenu: NSObject, NSMenuDelegate {
    private let open: (URL) -> Void
    private var folders: [ObjectIdentifier: URL] = [:]

    private init(open: @escaping (URL) -> Void) { self.open = open }

    static func show(_ folder: URL, open: @escaping (URL) -> Void) {
        let controller = FolderMenu(open: open)
        let menu = controller.menu(for: folder)
        // Menus hold their delegate and targets weakly: keep it alive while open.
        withExtendedLifetime(controller) { _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }

    private func menu(for folder: URL) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        folders[ObjectIdentifier(menu)] = folder
        fill(menu, with: folder)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.isEmpty, let folder = folders[ObjectIdentifier(menu)] else { return }
        fill(menu, with: folder)
    }

    private func fill(_ menu: NSMenu, with folder: URL) {
        let entries = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [])
            .map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 : lhs.0.lastPathComponent.localizedStandardCompare(rhs.0.lastPathComponent) == .orderedAscending
            }
        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for (url, isDirectory) in entries {
            let item = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
            item.representedObject = url
            if isDirectory {
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                // Filled by menuNeedsUpdate when it opens.
                let submenu = NSMenu()
                submenu.delegate = self
                folders[ObjectIdentifier(submenu)] = url
                item.submenu = submenu
            } else {
                item.action = #selector(openFile(_:))
                item.target = self
            }
            menu.addItem(item)
        }
    }

    @objc private func openFile(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        open(url)
    }
}
