import AppKit
import CoreText
import Foundation

// Runtime check harness (`make check`) — stands in for a test target, because
// the Command Line Tools ship no XCTest (see CONTRIBUTING.md). The Makefile
// compiles this against the pure sources it exercises: TerminalTheme,
// TerminalMetrics, Config, AppState, PanelGeometry, QuickCommands, Hotkeys,
// DebugLog. Anything that touches the panel, the terminal view or a real shell
// is out of reach here and gets a manual smoke test instead — the list of those
// lives in CLAUDE.md.

var failures = 0
func check(_ ok: Bool, _ label: String) {
    print("\(ok ? "PASS" : "FAIL")  \(label)")
    if !ok { failures += 1 }
}

/// A file in the repository, by path relative to the repository root.
///
/// Located from `#filePath` rather than the working directory, so the checks
/// that read documentation hold wherever the binary is run from.
func repoFile(_ name: String) -> String {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: repoRoot.appendingPathComponent(name), encoding: .utf8)) ?? ""
}

/// `TerminalTheme.RGBA` is a tuple, so `TerminalTheme` cannot be `Equatable`
/// and neither can its `ansi` array. These two compare by hand.
func sameColor(_ a: TerminalTheme.RGBA, _ b: TerminalTheme.RGBA) -> Bool {
    (a.r, a.g, a.b, a.a) == (b.r, b.g, b.b, b.a)
}

func sameTheme(_ a: TerminalTheme, _ b: TerminalTheme) -> Bool {
    a.id == b.id && a.title == b.title
        && a.ansi.count == b.ansi.count
        && zip(a.ansi, b.ansi).allSatisfy(sameColor)
        && sameColor(a.background, b.background)
        && sameColor(a.foreground, b.foreground)
        && sameColor(a.cursor, b.cursor)
        && sameColor(a.selection, b.selection)
        && sameColor(a.tabBarText, b.tabBarText)
}

