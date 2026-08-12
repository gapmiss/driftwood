# Driftwood — a floating terminal panel for macOS

A borderless, blurred, always-on-top terminal panel with tabs, themes and global hotkeys. Press ⌃⌥T over whatever you are working in, type a command, press it again. No Dock icon, no menu bar item, no Accessibility permission, no network calls. Current release is `VERSION` in the Makefile (0.3.0), shipped as a DMG.

Driftwood keeps Starboard's terminal — a real PTY-backed login shell in a nonactivating `NSPanel` — and drops Starboard's Dock tracking, which is what removes the Accessibility grant, the certificate-pinning install script and the 1-second polling timer along with it. Conventions throughout follow Chestnut: SPM + Makefile, JSON settings in Application Support, a check harness in place of XCTest, rationale in doc comments.

## Where things are documented

**Rationale lives next to the code it governs.** The dense "why is it like this" prose is in doc comments on the types themselves, not here. This file carries orientation, the rules that must never break, and an index pointing at the rest.

| Document | Covers |
|---|---|
| `README.md` | What it does, install, `config.json` reference |
| `CONTRIBUTING.md` | Ground rules and code style |
| `CHANGELOG.md` | Release history |
| `RELEASING.md` | **Read this before cutting a release.** The step-by-step order, and the steps nothing can check: the cask in the other repository, the og-image recapture, the download that tests the blocked first launch. It is in `.gitignore` and untracked on purpose, so it is on disk but never in a diff, a clone or a PR — do not go looking for it in git, and do not commit it |
| Doc comments | Everything else — see the tripwire index below |
| `docs/` | The website and the user guide — see "Working on the website" below |

## Build & run

CLI-first: SPM + Makefile. No Xcode project — don't generate one.

```bash
make build    # swift build (CONFIG=debug|release)
make bundle   # build -> .build/Driftwood.app (Info.plist + ad-hoc codesign)
make run      # bundle + open the .app
make dmg      # release build -> .build/Driftwood.dmg (drag-to-Applications)
make icon     # redraw Resources/AppIcon.icns from Tools/make-icon.swift
make site     # redraw docs/themes.js from TerminalTheme.swift (the website)
make favicons # redraw docs/favicon.png + apple-touch-icon.png from make-icon.swift
make check    # runtime checks (Checks/main.swift) — run before committing
make clean
pkill -x Driftwood  # quit the app (no Dock icon; use the right-click menu)
```

- **Swift 5 language mode, deliberately.** Driftwood is the one repo of this family not in Swift 6 mode. SwiftTerm 1.15 predates `Sendable`: `TerminalView`, `LocalProcessTerminalView` and `LocalProcessTerminalViewDelegate` carry no global-actor isolation, so conforming a `@MainActor` type to that delegate is an actor-isolation *error* under Swift 6 checking. `@preconcurrency import SwiftTerm` was tried first and does not cover it — it silences `Sendable` diagnostics, not an isolation mismatch on a protocol witness. Language mode 5 leaves those as warnings. The full account is on the `swiftSettings:` line in `Package.swift`. Everything else is written as if Swift 6 mode were on (every UI type is `@MainActor`), so the switch back should be a one-line change there.
- **A clean build emits exactly one warning, and it is the expected one:** `conformance of 'TerminalSession' to protocol 'LocalProcessTerminalViewDelegate' crosses into main actor-isolated code`. That is the diagnostic language mode 5 exists to keep as a warning. Do not silence it with `@preconcurrency` or `nonisolated` — the first does not apply and the second would move the delegate callbacks off the main actor, where they touch AppKit views. Treat any *second* warning as new.
- **Language mode 5 also changes `main.swift`.** Swift 6 makes top-level code implicitly `@MainActor`; mode 5 leaves it nonisolated, so constructing the delegate is an error rather than a warning. Driftwood's `main.swift` wraps its body in `MainActor.assumeIsolated`, which Chestnut's identical file does not need.
- Min deployment target: macOS 14.
- `LSUIElement` app — no Dock icon, and the main menu exists only to carry key equivalents.
- Version source of truth: `VERSION` in the Makefile, stamped into the bundle plist.
- SwiftTerm is pinned to 1.15.0 in `Package.resolved`, and `make check` asserts the pin. Two doc comments depend on that exact version; see the tripwire index.

