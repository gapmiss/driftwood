# Contributing to Driftwood

Thanks for stopping by. Driftwood is a small app and I would like to keep it that way. Plain, readable code beats clever code here.

## Building

You need macOS 14 or later and a Swift 6 toolchain. Xcode's Command Line Tools are enough. There is no Xcode project on purpose, so please don't add one.

```bash
make build    # swift build (CONFIG=debug|release)
make run      # build → .build/Driftwood.app → launch
make check    # the test suite — run before every PR
pkill -x Driftwood   # quit (no Dock icon; or right-click the panel → Quit)
```

The package builds in **Swift 5 language mode**, which is unusual and deliberate. SwiftTerm 1.15 ships no `Sendable` or actor annotations, so conforming a `@MainActor` type to `LocalProcessTerminalViewDelegate` is an isolation error under Swift 6 checking rather than a warning. `@preconcurrency import` silences `Sendable` diagnostics, not that. The reasoning is in a comment in `Package.swift`. Write new code as though Swift 6 mode were on — every UI type is `@MainActor` already — so the switch stays a one-line change.

## Tests

There is no XCTest target: this project is developed with Command Line Tools only, which ship neither XCTest nor Swift Testing. Instead `make check` compiles `Checks/main.swift` directly against the sources it exercises and runs the assertions.

Only AppKit-free and SwiftTerm-free files can join that target. That is why the color, geometry, metrics and validation logic lives in its own types with no framework imports — it is the part that can be tested. If you add logic that can be tested, put it somewhere reachable and add checks for it. In-app invariants stay as runtime `precondition`s.

`make check` also runs seven drift guards after the Swift assertions, each catching a file that restates something by hand: `docs/themes.js` must match what `make site` generates from `TerminalTheme.swift`; both website pages must print the current version in their footer; every local file the two pages name must exist; the bundle version must match the Makefile; `CLAUDE.md` must name the current release; `Package.resolved` must still pin SwiftTerm 1.15.0; and every `File.swift:symbol` pointer in `CLAUDE.md`'s tripwire index must still resolve. Read `make`'s exit status rather than grepping for `ALL CHECKS PASSED`, which the Swift binary prints before those guards run.

Anything touching the panel, the terminal view or a real shell cannot be checked automatically. `CLAUDE.md` carries a manual smoke test; run the parts your change touches and say in the PR which ones you ran.

## Ground rules

A few things the whole app is built around. PRs that break these won't land, so it is worth knowing them up front.

- **No permission prompts.** Global hotkeys go through Carbon, which needs no Accessibility grant. Anything that would put Driftwood in System Settings → Privacy is out.
- **The panel never steals the frontmost application.** If a change makes the app behind visibly deactivate, the change is wrong, however convenient.
- **`run` on a quick command defaults to false.** A hotkey that executes a shell command with no confirmation is opt-in, one command at a time.
- **The app never writes `config.json`** except to create it on first launch. A setting that gains a UI moves to `AppState`.
- **No migrations.** Every decoder gets a default for every key, so an old file degrades to defaults instead of throwing.
- **No network calls, no telemetry.** Check for Updates opens a browser.

## Style

- Rationale goes in a doc comment next to the code it governs, not in a commit message and not in `CLAUDE.md`. `CLAUDE.md` carries one-line verdicts pointing at those comments, and `make check` fails when a pointer stops resolving — so if you rename a symbol named there, repoint it.
- Write down what you *tried and reverted*, not only what you kept. Most of the doc comments in this codebase exist because an obvious approach was wrong in a way that is not obvious afterward.
- Don't hard-wrap prose in Markdown; let it soft-wrap.
- The app icon is generated. `Tools/make-icon.swift` draws it and `make icon` writes `Resources/AppIcon.icns`; don't edit the `.icns` directly, or the next `make icon` throws your change away.
- Match the surrounding code. There is no formatter config to argue with.

## Reporting bugs

Say what you did, what happened and what you expected. If it involves the panel, hotkeys or focus, set `"debug": true` in `config.json`, reproduce it, and attach the tail of `~/Library/Logs/Driftwood/driftwood.log` — it records hotkey registration, the resolved font, and the focus state on every summon.
