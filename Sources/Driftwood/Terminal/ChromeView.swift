import AppKit

/// A transparent view filling the panel, sitting above the terminal, that
/// claims the mouse events the window needs and lets every other one through.
///
/// `hitTest(_:)` is the whole mechanism, and the "lets through" half is the
/// part that matters. The terminal underneath needs drags for text selection,
/// so a chrome view that claimed every click would break selection entirely.
/// This one answers with itself only for a click within `resizeMargin` of an
/// edge, and answers `nil` otherwise — see the account on `hitTest` for why
/// `nil` and not `super.hitTest`.
///
/// ⌘-drag and right-click are handled differently: `hitTest` cannot see
/// modifier flags reliably (it is asked about a point, and AppKit also calls
/// it during cursor tracking with no event in flight), so those two are
/// claimed in `TerminalPanel`'s event path instead — see
/// `AppDelegate.panelShouldHandle`.
@MainActor
final class ChromeView: NSView {
    /// Called with the edges being dragged and the cursor's delta in screen
    /// coordinates, on every `mouseDragged` of a resize.
    var onResize: ((TerminalMetrics.ResizeEdges, CGSize) -> Void)?
    /// Called once when a resize drag ends, so the frame can be persisted.
    var onResizeFinished: (() -> Void)?
    /// Called on right-click anywhere, with the event to pop a menu from.
    var onContextMenu: ((NSEvent) -> Void)?
    /// Called on a ⌘-held left click, which drags the window.
    var onWindowDrag: ((NSEvent) -> Void)?

    override var isFlipped: Bool { false }

