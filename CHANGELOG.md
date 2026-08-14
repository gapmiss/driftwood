# Changelog

All notable changes to Driftwood are recorded here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Opening Driftwood while it is already running summons the panel, tabs and scrollback untouched. It matters when the panel is hidden — after a second ⌃⌥T, or under When Unfocused ▸ Hide — where opening the app from Finder, Spotlight or a launcher used to do nothing visible at all: Driftwood came to the front with no window on screen, so an app that was running looked like one that had failed to launch. With the panel already on screen, nothing changes.
- `scrollbackLines` in `config.json` sets how many lines of output each tab keeps above the visible screen. 500 by default, which is what every release before this one used, so leaving it alone changes nothing. Raise it to keep more history in a tab; set it to 0 to keep none at all, so anything that scrolls off the top is gone. There is no unlimited setting — the buffer is allocated at its full length when a tab opens, and its cost is lines × columns per tab — so values are capped at 100,000 rather than rejected. Full-screen programs like `less` and `vim` draw into a separate buffer that has never had scrollback, and this does not change that.

## [0.3.0] — 2026-08-12

### Added

- **When Unfocused ▸** in the right-click menu decides what the panel does once it is no longer the window you are typing in. **Stay Visible** is the default and is 0.2.0's behavior. **Dim** fades the panel, which is otherwise impossible to see: the panel is borderless, so a focused one and an unfocused one are pixel-identical, and ⌃⌥T behaves differently in each. **Hide** puts the panel away, so clicking back into your editor dismisses it without a keypress — nothing is lost, because hiding is not closing and every tab keeps its shell, its scrollback and its half-typed command line. The cost of Hide is that you can no longer leave a running command on screen while you work in another app, which is why both ship and the choice is one click. Stored in `state.json` as `onFocusLoss`.
- `newTab` on a quick command opens a fresh tab and puts the command in that, instead of typing into whichever tab is active. Off by default. It is for the commands you leave running — a `tail -f`, a dev server, a watcher — which otherwise land in a tab busy with something else: with `run` false the text appends to whatever is already typed at that prompt, and with `run` true it goes to the foreground process rather than to the shell. Independent of `run`, so `newTab` alone opens a tab and leaves the command typed there, unexecuted. The palette row and the menu row both say when a command opens its own tab. Driftwood waits for the new tab's prompt before typing, up to two seconds, so the command is not echoed twice — once by the terminal and once by the shell.
- `dimOpacity` in `config.json` sets how far Dim fades the panel. 0.8 by default; lower is dimmer, down to a floor of 0.05. The floor is not zero because fading a window does not stop it taking clicks, and an invisible panel would still swallow every click inside its frame.

### Changed

- The panel's default position is the middle of the display, in both axes. It is where the panel lands on first launch, where Reset Position puts it, and where an untrusted saved frame falls back to. It was meant to sit in the lower third, and the arithmetic put the panel's centre one sixth of the way up the screen instead — at the default 720×360 size on a 900pt display that left the bottom of the panel below the visible area, under the Dock. Reset Position therefore appeared to shove the panel off the bottom edge rather than rescue it.
- ⌘Q no longer quits Driftwood. Quitting ends every shell in every tab, and the panel takes the keyboard while your frontmost app carries on looking frontmost — so a ⌘Q aimed at that app hit Driftwood instead, and it did so even for someone who had set the `quit` hotkey in `config.json` to something else on purpose. Quit from the right-click menu, or set `quit` in `config.json`, which is empty by default for the same reason.

### Fixed

