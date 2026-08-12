import AppKit

/// The tab strip across the top of the panel, which doubles as the drag
/// handle.
///
/// A plain `NSView` that draws the strip itself rather than an `NSStackView`
/// of buttons, for one reason: it has to be draggable. A click that misses a
/// tab has to start a window drag, and a stack view of controls gives every
/// pixel to some control's own tracking. Drawing it here means `hitTest` and
/// `mouseDown` see the whole strip and decide what a click meant.
@MainActor
final class TabBar: NSView {
    /// Called with the index of the tab that was clicked.
    var onSelect: ((Int) -> Void)?
    /// Called with the index of the tab whose close button was clicked.
    var onClose: ((Int) -> Void)?
    /// Called when a click lands on empty strip, which drags the window.
    var onDrag: ((NSEvent) -> Void)?
    /// Called when the "+" at the right end is clicked.
    var onNewTab: (() -> Void)?

    var titles: [String] = [] { didSet { needsDisplay = true } }
    var activeIndex = 0 { didSet { needsDisplay = true } }
    var theme = TerminalTheme.driftwoodNight { didSet { needsDisplay = true } }

    private static let closeButtonSize: CGFloat = 12
    private static let horizontalInset: CGFloat = 8

    override var isFlipped: Bool { false }

    /// Tab widths share the strip evenly, minus the "+" and the reserved drag
    /// handle. The arithmetic and the four constants behind it are in
    /// `TerminalMetrics.tabWidth`, where `make check` can reach them — the
    /// invariant they carry is that a click always lands somewhere that drags
    /// the window, and this view cannot be built without a window.
    private var tabWidth: CGFloat {
        TerminalMetrics.tabWidth(inStripOfWidth: bounds.width, tabCount: titles.count)
    }

    private func tabRect(_ index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * tabWidth, y: 0, width: tabWidth, height: bounds.height)
    }

    private var newTabRect: NSRect {
        NSRect(
            x: bounds.maxX - TerminalMetrics.newTabButtonWidth, y: 0,
            width: TerminalMetrics.newTabButtonWidth, height: bounds.height
        )
    }

    private func closeRect(_ index: Int) -> NSRect {
        let tab = tabRect(index)
        let size = Self.closeButtonSize
        return NSRect(
            x: tab.maxX - size - 4,
            y: tab.midY - size / 2,
            width: size, height: size
        )
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        guard tabWidth > 0 else { return nil }
        let index = Int(point.x / tabWidth)
        return titles.indices.contains(index) ? index : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if newTabRect.contains(point) {
            onNewTab?()
            return
        }
        if let index = tabIndex(at: point) {
            // The close target is checked before the tab body, since it sits
            // inside it.
            if closeRect(index).contains(point) {
                onClose?(index)
            } else {
                onSelect?(index)
            }
            return
        }
        // A click on empty strip drags the window. This is the reason the tab
        // bar is drawn rather than assembled from controls.
        onDrag?(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = nsColor(theme.tabBarText)
        // The strip is a slightly darker wash of the panel tint rather than a
        // color of its own, so it reads as part of the window at any theme.
        nsColor(theme.background).withAlphaComponent(0.35).setFill()
        bounds.fill()

        for (index, title) in titles.enumerated() {
            let rect = tabRect(index)
            if index == activeIndex {
                text.withAlphaComponent(0.14).setFill()
                rect.fill()
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: index == activeIndex
                    ? text : text.withAlphaComponent(0.55),
            ]
            let available = rect.width - Self.horizontalInset - Self.closeButtonSize - 8
            let drawn = truncated(title, to: available, attributes: attributes)
            let size = drawn.size(withAttributes: attributes)
            drawn.draw(
                at: NSPoint(x: rect.minX + Self.horizontalInset, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )

            // A close ×, drawn as two strokes rather than set as a glyph so it
            // stays crisp at 12pt on any display scale.
            let close = closeRect(index).insetBy(dx: 3, dy: 3)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: close.minX, y: close.minY))
            path.line(to: NSPoint(x: close.maxX, y: close.maxY))
            path.move(to: NSPoint(x: close.minX, y: close.maxY))
            path.line(to: NSPoint(x: close.maxX, y: close.minY))
            path.lineWidth = 1
            text.withAlphaComponent(index == activeIndex ? 0.8 : 0.4).setStroke()
            path.stroke()
        }

        // The "+", same two-stroke treatment.
        let plus = newTabRect.insetBy(dx: 8, dy: 0)
        let plusPath = NSBezierPath()
        plusPath.move(to: NSPoint(x: plus.midX, y: plus.midY - 4))
        plusPath.line(to: NSPoint(x: plus.midX, y: plus.midY + 4))
        plusPath.move(to: NSPoint(x: plus.midX - 4, y: plus.midY))
        plusPath.line(to: NSPoint(x: plus.midX + 4, y: plus.midY))
        plusPath.lineWidth = 1
        text.withAlphaComponent(0.6).setStroke()
        plusPath.stroke()
    }

    /// Cut a title down to fit, with an ellipsis. Truncates from the *front*,
    /// keeping the tail: a tab titled with a path or a long command is told
    /// apart from its siblings by how it ends, not how it starts.
    private func truncated(
        _ title: String, to width: CGFloat, attributes: [NSAttributedString.Key: Any]
    ) -> String {
        guard width > 0 else { return "" }
        if title.size(withAttributes: attributes).width <= width { return title }
        var result = title
        while !result.isEmpty,
              ("…" + result).size(withAttributes: attributes).width > width {
            result.removeFirst()
        }
        return "…" + result
    }

    private func nsColor(_ c: TerminalTheme.RGBA) -> NSColor {
        NSColor(
            srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
            blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255
        )
    }
}