**Testing:** this machine has Command Line Tools only (no Xcode), so there is no XCTest or Swift Testing. `make check` compiles `Checks/main.swift` against the pure sources and runs assertions. Only AppKit-free, SwiftTerm-free files can join that target — the panel, the terminal view and the shell are out of reach and get the manual smoke test below instead. Extend the harness when adding testable logic; in-app invariants stay as runtime `precondition`s.

**Bash output truncation:** the harness silently truncates long stdout. Never rely on seeing full output. Redirect and read `make`'s own exit status:

```bash
make check > /tmp/chk.txt 2>&1; echo "EXIT: $?"; tail -5 /tmp/chk.txt
```

Do **not** pipe `make check` into `grep` and report `$?` — that is grep's status, not make's, and the two disagree in the case that matters. `ALL CHECKS PASSED` is printed by the Swift binary partway through the target; the version, changelog and tripwire guards all run *after* it and fail on their own. A grep for `ALL CHECKS` finds that line while `make` is exiting non-zero.

## Source layout

```
Sources/Driftwood/
  main.swift                       # entry point (MainActor.assumeIsolated — see above)
  AppDelegate.swift                # panel, sessions, theme, menus, hotkeys, quick commands

  Terminal/
    TerminalPanel.swift            # NSPanel subclass: borderless, nonactivating, floating
    ChromeView.swift               # transparent overlay: resize edges, ⌘-drag, right-click
    TabBar.swift                   # drawn tab strip, doubles as the window's drag handle
    TerminalSession.swift          # one LocalProcessTerminalView + its delegate
    SessionStack.swift             # tab bookkeeping
    TerminalTheme.swift            # PURE — palettes, custom themes, per-role overrides
    TerminalMetrics.swift          # PURE — cell size, content frame, resize maths

  Support/
    Config.swift                   # PURE — user-owned config.json
    AppState.swift                 # PURE — app-owned state.json
    PanelGeometry.swift            # PURE — validated frame restore
    QuickCommands.swift            # PURE — saved command validation
    Hotkeys.swift                  # HotkeySpec parser + Carbon registration ("DRFT")
    CommandPalette.swift           # NSPanel + SwiftUI quick-command picker
    DebugLog.swift                 # opt-in file log at ~/Library/Logs/Driftwood/
    AppInfo.swift                  # version, GitHub URLs

Resources/                         # Info.plist, AppIcon.icns
Tools/make-icon.swift              # draws AppIcon.icns (make icon) — not built into the app
Tools/make-site-themes.swift       # writes docs/themes.js (make site) — not built into the app
docs/                              # the website: hand-written HTML, one generated file
Checks/main.swift                  # runtime assertions (make check)
```

## Hard invariants

Breaking any of these is a bug, not a trade-off.

- **No Accessibility permission, and nothing that would need one.** Global hotkeys go through Carbon's `RegisterEventHotKey`, which needs no TCC grant. An `NSEvent` global monitor would, and would drag the whole install-script apparatus back in.
- **The panel never steals the frontmost application.** It is a `.nonactivatingPanel` that becomes key without activating Driftwood. If a change makes the app behind visibly deactivate, that change is wrong.
- **`run` on a quick command defaults to false, and that is a safety decision.** A hotkey that executes a shell command with no confirmation, possibly while the panel is hidden, must be opted into one word at a time. `make check` asserts the default in the code, in `config.json`'s doc comment and in the README.
- **The app never writes `config.json`** except `createIfMissing()` on first run. Anything gaining a UI moves to `AppState`.
- **A corrupt settings file is moved aside, never overwritten.** `.bak`, then `.bak.1`, `.bak.2`… so an earlier rescue is never clobbered.
- **No network calls, no telemetry.** "Check for Updates" opens the GitHub releases page in a browser.
- **No migrations.** Every decoder has a default for every key, so an old or hand-broken file degrades to defaults instead of throwing. A stale key is inert, never fatal.
- **The right-click menu is the whole settings surface.** There is no preferences window and no menu bar item, so anything that has to be reachable must be reachable there — and by keyboard, which rules out `NSMenuItem.view` sliders.

## Tripwire index

