import Foundation

/// A named color scheme for the terminal: the 16 ANSI colors plus the roles
/// Driftwood paints itself (panel tint, text, caret, selection, tab bar).
///
/// Foundation-only — no AppKit, no SwiftTerm — so `make check` can compile and
/// exercise hex parsing, the 16-color validation, and the override merge. The
/// conversion to SwiftTerm's `Color` and AppKit's `NSColor` lives at the call
/// site in `AppDelegate`, which is where those frameworks are already in play.
///
/// **What a theme changes, and what it does not.** Swapping the ANSI palette
/// changes what an ANSI color *code* renders as. It does not change *which*
/// color a shell prompt asks for. oh-my-zsh's `robbyrussell` will still pick
/// green for its arrow and red for a dirty git status, because that choice
/// lives in the user's shell config and runs identically in every emulator.
/// "Syntax highlighting" in a terminal *is* the ANSI palette; there is no
/// separate highlighting layer here to theme. Starboard learned this by
/// looking for one.
struct TerminalTheme {
    typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    let id: String
    let title: String
    /// Exactly 16 entries: black, red, green, yellow, blue, magenta, cyan,
    /// white, then the eight bright variants in the same order.
    let ansi: [RGBA]
    /// The tint layer painted over the window blur. Its alpha is the
    /// translucency of the whole panel, so a theme owns how see-through it is.
    let background: RGBA
    let foreground: RGBA
    let cursor: RGBA
    /// The band behind selected text. Read it together with
    /// `applyTheme`'s `selectedTextForegroundColor` line: what a selection
    /// looks like is those two colors, and 0.1.0 only set this one.
    ///
    /// **Selected text is not this color's problem to solve.** SwiftTerm draws
    /// selected glyphs in `selectedTextForegroundColor`, which defaults to
    /// black; darkening or lightening the band cannot rescue black text on a
    /// dark theme. `applyTheme` sets that foreground now, so the band is free
    /// to be tuned for one job: making the edges of a selection findable.
    ///
    /// Each color is aimed at two contrast ratios, measured against the theme's
    /// own background: at least 7:1 for `foreground` drawn on the band, and
    /// 1.5–1.8:1 for the band against unselected background. The two pull
    /// against each other on a dark theme — a band is only findable by being
    /// lighter than a near-black background, and every step lighter costs text
    /// contrast. Paper's pair (7.4:1 and 1.55:1) is what the other three were
    /// tuned to; it is the one theme of the four that read correctly in 0.1.0.
    ///
    /// The alpha is part of the tuning and not decoration. The terminal view's
    /// layer is clear (see `applyTheme`), so this band composites over the
    /// tint, the blur and whatever wallpaper is behind the panel — not over
    /// `background`. At 0.1.0's 96–110 the desktop bled through enough to move
    /// the band around; 180 holds the intended color while keeping the panel
    /// see-through where it is selected.
    let selection: RGBA
    let tabBarText: RGBA

    static let defaultID = "driftwood-night"

    /// How many entries `installColors` demands.
    ///
    /// SwiftTerm's `TerminalView.installColors(_:)` is a thin wrapper around
    /// `Terminal.installPalette`, and it indexes 0...15 without checking the
    /// array it was handed. A short array is a crash, not a fallback, which is
    /// why `register(_:)` rejects a custom theme by count before it can ever
    /// reach the terminal. Pinned to SwiftTerm 1.15.0 (`make check` asserts
    /// the pin in Package.resolved).
    static let swiftTermPaletteSize = 16

    /// The ANSI role names a custom theme spells in `config.json`, in palette
    /// order. Also the order `ansi` itself is in, so the two cannot drift.
    static let ansiRoleNames: [String] = (0..<swiftTermPaletteSize).map { "ansi\($0)" }
}

// MARK: - Built-in themes

