import AppKit
import CoreText
import ServiceManagement
import SwiftTerm

/// `SwiftTerm.Color`'s public initializer takes 16-bit (0…65535) components;
/// this takes the familiar 8-bit form and scales up. `* 257` maps 0…255 onto
/// 0…65535 exactly, since 255 × 257 == 65535.
private func swiftTermColor(_ c: TerminalTheme.RGBA) -> SwiftTerm.Color {
    SwiftTerm.Color(
        red: UInt16(c.r) * 257, green: UInt16(c.g) * 257, blue: UInt16(c.b) * 257
    )
}

private func nsColor(_ c: TerminalTheme.RGBA) -> NSColor {
    NSColor(
        srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
        blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var config = Config()
    private var state = AppState()
    private var quickCommands: [QuickCommand] = []

    private var panel: TerminalPanel!
    private var rootView: NSView!
    private var effectView: NSVisualEffectView!
    private var tintView: NSView!
    private var tabBar: TabBar!
    private var chromeView: ChromeView!
    private let sessions = SessionStack()
    private let hotkeys = HotkeyCenter()
    private var palette: CommandPalette?

    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var frameSaveWork: DispatchWorkItem?
    private var focusLossWork: DispatchWorkItem?
    /// True for as long as the settings menu is tracking. See
    /// `showSettingsMenu` for why the focus-loss handler cannot work this out
    /// for itself.
    private var menuIsTracking = false

    private let cornerRadius: CGFloat = 10
    /// How far the blur hangs past the root view on every edge, so the
    /// material's own edge stroke lands outside the clip — see `buildPanel`.
    private let blurBleed: CGFloat = 2
    /// How long to wait after the last move or resize before writing
    /// `state.json`. A drag produces an event per pixel, and each one would
    /// otherwise be an atomic write of the whole file; 250ms collapses a drag
    /// into one write while still being short enough that quitting right after
    /// letting go saves the frame you let go at.
    private let frameSaveDelay: TimeInterval = 0.25

    /// How long the panel has to be without the keyboard before
    /// `state.onFocusLoss` acts on it.
    ///
    /// **Losing key status is not the same as being finished with, and the
    /// difference is measured in milliseconds.** Opening the command palette
    /// takes key away from the panel; so does anything else that borrows focus
    /// for a moment. Worse, the two notifications arrive in the wrong order for
    /// a naive handler: the panel's `didResignKey` fires *before* the palette's
    /// `didBecomeKey`, so at the instant the panel resigns, nothing in the app
    /// is key and `panelHasKeyboard` is false. Acting immediately would hide the
    /// panel out from under the palette it just opened.
    ///
    /// So the decision is deferred and re-checked. Anything that takes the
    /// keyboard back inside this window cancels it. 200ms is long enough to
    /// cover the handoff and short enough that a deliberate click into another
    /// app reads as immediate.
    private let focusLossDelay: TimeInterval = 0.2


    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        config.createIfMissing()
        DebugLog.configure(enabled: config.debug)
        state = AppState.load()

        for failure in TerminalTheme.registerCustomThemes(config.terminalThemes ?? []) {
            NSLog("TerminalTheme: skipping custom theme \"%@\" (%@)", failure.id, failure.reason)
            DebugLog.log("theme: rejected \"\(failure.id)\" — \(failure.reason)")
        }

        let validated = QuickCommands.validate(
            config.quickCommands ?? [], reservedHotkeys: config.hotkeys.byName
        )
        quickCommands = validated.commands
        for problem in validated.problems {
            NSLog("QuickCommands: %@ \"%@\" (%@)",
                  problem.dropped ? "dropping" : "keeping", problem.id, problem.reason)
            DebugLog.log("quick command \(problem.id): \(problem.reason)")
        }

        font = Self.resolveFont(names: config.fontNames, size: state.fontSize)
        DebugLog.log("font: resolved \(font.fontName) at \(state.fontSize)pt")

        setUpMainMenu()
        buildPanel()
        openSession(directory: NSHomeDirectory())
        applyTheme()
        layoutContent()
        startFocusTracking()

        // `showPanel` rather than `orderFrontRegardless`, so first launch and
        // every later summon take the same path. Measured: `orderFrontRegardless`
        // shows the panel without making it key, so the terminal was visible
        // but ignored the keyboard until the user clicked it or pressed the
        // summon hotkey. `makeKeyAndOrderFront` shows it *and* gives it the
        // keyboard — see the account on `showPanel`.
        showPanel()

        startHotkeys()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The debounce means the last drag may still be pending. Cancel it and
        // write synchronously, or quitting immediately after a move loses it.
        frameSaveWork?.cancel()
        if let panel { state.frame = panel.frame }
        state.save()
        hotkeys.stop()
    }

    // MARK: - Panel construction

    /// The view stack, bottom to top: blur, tint, tab strip, terminal, chrome.
    private func buildPanel() {
        let screens = NSScreen.screens.map {
            PanelScreen(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let frame = PanelGeometry.validatedFrame(
            saved: state.frame,
            screens: screens,
            defaultSize: PanelGeometry.defaultSize,
            mainVisible: NSScreen.main?.visibleFrame ?? PanelGeometry.fallbackVisibleFrame
        )

        panel = TerminalPanel(contentRect: frame)
        panel.delegate = self

        // **The root view is a plain view that clips, and the blur is a
        // subview that hangs `blurBleed` past every edge of it. That is what
        // makes the panel borderless.**
        //
        // Two separate things drew an outline. The first was ours: a 1pt white
        // hairline at 15% alpha, set here as the effect view's layer border to
        // define the rounded edge. Deleting it left the outline on screen,
        // because the second one is `NSVisualEffectView`'s own. Every material
        // tested — `.hudWindow` under both blending modes, `.popover`,
        // `.underWindowBackground` — paints a light stroke at the view's edge,
        // following whatever corner radius the layer has, and a plain layer
        // with the same radius and the same shadow paints none. `maskImage`
        // does not suppress it either; the stroke just follows the mask.
        //
        // So the stroke is clipped away instead. The effect view is inset by a
        // negative amount, putting its edge outside the root view, and the
        // root view masks to its own rounded bounds. Nothing is lost: the blur
        // still covers the panel edge to edge, and only the material's edge
        // treatment falls outside. 1pt is enough — 2pt is used for the same
        // reason a hairline is 1pt: the stroke is one *point* wide, so a
        // fractional scale factor could round it to more than one pixel.
        //
        // `.borderless` in the style mask never had anything to do with this.
        // It means "no title bar".
        rootView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        rootView.autoresizingMask = [.width, .height]
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = cornerRadius
        // Clip subviews to the rounded shape. Without this the terminal view,
        // which fills the panel edge to edge, paints square corners over the
        // rounded blur — the blur is still round, and the content covers it.
        rootView.layer?.masksToBounds = true

        effectView = NSVisualEffectView(
            frame: rootView.bounds.insetBy(dx: -blurBleed, dy: -blurBleed)
        )
        // Not `.width`/`.height` by accident: the four margins are fixed, so
        // AppKit keeps the −`blurBleed` overhang on every edge as the panel
        // resizes. A flexible margin here would let the overhang shrink to
        // zero and the stroke reappear at some sizes and not others.
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        rootView.addSubview(effectView)

        // The theme's own tint, layered over the system blur and deliberately
        // independent of the desktop behind it. Starboard tried matching a
        // system material and found it a losing game: the exact recipe is
        // private, OS-version-tuned, and reacts live to the wallpaper, so
        // chasing it means drifting apart on every macOS release. A fixed
        // color stays where you put it.
        tintView = NSView(frame: rootView.bounds)
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        rootView.addSubview(tintView)

        tabBar = TabBar(frame: TerminalMetrics.tabBarFrame(in: rootView.bounds))
        tabBar.autoresizingMask = [.width, .minYMargin]
        tabBar.isHidden = true
        tabBar.onSelect = { [weak self] index in self?.selectTab(index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onNewTab = { [weak self] in self?.newTab() }
        tabBar.onDrag = { [weak self] event in self?.panel.performDrag(with: event) }
        rootView.addSubview(tabBar)

        chromeView = ChromeView(frame: rootView.bounds)
        chromeView.autoresizingMask = [.width, .height]
        chromeView.onResize = { [weak self] edges, delta in self?.resizePanel(edges, by: delta) }
        chromeView.onResizeFinished = { [weak self] in self?.scheduleFrameSave() }
        chromeView.onContextMenu = { [weak self] event in self?.showSettingsMenu(event) }
        chromeView.onWindowDrag = { [weak self] event in self?.panel.performDrag(with: event) }
        rootView.addSubview(chromeView)

        panel.contentView = rootView
        enforceMinimumSize()
    }

    /// Grow the panel if it is below the minimum for the current font and tab
    /// strip. Call this after anything that *raises* the minimum.
    ///
    /// This is the floor that `NSWindow.minSize` used to be. The panel is not
    /// `.resizable` any more (see `TerminalPanel.init` for why), and `minSize`
    /// is ignored on a window that is not — so nothing but this stops a panel
    /// from sitting below its own minimum. `minSize` never covered this case
    /// well in the first place: setting it does not resize a window that is
    /// already too small, it only constrains the next `setFrame`, so raising
    /// the font size left the panel undersized until something else moved it.
    private func enforceMinimumSize() {
        let minimum = TerminalMetrics.minimumPanelSize(
            font: font, showingTabBar: sessions.showsTabBar
        )
        let grown = PanelGeometry.grownToMinimum(panel.frame, minimum: minimum)
        guard grown != panel.frame else { return }
        panel.setFrame(grown, display: true)
        layoutContent()
    }

    // MARK: - Sessions

    /// SwiftTerm's default environment plus `SHELL`.
    ///
    /// Passing `nil` for `startProcess`'s `environment` makes it fall back to
    /// `Terminal.getEnvironmentVariables()`, a deliberately minimal set —
    /// `TERM`, `LANG`, and a few identity variables — that does not include
    /// `SHELL`. In a normal terminal `login(1)` sets that; nothing does here,
    /// so the child shell starts with `SHELL` empty.
    ///
    /// That is not cosmetic. Tools that read `$SHELL` to decide which dialect
    /// to emit guess wrong and produce bash for a zsh session: `ngrok
    /// completion`, run from `.zshrc`, emits a bash completion script whose
    /// `[[ $(type -t compopt) = "builtin" ]]` line makes zsh fail with
    /// `(eval):type:11434: bad option: -t` on every single launch.
    /// Powerlevel10k's instant prompt then reports the resulting stray output
    /// as a configuration warning, which points at the user's `.zshrc` rather
    /// than at the terminal — the original symptom was several layers removed
    /// from this line.
    ///
    /// Appended rather than assigned unconditionally, so that if a future
    /// SwiftTerm starts providing `SHELL` itself, its value wins instead of
    /// being silently shadowed by ours.
    private func childEnvironment() -> [String] {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        if !environment.contains(where: { $0.hasPrefix("SHELL=") }) {
            environment.append("SHELL=\(config.shell)")
        }
        return environment
    }

    @discardableResult
    private func openSession(directory: String) -> TerminalSession {
        let session = TerminalSession(
            frame: TerminalMetrics.contentFrame(
                in: rootView.bounds, font: font, showingTabBar: sessions.count >= 1
            ),
            shell: config.shell,
            scrollbackLines: config.scrollbackLines
        )
        session.view.font = font
        session.onTitleChange = { [weak self] in self?.refreshTabBar() }
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            closeTab(id: session.id)
        }

        sessions.add(session)
        session.start(
            shell: config.shell,
            arguments: config.shellArguments,
            environment: childEnvironment(),
            directory: directory
        )
        applyTheme(to: session)
        swapVisibleSession()
        return session
    }

    /// Put only the active session's view in the hierarchy. A background tab
    /// keeps its shell and its scrollback and draws nothing.
    private func swapVisibleSession() {
        for session in sessions.sessions where session !== sessions.active {
            session.view.removeFromSuperview()
        }
        guard let active = sessions.active else { return }
        if active.view.superview !== rootView {
            // Below the chrome, which must stay on top to keep hit-testing.
            rootView.addSubview(active.view, positioned: .below, relativeTo: chromeView)
        }
        refreshTabBar()
        layoutContent()
        focusActiveSession()
    }

    private func focusActiveSession() {
        guard let active = sessions.active else { return }
        panel.makeFirstResponder(active.view)
    }

    private func refreshTabBar() {
        tabBar.titles = sessions.sessions.map(\.title)
        tabBar.activeIndex = sessions.activeIndex
        let showing = sessions.showsTabBar
        if tabBar.isHidden == showing {
            tabBar.isHidden = !showing
            enforceMinimumSize()
            layoutContent()
        }
    }

    private func layoutContent() {
        tabBar.frame = TerminalMetrics.tabBarFrame(in: rootView.bounds)
        sessions.active?.view.frame = TerminalMetrics.contentFrame(
            in: rootView.bounds, font: font, showingTabBar: sessions.showsTabBar
        )
    }

    // MARK: - Tabs

    @objc private func newTab() {
        // A new tab starts where the active one is, when the shell has told us
        // — OSC 7, which a stock zsh with no prompt framework never emits. The
        // home directory is the fallback rather than an error.
        let directory = sessions.active?.inheritableDirectory(fallback: NSHomeDirectory())
            ?? NSHomeDirectory()
        openSession(directory: directory)
    }

    @objc private func closeCurrentTab() {
        guard let active = sessions.active else { return }
        closeTab(id: active.id)
    }

    private func closeTab(at index: Int) {
        guard let session = sessions.session(at: index) else { return }
        closeTab(id: session.id)
    }

    private func closeTab(id: UUID) {
        guard let session = sessions.sessions.first(where: { $0.id == id }) else { return }
        session.view.removeFromSuperview()
        sessions.close(id: id)

        // Closing the last tab hides the panel rather than quitting, so the
        // summon hotkey brings back a fresh shell. Quitting instead would make
        // ⌘W an app-killer that looks like a window-closer, and there is no
        // Dock icon to relaunch from.
        if sessions.isEmpty {
            hidePanel()
            return
        }
        swapVisibleSession()
    }

    private func selectTab(_ index: Int) {
        sessions.select(index: index)
        swapVisibleSession()
    }

    @objc private func selectTabFromMenu(_ sender: NSMenuItem) {
        selectTab(sender.tag)
    }

    @objc private func nextTab() {
        sessions.cycle(by: 1)
        swapVisibleSession()
    }

    @objc private func previousTab() {
        sessions.cycle(by: -1)
        swapVisibleSession()
    }

    // MARK: - Showing and hiding

    /// Show the panel and give it the keyboard.
    ///
    /// **`makeKeyAndOrderFront` on a nonactivating panel is the whole focus
    /// model.** A `.nonactivatingPanel` that returns true from `canBecomeKey`
    /// is meant to accept keystrokes as the key window *without* Driftwood
    /// becoming the active app: you press ⌃⌥T over your editor, type a
    /// command, press it again, and the editor never lost focus — its title
    /// bar stays active throughout.
    ///
    /// **What was measured, on macOS 15, with VSCodium frontmost.** After this
    /// call the panel reports `isKeyWindow == true`, and VSCodium is still the
    /// frontmost application — checked from outside the process with
    /// `lsappinfo front`, not only from `NSWorkspace` inside it. So the panel
    /// does take the keyboard, and taking it does not move the system's idea of
    /// which app is in front. Both facts go into `DebugLog` on every summon, so
    /// this is re-checkable with `debug: true` rather than by reading code.
    ///
    /// **`NSApp.isActive` reads `true` here, and that is not the contradiction
    /// it looks like.** It says the *app* considers itself active because it
    /// owns the key window; it does not say Driftwood is frontmost, and the two
    /// disagree for exactly this window style. Do not use `NSApp.isActive` to
    /// decide whether the summon stole focus — it will always say yes. Ask
    /// `NSWorkspace.shared.frontmostApplication`.
    ///
    /// What has *not* been tested is a real keypress arriving at the shell
    /// while another app stays focused behind. That needs a human at the
    /// keyboard; CLAUDE.md carries it as step 1 of the smoke test.
    ///
    /// The documented fallback, if this ever stops working, is
    /// `NSApp.activate(ignoringOtherApps: true)` here and `NSApp.hide(nil)` on
    /// dismiss. That path *works* but costs the whole point: the app behind
    /// visibly deactivates. Do not switch to it without re-testing this one
    /// first, and record the result here — the difference is subtle enough
    /// that it reads as a bug if nobody wrote down that it was tested.
    private func showPanel() {
        if sessions.isEmpty { openSession(directory: NSHomeDirectory()) }
        // A panel hidden while dimmed would otherwise come back dimmed and stay
        // that way until the next focus change.
        focusLossWork?.cancel()
        focusLossWork = nil
        panel.alphaValue = 1
        rescueFrameIfLost()
        panel.makeKeyAndOrderFront(nil)
        focusActiveSession()
        DebugLog.log(
            "show: key=\(panel.isKeyWindow) appActive=\(NSApp.isActive) "
            + "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"
        )
    }

    private func hidePanel() {
        palette?.dismiss()
        panel.orderOut(nil)
    }

    /// Is the panel the window keystrokes are going to right now?
    ///
    /// The palette counts. It is a second `NSPanel`, so opening it takes key
    /// status away from `panel` — without this, ⌃⌥T with the palette open would
    /// read as "visible but not focused" and pull the keyboard back to the
    /// terminal underneath, leaving the palette on screen and inert.
    private var panelHasKeyboard: Bool {
        panel.isKeyWindow || (palette?.isKeyWindow ?? false)
    }

    /// Is the panel being used right now, whether or not it holds the keyboard?
    ///
    /// **This is a wider question than `panelHasKeyboard`, and asking the
    /// narrow one instead was a bug.** `CommandPalette` is built to survive
    /// losing key status — its `init` says so, so that a half-typed filter is
    /// not thrown away by a stray click into another app. "The palette is open"
    /// and "the palette has the keyboard" are therefore different conditions.
    /// Under `onFocusLoss: "hide"` the narrow question hid the panel while the
    /// palette sat visible above it, and because `hidePanel` dismisses the
    /// palette, both disappeared and the palette's contents were gone for good.
    ///
    /// The known cost: a palette left open pins the panel on screen, because
    /// nothing here can tell a palette you are reading from one you walked away
    /// from. Driftwood is never the frontmost application, so there is no
    /// frontmost app to compare against. Escape or running a command closes the
    /// palette and releases the pin.
    private var panelIsInUse: Bool {
        panelHasKeyboard || (palette?.isVisible ?? false) || menuIsTracking
    }

    /// Watch every window in the app for a change of key status, so
    /// `state.onFocusLoss` can act when the panel stops being the thing you
    /// are typing in.
    ///
    /// **Registered with `object: nil`, meaning every window, not just the
    /// panel.** The palette is created and destroyed on demand, so an observer
    /// bound to a specific window could not cover it, and the palette is
    /// exactly the window whose key status has to be counted — see
    /// `panelHasKeyboard`. Each notification re-asks the same question rather
    /// than trusting which window sent it.
    private func startFocusTracking() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(
                self, selector: #selector(keyWindowChanged),
                name: name, object: nil
            )
        }
    }

    @objc private func keyWindowChanged() {
        // Any change supersedes a pending decision, including one that was
        // about to hide the panel.
        focusLossWork?.cancel()
        focusLossWork = nil

        if panelIsInUse {
            panel.alphaValue = 1
            return
        }
        guard state.onFocusLoss != .nothing, panel.isVisible else { return }

        // Deferred and re-checked — see `focusLossDelay` for why acting here
        // would hide the panel out from under its own palette.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !panelIsInUse, panel.isVisible else { return }
            DebugLog.log(
                "focus lost: \(state.onFocusLoss.rawValue) (dimOpacity=\(config.dimOpacity)) "
                + "(panelKey=\(panel.isKeyWindow) paletteKey=\(palette?.isKeyWindow ?? false) "
                + "paletteVisible=\(palette?.isVisible ?? false))"
            )
            switch state.onFocusLoss {
            case .nothing:
                break
            case .dim:
                panel.alphaValue = CGFloat(config.dimOpacity)
            case .hide:
                // Re-entrant: `orderOut` resigns key and calls straight back
                // into this handler. The `panel.isVisible` guard above is what
                // ends the recursion.
                hidePanel()
            }
        }
        focusLossWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + focusLossDelay, execute: work)
    }

    /// ⌃⌥T. Three states, not two.
    ///
    /// **Visible and focused are different questions, and asking only the first
    /// one costs a press.** A nonactivating panel keeps standing on screen after
    /// you click back into your editor; it is still visible, it just no longer
    /// has the keyboard. `panel.isVisible` alone cannot tell that apart from
    /// "visible and you are typing in it", so the hotkey hid the panel and the
    /// user pressed it a second time to get it back — twice to do one thing.
    ///
    /// So the rule is that ⌃⌥T always leaves you with a panel you can type in,
    /// and only hides the panel when the panel is already what you were typing
    /// in. Summoning while it is visible-but-unfocused takes the keyboard,
    /// which is what ⌃⌥F does; the two hotkeys overlap in that one state on
    /// purpose. ⌃⌥F is the binding that *never* hides.
    @objc private func togglePanel() {
        if panel.isVisible && panelHasKeyboard {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Geometry

    private func resizePanel(_ edges: TerminalMetrics.ResizeEdges, by delta: CGSize) {
        let minimum = TerminalMetrics.minimumPanelSize(
            font: font, showingTabBar: sessions.showsTabBar
        )
        let next = TerminalMetrics.resized(
            panel.frame, edges: edges, by: delta, minimum: minimum
        )
        panel.setFrame(next, display: true)
        layoutContent()
    }

    func windowDidMove(_ notification: Notification) {
        scheduleFrameSave()
    }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
    }

    /// Debounced frame persistence — see `frameSaveDelay`.
    private func scheduleFrameSave() {
        frameSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            state.frame = panel.frame
            state.save()
        }
        frameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + frameSaveDelay, execute: work)
    }

    /// Put the panel back on a display if it is no longer on one.
    ///
    /// The display list changes while the app runs — a monitor is unplugged, a
    /// laptop is undocked — and until now only launch re-checked the frame
    /// against it, so a panel left on a display that went away stayed at
    /// coordinates nothing could show until the next relaunch. Reset Position
    /// could not fix it: that row is in the panel's own right-click menu, and
    /// the panel is not there to right-click. See `PanelGeometry.isReachable`
    /// for why this is a narrower test than the one at launch.
    private func rescueFrameIfLost() {
        let screens = NSScreen.screens.map {
            PanelScreen(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        guard !screens.isEmpty,
              !PanelGeometry.isReachable(panel.frame, screens: screens) else { return }
        DebugLog.log("rescue: panel frame \(panel.frame) is off every display")
        resetPosition()
    }

    @objc private func resetPosition() {
        let visible = NSScreen.main?.visibleFrame ?? PanelGeometry.fallbackVisibleFrame
        panel.setFrame(
            PanelGeometry.defaultFrame(size: PanelGeometry.defaultSize, onVisible: visible),
            display: true
        )
        layoutContent()
        scheduleFrameSave()
    }

    // MARK: - Theme and font

    /// The first installed name from the list, falling back to the monospaced
    /// system font. See `Config.fontNames` for why the order is what it is and
    /// why a typo here is silent.
    private static func resolveFont(names: [String], size: CGFloat) -> NSFont {
        names.lazy.compactMap { NSFont(name: $0, size: size) }.first
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private var resolvedTheme: TerminalTheme {
        TerminalTheme.resolvedTheme(id: state.theme, overrides: config.terminalPalette)
    }

    /// Repaint every open session, not just the active one. A background tab
    /// that kept the old palette would show it the moment you switched to it,
    /// which reads as the theme change having half-failed.
    private func applyTheme() {
        let theme = resolvedTheme
        for session in sessions.sessions { applyTheme(to: session, theme: theme) }

        var background = nsColor(theme.background)
        // Opacity scales the theme's own alpha rather than replacing it: the
        // theme decides how translucent it wants to be, and the menu setting
        // moves that decision without discarding it.
        background = background.withAlphaComponent(
            background.alphaComponent * CGFloat(state.opacity)
        )
        tintView.layer?.backgroundColor = background.cgColor
        // **The blur follows the theme, not the system.** See
        // `TerminalTheme.isLight`: an `NSVisualEffectView` reads its material
        // from the effective appearance, so Paper over a Dark Mode `.hudWindow`
        // came out grey instead of warm white. Pinning the appearance here
        // makes a light theme blur light and a dark theme blur dark under
        // either system setting. Set on the effect view alone — the panel and
        // the terminal draw in explicit theme colors, and forcing an appearance
        // on the whole window would also repaint AppKit's own menu chrome.
        effectView.appearance = NSAppearance(named: theme.isLight ? .vibrantLight : .vibrantDark)
        tabBar.theme = theme
    }

    private func applyTheme(to session: TerminalSession, theme: TerminalTheme? = nil) {
        let theme = theme ?? resolvedTheme
        // `installColors` indexes 0…15 without checking; the registry
        // guarantees the count, and this assertion is what would catch a
        // built-in theme edited to fifteen entries.
        precondition(
            theme.ansi.count == TerminalTheme.swiftTermPaletteSize,
            "theme \(theme.id) has \(theme.ansi.count) ANSI colors, not 16"
        )
        session.view.installColors(theme.ansi.map(swiftTermColor))
        session.view.nativeForegroundColor = nsColor(theme.foreground)
        // Transparent, so the tint layer and the window blur behind it show
        // through. The theme's `background` paints that tint, not this.
        session.view.nativeBackgroundColor = .clear
        // **`nativeBackgroundColor` alone is not enough, and this line is the
        // whole reason the panel is see-through.** In SwiftTerm 1.15 the
        // setter (`MacTerminalView.swift:687`) records the color and pushes it
        // into `terminal.backgroundColor`; it never touches the view's layer.
        // The layer is painted once, in `setupOptions()`, which runs from
        // `setup()` during `init` and from nowhere else — by then
        // `terminal.backgroundColor = Color.defaultBackground` has already made
        // `nativeBackgroundColor` SwiftTerm's opaque default. So the terminal
        // view carried an opaque layer for its whole life, covering the tint
        // and the blur underneath: the panel rendered as a solid slab, with the
        // desktop behind it invisible, and no theme or opacity setting could
        // reach it.
        //
        // Cell drawing is unaffected either way. A cell with the default
        // background fills with `nativeBackgroundColor`, and filling with a
        // zero-alpha color composites to nothing.
        session.view.layer?.backgroundColor = NSColor.clear.cgColor
        session.view.caretColor = nsColor(theme.cursor)
        session.view.selectedTextBackgroundColor = nsColor(theme.selection)
        // **Selected text is drawn in `NSColor.black` unless this line sets it.**
        // SwiftTerm 1.15 does not tint the selection over the glyphs that are
        // already there. It re-renders the selected run with two overridden
        // attributes — the background *and* the foreground
        // (`AppleTerminalView.swift:751`) — and `selectedTextForegroundColor`
        // defaults to `NSColor.black` (`MacTerminalView.swift:743`). Leave it
        // alone and every selected character on a dark theme is black on a dark
        // band, which is what 0.1.0 shipped. Paper escaped it only because black
        // ink happens to read on a light background.
        //
        // Setting it to the theme's own foreground keeps selected text the color
        // it already was. The trade is that a selection flattens ANSI color:
        // SwiftTerm overrides the foreground of every selected run, so colored
        // output goes monochrome while it is selected. That is SwiftTerm's
        // design and there is no attribute to opt out of it.
        session.view.selectedTextForegroundColor = nsColor(theme.foreground)
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        state.theme = id
        state.save()
        applyTheme()
    }

    @objc private func selectFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? CGFloat else { return }
        setFontSize(size)
    }

    @objc private func increaseFontSize() {
        setFontSize(AppState.steppedFontSize(state.fontSize, by: 1))
    }

    @objc private func decreaseFontSize() {
        setFontSize(AppState.steppedFontSize(state.fontSize, by: -1))
    }

    private func setFontSize(_ size: CGFloat) {
        guard size != state.fontSize else { return }
        state.fontSize = size
        state.save()
        font = Self.resolveFont(names: config.fontNames, size: size)
        for session in sessions.sessions { session.view.font = font }
        enforceMinimumSize()
        // The cell height changed, so the centered slack did too — relayout
        // rather than waiting for the next resize.
        layoutContent()
    }

    /// When Unfocused ▸. Three ordinary menu items, so arrow keys reach them
    /// and the checkmark is the current value — see `AppState.opacityPresets`
    /// for why nothing in this menu is a slider.
    private func focusLossMenu() -> NSMenu {
        let submenu = NSMenu()
        for choice in AppState.focusLossChoices {
            let entry = item(choice.menuTitle, #selector(selectFocusLoss(_:)))
            entry.representedObject = choice.rawValue
            entry.state = choice == state.onFocusLoss ? .on : .off
            submenu.addItem(entry)
        }
        return submenu
    }

    @objc private func selectFocusLoss(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        state.onFocusLoss = FocusLossBehavior(raw)
        state.save()
        // Picking "Stay Visible" while the panel is dimmed has to undo the dim,
        // or the setting reads as having done nothing until the next focus
        // change. `showSettingsMenu` restores the keyboard on the way out, so
        // the panel is in use here by definition.
        panel.alphaValue = 1
    }

    @objc private func selectOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        state.opacity = value.clamped(to: AppState.opacityRange)
        state.save()
        applyTheme()
    }


    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Launch at Login toggle failed: %@", error.localizedDescription)
        }
    }

    @objc private func editConfiguration() {
        NSWorkspace.shared.open(Config.fileURL)
    }

    @objc private func checkForUpdates() {
        NSWorkspace.shared.open(AppInfo.releasesURL)
    }

    // MARK: - Quick commands

    /// ⌃⌥K opens the palette, and pressing it again closes it.
    ///
    /// The second press has to dismiss rather than re-present. Re-presenting an
    /// open palette rebuilt its contents underneath a user who was already
    /// typing into it and reset the highlighted row, so ⏎ fired whichever
    /// command happened to be first rather than the one that looked selected.
    /// It also has to match the summon hotkey's behaviour: every other binding
    /// in Driftwood toggles, so a palette that only ever opened left the
    /// keyboard with no way to back out except Escape.
    @objc private func showPalette() {
        if let open = palette, open.isVisible {
            open.dismiss()
            return
        }
        let palette = CommandPalette()
        self.palette = palette
        palette.onRun = { [weak self] id in self?.fireQuickCommand(id: id) }
        palette.onClose = { [weak self] in self?.palette = nil }
        showPanel()
        palette.present(commands: quickCommands, above: panel.frame)
    }

    @objc private func fireQuickCommandFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        fireQuickCommand(id: id)
    }

    /// Type a saved command into the active shell, and press Return only when
    /// the command opted in.
    ///
    /// The panel is summoned first, unconditionally. A command fired into a
    /// hidden window is invisible: with `run: true` you would have no idea
    /// what just executed, and with `run: false` the text would be sitting at
    /// a prompt nobody can see, ready to run on the next Return that reaches
    /// the panel.
    private func fireQuickCommand(id: String) {
        guard let command = quickCommands.first(where: { $0.id == id }) else { return }
        showPanel()
        // A `newTab` command types into a shell that started microseconds ago,
        // so it waits for that shell's prompt first. `TerminalSession.whenReady`
        // says what happens without the wait: the tty echoes the command at the
        // top of the screen and the shell draws it again at its prompt, one
        // above the other. A command going into an existing tab is sent
        // straight away — that shell has been running since its tab opened, and
        // `whenReady` would return on the first poll anyway.
        if command.opensNewTab {
            newTab()
            guard let session = sessions.active else { return }
            session.whenReady { [weak session] in
                guard let session else { return }
                session.send(text: command.command)
                if command.runsImmediately { session.send(text: "\r") }
            }
        } else {
            guard let session = sessions.active else { return }
            session.send(text: command.command)
            if command.runsImmediately { session.send(text: "\r") }
        }
        DebugLog.log(
            "quick command \(id): \(command.runsImmediately ? "ran" : "typed")"
            + (command.opensNewTab ? " in a new tab" : "")
        )
    }

    // MARK: - Hotkeys

    private func startHotkeys() {
        hotkeys.onToggle = { [weak self] in self?.togglePanel() }
        hotkeys.onFocus = { [weak self] in self?.showPanel() }
        hotkeys.onNewTab = { [weak self] in
            self?.showPanel()
            self?.newTab()
        }
        hotkeys.onCommands = { [weak self] in self?.showPalette() }
        hotkeys.onQuit = { NSApp.terminate(nil) }
        hotkeys.onQuickCommand = { [weak self] id in self?.fireQuickCommand(id: id) }
        hotkeys.start(config: config.hotkeys, quickCommands: quickCommands)
    }

    // MARK: - Menus

    /// The hidden main menu.
    ///
    /// Never drawn — a nonactivating panel never makes Driftwood the frontmost
    /// app, so its menu bar never displays — and it exists purely so that
    /// ⌘-key equivalents resolve. Without a main menu at all there is no
    /// routing of ⌘C/⌘V/⌘A to the terminal view's standard responder-chain
    /// actions, and an accessory app with no Dock icon otherwise has no reason
    /// to set one up.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        // **No ⌘Q, deliberately.** This row exists so the menu is well-formed;
        // it is never drawn, because Driftwood never becomes the frontmost app.
        // Giving it the usual key equivalent made ⌘Q a second, unremovable quit
        // binding that fired whenever the panel held the keyboard — including
        // for someone who had set `hotkeys.quit` to something else on purpose,
        // and including a ⌘Q meant for the app they thought was in front. That
        // costs every running shell in every tab, which is the same reason
        // `Config.quit` is off by default. Quitting is the right-click menu's
        // Quit Driftwood row, or `hotkeys.quit` if one is configured.
        appMenu.addItem(withTitle: "Quit Driftwood",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let tabsMenuItem = NSMenuItem()
        mainMenu.addItem(tabsMenuItem)
        let tabsMenu = NSMenu(title: "Tabs")
        tabsMenuItem.submenu = tabsMenu
        tabsMenu.addItem(targeted("New Tab", #selector(newTab), "t"))
        tabsMenu.addItem(targeted("Close Tab", #selector(closeCurrentTab), "w"))
        let next = targeted("Next Tab", #selector(nextTab), "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        tabsMenu.addItem(next)
        let previous = targeted("Previous Tab", #selector(previousTab), "[")
        previous.keyEquivalentModifierMask = [.command, .shift]
        tabsMenu.addItem(previous)
        for n in 1...9 {
            let item = targeted("Tab \(n)", #selector(selectTabFromMenu(_:)), String(n))
            // The tag carries the zero-based index, so the action needs no
            // parsing of the title.
            item.tag = n - 1
            tabsMenu.addItem(item)
        }
        // "+" rather than "=" would need shift held to match; AppKit compares
        // the typed character, and ⌘= is what an unshifted press produces on a
        // US layout. Both are registered so either reaches the same action.
        tabsMenu.addItem(targeted("Bigger Text", #selector(increaseFontSize), "="))
        tabsMenu.addItem(targeted("Bigger Text", #selector(increaseFontSize), "+"))
        tabsMenu.addItem(targeted("Smaller Text", #selector(decreaseFontSize), "-"))

        NSApp.mainMenu = mainMenu
    }

    private func targeted(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// The right-click menu, which is the whole settings surface — there is no
    /// Settings window, following Chestnut's convention.
    private func showSettingsMenu(_ event: NSEvent) {
        let menu = buildSettingsMenu()
        // Carbon queues hotkey presses while a menu tracks and replays them
        // the instant tracking ends, so every binding is handed back to the
        // system for the duration. `HotkeyCenter.setEnabled` says what that
        // looks like when it is skipped.
        hotkeys.setEnabled(false, config: config.hotkeys, quickCommands: quickCommands)
        // **The settings menu is the one case the focus-loss handler cannot
        // work out for itself.** A tracking `NSMenu` runs its own event loop,
        // and whether that costs the panel its key status is AppKit's business,
        // not something observable from here — under `onFocusLoss: "hide"` a
        // panel that resigned key here would be ordered out from under the menu
        // popped from it, leaving the settings surface floating over nothing.
        // `popUpContextMenu` blocks until tracking ends, so a flag around it is
        // exact where the 200ms delay would only be likely.
        menuIsTracking = true
        focusLossWork?.cancel()
        focusLossWork = nil
        NSMenu.popUpContextMenu(menu, with: event, for: chromeView)
        menuIsTracking = false
        hotkeys.setEnabled(true, config: config.hotkeys, quickCommands: quickCommands)
        // **Take the keyboard back rather than re-asking who has it.** Asking
        // was a bug: at the instant tracking ends the panel has not necessarily
        // regained key status, so under `onFocusLoss: "hide"` the answer was
        // "nobody", and picking a theme out of this menu put the panel away
        // 200ms later. Someone who just used the panel's own settings menu was
        // using the panel, so the keyboard goes back where it was.
        if panel.isVisible { showPanel() }
    }

    private func buildSettingsMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(submenu("Theme", themeMenu()))
        menu.addItem(submenu("Font Size", fontSizeMenu()))
        menu.addItem(submenu("Opacity", opacityMenu()))
        menu.addItem(submenu("When Unfocused", focusLossMenu()))

        menu.addItem(.separator())
        menu.addItem(item("New Tab", #selector(newTab), hotkey: config.hotkeys.newTab))
        menu.addItem(submenu("Quick Commands", quickCommandMenu()))

        menu.addItem(.separator())
        // First in this group, and not last. The three rows below it are verbs
        // that happen when you pick them; this one reports a state with a
        // checkmark, and it reads better above them than buried between them.
        // It also keeps a rarely-wanted toggle away from Quit Driftwood, which
        // ends every shell in every tab — arrowing one row past the bottom of
        // this group lands on the inert version row instead.
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Reset Position", #selector(resetPosition)))
        menu.addItem(item("Edit Configuration…", #selector(editConfiguration)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))

        menu.addItem(.separator())
        let version = NSMenuItem(title: "Driftwood \(AppInfo.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        // Target left nil so it walks the responder chain to NSApp;
        // `item(_:_:hotkey:)` would point it at this delegate, which does not
        // implement `terminate:`, and the row would draw disabled.
        menu.addItem(NSMenuItem(title: "Quit Driftwood",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: ""))

        return menu
    }

    private func themeMenu() -> NSMenu {
        let submenu = NSMenu()
        for theme in TerminalTheme.all {
            let entry = item(theme.title, #selector(selectTheme(_:)))
            entry.representedObject = theme.id
            entry.state = theme.id == state.theme ? .on : .off
            submenu.addItem(entry)
        }
        return submenu
    }

    private func fontSizeMenu() -> NSMenu {
        let submenu = NSMenu()
        for size in AppState.fontSizePresets {
            let entry = item("\(Int(size))pt", #selector(selectFontSize(_:)))
            entry.representedObject = size
            entry.state = size == state.fontSize ? .on : .off
            submenu.addItem(entry)
        }
        return submenu
    }

    private func opacityMenu() -> NSMenu {
        let submenu = NSMenu()
        for preset in AppState.opacityPresets {
            let entry = item("\(Int((preset * 100).rounded()))%", #selector(selectOpacity(_:)))
            entry.representedObject = preset
            entry.state = AppState.isPreset(preset, matching: state.opacity) ? .on : .off
            submenu.addItem(entry)
        }
        return submenu
    }

    /// Quick Commands ▸, including when there are none.
    ///
    /// **The row stays when the list is empty, and the submenu explains
    /// itself.** Through 0.1.0 the whole row was omitted, which hid the feature
    /// from the one person who most needed to hear about it: quick commands
    /// have no UI that creates one, so a user who has never edited
    /// `config.json` had nothing to discover. Disabling the row instead would
    /// not have fixed that — AppKit skips disabled rows when you arrow through
    /// a menu, so a keyboard user would never land on it, and this menu is the
    /// whole settings surface.
    ///
    /// So the empty submenu carries the same sentence the palette shows, and
    /// then the two things worth doing about it: open the file, or open the
    /// palette and see the state for yourself.
    private func quickCommandMenu() -> NSMenu {
        let submenu = NSMenu()
        if quickCommands.isEmpty {
            let empty = NSMenuItem(
                title: QuickCommands.emptyStateMessage, action: nil, keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
            submenu.addItem(.separator())
            submenu.addItem(item("Edit Configuration…", #selector(editConfiguration)))
        }
        for command in quickCommands {
            let entry = item(
                command.title, #selector(fireQuickCommandFromMenu(_:)), hotkey: command.hotkey
            )
            entry.representedObject = command.id
            // The row says whether picking it executes or only types, and
            // whether it opens a tab to do it in. Neither is visible from the
            // title, and executing is not undoable.
            if #available(macOS 14.4, *) {
                let action = command.runsImmediately ? "Runs immediately" : "Types at the prompt"
                entry.subtitle = command.opensNewTab ? "\(action), in a new tab" : action
            }
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(item("Show Palette…", #selector(showPalette),
                             hotkey: config.hotkeys.commands))
        return submenu
    }

    private func item(_ title: String, _ action: Selector, hotkey: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        // One grammar: the same parse that backs the Carbon registration
        // supplies the display, so the two cannot drift.
        if let hotkey, let (key, mods) = HotkeySpec(hotkey)?.menuKeyEquivalent {
            entry.keyEquivalent = key
            entry.keyEquivalentModifierMask = mods
        }
        return entry
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }
}
