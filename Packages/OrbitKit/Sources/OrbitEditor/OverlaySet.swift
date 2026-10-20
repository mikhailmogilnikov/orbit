import AppKit

/// Views a plugin places over the text view, kept between viewport layouts.
/// Each pass places what it shows by key; a view whose key was placed last
/// time is reused and only moved, the rest are removed on `commit()`.
///
/// Removing and re-adding every overlay on each pass re-dirtied the text
/// view's layout, so it laid itself out again every frame: 100% CPU with an
/// agent change on screen and the whole window stuttering.
@MainActor
final class OverlaySet {
    private var views: [AnyHashable: NSView] = [:]
    private var placed: [AnyHashable: NSView] = [:]

    /// The view for `key`: made and added once, then only moved when its frame changed.
    /// The key must cover everything the view was made with.
    @discardableResult
    func place<V: NSView>(_ key: AnyHashable..., frame: CGRect, in parent: NSView, below: Bool = false, make: () -> V) -> V {
        let key = AnyHashable(key)
        if let view = placed[key] as? V { return view }
        let view: V
        if let existing = views.removeValue(forKey: key) as? V {
            view = existing
        } else {
            view = make()
            view.frame = frame
            if below {
                parent.addSubview(view, positioned: .below, relativeTo: nil)
            } else {
                parent.addSubview(view)
            }
        }
        if view.frame != frame { view.frame = frame }
        placed[key] = view
        return view
    }

    /// Removes what the pass since the last commit didn't place.
    func commit() {
        for view in views.values { view.removeFromSuperview() }
        views = placed
        placed = [:]
    }

    func removeAll() {
        for view in views.values { view.removeFromSuperview() }
        for view in placed.values { view.removeFromSuperview() }
        views = [:]
        placed = [:]
    }

    func view(for key: AnyHashable...) -> NSView? { views[AnyHashable(key)] ?? placed[AnyHashable(key)] }

    var all: Dictionary<AnyHashable, NSView>.Values { views.values }
    var isEmpty: Bool { views.isEmpty && placed.isEmpty }
}
