# Driftwood

A floating terminal for macOS. Press ⌃⌥T over whatever you are working in, a blurred panel appears, you type a command, you press ⌃⌥T again and it goes away. The app you were in never loses focus.

It is a real terminal — a login shell on a PTY, with your prompt, your aliases and your `$PATH` — in a borderless window that sits above everything else.

- No Dock icon and no menu bar item. The panel and its right-click menu are the whole app.
- No Accessibility permission, no other system permission, no network calls.
- Tabs, four built-in themes plus your own, per-command global hotkeys.
- Settings are JSON files you can read: one you edit, one the app writes.

Requires macOS 14 or later. Apple silicon and Intel.

**[driftwood on the web](https://gapmiss.github.io/driftwood/)** — try the panel, the right-click menu and the ⌃⌥K palette in the browser before downloading anything. **[User guide](https://gapmiss.github.io/driftwood/guide.html)** — first launch, every setting, troubleshooting.

## Install

```bash
brew trust --cask gapmiss/tap/driftwood   # required for third-party taps
brew install --cask gapmiss/tap/driftwood
```

Or download the DMG from [Releases](https://github.com/gapmiss/driftwood/releases) and drag Driftwood to Applications. The cask installs the same app, so the first launch is blocked either way.

The app is signed ad-hoc rather than notarized, so the first launch is blocked. Right-click the app → Open → Open, once. After that it launches normally. On macOS 15 and later the step is different — the guide has [both](https://gapmiss.github.io/driftwood/guide.html#getting-started).

Or build it yourself:

```bash
git clone https://github.com/gapmiss/driftwood
cd driftwood
make run
```

## Using it

| Shortcut | Does |
|---|---|
| ⌃⌥T | Show the panel, or hide it if it is already showing |
| ⌃⌥F | Show the panel and take focus, without a second press hiding it |
| ⌃⌥N | Show the panel and open a new tab |
| ⌃⌥K | Open the quick-command palette |
| ⌘T / ⌘W | New tab / close tab |
| ⌘⇧] / ⌘⇧[ | Next tab / previous tab |
| ⌘1…⌘9 | Jump to a tab |
| ⌘+ / ⌘− | Font size up / down |

Drag the panel by its tab strip, or ⌘-drag anywhere in it. Resize from any edge or corner. Right-click for themes, opacity, what the panel does when it loses focus, launch at login and the rest.

The panel has no close button on purpose — hiding it is ⌃⌥T, and quitting is in the right-click menu.

## Settings

Two files in `~/Library/Application Support/Driftwood/`:

- **`config.json`** is yours. Driftwood writes it exactly once, to create it on first launch, and never again. Changes take effect on next launch.
- **`state.json`** is the app's. It holds the panel's frame and everything the right-click menu changes. Don't hand-edit it; the app rewrites it constantly.

A key you delete falls back to its default, and a key Driftwood does not recognize is ignored, so an old config never stops the app starting. A file that will not parse at all is *moved aside* to `config.json.bak` rather than overwritten, so nothing you wrote is lost.

### `config.json` reference

Every key, with its type and default, is in the guide's [configuration reference](https://gapmiss.github.io/driftwood/guide.html#configuration). The summary below is the part most people need.

```json
{
  "shell": "/bin/zsh",
  "shellArguments": ["-l"],
  "fontNames": ["MesloLGS NF", "Menlo"],
  "hotkeys": {
    "toggle": "control+option+t",
    "focus": "control+option+f",
    "newTab": "control+option+n",
    "commands": "control+option+k",
    "quit": ""
  },
  "dimOpacity": 0.8,
  "terminalPalette": { "ansi1": "#c64a5a" },
  "quickCommands": [
    { "id": "logs", "title": "Tail logs", "command": "tail -f /tmp/app.log", "hotkey": "control+option+1" }
  ],
  "debug": false
}
```

**`shell` / `shellArguments`** — the shell each tab launches. `-l` makes it a login shell, which is what sources the profile a normal terminal tab would. The same setting is exported as `$SHELL` to the child, so the two cannot disagree.

**`fontNames`** — preferred fonts, best first; the first one installed wins. Nerd Font variants come first because prompt themes like Powerlevel10k draw their separators and icons from glyph ranges no stock macOS font carries. A name that is not installed is skipped silently, so a typo costs you the font and says nothing — set `"debug": true` to log which one actually resolved.

**`hotkeys`** — `"modifier+modifier+key"`. At least one of control, option or command is required; shift alone does not count, because a registered hotkey consumes that keystroke in *every* application and `shift+a` is just A. Set a binding to `""` or `"none"` to turn it off. `quit` ships off: it is the one binding whose misfire costs you every running shell.

**`dimOpacity`** — how faded the panel gets when the right-click menu's When Unfocused ▸ is set to Dim. 0.8 by default; lower is dimmer. It multiplies with the theme's own translucency and with Opacity ▸, so at a low opacity a dimmed panel is very faint. Values are clamped to 0.05–1.0 rather than rejected. The floor is not zero because fading a window does not stop it taking clicks — an invisible panel would still swallow every click inside its frame, and you would type into a terminal you cannot see. Nothing else here is at risk: dimming only applies while the panel is unfocused, and every ⌃⌥T restores it to full.

**`terminalPalette`** — per-role color overrides on top of whichever theme is selected. Roles are `ansi0`…`ansi15`, `background`, `foreground`, `cursor`, `selection` and `tabBarText`; values are `#RRGGBB` or `#RRGGBBAA`. A line that does not parse costs that one color and nothing else.

**`terminalThemes`** — your own themes, which appear in the right-click Theme menu next to the built-ins. Each needs an `id`, a `title` and a `colors` object with all sixteen of `ansi0`…`ansi15`. The five non-ANSI roles are optional and inherit from the default theme.

Changing the ANSI palette changes what an ANSI color *code* renders as. It does not change *which* color your prompt asks for — that lives in your shell config and behaves identically in every terminal.

### Quick commands

Each entry needs an `id`, a `title` and a `command`. `hotkey` is optional; without one the command is still in the ⌃⌥K palette and the right-click menu.

**`"run"` decides whether the command executes or is only typed, and `run` defaults to false.** That is a safety decision rather than a style one. A global hotkey with `"run": true` executes the command verbatim, in a real login shell, with your full environment, with no confirmation — and possibly while the panel is hidden, so the window that would show you what just happened is not even on screen. Left at the default, the command is typed at the prompt and left there for you to read and run yourself. The palette labels each entry "runs" or "types" so the difference is visible before you press Return.

Opting in is one word. Opting out after an `rm -rf` fired from a keystroke is not.

**`"newTab": true` gives the command a fresh tab instead of the active one.** Off by default. Turn it on for anything you leave running — a `tail -f`, a dev server, a watcher — which otherwise lands in a tab that is busy with something else: with `run` false it appends to whatever is already typed at that prompt, and with `run` true it goes to the foreground process rather than to the shell. It is independent of `run`, so `newTab` on its own opens a tab and leaves the command typed there, unexecuted.

## Debugging

Set `"debug": true` and Driftwood writes to `~/Library/Logs/Driftwood/driftwood.log`:

```bash
tail -f ~/Library/Logs/Driftwood/driftwood.log
```

It records the resolved font, hotkey registrations and failures, rejected themes and quick commands, and the focus state on every summon.

## Known issues

Pasted text renders in black until the next keypress redraws it. This is in SwiftTerm, the terminal engine, and cannot be fixed from here — the wrong color is baked in before the echo is drawn.

## Credits

The terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza. Driftwood grew out of Starboard, an earlier Dock-tracking terminal panel, and keeps its shell handling and its default color scheme.

## License

MIT. See `LICENSE`.