- Paper looked flat grey in Dark Mode. The panel's blur takes its material from the system appearance, so a light theme's translucent background was compositing over a near-black blur; the blur now follows the theme instead of the system, and Paper renders as warm paper whatever macOS is set to. Custom themes are classed by their own `background` color and get the same treatment.
- Summoning the panel puts it back on screen if it is on no display at all — an unplugged monitor used to strand it until the next launch. Reset Position could not rescue it, because that row is in the panel's own right-click menu and there was no panel to right-click. A panel merely hanging off an edge is still left exactly where you dragged it.
- The tab strip always keeps somewhere to grab. The strip is the panel's drag handle, and the tabs used to divide all of it except the "+" — at the default panel width three tabs came to 178pt each, just under the 180pt cap, so they filled the strip exactly and left nothing to drag. Opening a third tab silently took away the only way to move the panel that is visible on screen, leaving ⌘-drag as the only one left. 44pt beside the "+" is now reserved and the tabs share what is left, which makes each of three tabs 164pt instead of 178pt. Past eight tabs they still overflow off the right edge, as before.

## [0.2.0] — 2026-08-11

### Added

- Homebrew is now the first install option: `brew trust --cask gapmiss/tap/driftwood` followed by `brew install --cask gapmiss/tap/driftwood`. The DMG download is still there. The guide also documents uninstalling that way — `brew uninstall --cask` and `brew zap --cask` — because deleting the app from Applications by hand leaves Homebrew believing Driftwood is still installed. Turn off Launch at Login before either: macOS holds that registration and it outlives the bundle.

### Changed

- ⌃⌥T now asks whether the panel has the keyboard, not only whether it is on screen. A panel left visible while you worked in another app took two presses to type in — the first hid it, the second brought it back. It takes one press now, and the hotkey only hides the panel when the panel is what you were typing in. ⌃⌥F is unchanged: it never hides.

- Quick Commands ▸ is now always in the right-click menu. With none saved it says "No quick commands in config.json" and offers Edit Configuration…, which is the only place the feature announces itself — nothing in the app creates a quick command for you. It used to vanish entirely when the list was empty.
- Launch at Login moved down, next to Reset Position and Edit Configuration…, instead of sitting alone between two separators.
- The grab area at each corner of the panel is larger. It runs 16pt along both edges rather than being only the 6pt by 6pt square where the two edge bands met, and the pointer now turns into a diagonal resize arrow there so you can see you have the corner before you drag. The edges themselves are unchanged at 6pt, so a click meant for text at the end of a line still reaches the terminal. On macOS 14 the corner pointer stays the horizontal arrow — AppKit has no public diagonal cursor before macOS 15 — and corner dragging works in both axes on both.

### Removed

- "Show in Full Screen" is gone from the right-click menu, and `showInFullScreen` from `state.json`. It never did anything: the panel joins all Spaces, which puts it over full-screen apps whatever the setting said. ⌃⌥T sends the panel away in one press instead, from anywhere.
- "Always on Top" is gone too, and `alwaysOnTop` with it. The panel is always above other windows. Turning it off dropped the panel to an ordinary window level, where it was a trap rather than a preference: Driftwood never becomes the frontmost app, so nothing could raise the panel once a window covered it, and it could still be taking your keystrokes from behind that window.
- An existing `state.json` keeps both retired keys. Nothing reads them, and the frame, theme, font size and opacity in the same file still load.

### Fixed

- Selected text was drawn in black on every theme, which made a selection unreadable on the three dark ones. SwiftTerm re-renders a selected run with its own foreground color, and that color defaults to black unless the app sets it; selected text now uses the theme's foreground. Note that a selection still flattens ANSI color to that one foreground while it covers the text, which is SwiftTerm's behavior and not settable.
- Retuned the selection band in Driftwood Night, Ember and Mono so the edges of a selection are findable without costing text contrast. Paper is unchanged.
- The panel had a visible outline around it, which is not what a borderless panel should look like. Two separate things drew one: a hairline Driftwood painted itself, and `NSVisualEffectView`'s own edge stroke underneath it. The blur now extends slightly past the panel's rounded shape so its stroke falls outside, and nothing draws an outline.
- Hovering an edge of the panel showed one of two different resize pointers depending on the exact pixel — the correct arrow a pixel in, a four-headed move cursor right on the edge. The second one was AppKit's, from a window flag Driftwood set for unrelated reasons and does not need, since it runs every resize itself. The flag is gone and the size floor it used to enforce is now enforced directly, which also fixes a case it never covered: raising the font size on an already-small panel left the panel below its own minimum until something else resized it.
- A grey stripe ran down the right side of the terminal. It is SwiftTerm's scroll bar, and it was showing exactly when there was nothing to scroll: with scrollback to move through, it drew nothing at all, even mid-scroll. It is hidden now. Scrolling with the wheel, the trackpad and the keyboard is unaffected.
- On the website, dragging across the mock terminal highlighted in the site's own blue rather than the selected theme's selection color.
- On the website, the submenu marker in the guide's menu reference table wrapped onto its own line.

