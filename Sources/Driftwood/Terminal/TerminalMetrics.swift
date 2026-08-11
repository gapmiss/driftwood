import CoreGraphics
import CoreText

/// Cell sizes, content insets and the panel's minimum size.
///
/// Pure: every function here is a function of a font and a rect, so `make
/// check` can exercise it without a window. `TerminalPanel` builds the calls
/// from its own bounds and the resolved font.
enum TerminalMetrics {
    /// Inset between the panel's edge and the terminal content.
    static let padding: CGFloat = 8
    /// The tab strip's height. Also the height `contentFrame` subtracts when
    /// the strip is showing, so the two cannot disagree.
    static let tabBarHeight: CGFloat = 22
    /// How close to an edge a click counts as a resize grab. 6pt is roughly
    /// the width of the system's own window-edge target and small enough that
    /// a click meant for text selection at the edge of a line still reaches
    /// the terminal.
    static let resizeMargin: CGFloat = 6

    /// The smallest panel that still holds a usable terminal: 20 columns by 2
    /// rows, plus the padding on both axes and the tab strip if it is showing.
    ///
    /// 20 columns is not arbitrary — it is about the width at which a shell
    /// prompt plus a short command stops wrapping mid-word. Two rows is
    /// Starboard's whole window, so it is known to be usable. The panel is
    /// clamped to this during a resize drag rather than after it, so the
    /// terminal never reflows to zero columns and back.
    static func minimumPanelSize(font: CTFont, showingTabBar: Bool) -> CGSize {
        let cell = cellSize(for: font)
        return CGSize(
            width: ceil(cell.width * 20) + padding * 2,
            height: ceil(cell.height * 2) + padding * 2 + (showingTabBar ? tabBarHeight : 0)
        )
    }

    /// One character cell, at this font.
    static func cellSize(for font: CTFont) -> CGSize {
        CGSize(width: estimatedCellWidth(for: font), height: estimatedCellHeight(for: font))
    }

    /// Mirrors SwiftTerm's own internal cell-height calculation — ascent +
    /// descent + leading, at its default 1.0 line spacing — so `contentFrame`
    /// can predict SwiftTerm's row count before SwiftTerm itself lays out.
    ///
    /// **This is a coupling to a detail SwiftTerm does not publish.** Copied
    /// verbatim from Starboard, checked against SwiftTerm 1.15.0. If the
    /// terminal starts sitting a row's worth of space off from the bottom of
    /// the panel after a dependency bump, this is the line that went stale;
    /// `make check` asserts the pin in `Package.resolved` so the bump cannot
    /// happen quietly.
    static func estimatedCellHeight(for font: CTFont) -> CGFloat {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        return ceil(ascent + descent + leading)
    }

    /// Advance width of "W" in this font, which for a monospaced font is every
    /// glyph's advance. Only ever used to size the *minimum* panel, so a
    /// proportional font resolving here (possible: `NSFont(name:)` will hand
    /// back whatever is installed under that name) makes the floor a little
    /// wrong rather than making the terminal wrong.
    static func estimatedCellWidth(for font: CTFont) -> CGFloat {
        var glyph = CGGlyph()
        var character: UniChar = 0x57  // "W"
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else {
            return ceil(CTFontGetSize(font) * 0.6)
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width > 0 ? advance.width : ceil(CTFontGetSize(font) * 0.6)
    }

    /// The terminal view's frame inside the panel: padded, with the tab strip
    /// reserved off the top, and the leftover vertical slack centered.
    ///
    /// The centering is the part that matters. SwiftTerm derives its row count
    /// as `floor(height / cellHeight)`, which almost never divides an
    /// arbitrary panel height evenly. Left alone, the leftover pixels collect
    /// at the bottom and the content reads as pinned to the top of the window,
    /// which looks like a layout bug rather than like rounding. Splitting the
    /// slack puts half above and half below, where it reads as padding.
    static func contentFrame(in bounds: CGRect, font: CTFont, showingTabBar: Bool) -> CGRect {
        let reserved = showingTabBar ? tabBarHeight : 0
        let usableWidth = bounds.width - padding * 2
        let usableHeight = bounds.height - padding * 2 - reserved
        let cellHeight = estimatedCellHeight(for: font)
        let rows = max(1, Int(usableHeight / cellHeight))
        let contentHeight = CGFloat(rows) * cellHeight
        let verticalSlack = max(0, (usableHeight - contentHeight) / 2)
        return CGRect(
            x: bounds.minX + padding,
            y: bounds.minY + padding + verticalSlack,
            width: max(usableWidth, 0),
            height: max(contentHeight, 0)
        )
    }

    /// The tab strip's frame: full width, flush with the top edge.
    static func tabBarFrame(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: bounds.maxY - tabBarHeight,
            width: bounds.width,
            height: tabBarHeight
        )
    }

    /// Which edges of `bounds` a point is within grabbing distance of. Empty
    /// means the point is in the interior and the click belongs to the
    /// terminal.
    static func resizeEdges(at point: CGPoint, in bounds: CGRect) -> ResizeEdges {
        var edges: ResizeEdges = []
        guard bounds.insetBy(dx: -resizeMargin, dy: -resizeMargin).contains(point) else {
            return edges
        }
        if point.x - bounds.minX <= resizeMargin { edges.insert(.left) }
        if bounds.maxX - point.x <= resizeMargin { edges.insert(.right) }
        if point.y - bounds.minY <= resizeMargin { edges.insert(.bottom) }
        if bounds.maxY - point.y <= resizeMargin { edges.insert(.top) }
        return edges
    }

    struct ResizeEdges: OptionSet {
        let rawValue: Int
        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let bottom = ResizeEdges(rawValue: 1 << 2)
        static let top = ResizeEdges(rawValue: 1 << 3)
    }

    /// Apply a drag delta to a frame, moving only the grabbed edges and
    /// keeping the opposite ones fixed.
    ///
    /// The clamp is the reason this is a function rather than four lines at
    /// the call site. In a bottom-left origin coordinate space, dragging the
    /// *left* edge right means both moving the origin and shrinking the width,
    /// so a naive clamp on width alone lets the origin keep travelling while
    /// the width sits at its floor — the window creeps sideways under a
    /// stalled cursor. Clamping the moving edge against the fixed one instead
    /// keeps the fixed edge fixed, which is what a resize means.
    static func resized(
        _ frame: CGRect, edges: ResizeEdges, by delta: CGSize, minimum: CGSize
    ) -> CGRect {
        var minX = frame.minX
        var maxX = frame.maxX
        var minY = frame.minY
        var maxY = frame.maxY

        if edges.contains(.left) { minX = min(frame.minX + delta.width, maxX - minimum.width) }
        if edges.contains(.right) { maxX = max(frame.maxX + delta.width, minX + minimum.width) }
        if edges.contains(.bottom) { minY = min(frame.minY + delta.height, maxY - minimum.height) }
        if edges.contains(.top) { maxY = max(frame.maxY + delta.height, minY + minimum.height) }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