Each line is a verdict you can act on without opening anything, plus where the full account lives. **Read the cited comment before changing the thing it describes** — every one of these records something that was measured, or an approach that was tried and reverted. `make check` verifies every pointer here still resolves.

### Focus, hotkeys and the panel

- The panel takes the keyboard without Driftwood becoming frontmost — measured, with the fallback path written down. `NSApp.isActive` reads `true` anyway and is the wrong thing to ask → `Sources/Driftwood/AppDelegate.swift:showPanel`
- `canBecomeKey` true and `canBecomeMain` false is what makes a nonactivating panel accept keystrokes at all → `Sources/Driftwood/Terminal/TerminalPanel.swift:canBecomeKey`
- ⌃⌥T asks two questions, visible *and* focused. Asking only `isVisible` costs a press: a panel left on screen while you work elsewhere is still visible, so the hotkey hid it and you pressed again to get it back → `Sources/Driftwood/AppDelegate.swift:togglePanel`
- Acting the instant the panel resigns key hides it out from under its own palette. The panel's `didResignKey` arrives *before* the palette's `didBecomeKey`, so at that moment nothing in the app is key; the decision is deferred 200ms and re-checked → `Sources/Driftwood/AppDelegate.swift:focusLossDelay`
- Auto-hide asks whether the panel is *in use*, not whether it holds the keyboard. The palette is built to stay open after losing key, so the narrow question hid the panel out from under a visible palette — and `hidePanel` dismisses the palette, so both vanished and a half-typed filter was gone for good → `Sources/Driftwood/AppDelegate.swift:panelIsInUse`
- The settings menu needs a flag around the tracking loop, and when tracking ends the panel *takes the keyboard back* instead of asking who has it. Asking got "nobody", so picking a theme out of the menu hid the panel 200ms later → `Sources/Driftwood/AppDelegate.swift:menuIsTracking`
- `onFocusLoss` is decoded as a string and mapped by hand; `Codable`'s synthesised enum conformance *throws* on an unknown value, which would make one stale word cost the whole settings file. It lives in `AppState`, not `Config`, because switching between dim and hide is a workflow choice made often, not an install-time one → `Sources/Driftwood/Support/AppState.swift:FocusLossBehavior`
- The hidden main menu's Quit row carries **no** ⌘Q. It was a second, unremovable quit binding that fired whenever the panel held the keyboard, including for a ⌘Q meant for the app that still looked frontmost → `Sources/Driftwood/AppDelegate.swift:setUpMainMenu`
- Every summon re-checks that the panel is on some display, because Reset Position lives in the panel's own right-click menu and cannot rescue a panel you cannot right-click. Narrower than the launch check: only "unreachable" resets, "hanging off an edge" is left alone → `Sources/Driftwood/AppDelegate.swift:rescueFrameIfLost` and `Sources/Driftwood/Support/PanelGeometry.swift:isReachable`
- `.resizable` is absent from the style mask on purpose: it switched on AppKit's own edge tracking, which drew a second, four-headed resize cursor at the outermost pixel of every edge, where our cursor rects cannot reach → `Sources/Driftwood/Terminal/TerminalPanel.swift:init`
- The panel's size floor is ours, not `NSWindow.minSize`, which a non-resizable window ignores — and which never resized an already-too-small window anyway → `Sources/Driftwood/Support/PanelGeometry.swift:grownToMinimum`
- The window level and the Space flags are fixed, and 0.1.0's two toggles for them were removed. `.canJoinAllSpaces` puts the panel over full-screen apps on its own, so "Show in Full Screen" had nothing behind it; "Always on Top" off dropped the panel to `.normal`, where an app that never comes to the front can never be raised again → `Sources/Driftwood/Terminal/TerminalPanel.swift:init`
- Carbon registration needs no Accessibility grant, and `InstallEventHandler` failing means register **nothing** — otherwise every binding is claimed system-wide and none of them fires → `Sources/Driftwood/Support/Hotkeys.swift:start`
- Every hotkey is handed back to the system while an `NSMenu` tracks, or Carbon queues the presses and replays them the instant the menu closes → `Sources/Driftwood/Support/Hotkeys.swift:setEnabled`
- A binding must carry one of ⌃⌥⌘; shift alone is not a modifier, because a registered hotkey consumes that keystroke in every application → `Sources/Driftwood/Support/Hotkeys.swift:HotkeySpec`
- The menu's key equivalent comes from the same parse as the Carbon registration, so the menu cannot draw a shortcut no hotkey backs → `Sources/Driftwood/Support/Hotkeys.swift:menuKeyEquivalent`