@main
struct Check {
    static func main() {
        themeChecks()
        customThemeChecks()
        overrideChecks()
        metricsChecks()
        geometryChecks()
        quickCommandChecks()
        hotkeyChecks()
        configChecks()
        appStateChecks()
        docsContractChecks()
        guideHotkeyChecks()

        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Hex parsing and the built-in themes

    static func themeChecks() {
        func hexEquals(_ s: String, _ expected: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
            guard let c = TerminalTheme.parseHex(s) else { return false }
            return (c.r, c.g, c.b, c.a) == expected
        }
        check(hexEquals("#3A7CA5", (58, 124, 165, 255)), "parseHex handles #RRGGBB")
        check(hexEquals("3a7ca5", (58, 124, 165, 255)), "parseHex is case-insensitive, # optional")
        check(hexEquals("#3A7CA566", (58, 124, 165, 102)), "parseHex handles #RRGGBBAA")
        check(TerminalTheme.parseHex("#3A7CA") == nil, "parseHex rejects wrong lengths")
        check(TerminalTheme.parseHex("#GGGGGG") == nil, "parseHex rejects non-hex digits")
        check(TerminalTheme.parseHex("") == nil, "parseHex rejects the empty string")
        // The reason the `allSatisfy(\.isHexDigit)` guard exists at all:
        // `UInt64(_:radix:)` accepts a leading sign, so without it "-12345"
        // parses as a color.
        check(TerminalTheme.parseHex("-12345") == nil, "parseHex rejects a leading minus")
        check(TerminalTheme.parseHex("+3A7CA5") == nil, "parseHex rejects a leading plus")

        // A short palette is a crash inside SwiftTerm's `installColors`, not a
        // wrong color, so every theme that can reach it must be full length.
        for theme in TerminalTheme.builtIn {
            check(theme.ansi.count == TerminalTheme.swiftTermPaletteSize,
                  "built-in theme \(theme.id) carries all 16 ANSI colors")
        }
        let ids = TerminalTheme.builtIn.map(\.id)
        check(Set(ids).count == ids.count, "built-in theme ids are unique")
        check(ids.contains(TerminalTheme.defaultID),
              "the default theme id names a theme that exists")
        check(TerminalTheme.theme(id: "no-such-theme").id == TerminalTheme.defaultID,
              "an unknown theme id resolves to the default rather than failing")
        check(TerminalTheme.ansiRoleNames.count == TerminalTheme.swiftTermPaletteSize
              && TerminalTheme.ansiRoleNames.first == "ansi0"
              && TerminalTheme.ansiRoleNames.last == "ansi15",
              "ansiRoleNames spans ansi0…ansi15")
    }

    // MARK: - Custom theme registration

    static func customThemeChecks() {
        func palette() -> [String: String] {
            var colors: [String: String] = [:]
            for (index, role) in TerminalTheme.ansiRoleNames.enumerated() {
                colors[role] = String(format: "#%02X%02X%02X", index * 16, 32, 64)
            }
            return colors
        }

        TerminalTheme.resetCustomThemes()
        let valid = CustomTerminalTheme(id: "test-theme", title: "Test", colors: palette())
        var rejected = TerminalTheme.registerCustomThemes([valid])
        check(rejected.isEmpty, "a complete custom theme registers")
        check(TerminalTheme.all.contains { $0.id == "test-theme" },
              "a registered theme appears in TerminalTheme.all")
        check(TerminalTheme.theme(id: "test-theme").title == "Test",
              "a registered theme is findable by id")
        // The four optional roles inherit rather than being required, so a
        // sixteen-line theme is a legal theme.
        check(sameColor(TerminalTheme.theme(id: "test-theme").background,
                        TerminalTheme.driftwoodNight.background),
              "an omitted background inherits from the default theme")

        // Duplicate ids, both against another custom entry and against a
        // built-in. Rejection is per theme and total.
        TerminalTheme.resetCustomThemes()
        rejected = TerminalTheme.registerCustomThemes([valid, valid])
        check(TerminalTheme.all.filter { $0.id == "test-theme" }.count == 1,
              "a duplicate custom id is rejected, keeping the first")
        check(rejected == [.init(id: "test-theme", reason: "duplicate id")],
              "the duplicate is reported with a reason to log")

        TerminalTheme.resetCustomThemes()
        let shadow = CustomTerminalTheme(
            id: TerminalTheme.defaultID, title: "Impostor", colors: palette())
        rejected = TerminalTheme.registerCustomThemes([shadow])
        check(TerminalTheme.theme(id: TerminalTheme.defaultID).title == "Driftwood Night",
              "a custom theme cannot shadow a built-in id")
        check(rejected.count == 1, "the shadowing attempt is reported")

        // A theme one color short. This is the case `swiftTermPaletteSize`
        // exists for: fifteen colors would index out of bounds inside SwiftTerm.
        TerminalTheme.resetCustomThemes()
        var short = palette()
        short.removeValue(forKey: "ansi15")
        rejected = TerminalTheme.registerCustomThemes([
            CustomTerminalTheme(id: "fifteen", title: "Fifteen", colors: short)
        ])
        check(!TerminalTheme.all.contains { $0.id == "fifteen" },
              "a theme with 15 ANSI colors is rejected outright")
        check(rejected.first?.reason == "missing ansi15",
              "the missing role is named in the failure (got \(rejected.first?.reason ?? "nil"))")

        TerminalTheme.resetCustomThemes()
        var badHex = palette()
        badHex["ansi3"] = "notahex"
        rejected = TerminalTheme.registerCustomThemes([
            CustomTerminalTheme(id: "bad-hex", title: "Bad", colors: badHex)
        ])
        check(!TerminalTheme.all.contains { $0.id == "bad-hex" },
              "a theme with an unparseable ANSI color is rejected outright")

        // An *optional* role that is present but unparseable is also a
        // rejection: it was meant to be a color.
        TerminalTheme.resetCustomThemes()
        var badOptional = palette()
        badOptional["cursor"] = "#GGG"
        rejected = TerminalTheme.registerCustomThemes([
            CustomTerminalTheme(id: "bad-cursor", title: "Bad", colors: badOptional)
        ])
        check(!TerminalTheme.all.contains { $0.id == "bad-cursor" },
              "a present-but-unparseable optional role is rejected too")

        TerminalTheme.resetCustomThemes()
        rejected = TerminalTheme.registerCustomThemes([
            CustomTerminalTheme(id: "   ", title: "Blank", colors: palette())
        ])
        check(rejected.count == 1 && TerminalTheme.all.count == TerminalTheme.builtIn.count,
              "a whitespace-only id is rejected")

        // One bad entry costs that entry and nothing else.
        TerminalTheme.resetCustomThemes()
        rejected = TerminalTheme.registerCustomThemes([
            CustomTerminalTheme(id: "keeper", title: "Keeper", colors: palette()),
            CustomTerminalTheme(id: "loser", title: "Loser", colors: short),
        ])
        check(TerminalTheme.all.contains { $0.id == "keeper" } && rejected.count == 1,
              "a rejected theme does not take its neighbours with it")

        // tabBarText falls back to the theme's own foreground, not the default
        // theme's — a pale custom background with the default's sand text would
        // be unreadable.
        TerminalTheme.resetCustomThemes()
        var lightish = palette()
        lightish["foreground"] = "#101010"
        TerminalTheme.registerCustomThemes([
            CustomTerminalTheme(id: "light", title: "Light", colors: lightish)
        ])
        let light = TerminalTheme.theme(id: "light")
        check(sameColor(light.tabBarText, light.foreground),
              "tabBarText inherits the theme's own foreground, not the default's")

        TerminalTheme.resetCustomThemes()
    }

    // MARK: - Per-role overrides

    static func overrideChecks() {
        TerminalTheme.resetCustomThemes()
        let base = TerminalTheme.driftwoodNight

        let red: TerminalTheme.RGBA = (r: 255, g: 0, b: 0, a: 255)
        let one = TerminalTheme.resolvedTheme(
            id: TerminalTheme.defaultID, overrides: ["ansi1": "#FF0000"])
        check(sameColor(one.ansi[1], red), "an override replaces exactly that ANSI slot")
        check(sameColor(one.ansi[2], base.ansi[2]) && sameColor(one.ansi[0], base.ansi[0]),
              "the other ANSI slots are untouched")
        check(sameColor(one.background, base.background), "the non-ANSI roles are untouched")

        // Tolerant per role, unlike registration: one bad line costs one color.
        let messy = TerminalTheme.resolvedTheme(id: TerminalTheme.defaultID, overrides: [
            "foreground": "#FFFFFF",   // valid
            "ansi4": "notahex",        // bad hex → ignored
            "ansi99": "#FF0000",       // out-of-range role → ignored
            "sparkle": "#FF0000",      // unknown role → ignored
        ])
        check(sameColor(messy.foreground, (r: 255, g: 255, b: 255, a: 255)),
              "a valid override still applies alongside bad ones")
        check(sameColor(messy.ansi[4], base.ansi[4]), "a bad hex leaves that color in place")
        check(messy.ansi.count == TerminalTheme.swiftTermPaletteSize,
              "an unknown role cannot lengthen or shorten the palette")

        check(sameTheme(
                TerminalTheme.resolvedTheme(id: TerminalTheme.defaultID, overrides: nil), base),
              "nil overrides resolve to the plain theme")
        check(sameTheme(
                TerminalTheme.resolvedTheme(id: TerminalTheme.defaultID, overrides: [:]), base),
              "empty overrides resolve to the plain theme")
        check(sameColor(
                TerminalTheme.resolvedTheme(
                    id: "no-such-theme", overrides: ["ansi1": "#FF0000"]).ansi[1], red),
              "overrides apply on top of the fallback when the theme id is unknown")
    }

    // MARK: - Cell metrics and resize maths

    static func metricsChecks() {
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)

        let cell = TerminalMetrics.cellSize(for: font)
        check(cell.width > 0 && cell.height > 0, "a cell has a positive size at 12pt Menlo")
        check(TerminalMetrics.cellSize(for: CTFontCreateWithName("Menlo" as CFString, 16, nil))
                .height > cell.height,
              "a larger font makes a taller cell")

        let minimum = TerminalMetrics.minimumPanelSize(font: font, showingTabBar: false)
        let withTabs = TerminalMetrics.minimumPanelSize(font: font, showingTabBar: true)
        check(withTabs.height - minimum.height == TerminalMetrics.tabBarHeight,
              "the tab strip adds exactly its own height to the minimum")
        check(minimum.width >= cell.width * 20, "the minimum holds 20 columns")

        // Content frame: padded, tab strip reserved, leftover slack split.
        let bounds = CGRect(x: 0, y: 0, width: 720, height: 361)
        let content = TerminalMetrics.contentFrame(in: bounds, font: font, showingTabBar: false)
        check(content.width == bounds.width - TerminalMetrics.padding * 2,
              "the content frame is inset by the padding on both sides")
        let slackBelow = content.minY - TerminalMetrics.padding
        let slackAbove = bounds.maxY - TerminalMetrics.padding - content.maxY
        check(abs(slackBelow - slackAbove) < 0.001,
              "leftover vertical slack is split evenly rather than collecting at the bottom")
        check(content.height.truncatingRemainder(
                dividingBy: TerminalMetrics.estimatedCellHeight(for: font)) < 0.001,
              "the content height is a whole number of rows")
        let tabbed = TerminalMetrics.contentFrame(in: bounds, font: font, showingTabBar: true)
        check(tabbed.height <= content.height,
              "showing the tab strip never grows the terminal")
        let tiny = TerminalMetrics.contentFrame(
            in: CGRect(x: 0, y: 0, width: 4, height: 4), font: font, showingTabBar: true)
        check(tiny.width >= 0 && tiny.height >= 0,
              "a panel smaller than its own padding yields no negative frame")

        check(TerminalMetrics.tabBarFrame(in: bounds).maxY == bounds.maxY,
              "the tab strip is flush with the top edge")

        // Edge detection.
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        check(TerminalMetrics.resizeEdges(at: CGPoint(x: 50, y: 50), in: box).isEmpty,
              "the interior belongs to the terminal, not to a resize")
        check(TerminalMetrics.resizeEdges(at: CGPoint(x: 1, y: 50), in: box) == .left,
              "a point near the left edge grabs only the left edge")
        check(TerminalMetrics.resizeEdges(at: CGPoint(x: 1, y: 1), in: box) == [.left, .bottom],
              "a corner grabs both of its edges")
        check(TerminalMetrics.resizeEdges(at: CGPoint(x: 99, y: 99), in: box) == [.right, .top],
              "the opposite corner grabs its own two edges")
        check(TerminalMetrics.resizeEdges(at: CGPoint(x: -500, y: -500), in: box).isEmpty,
              "a point far outside the panel grabs nothing")

        // The corner target is L-shaped: it runs `resizeCornerMargin` along
        // each edge, not only the square where the two edge bands overlap.
        check(TerminalMetrics.resizeEdges(at: CGPoint(x: 2, y: 12), in: box) == [.left, .bottom],
              "a grab on the left edge, 12pt up from the bottom, is still the corner")
        check(TerminalMetrics.resizeEdges(at: CGPoint(x: 12, y: 2), in: box) == [.left, .bottom],
              "a grab on the bottom edge, 12pt in from the left, is still the corner")
        check(TerminalMetrics.resizeEdges(at: CGPoint(x: 2, y: 20), in: box) == .left,
              "past the corner margin the left edge is only the left edge")
        check(TerminalMetrics.resizeEdges(at: CGPoint(x: 12, y: 12), in: box).isEmpty,
              "the corner margin widens the corner without deepening the edge bands")
        check(TerminalMetrics.resizeEdges(at: CGPoint(x: 98, y: 88), in: box) == [.right, .top],
              "the far corner widens the same way")

        // A panel narrower than two margins must still resize. Only the nearer
        // edge on each axis is grabbed, so a drag never moves both at once.
        let sliver = CGRect(x: 0, y: 0, width: 8, height: 8)
        let grab = TerminalMetrics.resizeEdges(at: CGPoint(x: 3, y: 3), in: sliver)
        check(!grab.contains(.left) || !grab.contains(.right),
              "a panel narrower than two margins grabs one horizontal edge, never both")
        check(!grab.contains(.top) || !grab.contains(.bottom),
              "a panel shorter than two margins grabs one vertical edge, never both")

        // Resizing moves only the grabbed edge.
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let floor = CGSize(width: 120, height: 60)
        let wider = TerminalMetrics.resized(
            frame, edges: .right, by: CGSize(width: 50, height: 0), minimum: floor)
        check(wider.minX == frame.minX && wider.width == 350,
              "dragging the right edge keeps the left edge fixed")
        let fromLeft = TerminalMetrics.resized(
            frame, edges: .left, by: CGSize(width: 50, height: 0), minimum: floor)
        check(fromLeft.maxX == frame.maxX && fromLeft.width == 250,
              "dragging the left edge keeps the right edge fixed")

        // The clamp this function exists for: a left-edge drag past the minimum
        // must stall, not keep walking the origin sideways.
        let stalled = TerminalMetrics.resized(
            frame, edges: .left, by: CGSize(width: 10_000, height: 0), minimum: floor)
        check(stalled.width == floor.width && stalled.maxX == frame.maxX,
              "a left-edge drag past the floor pins the width and leaves the right edge alone")
        let stalledBottom = TerminalMetrics.resized(
            frame, edges: .bottom, by: CGSize(width: 0, height: 10_000), minimum: floor)
        check(stalledBottom.height == floor.height && stalledBottom.maxY == frame.maxY,
              "a bottom-edge drag past the floor pins the height and leaves the top edge alone")
        let corner = TerminalMetrics.resized(
            frame, edges: [.left, .top], by: CGSize(width: -20, height: 30), minimum: floor)
        check(corner.width == 320 && corner.height == 230 && corner.maxX == frame.maxX
              && corner.minY == frame.minY,
              "a corner drag moves both grabbed edges and neither fixed one")
        check(TerminalMetrics.resized(
                frame, edges: [], by: CGSize(width: 40, height: 40), minimum: floor) == frame,
              "a drag with no grabbed edge changes nothing")
    }

