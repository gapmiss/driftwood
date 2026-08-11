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
    /// Keep the panel above other windows. Off drops it to a normal window
    /// level, where it can be covered.
    var alwaysOnTop = true
    /// Show the panel over full-screen apps.
    var showInFullScreen = true

    private enum CodingKeys: String, CodingKey {
        case frame, theme, fontSize, opacity, alwaysOnTop, showInFullScreen
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
        alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? true
        showInFullScreen = try c.decodeIfPresent(Bool.self, forKey: .showInFullScreen) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(frame.map(StoredFrame.init), forKey: .frame)
        try c.encode(theme, forKey: .theme)
        try c.encode(Double(fontSize), forKey: .fontSize)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(alwaysOnTop, forKey: .alwaysOnTop)
        try c.encode(showInFullScreen, forKey: .showInFullScreen)
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
