import CoreGraphics

/// One display, reduced to the two rects the frame maths needs.
///
/// The geometry takes these rather than an `NSScreen` so `make check` can
/// exercise it: `TerminalPanel` is AppKit and can't join the check target, and
/// a panel restored onto a display that no longer exists is exactly the
/// failure worth having under test. `AppDelegate` builds these from
/// `NSScreen.screens` at the call site.
struct PanelScreen: Equatable {
    /// Full display bounds — what a stranded panel is tested against.
    let frame: CGRect
    /// Bounds minus menu bar and Dock — what a trusted frame is clamped to.
    let visibleFrame: CGRect

    init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Where the panel sits, and how a saved frame is made safe.
///
/// Pure: no AppKit, no window, no persisted state. Everything here is a
/// function of a rect and the screens it is told about.
enum PanelGeometry {
    static let defaultSize = CGSize(width: 720, height: 360)

    /// How much of the panel must be on some display for a saved frame to be
    /// trusted, in each axis.
    ///
    /// 80pt rather than "any overlap at all": a panel with four points showing
    /// at the edge of a screen is technically visible and practically lost,
    /// and the user would have no way to grab it back — there is no Dock icon
    /// and no window list to pick it from. 80pt is enough to see and enough to
    /// aim at.
    static let minimumVisibleExtent: CGFloat = 80

    /// Stand-in when there is no screen to ask. A display list can be empty
    /// mid-reconfiguration, and a plausible rect beats a crash or a zero rect.
    static let fallbackVisibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// Centered horizontally in the lower third of the given visible area.
    ///
    /// Low rather than centered because a terminal is a thing you glance at
    /// while working in the window behind it, and the lower third is where a
    /// Dock-adjacent panel would have been — Driftwood is not glued there any
    /// more, but that is still where the eye expects to find it on first
    /// launch.
    static func defaultFrame(size: CGSize, onVisible visible: CGRect) -> CGRect {
        CGRect(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height / 6 - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Slide a frame until it sits inside `visible`, without resizing it.
    ///
    /// Translation only: a panel that is wider than the screen keeps its width
    /// and hangs off the right, because shrinking it would silently discard a
    /// size the user chose by dragging. Clamping the origin is a rescue;
    /// resizing would be an edit.
    static func clampedFrame(_ frame: CGRect, onVisible visible: CGRect) -> CGRect {
        var clamped = frame
        clamped.origin.x += max(0, visible.minX - frame.minX)
        clamped.origin.x -= max(0, frame.maxX - visible.maxX)
        clamped.origin.y += max(0, visible.minY - frame.minY)
        clamped.origin.y -= max(0, frame.maxY - visible.maxY)
        // A frame larger than the visible area has just been pushed by both
        // corrections; the second undid the first. Pin it to the top-left
        // corner so at least the origin is reachable.
        if frame.width > visible.width { clamped.origin.x = visible.minX }
        if frame.height > visible.height { clamped.origin.y = visible.maxY - frame.height }
        return clamped
    }

    /// Grow a frame to `minimum` on either axis it falls short of, keeping the
    /// top-left corner where it is.
    ///
    /// The panel is not `.resizable` (see `TerminalPanel.init`), so `minSize`
    /// is ignored and `setFrame` enforces no floor of its own. This is that
    /// floor. It is needed when the minimum *moves* rather than when the frame
    /// does: raising the font size or showing the tab strip both raise
    /// `TerminalMetrics.minimumPanelSize` under a panel that is already on
    /// screen, and nothing else would notice.
    ///
    /// The top-left corner is the anchor because the panel's origin is its
    /// *bottom* left. Growing without moving the origin would push the panel
    /// upward, out from under the pointer that just picked a larger font.
    static func grownToMinimum(_ frame: CGRect, minimum: CGSize) -> CGRect {
        guard frame.width < minimum.width || frame.height < minimum.height else {
            return frame
        }
        let height = max(frame.height, minimum.height)
        return CGRect(
            x: frame.minX,
            y: frame.maxY - height,
            width: max(frame.width, minimum.width),
            height: height
        )
    }

    /// A saved frame is only trusted if enough of it lands on some display —
    /// displays come and go, and a frame saved on a monitor that has since
    /// been unplugged names coordinates nothing can show.
    ///
    /// Intersection is tested against `frame`, not `visibleFrame`: a panel
    /// tucked under the Dock or behind the menu bar is still on a display the
    /// user can see, and the clamp will lift it out — whereas resetting it to
    /// the default would throw away a position they chose.
    ///
    /// `mainVisible` is where the panel lands when the saved frame is
    /// untrusted or absent.
    static func validatedFrame(
        saved: CGRect?, screens: [PanelScreen], defaultSize: CGSize, mainVisible: CGRect
    ) -> CGRect {
        guard let saved, saved.width > 0, saved.height > 0 else {
            return defaultFrame(size: defaultSize, onVisible: mainVisible)
        }
        let host = screens.first { screen in
            let overlap = screen.frame.intersection(saved)
            return !overlap.isNull
                && overlap.width >= min(minimumVisibleExtent, saved.width)
                && overlap.height >= min(minimumVisibleExtent, saved.height)
        }
        guard let host else {
            return defaultFrame(size: defaultSize, onVisible: mainVisible)
        }
        return clampedFrame(saved, onVisible: host.visibleFrame)
    }
}