extension TerminalTheme {
    /// Starboard's muted ocean palette, carried over intact: deep blues and
    /// teals instead of the harsh primaries most terminal defaults use, with
    /// red and green nodding to a ship's port and starboard navigation lights.
    /// Default, and the theme every custom theme inherits its optional roles
    /// from.
    static let driftwoodNight = TerminalTheme(
        id: defaultID,
        title: "Driftwood Night",
        ansi: [
            (20, 24, 33, 255),     // black
            (198, 74, 90, 255),    // red — port light
            (79, 157, 105, 255),   // green — starboard light
            (196, 154, 62, 255),   // yellow — brass
            (58, 124, 165, 255),   // blue — deep ocean
            (133, 110, 168, 255),  // magenta — dusk
            (69, 156, 156, 255),   // cyan — seafoam
            (196, 190, 172, 255),  // white — sand
            (75, 87, 99, 255),     // bright black — slate
            (222, 102, 118, 255),  // bright red
            (111, 191, 135, 255),  // bright green
            (224, 186, 105, 255),  // bright yellow
            (95, 168, 211, 255),   // bright blue
            (169, 143, 201, 255),  // bright magenta
            (114, 214, 207, 255),  // bright cyan
            (230, 224, 208, 255),  // bright white — foam
        ],
        // Near-black deep navy at 65% — the same tint Starboard used, and
        // deliberately its own color rather than a system material. The exact
        // recipe a system material uses reacts to the desktop behind it and
        // changes between macOS releases; a fixed color stays put.
        background: (5, 9, 15, 166),
        foreground: (196, 190, 172, 255),
        cursor: (114, 214, 207, 255),
        selection: (36, 70, 100, 180),
        tabBarText: (196, 190, 172, 255)
    )

    /// Warm dark: coals and rust against near-black brown. For anyone who
    /// finds a blue terminal cold at night.
    static let ember = TerminalTheme(
        id: "ember",
        title: "Ember",
        ansi: [
            (28, 22, 20, 255),     // black
            (214, 92, 66, 255),    // red — hot coal
            (152, 165, 84, 255),   // green — olive
            (222, 158, 65, 255),   // yellow — flame
            (150, 122, 92, 255),   // blue — the coldest thing here is still warm
            (186, 108, 122, 255),  // magenta — rose ash
            (168, 152, 108, 255),  // cyan — brass patina
            (222, 206, 186, 255),  // white — bone
            (92, 76, 68, 255),     // bright black
            (240, 122, 92, 255),   // bright red
            (180, 194, 108, 255),  // bright green
            (246, 190, 104, 255),  // bright yellow
            (186, 156, 122, 255),  // bright blue
            (216, 140, 152, 255),  // bright magenta
            (204, 186, 138, 255),  // bright cyan
            (246, 234, 218, 255),  // bright white
        ],
        background: (18, 12, 10, 176),
        foreground: (222, 206, 186, 255),
        cursor: (222, 158, 65, 255),
        selection: (112, 68, 44, 180),
        tabBarText: (222, 206, 186, 255)
    )

    /// Light: warm paper with saturated ink. The one theme meant for a bright
    /// room, and the reason `background` carries its own alpha — a light tint
    /// needs to be far more opaque than a dark one to stay readable over an
    /// arbitrary desktop.
    static let paper = TerminalTheme(
        id: "paper",
        title: "Paper",
        ansi: [
            (60, 56, 52, 255),     // black
            (176, 48, 48, 255),    // red
            (48, 128, 72, 255),    // green
            (160, 116, 24, 255),   // yellow
            (44, 96, 168, 255),    // blue
            (136, 72, 152, 255),   // magenta
            (32, 128, 132, 255),   // cyan
            (236, 230, 220, 255),  // white
            (120, 112, 104, 255),  // bright black
            (208, 76, 72, 255),    // bright red
            (68, 160, 96, 255),    // bright green
            (192, 148, 44, 255),   // bright yellow
            (72, 128, 200, 255),   // bright blue
            (168, 104, 184, 255),  // bright magenta
            (56, 160, 164, 255),   // bright cyan
            (252, 248, 240, 255),  // bright white
        ],
        background: (246, 242, 232, 224),
        foreground: (52, 48, 44, 255),
        cursor: (176, 48, 48, 255),
        selection: (44, 96, 168, 72),
        tabBarText: (52, 48, 44, 255)
    )

