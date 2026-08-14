import Foundation

/// Hand-edited settings, stored as JSON in
/// `~/Library/Application Support/Driftwood/config.json`.
///
/// This file belongs to the user. Driftwood writes it exactly once in its
/// life, to create it if it's missing — there is no other write path, and a
/// setting that gains a UI moves to `AppState` rather than earning one.
/// Everything the app changes for itself — the panel's frame, the selected
/// theme, font size, opacity — lives in `AppState`, so dragging the window can
/// never clobber a hand-edited hotkey.
///
/// Changes here take effect on next launch; nothing re-reads the file.
struct Config: Codable, Equatable {
    /// Preferred terminal fonts, best first; the first name that resolves
    /// wins. Nerd Font variants come ahead of plain Menlo because prompt
    /// themes like Powerlevel10k draw their separators and icons from the Nerd
    /// Font private-use ranges (U+E0B0, U+F179) that no stock macOS font
    /// carries — without one, those render as Last Resort's
    /// box-with-question-mark.
    ///
    /// Menlo is the floor rather than SF Mono, and that ordering is
    /// deliberate: SF Mono is missing glyphs common prompt themes use (`➜`
    /// U+27A4), so it is a worse floor than Menlo, which has broad coverage
    /// and is what Terminal.app has defaulted to for years.
    ///
    /// **A name that isn't installed degrades silently.** `NSFont(name:)`
    /// returns nil rather than failing, so a typo here costs you the font and
    /// says nothing. If the prompt looks wrong, check which entry actually
    /// resolved — `debug: true` logs it.
    var fontNames = Config.defaultFontNames
    /// Per-role color overrides applied on top of the selected theme:
    /// `{"ansi1": "#ff0000"}`. Role names match a custom theme's:
    /// `ansi0`…`ansi15`, `background`, `foreground`, `cursor`, `selection`,
    /// `tabBarText`. Kept verbatim so saving never rewrites a hand-edited
    /// config; an entry that doesn't parse is ignored per-role at resolve time
    /// (`TerminalTheme.resolvedTheme`).
    var terminalPalette: [String: String]?
    /// User-defined terminal themes (they appear in the right-click Theme
    /// menu alongside the built-ins).
    var terminalThemes: [CustomTerminalTheme]?
    /// Saved commands the palette and the per-command hotkeys type into the
    /// active shell.
    ///
    /// **`run` defaults to false on purpose.** A command with `"run": true`
    /// executes the instant its hotkey is pressed, verbatim, in a real login
    /// shell — no confirmation, and possibly while the panel is hidden. Left
    /// false, the command is typed at the prompt for you to read and run
    /// yourself. `QuickCommand.runsImmediately` carries the full account.
    ///
    /// `newTab` defaults to false as well, and is a convenience rather than a
    /// safety default: with it the command gets a fresh tab of its own instead
    /// of landing in whatever tab is active. See `QuickCommand.opensNewTab`.
    var quickCommands: [QuickCommandConfig]?
    /// Global hotkey bindings, hand-editable: "modifier+modifier+key". At
    /// least one of control/option/command is required (shift alone doesn't
    /// count); a binding without one is rejected and logged. Set a binding to
    /// "" or "none" to disable it.
    var hotkeys = HotkeyConfig()
    /// The shell launched in each tab, and the value exported as `SHELL` to
    /// it. Both come from this one setting so they cannot drift apart — see
    /// `AppDelegate.childEnvironment`.
    var shell = "/bin/zsh"
    /// Arguments passed to the shell. `-l` makes it a login shell, which is
    /// what sources the profile a normal terminal tab would.
    var shellArguments = ["-l"]
    /// The panel's alpha while it is dimmed, under When Unfocused ▸ Dim. Unused
    /// under the other two settings.
    ///
    /// Applied as `panel.alphaValue`, which fades the window whole — text
    /// included. That is the point: a panel whose background dimmed while its
    /// text stayed at full brightness would read as a rendering fault rather
    /// than as a state. It multiplies with the theme's own translucency and
    /// with Opacity ▸, so at a low opacity a dimmed panel is very faint indeed.
    ///
    /// **The floor is far below Opacity ▸'s, and that is safe for a reason
    /// Opacity ▸ cannot rely on.** A panel faded to nothing by Opacity ▸ stays
    /// faded, and the only control that would restore it is a menu on the
    /// window you can no longer see. Dimming only applies while the panel is
    /// unfocused, and `AppDelegate.showPanel` sets the alpha back to 1 on every
    /// summon, so ⌃⌥T is always a way back.
    ///
    /// It is not clamped to zero, though: `alphaValue` does not affect hit
    /// testing, so a fully invisible panel still swallows every click inside
    /// its frame — you would click at your editor and type into a terminal you
    /// cannot see. `dimOpacityRange` keeps a little of it on screen.
    var dimOpacity = 0.8
    /// How many lines of output each tab keeps above the visible screen.
    ///
    /// 500 is SwiftTerm's own default, so leaving this alone is exactly the
    /// behavior every release before this one had. Applied per session at
    /// construction (`TerminalSession.init`); nothing re-reads it, so an edit
    /// reaches existing tabs only after a relaunch.
    ///
    /// **0 means no scrollback at all**, not "unlimited" — the buffer is the
    /// visible rows and nothing more, so anything that scrolls off the top is
    /// gone. There is no unlimited setting: the buffer is a fixed-length ring
    /// allocated up front, and every line costs columns × a cell struct, per
    /// tab. `scrollbackLinesRange` caps it at 100,000 so a hand-typed extra
    /// zero costs memory instead of the launch.
    ///
    /// The alternate screen buffer — what full-screen programs like `less`,
    /// `vim` and `htop` draw into — has no scrollback and this does not change
    /// that. It is SwiftTerm's behavior and matches every other terminal:
    /// scrolling inside those programs is theirs to handle, not the
    /// terminal's.
    var scrollbackLines = 500
    var debug = false

