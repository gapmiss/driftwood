import CoreGraphics
import Foundation

/// Settings Driftwood writes for itself: the panel's frame and the choices
/// made in the right-click menu.
///
/// Split from `Config` so the app never writes the file the user hand-edits.
/// Anything with a UI lives here; anything hand-edited lives in `Config`.
/// Dragging the window rewrites this file several times a session, and it must
/// never be able to take a hand-edited hotkey with it.
struct AppState: Codable, Equatable {
    /// The panel's frame in screen coordinates; nil until the first move or
    /// resize. Validated against the current displays at launch by
    /// `PanelGeometry.validatedFrame` — a saved frame is a hint, never an
    /// instruction, because the display it names may be gone.
    var frame: CGRect?
    /// Selected theme id (see `TerminalTheme.all`).
    var theme = TerminalTheme.defaultID
    /// Terminal font size. One of `fontSizePresets`; a value from elsewhere is
    /// snapped to the nearest preset on read.
    var fontSize = defaultFontSize
    /// Panel opacity, multiplied into the theme's own background alpha rather
    /// than replacing it — the theme decides how translucent it wants to be,
    /// this scales that decision.
    var opacity = 1.0
    /// What the panel does when it stops being the window you are typing in,
    /// set from When Unfocused ▸. See `FocusLossBehavior`.
    var onFocusLoss = FocusLossBehavior.nothing

    /// `alwaysOnTop` and `showInFullScreen` were keys here through 0.1.0 and are
    /// gone in 0.2.0, along with the two menu rows that wrote them. A
    /// `state.json` written by 0.1.0 still carries both; nothing reads them, and
    /// by the no-migrations rule a key nobody claims is inert rather than an
    /// error. The account of why the settings went is on `TerminalPanel.init`,
    /// beside the level and collection behavior they used to move.
    private enum CodingKeys: String, CodingKey {
        case frame, theme, fontSize, opacity, onFocusLoss
    }

    /// The font sizes offered by Font Size ▸, and the only values `fontSize`
    /// ever holds.
    ///
    /// Discrete presets rather than a stepper or a slider, for the reason
    /// `opacityPresets` gives below: a menu is the whole settings surface
    /// here, and a menu can only offer things that are reachable by keyboard.
    /// ⌘+ / ⌘− step through this list, so the keyboard and the menu move the
    /// same value between the same stops.
    static let fontSizePresets: [CGFloat] = [10, 11, 12, 13, 14, 16]
    static let defaultFontSize: CGFloat = 12

    static let opacityRange = 0.2...1.0

    /// The choices offered by Opacity ▸.
    ///
    /// These are the whole of the setting, not shortcuts alongside a slider. A
    /// slider in a menu is an `NSMenuItem.view`, and AppKit skips view items
    /// when navigating a menu by keyboard, so a slider could only ever be set
    /// with a mouse. That is worse here than it sounds: faded to its floor,
    /// the panel is nearly invisible, and the only control that would restore
    /// it is a slider you have to find and drag on a window you can no longer
    /// see. Discrete items are ordinary items — arrow keys reach them, Return
    /// picks one, the checkmark is the current value. The cost is the fine
    /// control the slider had, spent deliberately.
    ///
    /// Ordered as they appear in the menu, and every entry must stay inside
    /// `opacityRange`: a preset outside it would be clamped on the next read,
    /// so picking it would silently do nothing.
    static let opacityPresets: [Double] = [1.0, 0.9, 0.8, 0.7, 0.5]

    /// Whether a preset is the one currently in effect, for the checkmark.
    /// Exact rather than nearest: a value written between stops by an older
    /// build should show no checkmark instead of pointing at a stop the app
    /// isn't actually using.
    static func isPreset(_ preset: Double, matching value: Double) -> Bool {
        abs(preset - value) < 0.000_001
    }

    /// The nearest offered font size to an arbitrary one. Used on read, so a
    /// hand-edited or older `state.json` lands on a size the menu can show a
    /// checkmark against rather than one nothing in the UI admits to.
    static func nearestFontSize(_ value: CGFloat) -> CGFloat {
        fontSizePresets.min { abs($0 - value) < abs($1 - value) } ?? defaultFontSize
    }

    /// The next preset up or down from the current size, or the current size
    /// when already at the end. Backs ⌘+ / ⌘−, which is why it saturates
    /// rather than wrapping — wrapping would make ⌘+ at 16pt jump to 10pt,
    /// which reads as a glitch.
    static func steppedFontSize(_ value: CGFloat, by step: Int) -> CGFloat {
        let current = nearestFontSize(value)
        guard let index = fontSizePresets.firstIndex(of: current) else { return defaultFontSize }
        let next = min(max(index + step, 0), fontSizePresets.count - 1)
        return fontSizePresets[next]
    }

    init() {}