    /// Grayscale: every ANSI color is a neutral of a different lightness, so
    /// colored output still separates but nothing shouts. Useful for reading
    /// output from a tool that colors too much of it.
    static let mono = TerminalTheme(
        id: "mono",
        title: "Mono",
        ansi: [
            (24, 24, 24, 255),     // black
            (128, 128, 128, 255),  // red
            (160, 160, 160, 255),  // green
            (184, 184, 184, 255),  // yellow
            (104, 104, 104, 255),  // blue
            (144, 144, 144, 255),  // magenta
            (172, 172, 172, 255),  // cyan
            (208, 208, 208, 255),  // white
            (72, 72, 72, 255),     // bright black
            (168, 168, 168, 255),  // bright red
            (196, 196, 196, 255),  // bright green
            (220, 220, 220, 255),  // bright yellow
            (140, 140, 140, 255),  // bright blue
            (180, 180, 180, 255),  // bright magenta
            (208, 208, 208, 255),  // bright cyan
            (244, 244, 244, 255),  // bright white
        ],
        background: (14, 14, 14, 176),
        foreground: (208, 208, 208, 255),
        cursor: (244, 244, 244, 255),
        selection: (82, 82, 82, 180),
        tabBarText: (208, 208, 208, 255)
    )

    static let builtIn: [TerminalTheme] = [driftwoodNight, ember, paper, mono]
}

// MARK: - Registry

extension TerminalTheme {
    /// Themes read from `config.json`, in the order they appear there.
    /// Not thread-safe by design: registration happens once at launch, on the
    /// main thread, before anything reads it. `nonisolated(unsafe)` rather
    /// than `@MainActor` so the check harness (which has no main actor to run
    /// on for a synchronous call) can exercise registration directly.
    nonisolated(unsafe) private static var custom: [TerminalTheme] = []

    static var all: [TerminalTheme] { builtIn + custom }

    /// The theme with this id, or the default. Never fails: a `state.json`
    /// naming a theme whose config entry was deleted falls back rather than
    /// leaving the terminal unpainted.
    static func theme(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? driftwoodNight
    }

    /// One rejected custom theme, with the reason to log.
    struct RegistrationFailure: Equatable {
        let id: String
        let reason: String
    }

    /// Register the custom themes from `config.json`, returning the ones that
    /// were rejected so the caller can log them.
    ///
    /// Rejection is per *theme*, and it is total: an entry with an empty id, a
    /// colliding id, an unparseable hex value, or a missing `ansi0`…`ansi15`
    /// does not become a half-built theme. That asymmetry with
    /// `resolvedTheme`'s per-role tolerance is deliberate — an override that
    /// does not parse leaves a working theme with one color unchanged, while a
    /// theme missing an ANSI entry has no defensible color to put there, and
    /// a short array is a crash inside SwiftTerm rather than a wrong color
    /// (see `swiftTermPaletteSize`).
    @discardableResult
    static func registerCustomThemes(_ entries: [CustomTerminalTheme]) -> [RegistrationFailure] {
        var seen = Set(builtIn.map(\.id))
        var accepted: [TerminalTheme] = []
        var failures: [RegistrationFailure] = []

        for entry in entries {
            let id = entry.id.trimmingCharacters(in: .whitespaces)
            if id.isEmpty {
                failures.append(RegistrationFailure(id: entry.id, reason: "empty id"))
                continue
            }
            if seen.contains(id) {
                failures.append(RegistrationFailure(id: id, reason: "duplicate id"))
                continue
            }

            var ansi: [RGBA] = []
            var badRole: String?
            for role in ansiRoleNames {
                guard let hex = entry.colors[role] else {
                    badRole = "missing \(role)"
                    break
                }
                guard let color = parseHex(hex) else {
                    badRole = "bad hex \"\(hex)\" for \(role)"
                    break
                }
                ansi.append(color)
            }
            if let badRole {
                failures.append(RegistrationFailure(id: id, reason: badRole))
                continue
            }

            // The four remaining roles are optional and inherit from the
            // default theme, so a custom theme can be sixteen lines of ANSI
            // and nothing else. A value that is *present* and unparseable is
            // still a rejection: it was meant to be a color.
            var optionals: [String: RGBA] = [:]
            var badOptional: String?
            for role in ["background", "foreground", "cursor", "selection", "tabBarText"] {
                guard let hex = entry.colors[role] else { continue }
                guard let color = parseHex(hex) else {
                    badOptional = "bad hex \"\(hex)\" for \(role)"
                    break
                }
                optionals[role] = color
            }
            if let badOptional {
                failures.append(RegistrationFailure(id: id, reason: badOptional))
                continue
            }

            let base = driftwoodNight
            seen.insert(id)
            accepted.append(TerminalTheme(
                id: id,
                title: entry.title.isEmpty ? id : entry.title,
                ansi: ansi,
                background: optionals["background"] ?? base.background,
                foreground: optionals["foreground"] ?? base.foreground,
                cursor: optionals["cursor"] ?? base.cursor,
                selection: optionals["selection"] ?? base.selection,
                // Falls back to the theme's own foreground rather than the
                // default theme's: a tab label in the default's sand over a
                // custom theme's pale background would be unreadable, and the
                // foreground the theme *did* declare is by construction
                // legible against its own background.
                tabBarText: optionals["tabBarText"] ?? optionals["foreground"] ?? base.foreground
            ))
        }

        custom = accepted
        return failures
    }