    /// The accepted range for `scrollbackLines`. Clamped on read like
    /// `dimOpacity`, rather than rejected, so a hand-edited 5000000 lands
    /// somewhere usable instead of costing the setting.
    static let scrollbackLinesRange = 0...100_000

    /// The accepted range for `dimOpacity`. A value outside it is clamped on
    /// read rather than rejected, so a hand-edited 0 or 5 lands somewhere
    /// usable instead of costing the setting.
    static let dimOpacityRange = 0.05...1.0

    static let defaultFontNames = [
        "MesloLGS NF",
        "MesloLGS Nerd Font",
        "Hack Nerd Font",
        "FiraCode Nerd Font",
        "JetBrainsMono Nerd Font",
        "Menlo",
    ]

    private enum CodingKeys: String, CodingKey {
        case fontNames, terminalPalette, terminalThemes, quickCommands
        case hotkeys, shell, shellArguments, dimOpacity, scrollbackLines, debug
    }

    init() {}

    /// Tolerant decoding: configs written by older builds lack newer keys, and
    /// keys that have since moved to `AppState` are ignored if still present.
    /// That tolerance is what lets settings move without migration code — a
    /// stale key is inert, never fatal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let names = try c.decodeIfPresent([String].self, forKey: .fontNames) ?? []
        // An empty list would resolve to no font at all and leave the terminal
        // measuring zero-width cells, so it falls back rather than being
        // honored. Deleting every entry reads as "use the defaults".
        fontNames = names.isEmpty ? Self.defaultFontNames : names
        terminalPalette = try c.decodeIfPresent([String: String].self, forKey: .terminalPalette)
        terminalThemes = try c.decodeIfPresent([CustomTerminalTheme].self, forKey: .terminalThemes)
        quickCommands = try c.decodeIfPresent([QuickCommandConfig].self, forKey: .quickCommands)
        hotkeys = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkeys) ?? HotkeyConfig()
        let rawShell = try c.decodeIfPresent(String.self, forKey: .shell) ?? "/bin/zsh"
        shell = rawShell.isEmpty ? "/bin/zsh" : rawShell
        shellArguments = try c.decodeIfPresent([String].self, forKey: .shellArguments) ?? ["-l"]
        let rawDim = try c.decodeIfPresent(Double.self, forKey: .dimOpacity) ?? 0.8
        dimOpacity = rawDim.clamped(to: Self.dimOpacityRange)
        // `try?`, unlike the keys above: a number written as `"5000"` or as
        // `500.5` is a typo people make, and a throwing decode here would cost
        // the whole file rather than the one key. The wrong type reads as
        // absent and falls back to 500.
        let rawScrollback = (try? c.decodeIfPresent(Int.self, forKey: .scrollbackLines)) ?? nil
        scrollbackLines = (rawScrollback ?? 500).clamped(to: Self.scrollbackLinesRange)
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontNames, forKey: .fontNames)
        try c.encodeIfPresent(terminalPalette, forKey: .terminalPalette)
        try c.encodeIfPresent(terminalThemes, forKey: .terminalThemes)
        try c.encodeIfPresent(quickCommands, forKey: .quickCommands)
        try c.encode(hotkeys, forKey: .hotkeys)
        try c.encode(shell, forKey: .shell)
        try c.encode(shellArguments, forKey: .shellArguments)
        // Always written, unlike `debug`: the file `createIfMissing` leaves on
        // disk is the only documentation of this setting a user is guaranteed
        // to find, and a key absent by default is a key nobody knows to add.
        try c.encode(dimOpacity, forKey: .dimOpacity)
        try c.encode(scrollbackLines, forKey: .scrollbackLines)
        if debug { try c.encode(true, forKey: .debug) }
    }

    static var fileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Driftwood/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            // Move the unreadable file aside rather than copy it: defaults are
            // then written to a clean path instead of overwriting JSON the
            // user could have fixed by hand.
            let backup = Self.availableBackupURL(
                base: fileURL.appendingPathExtension("bak"),
                exists: { FileManager.default.fileExists(atPath: $0.path) }
            )
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                NSLog("Config load failed (%@) — original moved to %@",
                      error.localizedDescription, backup.path)
            } catch {
                NSLog("Config load failed and the original could not be moved aside: %@",
                      error.localizedDescription)
            }
            return Config()
        }
    }

    /// First unused backup name (`config.json.bak`, `config.json.bak.1`, …) so
    /// recovering an earlier failure stays possible.
    static func availableBackupURL(base: URL, exists: (URL) -> Bool) -> URL {
        guard exists(base) else { return base }
        for n in 1...99 {
            let candidate = base.appendingPathExtension(String(n))
            if !exists(candidate) { return candidate }
        }
        return base.appendingPathExtension(String(Int(Date().timeIntervalSince1970)))
    }

    /// Writes the defaults so there's a documented file to edit — only when
    /// none exists. Never overwrites: an existing config is the user's.
    func createIfMissing() {
        let url = Self.fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("Config create failed: %@", error.localizedDescription)
        }
    }
}

