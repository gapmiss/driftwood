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
        // **The level and the Space flags are fixed, and the two menu toggles
        // that used to move them were removed in 0.2.0.**
        //
        // "Always on Top" set this to `.normal` when off, which is a level no
        // window of this app can survive at. Driftwood never becomes the
        // frontmost app, so nothing ever brings the panel forward again: the
        // next window you click covers it, and there is no visible panel left to
        // click. A covered panel can still be the key window — `hidesOnDeactivate`
        // is false and nothing watches for it losing focus — so keystrokes went
        // to a terminal the user could not see.
        //
        // "Show in Full Screen" only added and removed `.fullScreenAuxiliary`,
        // while `.canJoinAllSpaces` below puts the panel on every Space
        // regardless, full-screen Spaces included. The setting toggled a flag
        // with nothing behind it. Making it real would have meant dropping
        // `.canJoinAllSpaces`, which strands the panel on the one desktop it was
        // created on — the summon hotkey would then do nothing on every *other*
        // desktop, not only in full screen.
        //
        // ⌃⌥T answers both in one press: it puts the panel away from anywhere,
        // and brings it back the same way.
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