    /// Clears the registry. For the check harness, which registers several
    /// different entry lists in one process; nothing in the app calls it.
    static func resetCustomThemes() {
        custom = []
    }

    /// The selected theme with per-role overrides from `config.terminalPalette`
    /// on top.
    ///
    /// Tolerant per role, unlike registration: an unknown role name or an
    /// unparseable hex is skipped and the rest of the theme still applies. A
    /// hand-edited override is a tweak to a theme that already works, so one
    /// bad line should cost that one color and nothing else. Roles are named
    /// exactly as they are in a custom theme — `ansi0`…`ansi15`, `background`,
    /// `foreground`, `cursor`, `selection`, `tabBarText` — so there is one
    /// vocabulary to learn rather than two.
    static func resolvedTheme(id: String, overrides: [String: String]?) -> TerminalTheme {
        let base = theme(id: id)
        guard let overrides, !overrides.isEmpty else { return base }

        var ansi = base.ansi
        var background = base.background
        var foreground = base.foreground
        var cursor = base.cursor
        var selection = base.selection
        var tabBarText = base.tabBarText

        for (role, hex) in overrides {
            guard let color = parseHex(hex) else { continue }
            switch role {
            case "background": background = color
            case "foreground": foreground = color
            case "cursor": cursor = color
            case "selection": selection = color
            case "tabBarText": tabBarText = color
            default:
                guard let index = ansiRoleNames.firstIndex(of: role) else { continue }
                ansi[index] = color
            }
        }

        return TerminalTheme(
            id: base.id, title: base.title, ansi: ansi,
            background: background, foreground: foreground,
            cursor: cursor, selection: selection, tabBarText: tabBarText
        )
    }

    /// "#RRGGBB" or "#RRGGBBAA" (leading "#" optional, case-insensitive).
    /// Copied from Chestnut's `SpriteTheme.parseHex`, including the
    /// `allSatisfy(\.isHexDigit)` guard: without it `UInt64(_:radix:)` accepts
    /// a leading `-`, so "-12345" would parse as a color.
    static func parseHex(_ string: String) -> RGBA? {
        var hex = Substring(string)
        if hex.hasPrefix("#") { hex = hex.dropFirst() }
        guard hex.count == 6 || hex.count == 8,
              hex.allSatisfy(\.isHexDigit),
              let value = UInt64(hex, radix: 16)
        else { return nil }
        let rgba = hex.count == 6 ? value << 8 | 0xFF : value
        return (
            r: UInt8((rgba >> 24) & 0xFF),
            g: UInt8((rgba >> 16) & 0xFF),
            b: UInt8((rgba >> 8) & 0xFF),
            a: UInt8(rgba & 0xFF)
        )
    }
}