/// A user-defined terminal theme. `colors` needs all sixteen of
/// `ansi0`…`ansi15`; `background`, `foreground`, `cursor`, `selection` and
/// `tabBarText` are optional and inherit from the default theme. Values are
/// "#RRGGBB" or "#RRGGBBAA".
struct CustomTerminalTheme: Codable, Equatable {
    var id: String
    var title: String
    var colors: [String: String]

    init(id: String, title: String, colors: [String: String]) {
        self.id = id
        self.title = title
        self.colors = colors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        colors = try c.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
    }
}

struct HotkeyConfig: Codable, Equatable {
    /// Show the panel, or hide it if it's already showing.
    var toggle = "control+option+t"
    /// Show the panel and take keyboard focus, without the second press
    /// hiding it. The difference matters when you are not sure whether the
    /// panel is already up: `toggle` would put it away.
    var focus = "control+option+f"
    /// Summon the panel and open a new tab in it.
    var newTab = "control+option+n"
    /// Open the quick-command palette.
    var commands = "control+option+k"
    /// Quit Driftwood. Off by default: it is the one binding whose misfire
    /// costs you every running shell in every tab, and a hotkey that quits an
    /// app is easy to hit by accident while reaching for one that summons it.
    var quit = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toggle = try c.decodeIfPresent(String.self, forKey: .toggle) ?? "control+option+t"
        focus = try c.decodeIfPresent(String.self, forKey: .focus) ?? "control+option+f"
        newTab = try c.decodeIfPresent(String.self, forKey: .newTab) ?? "control+option+n"
        commands = try c.decodeIfPresent(String.self, forKey: .commands) ?? "control+option+k"
        quit = try c.decodeIfPresent(String.self, forKey: .quit) ?? ""
    }

    /// The bindings by name, for the duplicate check `QuickCommands.validate`
    /// runs against them. Built from the stored properties rather than a
    /// hand-written list so a new binding cannot be forgotten here.
    var byName: [String: String] {
        [
            "toggle": toggle, "focus": focus, "newTab": newTab,
            "commands": commands, "quit": quit,
        ]
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
