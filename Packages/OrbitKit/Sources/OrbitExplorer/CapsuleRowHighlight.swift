import AppKit
import ObjectiveC

/// AppKit rings the row a context menu (or a drop) is for with a rounded
/// rectangle inset 11 pt, its own selection's shape; the explorer's selection
/// is a capsule inset 4 (D229). The ring's path comes from a private
/// NSTableView method, replaced once: tables marked here get the capsule,
/// every other table keeps AppKit's path.
@MainActor
enum CapsuleRowHighlight {
    /// The capsule's distance from the row's edges, shared with `RowHighlight`.
    static let inset = CGSize(width: 4, height: 1)

    private static let marked = NSHashTable<NSTableView>.weakObjects()
    private static var isInstalled = false

    static func apply(to table: NSTableView) {
        install()
        if !marked.contains(table) { marked.add(table) }
    }

    private static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let selector = NSSelectorFromString("_roundedHighlightPathForRow:fillingRowBackground:")
        guard let method = class_getInstanceMethod(NSTableView.self, selector) else { return }
        typealias Original = @convention(c) (NSTableView, Selector, Int, Bool) -> NSBezierPath?
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSTableView, Int, Bool) -> NSBezierPath? = { table, row, fills in
            let rect: CGRect? = MainActor.assumeIsolated {
                guard marked.contains(table), row >= 0, row < table.numberOfRows else { return nil }
                return table.rect(ofRow: row).insetBy(dx: inset.width, dy: inset.height)
            }
            guard let rect else { return original(table, selector, row, fills) }
            return NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