    /// Claims the click only within `resizeMargin` of an edge, when ⌘ is held,
    /// or on a right-click. Everything else falls through to the terminal,
    /// which is what keeps text selection working.
    ///
    /// The ⌘ check reads `NSEvent.modifierFlags` — the *current* keyboard
    /// state — rather than an event's own flags, because `hitTest` is not
    /// handed an event. That is accurate for a click (the modifier is still
    /// down when AppKit routes it) and is why the ⌘-drag has to be decided
    /// here rather than in `mouseDown`: by `mouseDown` the view has already
    /// been chosen, and it will have been the terminal.
    ///
    /// Right-click is claimed by inspecting `NSApp.currentEvent` for the same
    /// reason, and it has to be claimed *somewhere* — the settings menu is the
    /// whole settings surface, so a right-click that reached SwiftTerm's own
    /// menu instead would leave no way to change a theme.
    /// **Declining a click is `nil`, never `super.hitTest`.** The terminal is a
    /// *sibling* of this view, not a subview — `AppDelegate.buildPanel` adds
    /// both to the effect view, with the chrome on top. `NSView.hitTest`
    /// searches the receiver's own subviews and this view has none, so
    /// `super.hitTest` returns *self* for every point inside the bounds. That
    /// silently claimed every click in the panel: `mouseDown` found no resize
    /// edge, returned, and the terminal never saw a mouse event at all. Text
    /// selection did not work, and a selection already on screen could not be
    /// cleared by clicking, because SwiftTerm clears it from its own
    /// `mouseDown`. `nil` is what makes AppKit keep searching the siblings
    /// underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if NSApp.currentEvent?.type == .rightMouseDown { return self }
        if NSEvent.modifierFlags.contains(.command) { return self }
        if !TerminalMetrics.resizeEdges(at: local, in: bounds).isEmpty { return self }
        return nil
    }

    /// Left/right on the vertical edges, up/down on the horizontal ones, and a
    /// diagonal at each corner, so the pointer changes shape before the click
    /// rather than after it.
    ///
    /// **The corner rects have to be added last.** Two cursor rects covering
    /// the same point resolve to the one added most recently, and every corner
    /// rect sits inside an edge band. Added first, they would never be seen.
    ///
    /// Each corner takes *two* rects, not one, because the corner grab region
    /// is L-shaped rather than square — `resizeCornerMargin` along each edge by
    /// `resizeMargin` deep. One rect per arm makes the pointer agree with
    /// `TerminalMetrics.resizeEdges` exactly, so there is no band where the
    /// cursor promises a corner and the drag delivers an edge.
    override func resetCursorRects() {
        let margin = TerminalMetrics.resizeMargin
        let corner = TerminalMetrics.resizeCornerMargin
        let b = bounds
        addCursorRect(NSRect(x: b.minX, y: b.minY, width: margin, height: b.height),
                      cursor: NSCursor.resizeLeftRight)
        addCursorRect(NSRect(x: b.maxX - margin, y: b.minY, width: margin, height: b.height),
                      cursor: NSCursor.resizeLeftRight)
        addCursorRect(NSRect(x: b.minX, y: b.minY, width: b.width, height: margin),
                      cursor: NSCursor.resizeUpDown)
        addCursorRect(NSRect(x: b.minX, y: b.maxY - margin, width: b.width, height: margin),
                      cursor: NSCursor.resizeUpDown)

        let corners: [(along: NSRect, up: NSRect, corner: Corner)] = [
            (NSRect(x: b.minX, y: b.minY, width: corner, height: margin),
             NSRect(x: b.minX, y: b.minY, width: margin, height: corner), .bottomLeft),
            (NSRect(x: b.maxX - corner, y: b.minY, width: corner, height: margin),
             NSRect(x: b.maxX - margin, y: b.minY, width: margin, height: corner), .bottomRight),
            (NSRect(x: b.minX, y: b.maxY - margin, width: corner, height: margin),
             NSRect(x: b.minX, y: b.maxY - corner, width: margin, height: corner), .topLeft),
            (NSRect(x: b.maxX - corner, y: b.maxY - margin, width: corner, height: margin),
             NSRect(x: b.maxX - margin, y: b.maxY - corner, width: margin, height: corner), .topRight),
        ]
        for (along, up, which) in corners {
            let cursor = Self.cursor(for: which)
            addCursorRect(along, cursor: cursor)
            addCursorRect(up, cursor: cursor)
        }
    }

    private enum Corner { case bottomLeft, bottomRight, topLeft, topRight }

    /// The diagonal pointer for a corner, or the horizontal one where there is
    /// no diagonal to be had.
    ///
    /// macOS 15 added `NSCursor.frameResize(position:directions:)`, which is
    /// the first *public* diagonal resize cursor AppKit has ever had. Before
    /// it there were only the private `_windowResizeNorthEast…` variants, which
    /// are not API — an app that calls them can stop drawing a cursor at all on
    /// the next macOS release. Driftwood deploys to macOS 14, so 14 keeps the
    /// old approximation: the horizontal cursor, with corner *dragging* working
    /// in both axes exactly as it does on 15. Only the picture is wrong there.
    private static func cursor(for corner: Corner) -> NSCursor {
        guard #available(macOS 15.0, *) else { return .resizeLeftRight }
        switch corner {
        case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
        case .topLeft: return .frameResize(position: .topLeft, directions: .all)
        case .topRight: return .frameResize(position: .topRight, directions: .all)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onWindowDrag?(event)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        let edges = TerminalMetrics.resizeEdges(at: local, in: bounds)
        guard !edges.isEmpty else { return }
        trackResize(from: event, edges: edges)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    /// A manual tracking loop rather than `mouseDragged`/`mouseUp` callbacks.
    ///
    /// `nextEvent(matching:)` keeps the whole drag inside one call, which
    /// matters for a nonactivating panel: the alternative relies on AppKit
    /// continuing to route dragged events to this view while the app is not
    /// frontmost, and a drag that leaves the window's bounds — which every
    /// resize that grows the window does — is exactly where that stops being
    /// reliable. Screen coordinates throughout, because the view's own
    /// coordinate space is moving underneath the cursor as the window resizes.
    private func trackResize(from event: NSEvent, edges: TerminalMetrics.ResizeEdges) {
        guard let window else { return }
        var last = NSEvent.mouseLocation

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            onResize?(edges, CGSize(width: now.x - last.x, height: now.y - last.y))
            last = now
        }
        onResizeFinished?()
    }
}