    // MARK: - Frame restore

    static func geometryChecks() {
        let main = PanelScreen(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let second = PanelScreen(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        let size = PanelGeometry.defaultSize
        let fallback = PanelGeometry.defaultFrame(size: size, onVisible: main.visibleFrame)

        check(fallback.midX == main.visibleFrame.midX, "the default frame is horizontally centered")
        check(fallback.midY < main.visibleFrame.midY, "the default frame sits in the lower half")

        func validated(_ saved: CGRect?, _ screens: [PanelScreen]) -> CGRect {
            PanelGeometry.validatedFrame(
                saved: saved, screens: screens, defaultSize: size, mainVisible: main.visibleFrame)
        }

        check(validated(nil, [main]) == fallback, "no saved frame lands on the default")
        check(validated(CGRect(x: 0, y: 0, width: 0, height: 0), [main]) == fallback,
              "a zero-size saved frame is not trusted")

        let good = CGRect(x: 200, y: 200, width: 600, height: 300)
        check(validated(good, [main]) == good, "a frame fully on screen is left exactly as saved")

        // Fully off screen: nothing can show it, so start over.
        let stranded = CGRect(x: 9000, y: 9000, width: 600, height: 300)
        check(validated(stranded, [main, second]) == fallback,
              "a frame on no display falls back to the default")

        // Partly off: slid back rather than reset, because the user chose that
        // position and only the edge of it is unreachable.
        let hanging = CGRect(x: 1200, y: 400, width: 600, height: 300)
        let rescued = validated(hanging, [main])
        check(rescued.size == hanging.size, "a rescued frame keeps the size the user dragged")
        check(rescued.maxX <= main.visibleFrame.maxX && rescued.minX >= main.visibleFrame.minX,
              "a rescued frame is slid fully inside the visible area")

        // The unplugged-monitor case.
        let onSecond = CGRect(x: 2000, y: 300, width: 600, height: 300)
        check(validated(onSecond, [main, second]).origin == onSecond.origin,
              "a frame on the second display is trusted while that display exists")
        check(validated(onSecond, [main]) == fallback,
              "the same frame falls back once that display is gone")

        // Enough of the panel has to be showing to be worth rescuing — there is
        // no Dock icon and no window list to recover it from.
        let sliver = CGRect(
            x: main.frame.maxX - 4, y: 400,
            width: 600, height: 300)
        check(validated(sliver, [main]) == fallback,
              "a frame with a 4pt sliver on screen is treated as lost")
        let grabbable = CGRect(
            x: main.frame.maxX - PanelGeometry.minimumVisibleExtent - 1, y: 400,
            width: 600, height: 300)
        check(validated(grabbable, [main]) != fallback,
              "a frame with 80pt showing is rescued rather than reset")

        // A panel wider than the display keeps its width and pins its origin.
        let oversize = CGRect(x: -100, y: 100, width: 2000, height: 300)
        let pinned = PanelGeometry.clampedFrame(oversize, onVisible: main.visibleFrame)
        check(pinned.width == oversize.width, "clamping never resizes")
        check(pinned.minX == main.visibleFrame.minX,
              "a panel wider than the screen is pinned to the left edge")

        check(PanelGeometry.defaultFrame(
                size: size, onVisible: PanelGeometry.fallbackVisibleFrame).width == size.width,
              "the no-screen fallback frame is a usable rect")

        // The size floor, which `NSWindow.minSize` no longer provides — the
        // panel is not `.resizable`. Growth hangs off the top-left corner.
        let small = CGRect(x: 200, y: 500, width: 100, height: 40)
        let floorSize = CGSize(width: 300, height: 120)
        let grown = PanelGeometry.grownToMinimum(small, minimum: floorSize)
        check(grown.width == 300 && grown.height == 120,
              "a panel below the minimum is grown to it on both axes")
        check(grown.minX == small.minX && grown.maxY == small.maxY,
              "growing to the minimum keeps the top-left corner where it was")
        let roomy = CGRect(x: 0, y: 0, width: 800, height: 400)
        check(PanelGeometry.grownToMinimum(roomy, minimum: floorSize) == roomy,
              "a panel already above the minimum is left alone")
        let halfShort = CGRect(x: 0, y: 0, width: 800, height: 40)
        check(PanelGeometry.grownToMinimum(halfShort, minimum: floorSize).width == 800,
              "growing one axis to the minimum never shrinks the other")
    }

    // MARK: - Quick commands

    static func quickCommandChecks() {
        let reserved = HotkeyConfig().byName

        func validate(_ entries: [QuickCommandConfig]) -> QuickCommands.Result {
            QuickCommands.validate(entries, reservedHotkeys: reserved)
        }

        let ok = validate([
            QuickCommandConfig(id: "logs", title: "Tail logs", command: "tail -f /tmp/x.log")
        ])
        check(ok.problems.isEmpty && ok.commands.count == 1, "a plain entry validates")

        // The empty state is the only thing that tells a user quick commands
        // exist — there is no UI that creates one — so it has to name the file
        // they would have to edit. Both the menu submenu and the palette print
        // this one string.
        check(QuickCommands.emptyStateMessage.contains("config.json"),
              "the empty state names the file to edit, not just that the list is empty")

        // The safety default. A hotkey that fires a shell command with no
        // confirmation, possibly while the panel is hidden, is opt-in.
        check(ok.commands.first?.runsImmediately == false,
              "an entry without \"run\" types the command instead of executing it")
        check(validate([QuickCommandConfig(
                id: "x", title: "X", command: "echo hi", run: true)])
                .commands.first?.runsImmediately == true,
              "\"run\": true opts in to executing on the spot")
        check(validate([QuickCommandConfig(
                id: "x", title: "X", command: "echo hi", run: false)])
                .commands.first?.runsImmediately == false,
              "\"run\": false is honored explicitly")
        // The default has to survive the JSON path too, since that is the only
        // way a real entry arrives.
        let decoded = try? JSONDecoder().decode(
            [QuickCommandConfig].self,
            from: Data(#"[{"id":"a","title":"A","command":"echo hi"}]"#.utf8))
        check(QuickCommands.validate(decoded ?? []).commands.first?.runsImmediately == false,
              "an entry decoded from config.json without \"run\" still defaults to typing")

        // Dropped entries.
        let dupe = validate([
            QuickCommandConfig(id: "a", title: "First", command: "echo 1"),
            QuickCommandConfig(id: "a", title: "Second", command: "echo 2"),
        ])
        check(dupe.commands.count == 1 && dupe.commands.first?.title == "First",
              "a duplicate id is dropped, keeping the first")
        check(dupe.problems == [.init(id: "a", reason: "duplicate id", dropped: true)],
              "the duplicate is reported as dropped")

        let empty = validate([QuickCommandConfig(id: "a", title: "A", command: "")])
        check(empty.commands.isEmpty && empty.problems.first?.dropped == true,
              "an entry with an empty command is dropped")
        let noID = validate([QuickCommandConfig(id: "  ", title: "A", command: "echo hi")])
        check(noID.commands.isEmpty && noID.problems.first?.dropped == true,
              "an entry with a blank id is dropped")

        // Kept entries with the hotkey taken away. A bad hotkey costs the
        // hotkey; a bad command costs the entry.
        let badKey = validate([
            QuickCommandConfig(id: "a", title: "A", command: "echo hi", hotkey: "shift+a"),
            QuickCommandConfig(id: "b", title: "B", command: "echo bye"),
        ])
        check(badKey.commands.count == 2, "an invalid hotkey does not drop the entry")
        check(badKey.commands.first?.hotkey == nil, "the invalid hotkey is stripped")
        check(badKey.problems.count == 1 && badKey.problems.first?.dropped == false,
              "the invalid hotkey is reported without dropping anything")

        // A command claiming one of the app's own bindings. Carbon gives the
        // key to whoever registers first, which is not something a user should
        // have to reason about.
        let clash = validate([
            QuickCommandConfig(id: "a", title: "A", command: "echo hi",
                               hotkey: HotkeyConfig().toggle)
        ])
        check(clash.commands.first?.hotkey == nil && clash.problems.count == 1,
              "a command claiming the summon hotkey loses the binding, not the command")
        check(clash.problems.first?.reason.contains("toggle") == true,
              "the collision names the app binding it collided with")

        // Two spellings of the same chord collide the way the keyboard does.
        let spelled = validate([
            QuickCommandConfig(id: "a", title: "A", command: "echo 1", hotkey: "control+option+1"),
            QuickCommandConfig(id: "b", title: "B", command: "echo 2", hotkey: "ctrl+alt+1"),
        ])
        check(spelled.commands.count == 2, "both commands survive a hotkey collision")
        check(spelled.commands.first?.hotkey != nil && spelled.commands.last?.hotkey == nil,
              "\"ctrl+alt+1\" collides with \"control+option+1\" despite the different spelling")

        // Opting out is silent; a typo is not.
        for quiet in ["", "none", "disabled", "  NONE  "] {
            let result = validate([QuickCommandConfig(
                id: "a", title: "A", command: "echo hi", hotkey: quiet)])
            check(result.problems.isEmpty && result.commands.first?.hotkey == nil,
                  "hotkey \"\(quiet)\" means no hotkey, silently")
        }

        check(validate([QuickCommandConfig(id: "a", title: "", command: "echo hi")])
                .commands.first?.title == "echo hi",
              "an entry with no title falls back to the command text")

        // `QuickCommands.isOptedOut` is duplicated in `HotkeyCenter` because
        // that one is private to a @MainActor class this file cannot depend on.
        // Nothing but this assertion keeps the two honest.
        let optOuts = ["", "  ", "none", "None", " disabled ", "DISABLED"]
        let realBindings = ["control+option+t", "cmd+shift+k", "ctrl+f1"]
        let malformed = ["shift+a", "space", "control+bogus+a", "control+option"]
        for binding in optOuts {
            check(QuickCommands.isOptedOut(binding) && HotkeySpec(binding) == nil,
                  "\"\(binding)\" is opted out and parses to nil, in agreement")
        }
        for binding in realBindings {
            check(!QuickCommands.isOptedOut(binding) && HotkeySpec(binding) != nil,
                  "\"\(binding)\" is neither opted out nor malformed")
        }
        for binding in malformed {
            check(!QuickCommands.isOptedOut(binding) && HotkeySpec(binding) == nil,
                  "\"\(binding)\" fails to parse without being mistaken for an opt-out")
        }
    }

    // MARK: - Hotkey parsing

    static func hotkeyChecks() {
        let defaults = HotkeyConfig()
        for (name, binding) in defaults.byName where !binding.isEmpty {
            check(HotkeySpec(binding) != nil, "the default \(name) binding \"\(binding)\" parses")
        }
        check(defaults.quit.isEmpty,
              "the quit binding ships disabled — a misfire costs every running shell")
        check(Set(defaults.byName.values.filter { !$0.isEmpty }).count
              == defaults.byName.values.filter { !$0.isEmpty }.count,
              "no two default bindings are the same chord")

        check(HotkeySpec("cmd+shift+k") != nil, "command+shift+letter parses")
        check(HotkeySpec("ctrl+f1") != nil, "ctrl+F1 parses")
        check(HotkeySpec("  Control + Option + T  ") != nil, "whitespace and case are tolerated")

        check(HotkeySpec("") == nil, "the empty string returns nil")
        check(HotkeySpec("none") == nil, "\"none\" returns nil")
        check(HotkeySpec("disabled") == nil, "\"disabled\" returns nil")
        check(HotkeySpec("control+option") == nil, "modifiers with no key returns nil")
        check(HotkeySpec("control+a+b") == nil, "two keys returns nil")
        check(HotkeySpec("control+bogus+a") == nil, "an unknown token returns nil")

        // A registered hotkey consumes the keystroke in every app, so a binding
        // must carry one of ⌃⌥⌘. Shift alone does not make one — "shift+a" is A.
        check(HotkeySpec("shift+a") == nil, "shift alone is not enough of a modifier")
        check(HotkeySpec("a") == nil, "a bare letter would kill that key system-wide")
        check(HotkeySpec("f1") == nil, "a bare F-key is refused for the same reason")
        check(HotkeySpec("control+shift+k") != nil, "shift alongside control is fine")

        check(HotkeySpec.display("control+option+t") == "⌃⌥T", "display renders ⌃⌥T")
        check(HotkeySpec.display("cmd+shift+k") == "⇧⌘K", "display orders modifiers ⌃⌥⇧⌘")
        check(HotkeySpec.display("ctrl+f12") == "⌃F12", "display uppercases F-keys")
        check(HotkeySpec.display("none") == nil, "display of a disabled binding is nil")
        check(HotkeySpec.display("shift+a") == nil,
              "display refuses what registration refuses, so no menu can show a dead key")

        // The menu equivalent comes from the same parse as the Carbon
        // registration, so the menu can never draw a key equivalent that no
        // hotkey backs.
        func equivalent(_ s: String) -> (String, NSEvent.ModifierFlags)? {
            HotkeySpec(s)?.menuKeyEquivalent
        }
        check(equivalent("control+option+t").map { $0 == ("t", [.control, .option]) } == true,
              "the menu equivalent maps a letter binding")
        check(equivalent("ctrl+f1").map {
                  $0 == (String(UnicodeScalar(NSF1FunctionKey)!), .control) } == true,
              "the menu equivalent maps F-keys to the function-key scalars")
        check(equivalent("shift+a") == nil, "the menu equivalent refuses what Carbon refuses")
    }

    // MARK: - Config

    static func configChecks() {
        func decode(_ json: String) -> Config? {
            try? JSONDecoder().decode(Config.self, from: Data(json.utf8))
        }
        check(decode(#"{}"#)?.fontNames == Config.defaultFontNames,
              "a config with no fontNames uses the default list")
        // An empty list would resolve to no font and leave the terminal
        // measuring zero-width cells.
        check(decode(#"{"fontNames":[]}"#)?.fontNames == Config.defaultFontNames,
              "an emptied fontNames list reads as \"use the defaults\"")
        check(decode(#"{"fontNames":["Menlo"]}"#)?.fontNames == ["Menlo"],
              "a fontNames list round-trips")
        check(Config.defaultFontNames.last == "Menlo",
              "Menlo is the floor of the font list, not SF Mono")

        check(decode(#"{}"#)?.shell == "/bin/zsh", "the default shell is /bin/zsh")
        check(decode(#"{"shell":""}"#)?.shell == "/bin/zsh",
              "an empty shell falls back rather than launching nothing")
        check(decode(#"{}"#)?.shellArguments == ["-l"],
              "the shell is a login shell by default, so profiles are sourced")
        check(decode(#"{}"#)?.debug == false, "debug is off by default")

        check(decode(#"{}"#)?.hotkeys.toggle == "control+option+t",
              "a config with no hotkeys object uses the defaults")
        check(decode(#"{"hotkeys":{"toggle":"cmd+shift+t"}}"#)?.hotkeys.toggle == "cmd+shift+t",
              "a hotkey override round-trips")
        check(decode(#"{"hotkeys":{"toggle":"cmd+shift+t"}}"#)?.hotkeys.focus
              == "control+option+f",
              "a partial hotkeys object keeps the defaults for the keys it omits")

        check(decode(##"{"terminalPalette":{"ansi1":"#FF0000"}}"##)?.terminalPalette
              == ["ansi1": "#FF0000"],
              "a palette override survives decoding verbatim")
        check(decode(#"{}"#)?.terminalThemes == nil, "terminalThemes defaults to absent")
        check(decode(#"{}"#)?.quickCommands == nil, "quickCommands defaults to absent")

        // Tolerance is what stands in for migration code: a stale key is inert.
        let stale = decode(#"{"dockPosition":"bottom","shell":"/bin/bash"}"#)
        check(stale?.shell == "/bin/bash", "an unknown key does not stop the rest decoding")
        let reencoded = String(data: try! JSONEncoder().encode(stale!), encoding: .utf8)!
        check(!reencoded.contains("dockPosition"), "an unknown key is not written back out")
        check(!reencoded.contains("debug"), "debug is omitted from the file when off")

        // Corrupt files are moved aside, never overwritten, and an earlier
        // rescue is never clobbered by a later one.
        let base = URL(fileURLWithPath: "/tmp/config.json.bak")
        check(Config.availableBackupURL(base: base, exists: { _ in false }) == base,
              "the first backup uses the plain .bak name")
        let taken: Set<String> = ["/tmp/config.json.bak", "/tmp/config.json.bak.1"]
        check(Config.availableBackupURL(base: base, exists: { taken.contains($0.path) }).path
              == "/tmp/config.json.bak.2",
              "a backup name skips past the backups already there")

        check(Config.fileURL.lastPathComponent == "config.json"
              && Config.fileURL.deletingLastPathComponent().lastPathComponent == "Driftwood",
              "config.json lives in Application Support/Driftwood")
        check(AppState.fileURL.deletingLastPathComponent()
              == Config.fileURL.deletingLastPathComponent(),
              "state.json is a separate file in the same directory")
    }

    // MARK: - App state

    static func appStateChecks() {
        func decode(_ json: String) -> AppState? {
            try? JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        }
        check(decode(#"{}"#)?.frame == nil, "state with no frame has none to restore")
        check(decode(#"{"frame":{"x":10,"y":20,"width":300,"height":200}}"#)?.frame
              == CGRect(x: 10, y: 20, width: 300, height: 200),
              "a saved frame round-trips through the flat {x,y,width,height} shape")
        // A truncated frame decodes to zeroes, which validatedFrame then
        // rejects — better than throwing the whole state file away.
        check(decode(#"{"frame":{"x":10}}"#)?.frame == CGRect(x: 10, y: 0, width: 0, height: 0),
              "a truncated frame decodes to an untrusted rect rather than throwing")

        check(decode(#"{}"#)?.theme == TerminalTheme.defaultID,
              "state with no theme uses the default")
        check(decode(#"{"theme":"not-registered-yet"}"#)?.theme == "not-registered-yet",
              "an unknown theme id is accepted at decode time (custom themes register later)")

        check(decode(#"{}"#)?.fontSize == AppState.defaultFontSize,
              "state with no font size uses the default")
        check(decode(#"{"fontSize":13}"#)?.fontSize == 13, "a preset font size round-trips")
        check(decode(#"{"fontSize":11.4}"#)?.fontSize == 11,
              "an off-preset font size snaps to the nearest preset the menu can check")
        check(decode(#"{"fontSize":900}"#)?.fontSize == AppState.fontSizePresets.last,
              "an absurd font size lands on the largest preset")

        check(decode(#"{}"#)?.opacity == 1.0, "state with no opacity is fully opaque")
        check(decode(#"{"opacity":0.7}"#)?.opacity == 0.7, "a preset opacity round-trips")
        check(decode(#"{"opacity":0.01}"#)?.opacity == AppState.opacityRange.lowerBound,
              "an opacity below the floor is clamped, so the panel stays findable")
        check(decode(#"{"opacity":5}"#)?.opacity == 1.0, "an opacity above 1 is clamped")

        // alwaysOnTop and showInFullScreen were real settings through 0.1.0.
        // Every state.json written by that release carries both, so they have to
        // decode to nothing rather than throw — the whole file would otherwise
        // be moved aside on first launch of 0.2.0, taking the frame, the theme
        // and the opacity with it.
        let retired = decode(#"""
            {"opacity":0.7,"alwaysOnTop":false,"showInFullScreen":false}
            """#)
        check(retired?.opacity == 0.7,
              "a 0.1.0 state file still decodes, and the settings beside the retired keys survive")
        let rewritten = String(
            data: try! JSONEncoder().encode(retired!), encoding: .utf8
        )!
        check(!rewritten.contains("alwaysOnTop") && !rewritten.contains("showInFullScreen"),
              "neither retired key is written back out")

        // Presets are the whole of these settings — there is no slider — so a
        // preset that cannot be selected is a value nobody can reach.
        check(AppState.opacityPresets.allSatisfy { AppState.opacityRange.contains($0) },
              "every opacity preset survives the clamp applied on read")
        check(AppState.opacityPresets.contains(1.0),
              "the opacity presets include fully opaque, the recovery value")
        check(Set(AppState.opacityPresets).count == AppState.opacityPresets.count,
              "no duplicate opacity presets, which would check two rows at once")
        check(AppState.fontSizePresets.contains(AppState.defaultFontSize),
              "the default font size is one of the presets, so it stays checkable")
        check(AppState.fontSizePresets == AppState.fontSizePresets.sorted(),
              "the font size presets are ordered, which ⌘+ / ⌘− step through")

        check(AppState.isPreset(0.8, matching: 0.8), "the preset in effect is checked")
        check(!AppState.isPreset(0.8, matching: 0.7), "a preset not in effect is unchecked")
        check(!AppState.opacityPresets.contains { AppState.isPreset($0, matching: 0.73) },
              "a value between stops checks nothing rather than the nearest stop")

        // ⌘+ / ⌘− saturate rather than wrap: ⌘+ at the top jumping to 10pt
        // would read as a glitch.
        check(AppState.steppedFontSize(12, by: 1) == 13, "⌘+ steps up one preset")
        check(AppState.steppedFontSize(12, by: -1) == 11, "⌘− steps down one preset")
        check(AppState.steppedFontSize(AppState.fontSizePresets.last!, by: 1)
              == AppState.fontSizePresets.last,
              "⌘+ at the largest preset stays there rather than wrapping to the smallest")
        check(AppState.steppedFontSize(AppState.fontSizePresets.first!, by: -1)
              == AppState.fontSizePresets.first,
              "⌘− at the smallest preset stays there")
        check(AppState.steppedFontSize(11.4, by: 1) == 12,
              "stepping from an off-preset size snaps first, then steps")

        var state = AppState()
        state.frame = CGRect(x: 5, y: 6, width: 700, height: 350)
        state.opacity = 0.7
        state.fontSize = 14
        let round = try? JSONDecoder().decode(
            AppState.self, from: JSONEncoder().encode(state))
        check(round == state, "a full state round-trips through encode and decode unchanged")
    }

    // MARK: - Docs / code contract

    /// Holds the documentation to the code where getting it wrong would be
    /// dangerous rather than merely untidy.
    ///
    /// Only one setting qualifies. `run` decides whether a global hotkey
    /// executes a shell command outright or types it at the prompt for you to
    /// read first, and the README and the config's own doc comment are the only
    /// places a user learns which. Documentation that said the opposite would
    /// not break anything the other checks can see.
    ///
    /// Located from `#filePath` rather than the working directory, so it holds
    /// wherever the binary is run from.
    static func docsContractChecks() {
        let text = repoFile

        let readme = text("README.md")
        check(!readme.isEmpty, "README.md is readable from #filePath")
        check(readme.contains("\"run\""), "the README documents the `run` key by name")
        check(readme.contains("`run` defaults to false"),
              "the README states that `run` defaults to false")

        let configSource = text("Sources/Driftwood/Support/Config.swift")
        check(configSource.contains("defaults to false"),
              "config.json's own documentation states that `run` defaults to false")

        // The website's guide is the fullest description of `run` anywhere, and
        // it is hand-written HTML with nothing generating it, so it joins the
        // README and the doc comment rather than being trusted.
        let guide = text("docs/guide.html")
        check(!guide.isEmpty, "docs/guide.html is readable from #filePath")
        check(guide.contains("<code>run</code>"), "the guide documents the `run` key by name")
        check(guide.contains("<code>run</code> defaults to false"),
              "the guide states that `run` defaults to false")

        // The default has to agree with both documents, which is the whole
        // point of asserting them.
        check(QuickCommands.validate([
                QuickCommandConfig(id: "a", title: "A", command: "echo hi")
              ]).commands.first?.runsImmediately == false,
              "the code agrees with both documents: no `run` means no execution")
    }

    // MARK: - The guide's hotkey table

    /// Holds `docs/guide.html`'s hotkey table to `HotkeyConfig`'s own defaults.
    ///
    /// The table restates all five bindings by hand, and a default that moves in
    /// the code takes nothing on the site with it — the reader would set a
    /// binding to what the page says and get the app's behaviour instead, with
    /// no error anywhere. Each cell carries `data-hotkey-default="<name>"`, and
    /// the comparison runs in both directions: every stated default must match
    /// the code, and every binding in the code must be stated. The second half
    /// is what catches a *new* binding that nobody documented.
    ///
    /// This reads the defaults from `HotkeyConfig()` rather than grepping
    /// `Config.swift` for the strings, which the check harness can do because it
    /// compiles against that type.
    static func guideHotkeyChecks() {
        let guide = repoFile("docs/guide.html")
        let defaults = HotkeyConfig().byName
        let marker = "data-hotkey-default=\""
        var stated: [String: String] = [:]
        var cursor = guide.startIndex

        while let start = guide.range(of: marker, range: cursor..<guide.endIndex) {
            guard
                let quote = guide.range(of: "\"", range: start.upperBound..<guide.endIndex),
                let open = guide.range(of: ">", range: quote.upperBound..<guide.endIndex),
                let close = guide.range(of: "</code>", range: open.upperBound..<guide.endIndex)
            else { break }
            let name = String(guide[start.upperBound..<quote.lowerBound])
            // The disabled binding is written as a pair of quote marks, because
            // an empty table cell would read as an omission rather than as the
            // value. Stripping them is what makes it comparable to "".
            let value = String(guide[open.upperBound..<close.lowerBound])
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)
            stated[name] = value
            cursor = close.upperBound
        }

        check(!stated.isEmpty, "docs/guide.html's hotkey table is marked up for this check")
        for (name, value) in stated.sorted(by: { $0.key < $1.key }) {
            check(defaults[name] == value,
                  "the guide's \(name) default \"\(value)\" is what HotkeyConfig ships")
        }
        check(Set(stated.keys) == Set(defaults.keys),
              "the guide states every binding HotkeyConfig has, and no binding it does not")
    }
}
