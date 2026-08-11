import Foundation

/// The open tabs and which one is active.
///
/// Bookkeeping only: it holds sessions and an index, and knows nothing about
/// views or the panel. `AppDelegate` swaps the visible terminal view when
/// `activeIndex` changes — only the active session's view is ever in the view
/// hierarchy, so a background tab costs a running shell and no drawing.
@MainActor
final class SessionStack {
    private(set) var sessions: [TerminalSession] = []
    private(set) var activeIndex = 0

    var active: TerminalSession? {
        sessions.indices.contains(activeIndex) ? sessions[activeIndex] : nil
    }

    var count: Int { sessions.count }
    var isEmpty: Bool { sessions.isEmpty }

    /// The tab strip is hidden at one session, so the common case is an
    /// unbroken terminal with no chrome at all.
    var showsTabBar: Bool { sessions.count > 1 }

    /// Append a session and make it active. New tabs open at the end rather
    /// than beside the current one, so ⌘1…⌘9 keep pointing at the same tabs
    /// as you open more.
    func add(_ session: TerminalSession) {
        sessions.append(session)
        activeIndex = sessions.count - 1
    }

    /// Remove a session by identity. Returns whether anything was removed.
    ///
    /// The active index follows the *neighbour*, not the number: closing the
    /// tab left of the active one keeps the same tab active rather than
    /// sliding the selection sideways, which is what a bare `min(index,
    /// count-1)` would do.
    @discardableResult
    func close(id: UUID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        sessions.remove(at: index)
        if sessions.isEmpty {
            activeIndex = 0
        } else if index < activeIndex {
            activeIndex -= 1
        } else if activeIndex >= sessions.count {
            activeIndex = sessions.count - 1
        }
        return true
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        activeIndex = index
    }

    /// Move the selection by `offset`, wrapping at both ends.
    ///
    /// Wrapping here and saturating in `AppState.steppedFontSize` is not an
    /// inconsistency: cycling tabs is a round trip you take repeatedly, while
    /// a font size has a smallest and largest value that stepping past should
    /// mean "stay".
    func cycle(by offset: Int) {
        guard !sessions.isEmpty else { return }
        let count = sessions.count
        activeIndex = ((activeIndex + offset) % count + count) % count
    }

    func session(at index: Int) -> TerminalSession? {
        sessions.indices.contains(index) ? sessions[index] : nil
    }

    func removeAll() {
        sessions.removeAll()
        activeIndex = 0
    }
}