    /// Tolerant decoding: files written by older builds lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decodeIfPresent(StoredFrame.self, forKey: .frame)?.rect
        // Theme id validation is deferred: custom themes aren't registered yet
        // at decode time, so accept any non-empty id here. `TerminalTheme.theme(id:)`
        // falls back to the default for an id that never shows up.
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? TerminalTheme.defaultID
        let rawSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
            ?? Double(Self.defaultFontSize)
        fontSize = Self.nearestFontSize(CGFloat(rawSize))
        let rawOpacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        opacity = rawOpacity.clamped(to: Self.opacityRange)
        // Decoded as a string and mapped by hand rather than through
        // `Codable`'s synthesised `RawRepresentable` conformance, which
        // *throws* on any value outside the enum. By the no-migrations rule a
        // hand-edited or stale value has to cost the setting, not the file.
        onFocusLoss = FocusLossBehavior(
            try c.decodeIfPresent(String.self, forKey: .onFocusLoss)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(frame.map(StoredFrame.init), forKey: .frame)
        try c.encode(theme, forKey: .theme)
        try c.encode(Double(fontSize), forKey: .fontSize)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(onFocusLoss.rawValue, forKey: .onFocusLoss)
    }

    /// `{x, y, width, height}` rather than `CGRect`'s own `Codable` shape,
    /// which nests an origin and a size and reads badly for a file people open
    /// to see where their window went. Decoding is tolerant per field, so a
    /// truncated object yields a zero and `PanelGeometry.validatedFrame`
    /// rejects it as untrusted rather than throwing the whole file away.
    private struct StoredFrame: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
            y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
            width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
            height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0
        }

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    /// The order When Unfocused ▸ lists them in, and the whole of the setting.
    /// Discrete menu items for the reason `opacityPresets` gives: a menu is the
    /// entire settings surface here, and only ordinary items are reachable by
    /// keyboard.
    static let focusLossChoices: [FocusLossBehavior] = [.nothing, .dim, .hide]

    static var fileURL: URL {
        Config.fileURL.deletingLastPathComponent()
            .appendingPathComponent("state.json")
    }

    /// Loads `state.json`, falling back to defaults when it's missing or
    /// unreadable. Decoding is tolerant, so an unknown or stale key is ignored
    /// rather than fatal, and everything here is a menu click away.
    static func load() -> AppState {
        guard let data = try? Data(contentsOf: fileURL) else { return AppState() }
        do {
            return try JSONDecoder().decode(AppState.self, from: data)
        } catch {
            // Same treatment as a corrupt config: move it aside rather than
            // overwrite it, so nothing is lost to a bad parse.
            let backup = Config.availableBackupURL(
                base: fileURL.appendingPathExtension("bak"),
                exists: { FileManager.default.fileExists(atPath: $0.path) }
            )
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("State load failed (%@) — original moved to %@",
                  error.localizedDescription, backup.path)
            return AppState()
        }
    }

    func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("State save failed: %@", error.localizedDescription)
        }
    }
}

/// What the panel does when it stops being the window keystrokes go to.
///
/// The three values are one mechanism with a different last line, and shipping
/// all three is the point: `dim` and `hide` answer the same complaint from
/// opposite directions, and which one is right depends on what you are doing at
/// the time. The same person wants `hide` while using the panel as a launcher
/// and `dim` while watching a build run in it, which is why this lives here and
/// in the right-click menu rather than in `config.json` — switching is a
/// workflow choice, not a one-time install decision.
///
/// - `nothing` — the panel stays exactly as it is. The default, because it is
///   0.2.0's behavior, and an upgrade that changes how the app behaves without
///   being asked is worse than one that changes nothing.
/// - `dim` — the panel fades to `Config.dimOpacity`. **The panel is
///   borderless: no title bar, no border, no highlight, so a focused panel and
///   an unfocused one are otherwise pixel-identical.** That is the gap this
///   fills. ⌃⌥T behaves differently in those two states (see
///   `AppDelegate.togglePanel`), and until now nothing on screen said which one
///   you were in.
/// - `hide` — the panel is ordered out, so clicking back into your editor puts
///   it away without a keypress. **Hiding is not closing:** `AppDelegate.hidePanel`
///   only calls `orderOut`, so every tab keeps its shell, its scrollback and
///   its half-typed command line. The cost is that you can no longer watch a
///   running command in the panel while you work in another app, which is a
///   real use of an always-on-top window — the trade `dim` refuses to make.
enum FocusLossBehavior: String, Codable, Equatable {
    case nothing
    case dim
    case hide

    /// What When Unfocused ▸ calls this value.
    var menuTitle: String {
        switch self {
        case .nothing: return "Stay Visible"
        case .dim: return "Dim"
        case .hide: return "Hide"
        }
    }

    /// Maps a raw string, including nil and anything unrecognised, onto a
    /// value. The tolerance lives here so the decoder and `make check`
    /// exercise the same function.
    init(_ raw: String?) {
        guard let raw else {
            self = .nothing
            return
        }
        self = FocusLossBehavior(rawValue: raw.lowercased()) ?? .nothing
    }
}
