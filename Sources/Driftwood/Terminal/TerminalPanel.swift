import AppKit

/// The floating terminal window.
///
/// `.nonactivatingPanel` together with `canBecomeKey` returning true is the
/// whole focus model, and it is what makes Driftwood worth having: clicking
/// the panel gives it keystrokes without making Driftwood the frontmost app,
/// so the editor behind it keeps its focus ring and its title bar stays
/// active. You summon the panel, type a command, dismiss it, and the app you
/// were working in never noticed.
///
/// `canBecomeMain` stays false, which is the other half of that. A main window
/// is the one whose app owns the menu bar; a panel that became main would drag
/// activation along with it and undo the point.
@MainActor
final class TerminalPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            // `.resizable` is in the mask because `minSize`/`maxSize` only
            // apply to a resizable window and live-resize notifications only
            // fire for one. It does **not** mean AppKit handles the resize:
            // borderless edge dragging is unreliable at the corners, so
            // `ChromeView` runs the drag itself.
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // With this on, a text-selection drag inside the terminal would move
        // the window instead of selecting text. Dragging is explicit: the tab
        // bar, or ⌘ held anywhere.
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