### Terminal, chrome and layout

- `hitTest` claims only the resize edges, ⌘-clicks and right-clicks; everything else falls through, which is what keeps text selection working. Declining must return **`nil`**, not `super.hitTest` — the terminal is a sibling, not a subview, so `super.hitTest` returns self and swallows every click in the panel. Right-click has to be claimed here or SwiftTerm's own menu appears and there is no way left to change a theme → `Sources/Driftwood/Terminal/ChromeView.swift:hitTest`
- Resizing runs a manual `nextEvent(matching:)` loop in screen coordinates, because callback-based dragging is unreliable once the drag leaves the window of a nonactivating panel → `Sources/Driftwood/Terminal/ChromeView.swift:trackResize`
- Corners get a real diagonal cursor on macOS 15 and the horizontal one on 14, which is the floor: `NSCursor.frameResize` is 15-only and the pre-15 diagonals are private API. Dragging works in both axes either way. The corner rects must be added *last*, or the edge bands they sit inside win → `Sources/Driftwood/Terminal/ChromeView.swift:resetCursorRects`
- The corner grab region is L-shaped, 16pt along each edge by 6pt deep, because the square where two 6pt bands overlap is a 6×6 target nobody can hit. The edge bands stay at 6pt so a click meant for text at the end of a line still reaches the terminal → `Sources/Driftwood/Terminal/TerminalMetrics.swift:resizeCornerMargin`
- Two separate things drew the outline the panel is not supposed to have. Deleting our 1pt hairline left `NSVisualEffectView`'s own edge stroke, which every material draws and `maskImage` does not suppress — the blur now bleeds 2pt past a plain root view that clips → `Sources/Driftwood/AppDelegate.swift:buildPanel`
- Cell height mirrors a calculation SwiftTerm does not publish; a dependency bump is exactly what invalidates it → `Sources/Driftwood/Terminal/TerminalMetrics.swift:estimatedCellHeight`
- Leftover vertical slack is split above and below the terminal; left alone it collects at the bottom and reads as a layout bug rather than as rounding → `Sources/Driftwood/Terminal/TerminalMetrics.swift:contentFrame`
- A resize clamps the *moving* edge against the fixed one. Clamping width alone lets the origin creep sideways under a stalled cursor → `Sources/Driftwood/Terminal/TerminalMetrics.swift:resized`
- The root view needs `masksToBounds`, or the terminal paints square corners over the rounded panel → `Sources/Driftwood/AppDelegate.swift:buildPanel`
- SwiftTerm's scroller is hidden by hand, because it is visible exactly when there is nothing to scroll: disabled it draws a full-height grey track, enabled it draws nothing even mid-scroll. Moving the terminal out of the effect view is what exposed it → `Sources/Driftwood/Terminal/TerminalSession.swift:hideScroller`
- Transparency takes **two** assignments, not one. SwiftTerm's `nativeBackgroundColor` setter never touches the view's layer, and the layer is painted once during `init` with SwiftTerm's own opaque default — set the layer's background to clear as well or the panel is a solid slab → `Sources/Driftwood/AppDelegate.swift:applyTheme`
- Selected text needs **two** colors set, not one. SwiftTerm re-draws a selected run with its own foreground, which defaults to `NSColor.black` — set `selectedTextForegroundColor` or every selection is black text on a dark band → `Sources/Driftwood/AppDelegate.swift:applyTheme`
- The selection band is tuned to two measured contrast ratios, and its alpha composites over the wallpaper rather than over the theme background → `Sources/Driftwood/Terminal/TerminalTheme.swift:selection`
- `$SHELL` is exported from the same setting that launches the shell, so the two cannot drift; several completion scripts misbehave without it → `Sources/Driftwood/AppDelegate.swift:childEnvironment`
- The tab strip is drawn rather than an `NSStackView`, because it also has to be the window's drag handle → `Sources/Driftwood/Terminal/TabBar.swift:TabBar`
- 44pt of the strip is reserved beside the "+" and the tabs may not take it. Sharing the whole strip left *no* drag handle at three tabs, which is where the even width first lands under the 180pt cap → `Sources/Driftwood/Terminal/TerminalMetrics.swift:tabStripDragHandle`

