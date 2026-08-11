// Draws Resources/AppIcon.icns. Run it with `make icon`, not by hand.
//
// The icon is a checked-in binary, and a checked-in binary nobody can
// regenerate is a binary nobody dares change. This script is the source it
// was generated from. Nothing in the app builds against it; it lives outside
// `Sources/Driftwood`, which is the only path the SPM target reads.
//
// Every shape is drawn from a Bézier path rather than set in a font, so the
// icon needs no font installed and renders identically at 16pt and 1024pt.
//
// Usage: swift Tools/make-icon.swift <output.iconset directory>

import AppKit

// Straight out of `TerminalTheme.driftwoodNight`. If that palette changes,
// these four lines are what keeps the icon in step with it — they are copies,
// not references, because this file cannot import the app target.
let panel = NSColor(srgbRed: 20 / 255, green: 24 / 255, blue: 33 / 255, alpha: 1)
let seafoam = NSColor(srgbRed: 114 / 255, green: 214 / 255, blue: 207 / 255, alpha: 1)
let sand = NSColor(srgbRed: 196 / 255, green: 190 / 255, blue: 172 / 255, alpha: 1)
let slate = NSColor(srgbRed: 75 / 255, green: 87 / 255, blue: 99 / 255, alpha: 1)

/// Renders one square PNG. Every coordinate below is expressed in 1024ths of
/// the side, so a single set of numbers describes all ten sizes.
func render(_ side: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let u = side / 1024

    // Apple's icon grid: the body fills 824 of the 1024, centred, leaving the
    // margin the system expects. Drawing edge to edge makes the icon look
    // oversized next to every other app in the Dock and in Finder.
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)

    panel.setFill()
    shape.fill()

    // A hairline rim, so the shape reads as a floating panel rather than as a
    // flat tile once it is sitting on a dark wallpaper.
    slate.withAlphaComponent(0.55).setStroke()
    shape.lineWidth = 4 * u
    shape.stroke()

    // The prompt chevron.
    let chevron = NSBezierPath()
    chevron.lineWidth = 54 * u
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: 320 * u, y: 640 * u))
    chevron.line(to: NSPoint(x: 470 * u, y: 512 * u))
    chevron.line(to: NSPoint(x: 320 * u, y: 384 * u))
    seafoam.setStroke()
    chevron.stroke()

    // The cursor, sitting on the same baseline as the chevron's lower arm.
    sand.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 540 * u, y: 384 * u, width: 164 * u, height: 54 * u),
        xRadius: 18 * u, yRadius: 18 * u
    ).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: swift Tools/make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// The ten files `iconutil` requires. A missing size is a hard error there, not
// a downscale, so the list is spelled out rather than derived.
let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (side, name) in sizes {
    try render(side).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote \(sizes.count) PNGs to \(out)")