## [0.1.0] — 2026-08-09

First release.

### Added

- Floating terminal panel: borderless, blurred, always on top, with a real login shell on a PTY (SwiftTerm 1.15.0).
- Nonactivating focus. Summoning the panel gives it the keyboard without making Driftwood the frontmost application, so the app you were working in never deactivates.
- Global hotkeys via Carbon, needing no Accessibility permission: show/hide (⌃⌥T), focus (⌃⌥F), new tab (⌃⌥N), command palette (⌃⌥K), and an optional quit binding that ships disabled.
- Tabs, with the tab strip doubling as the window's drag handle. ⌘T, ⌘W, ⌘⇧], ⌘⇧[ and ⌘1…⌘9.
- Four built-in themes — Driftwood Night, Ember, Paper, Mono — plus user themes and per-role color overrides in `config.json`.
- Right-click settings menu: theme, font size, opacity, always on top, show in full screen, launch at login, reset position, edit configuration.
- Quick commands with optional per-command hotkeys and a filtering palette. `run` defaults to false, so a command is typed at the prompt rather than executed until you opt in.
- Resizing from any edge or corner, ⌘-drag to move, and a saved frame that is validated against the displays actually attached at launch.
- Settings split across a user-owned `config.json` and an app-owned `state.json`, both tolerant of missing and unknown keys, with corrupt files moved aside rather than overwritten.
- Opt-in debug log at `~/Library/Logs/Driftwood/driftwood.log`.
- App icon, drawn from `Tools/make-icon.swift` and rebuilt with `make icon`.
- `make check` runtime harness covering theme parsing and registration, cell metrics and resize maths, frame restore, quick-command validation, hotkey parsing, and both settings files.

### Fixed

Both found by the first manual smoke test, before release.

- The panel rendered as a solid slab. SwiftTerm's terminal view kept an opaque layer regardless of `nativeBackgroundColor`, hiding the tint and the window blur beneath it, so no theme or opacity setting had any visible effect.
- Clicking in the terminal did nothing. The chrome overlay claimed every click instead of letting it through, so text selection never worked and a selection on screen could not be cleared.
- The palette ran the wrong command. Moving the highlight with ↑/↓ updated the visible row but not the model behind it, so Return fired whichever command was first in the list — including, for a `run: true` entry, executing a shell command other than the one on screen.
- ⌃⌥K now closes the palette if it is already open, instead of re-presenting it on top of itself.
- Running a command from the palette now always dismisses it. Selecting with the mouse, or with Return while the filter field had focus, left it open over the terminal.

### Notes

- Built in Swift 5 language mode. SwiftTerm 1.15 predates `Sendable`, so conforming a `@MainActor` type to `LocalProcessTerminalViewDelegate` is an actor-isolation error under Swift 6 checking; `@preconcurrency import` does not cover it. See `Package.swift`.
- Pasted text renders in black until the next redraw. The bug is in SwiftTerm's own paste path.

[0.3.0]: https://github.com/gapmiss/driftwood/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/gapmiss/driftwood/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/gapmiss/driftwood/releases/tag/v0.1.0