### Themes and settings

- The window blur's appearance is pinned from the theme's own lightness, not the system's. `NSVisualEffectView` reads the effective appearance, so Paper's translucent tint over a Dark Mode `.hudWindow` rendered flat grey → `Sources/Driftwood/Terminal/TerminalTheme.swift:isLight`
- A theme short of 16 ANSI colors is a **crash** inside SwiftTerm's `installColors`, not a wrong color, which is why registration rejects by count before anything reaches the terminal → `Sources/Driftwood/Terminal/TerminalTheme.swift:swiftTermPaletteSize`
- Registration is per-theme and total; overrides are per-role and tolerant. The asymmetry is deliberate → `Sources/Driftwood/Terminal/TerminalTheme.swift:registerCustomThemes` and `Sources/Driftwood/Terminal/TerminalTheme.swift:resolvedTheme`
- `parseHex` rejects a leading sign explicitly, because `UInt64(_:radix:)` would otherwise accept `-12345` as a color → `Sources/Driftwood/Terminal/TerminalTheme.swift:parseHex`
- A saved frame on a display that no longer exists is reset; one merely hanging off an edge is *slid back*, never resized → `Sources/Driftwood/Support/PanelGeometry.swift:validatedFrame`
- 80pt must be showing for a frame to be worth rescuing: there is no Dock icon and no window list to recover the panel from → `Sources/Driftwood/Support/PanelGeometry.swift:minimumVisibleExtent`
- Opacity and font size are discrete presets, not sliders, because a menu slider is an `NSMenuItem.view` and AppKit skips those when navigating by keyboard — a panel faded to its floor would be unrecoverable → `Sources/Driftwood/Support/AppState.swift:opacityPresets`
- A font name that is not installed degrades silently; the list is ordered so a Nerd Font wins and Menlo is the floor, not SF Mono → `Sources/Driftwood/Support/Config.swift:fontNames`

### Quick commands and the palette

- `run` defaults to false, and the reason is written out in full where the flag is declared → `Sources/Driftwood/Support/QuickCommands.swift:runsImmediately`
- `newTab` is a convenience, not a second safety flag, and is independent of `run` — the two combine exactly as written → `Sources/Driftwood/Support/QuickCommands.swift:opensNewTab`
- A command going into a *new* tab waits for that shell's prompt, because a pseudo-terminal echoes in canonical mode: text sent before the shell takes the line discipline is drawn once by the tty and again by the shell. Readiness is polled from the cursor position — SwiftTerm has no data or readiness callback — and a 2s timeout sends regardless rather than swallowing the command → `Sources/Driftwood/Terminal/TerminalSession.swift:whenReady`
- A bad hotkey costs the hotkey; a bad command costs the entry. Collisions are keyed by the parsed chord, so `ctrl+alt+1` collides with `control+option+1` → `Sources/Driftwood/Support/QuickCommands.swift:validate`
- `isOptedOut` is duplicated in `HotkeyCenter`, and nothing but a check assertion keeps the two honest → `Sources/Driftwood/Support/QuickCommands.swift:isOptedOut`
- The palette is sized **once**, at open; measure *before* clearing `sizingOptions` or the panel opens invisible → `Sources/Driftwood/Support/CommandPalette.swift:host`
- The row the palette **opens** on is announced separately, after 1800ms; moving the sentence onto `.accessibilityLabel` was tried in Chestnut and is silent → `Sources/Driftwood/Support/CommandPalette.swift:announceOnOpen`
- `filter`'s `didSet` must ignore a write that changes nothing. SwiftUI's `TextField` writes the same string back on every re-render, and re-arming the selection there discards the row the user moved to — the highlight and the model disagree, and ⏎ runs a command other than the visible one → `Sources/Driftwood/Support/CommandPalette.swift:PaletteModel`
- ⌃⌥K toggles. Re-presenting an open palette resets the highlighted row under a user mid-type, and installing a second key monitor on the same instance orphans the first → `Sources/Driftwood/AppDelegate.swift:showPalette` and `Sources/Driftwood/Support/CommandPalette.swift:installKeyMonitor`
- Firing a command dismisses the palette, and that is centralised on `model.onRun` because three separate paths fire one → `Sources/Driftwood/Support/CommandPalette.swift:present`

