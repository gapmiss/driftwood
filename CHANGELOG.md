# Changelog

All notable changes to Driftwood are recorded here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Selected text was drawn in black on every theme, which made a selection unreadable on the three dark ones. SwiftTerm re-renders a selected run with its own foreground color, and that color defaults to black unless the app sets it; selected text now uses the theme's foreground. Note that a selection still flattens ANSI color to that one foreground while it covers the text, which is SwiftTerm's behavior and not settable.
- Retuned the selection band in Driftwood Night, Ember and Mono so the edges of a selection are findable without costing text contrast. Paper is unchanged.
- On the website, dragging across the mock terminal highlighted in the site's own blue rather than the selected theme's selection color.

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

[0.1.0]: https://github.com/gapmiss/driftwood/releases/tag/v0.1.0