## Known issues

**Pasted text renders in black until the next keypress.** Inherited from Starboard, and it is SwiftTerm's own `MacTerminalView.paste`: the wrong color is baked in before the echo is drawn, so forcing `needsDisplay` afterward does not fix it — that was already tried there. Any real fix is upstream. Typing over the pasted text, or any redraw, restores the theme foreground.

**A second ⌃⌥T looks like a crash.** Pressing the summon hotkey while the panel has the keyboard hides it, which is the intended behavior. But with no Dock icon and no menu bar item, a user who does that by accident has no way to tell Driftwood is still running, and nothing on screen says which key brings it back. Narrowed since 0.1.0 — a press while the panel is visible but *unfocused* now focuses it instead of hiding it, so the accident needs the panel to already be the thing you were typing in. Still open for the remaining case.

## Manual smoke test

Nothing below the compiler verifies these; `make check` cannot reach the panel, the terminal or a real shell.

**Test a release build the way a user gets it: download it.** The blocked first launch that both pages and the cask caveats describe cannot be reproduced by hand-writing `com.apple.quarantine` onto a locally built app. A flag value copied from the usual recipe carries bits that mark the file as already assessed, so macOS runs the app — translocated, from a random read-only path — and prints nothing. `spctl -a -vvv` still reports `rejected`, which is the static policy verdict and says nothing about whether a dialog appears. Worse, once any copy of a given signature has been approved, LaunchServices remembers, and no attribute editing brings the prompt back. Download the DMG from the release page in a browser, which is also the only version of the test that exercises the site's download button.

1. **The focus model.** With an editor frontmost, press ⌃⌥T, type `echo hi`, press Return. The command must run in Driftwood while the editor's title bar stays active. Press ⌃⌥T again; focus must return to the editor untouched. This is the one test the whole design rests on — `showPanel` records `key=` and `frontmost=` in the debug log, so run it with `debug: true` and read the log back.
2. Resize from all four edges and all four corners. A text-selection drag inside the terminal must not move the window; a ⌘-drag must.
3. Right-click anywhere in the panel. Driftwood's settings menu must appear, not SwiftTerm's.
4. `echo $SHELL` in a fresh tab must print the configured shell.
5. Open three tabs, close the middle one, cycle with ⌘⇧] and ⌘⇧[, and jump with ⌘1…⌘3.
6. Change theme, font size and opacity from the menu; quit and relaunch; all three must persist.
7. Drag the panel to a second display, quit, unplug it, relaunch — the panel must come back on a display that exists. **Never run.** No second display was attached when 0.1.0 or 0.2.0 was smoke-tested, so this step was skipped rather than passed both times, and `PanelGeometry.validatedFrame`'s screen-gone branch has only ever been exercised by `make check` against synthetic screen rectangles. Run it before assuming it works.
8. Open the palette with ⌃⌥K, filter, and press Return on a command with no `run` flag. It must be typed at the prompt and left there, unexecuted.
9. **`onFocusLoss`, both non-default values.** Set `"onFocusLoss": "hide"`, relaunch, summon the panel, then click into another app — the panel must go away. Summon it again: the tab, its scrollback and anything half-typed must all still be there. Then, with the panel focused, open the palette with ⌃⌥K and right-click for the settings menu; **neither may make the panel disappear**, and that is the case the 200ms delay and `menuIsTracking` exist for. Repeat with `"dim"`, where the same two must not fade it either.

## Working on the website

`docs/` is the site GitHub Pages serves: two hand-written pages, `index.html` and `guide.html`, plus `driftwood.js`, which re-creates the panel in the browser. Every rule below is here because breaking it already cost something.

- **Render the page and look at it.** Most of the bugs this site has had were invisible in the source and obvious on screen — a code box drawn around the mock editor, a double-spaced terminal, a misplaced button. Screenshot headlessly, and keep `--force-prefers-reduced-motion`: without it the cursor's blink animation leaves the block cursor missing from about half of all captures, which reads as a bug.

  ```bash
  /Applications/Helium.app/Contents/MacOS/Helium --headless --disable-gpu \
    --hide-scrollbars --force-prefers-reduced-motion --force-device-scale-factor=1 \
    --window-size=900,760 --screenshot=/tmp/x.png --virtual-time-budget=2500 \
    "http://127.0.0.1:8731/index.html"
  ```

- **Serve `docs/` and drive the DOM for anything about state.** A screenshot cannot settle "are all twelve menu rows there" or "did ⌃⌥1 type without running". Run `python3 -m http.server 8731` from inside `docs/`, add a temporary wrapper page in `docs/` — it has to be same-origin for its script to reach the iframe's DOM — holding an `<iframe>` of the page under test, write the driver's findings into a `<div>`, and read them back with `--dump-dom` in place of `--screenshot`. Delete the wrapper afterward. Review over the server rather than `file://` for the same reason: a browser gives each `file://` document its own storage partition, so the light/dark choice does not carry from one page to the other and `mode.js` looks broken when it is not.
- **The hero's panel is draggable, and its position is `--dw-dx`/`--dw-dy` folded into the transform that centers it.** A second `transform` declaration on `.dw-panel` replaces that one and sends a moved panel back to the middle, which is why `.is-hidden` repeats the offset in its own slide. The palette is placed from the panel's measured frame at open, mirroring `CommandPalette.show(above:)`; it used to sit at a hardcoded distance from the stage, which a moving panel leaves behind.
- **No color literal in `panel.css`.** Every color reads a `--dw-*` custom property that `driftwood.js` sets from the generated `docs/themes.js`, so the site's palettes cannot disagree with the app's. `make check` fails when that file is stale — run `make site`.
- **`#out` is an `aria-live` log region: append, never re-render.** Replacing every node makes a screen reader recite the whole scrollback, so a tab switch would read the other tab's history aloud. `appendLines` is the normal path; `renderTerm` is the wholesale redraw, and it switches the region off and re-arms it on the next frame.
- **`.dw-line` is `white-space: pre-wrap`**, so a newline or an indent inside the element renders as a real line break and a real indent. Write the contents of a `.dw-line` on one source line.
- **Anything selecting the `pre` tag hits the mock editor**, which is why it is a `<div>` with `white-space: pre`. `style.css` draws every `<pre>` as a code box, `copy-code.js` appends a copy button to it, and Prism highlights it.
- **The mock's measurements are hand-copied and nothing guards them** — tab widths, the 22px strip, the 8px inset, the 24px "+", the 10px radius, taken from `TabBar.swift`, `TerminalMetrics.swift` and `AppDelegate.swift`. Each names its source in a comment in `panel.css`. A stale one makes the mock slightly wrong rather than broken, which is why it is a comment and not a check.
- **Nothing turns visitor input into markup.** Output is written with `textContent`. `echo` is the only path from a visitor's text to the DOM: capped at 200 characters, with `$SHELL` the single expansion, and the scrollback capped at 200 lines.

## Conventions

- The app is "Driftwood" in copy, never "the Driftwood".
- **Install instructions live in four places and nothing guards them:** `README.md`, `docs/index.html`, `docs/guide.html`, and the cask's `caveats` in `gapmiss/homebrew-tap`. A change to how someone installs or unblocks Driftwood has to reach all four. The cask carries the release's `version` and the DMG's sha256 as well, in a repository `make check` cannot read, which is why the release checklist states it as a human step. Lint a cask edit with `brew style --cask gapmiss/tap/driftwood` — run from the tap, since Homebrew refuses to check a cask file outside one.
- `Resources/AppIcon.icns` is checked in, and `Tools/make-icon.swift` is the source it came from. Edit the script and run `make icon`; never edit the `.icns`. The script redraws it byte for byte, so a regeneration with no edit leaves the tree clean. Its colors are copied out of `TerminalTheme.driftwoodNight` by hand, because a standalone script cannot import the app target — change that palette and the icon does not follow on its own.
- Don't hard-wrap prose in Markdown; let it soft-wrap.
- When you fix something subtle, put the account in a doc comment beside the code and add a one-line verdict to the tripwire index above.
