// The hero's panel re-creation: fake shell, tabs, themes, and — from step 5 —
// the right-click menu, the command palette and the page-level hotkeys. A
// second, much smaller block at the bottom draws the guide's theme swatches;
// both pages load this file and each one runs only the part that has markup.
//
// The rules this file follows, written down before the code that has to
// follow them:
//
//   * Output is written with textContent, never innerHTML. `echo` takes
//     arbitrary text from a visitor, and that is the only path on this site
//     where input reaches the DOM.
//   * Input is capped at 200 characters per line, scrollback at 200 lines.
//   * No shell-style expansion. `echo $HOME` prints the literal `$HOME`. The
//     one exception is `$SHELL`, which prints /bin/zsh, because `echo $SHELL`
//     is in the app's own smoke test and is the first thing people type.
//   * Colored output is assembled from pre-written (text, theme role) pairs.
//     Nothing parses input into styled markup.
//
// The demo never claims to be a terminal. Anything outside the command table
// answers with a line that says so, rather than with a plausible-looking
// error, so nobody leaves thinking they used Driftwood.
(function () {
  "use strict";

  var MAX_LINE = 200;
  var MAX_SCROLLBACK = 200;

  var stage = document.getElementById("stage");
  var themes = window.DRIFTWOOD_THEMES;
  if (!stage || !themes || !themes.length) return;

  var panelEl = document.getElementById("panel");
  var tabsEl = document.getElementById("tabs");
  var newTabEl = document.getElementById("newtab");
  var termEl = document.getElementById("term");
  var outEl = document.getElementById("out");
  var typedEl = document.getElementById("typed");
  var inputEl = document.getElementById("input");
  var chipsEl = document.getElementById("chips");
  var hintEl = document.getElementById("stage-hint");
  var hintBtn = document.getElementById("stage-hint-btn");

  // ---------------------------------------------------------------- themes

  // "#RRGGBB" or "#RRGGBBAA" -> "R G B", the space-separated channels that
  // rgb(... / <alpha>) takes. themes.js carries each color at the alpha
  // TerminalTheme gives it, but two places in the app re-alpha a theme color
  // rather than using it as-is: the tab strip fills with the background at
  // 0.35, and a tab highlights with the tab text at 0.14. Those need the
  // channels without the theme's own alpha attached, so every color that gets
  // re-alphaed in panel.css is published in both forms.
  function channels(hex) {
    return [
      parseInt(hex.slice(1, 3), 16),
      parseInt(hex.slice(3, 5), 16),
      parseInt(hex.slice(5, 7), 16)
    ].join(" ");
  }

  // The alpha channel on its own, 0…1, defaulting to opaque when the color
  // carries no alpha. The Opacity menu multiplies the theme's own alpha rather
  // than replacing it — `AppDelegate.applyTheme` does exactly this — so the
  // panel's background rule needs the alpha as a number it can multiply, not
  // baked into the color.
  function alphaOf(hex) {
    return hex.length >= 9 ? parseInt(hex.slice(7, 9), 16) / 255 : 1;
  }

  // One assignment per color onto .stage, which is what makes a theme switch
  // a single call: every rule in panel.css reads these and nothing caches
  // them, so output already on screen recolors along with the panel.
  function applyTheme(theme) {
    var s = stage.style;
    s.setProperty("--dw-bg", theme.background);
    s.setProperty("--dw-bg-rgb", channels(theme.background));
    s.setProperty("--dw-bg-alpha", String(alphaOf(theme.background)));
    s.setProperty("--dw-fg", theme.foreground);
    s.setProperty("--dw-cursor", theme.cursor);
    s.setProperty("--dw-selection", theme.selection);
    s.setProperty("--dw-tab-text", theme.tabBarText);
    s.setProperty("--dw-tab-text-rgb", channels(theme.tabBarText));
    for (var i = 0; i < theme.ansi.length; i++) {
      s.setProperty("--dw-ansi" + i, theme.ansi[i]);
    }
    stage.dataset.theme = theme.id;
  }

  // themes.js lists the built-ins in TerminalTheme.builtIn's order, and the
  // first is the app's own default.
  var themeIndex = 0;
  applyTheme(themes[0]);

  // Everything that can change a theme — the chips, the menu's Theme submenu,
  // the "cycle the theme" demo — goes through here, so the chips' pressed
  // state and the menu's checkmarks cannot disagree about which theme is on.
  function setTheme(index) {
    themeIndex = index;
    applyTheme(themes[index]);
    syncChips();
  }

  // ------------------------------------------------- font size and opacity

  // AppState.fontSizePresets and AppState.opacityPresets, in the app's order.
  // Hand-copied, like the measurements in panel.css, and nothing guards them.
  var FONT_PRESETS = [10, 11, 12, 13, 14, 16];
  var OPACITY_PRESETS = [1.0, 0.9, 0.8, 0.7, 0.5];
  var fontSize = 12;                               // AppState.defaultFontSize
  var opacity = 1.0;

  // One point larger in CSS pixels than in the app's points, which is the
  // same offset panel.css takes for its 13px default: a browser at 100% zoom
  // renders 12px monospace a step smaller than macOS draws 12pt.
  function setFontSize(points) {
    fontSize = points;
    stage.style.setProperty("--dw-font-size", (points + 1) + "px");
  }

  function setOpacity(value) {
    opacity = value;
    stage.style.setProperty("--dw-opacity", String(value));
  }

  // ------------------------------------------------------------ the model

  // A line is an array of segments. A segment is {t: text} in the foreground
  // color, or {t: text, c: "ansi2"} in one of the theme's ANSI roles. Roles,
  // never literal colors — that is what makes a theme switch recolor output
  // that is already on screen.
  function line() {
    return Array.prototype.slice.call(arguments);
  }

  function prompt(command) {
    return [{ t: "~ $", c: "ansi6" }, { t: " " + command }];
  }

  function newTab(title) {
    return { title: title, lines: [], input: "" };
  }

  var tabs = [newTab("zsh"), newTab("driftwood")];
  var active = 0;

  // The opening exchange, which is also what index.html shows before this
  // script runs. Both have to say the same thing, or the hero flickers from
  // one to the other on load.
  tabs[0].lines = [prompt("echo $SHELL"), line({ t: "/bin/zsh" })];

  // Undefined when the last tab has been closed and the panel is hidden. Every
  // caller either guards or is unreachable in that state, because the hidden
  // panel is `inert` and cannot be typed into or clicked.
  function current() {
    return tabs[active];
  }

  // Keep the half-typed line with the tab it was typed into.
  function stashInput() {
    if (current()) current().input = inputEl.value;
  }

  // ----------------------------------------------------------- the shell

  function helpLines() {
    return [
      line({ t: "This is a demo shell in a web page. It is not a terminal." }),
      line({ t: "It answers: " }, {
        t: "echo  ls  pwd  date  whoami  git status  clear  help", c: "ansi6"
      }),
      line({ t: "The real Driftwood runs your login shell on a PTY." })
    ];
  }

  // `ls` and `git status` are pre-written segment lists rather than anything
  // assembled from input, which is what keeps a colored path off the input
  // path entirely. Directories in blue and staged/unstaged in green and red
  // are the colors a default zsh and git actually use, and here they are ANSI
  // roles, so they change with the theme the way the real ones do.
  function lsLines() {
    return [
      line(
        { t: "CHANGELOG.md   CLAUDE.md      LICENSE        Makefile" }
      ),
      line(
        { t: "Package.swift  README.md      " },
        { t: "Resources", c: "ansi4" }, { t: "      " },
        { t: "Sources", c: "ansi4" }
      ),
      line(
        { t: "Checks", c: "ansi4" }, { t: "         " },
        { t: "Tools", c: "ansi4" }, { t: "          " },
        { t: "docs", c: "ansi4" }
      )
    ];
  }

  function gitStatusLines() {
    return [
      line({ t: "On branch " }, { t: "site-scaffold", c: "ansi2" }),
      line({ t: "Changes to be committed:" }),
      line({ t: "        new file:   docs/panel.css", c: "ansi2" }),
      line({ t: "Changes not staged for commit:" }),
      line({ t: "        modified:   docs/index.html", c: "ansi1" }),
      line({ t: "" })
    ];
  }

  function dateLine() {
    var d = new Date();
    var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    function pad(n) { return (n < 10 ? "0" : "") + n; }
    return line({
      t: days[d.getDay()] + " " + months[d.getMonth()] + " " + pad(d.getDate()) +
         " " + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" +
         pad(d.getSeconds()) + " " + d.getFullYear()
    });
  }

  // The one place a visitor's own text is printed back. It is echoed
  // verbatim: no quote handling, no globbing, no variable expansion, with
  // $SHELL the single exception. The lookahead stops $SHELLS and $SHELL_PATH
  // from being rewritten into something that reads like expansion but is not.
  function echoLine(rest) {
    return line({ t: rest.replace(/\$SHELL(?![A-Za-z0-9_])/g, "/bin/zsh") });
  }

  function respond(command) {
    var trimmed = command.trim();
    if (trimmed === "") return [];

    var word = trimmed.split(/\s+/)[0];

    if (trimmed === "clear") return null;          // null means wipe, below
    if (word === "echo") return [echoLine(trimmed.slice(4).replace(/^ /, ""))];
    if (trimmed === "help") return helpLines();
    if (trimmed === "ls") return lsLines();
    if (trimmed === "pwd") return [line({ t: "/Users/you" })];
    if (trimmed === "whoami") return [line({ t: "you" })];
    if (trimmed === "date") return [dateLine()];
    if (trimmed === "git status") return gitStatusLines();
    if (word === "git") {
      return [line({ t: "driftwood: the demo shell only answers 'git status'" })];
    }
    return [line({ t: "driftwood: this is a demo shell — try 'help'" })];
  }

  function submit(command) {
    var tab = current();
    var output = respond(command);

    if (output === null) {                         // `clear`
      tab.lines = [];
      renderTerm();
    } else {
      var added = [prompt(command)].concat(output);
      tab.lines = tab.lines.concat(added);
      appendLines(added);

      // Oldest lines go first, so a long run of output cannot grow the page's
      // memory without bound. The model and the DOM are trimmed by the same
      // count, in the same place, so they cannot come apart.
      var excess = tab.lines.length - MAX_SCROLLBACK;
      if (excess > 0) {
        tab.lines = tab.lines.slice(excess);
        for (var i = 0; i < excess && outEl.firstChild; i++) {
          outEl.removeChild(outEl.firstChild);
        }
      }
    }

    tab.input = "";
    inputEl.value = "";
    typedEl.textContent = "";
    scrollToEnd();
  }

  // --------------------------------------------------------- rendering

  function renderLine(segments) {
    var p = document.createElement("p");
    p.className = "dw-line";
    for (var i = 0; i < segments.length; i++) {
      var span = document.createElement("span");
      span.textContent = segments[i].t;            // never innerHTML
      if (segments[i].c) {
        span.style.color = "var(--dw-" + segments[i].c + ")";
      }
      p.appendChild(span);
    }
    return p;
  }

  function scrollToEnd() {
    termEl.scrollTop = termEl.scrollHeight;
  }

  // New output only. #out is a live region, so appending announces just the
  // lines that arrived — which is the point of making it one.
  function appendLines(lines) {
    for (var i = 0; i < lines.length; i++) {
      outEl.appendChild(renderLine(lines[i]));
    }
    scrollToEnd();
  }

  // A wholesale replacement, for a tab switch or `clear`. It has to happen
  // with the live region switched off: replacing every node in a polite live
  // region makes a screen reader read the entire scrollback aloud, so
  // switching tabs would recite the other tab's history. Re-armed on the next
  // frame, once the replacement has settled.
  function renderTerm() {
    if (!current()) return;                        // no tabs: the panel is hidden
    var lines = current().lines;
    outEl.setAttribute("aria-live", "off");
    outEl.textContent = "";
    for (var i = 0; i < lines.length; i++) {
      outEl.appendChild(renderLine(lines[i]));
    }
    typedEl.textContent = current().input;
    scrollToEnd();
    requestAnimationFrame(function () {
      outEl.setAttribute("aria-live", "polite");
    });
  }

  function renderTabs() {
    // SessionStack.showsTabBar is `count > 1`: one tab means no strip.
    tabsEl.hidden = tabs.length < 2;
    tabsEl.textContent = "";

    tabs.forEach(function (tab, index) {
      var wrap = document.createElement("div");
      wrap.className = "dw-tab" + (index === active ? " is-active" : "");

      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "dw-tab-btn";
      btn.textContent = tab.title;
      btn.setAttribute("aria-current", index === active ? "true" : "false");
      btn.addEventListener("click", function () { select(index); });

      var close = document.createElement("button");
      close.type = "button";
      close.className = "dw-close";
      close.setAttribute("aria-label", "Close " + tab.title);
      close.addEventListener("click", function (e) {
        e.stopPropagation();
        closeTab(index);
      });

      wrap.appendChild(btn);
      wrap.appendChild(close);
      tabsEl.appendChild(wrap);
    });

    tabsEl.appendChild(newTabEl);
  }

  // ------------------------------------------------------------- tabs

  function select(index) {
    stashInput();
    active = index;
    inputEl.value = current().input;
    renderTabs();
    renderTerm();
    inputEl.focus();
  }

  function addTab() {
    stashInput();
    tabs.push(newTab("zsh"));
    active = tabs.length - 1;
    inputEl.value = "";
    renderTabs();
    renderTerm();
    inputEl.focus();
  }

  // Closing the last tab hides the panel rather than emptying it, which is
  // `AppDelegate.closeTab`: quitting instead would make ⌘W an app-killer that
  // looks like a window-closer, and there is no Dock icon to relaunch from.
  // ⌃⌥T brings the panel back with a fresh shell, and `showPanel` below opens
  // that shell the same way the app's does.
  function closeTab(index) {
    if (!tabs.length) return;
    tabs.splice(index, 1);
    if (active >= tabs.length) active = tabs.length - 1;
    else if (index < active) active -= 1;

    if (!tabs.length) {
      hidePanel();
      return;
    }
    inputEl.value = current().input;
    renderTabs();
    renderTerm();
    inputEl.focus();
  }

  // ------------------------------------------------------ panel visibility

  function panelIsHidden() {
    return panelEl.classList.contains("is-hidden");
  }

  // `if sessions.isEmpty { openSession(...) }` in AppDelegate.showPanel: the
  // summon hotkey after the last tab closed brings back a fresh shell rather
  // than an empty panel.
  function showPanel() {
    if (!tabs.length) {
      tabs = [newTab("zsh")];
      active = 0;
      inputEl.value = "";
      renderTabs();
      renderTerm();
    }
    panelEl.classList.remove("is-hidden");
    panelEl.removeAttribute("inert");
    if (hintEl) hintEl.hidden = true;
    inputEl.focus();
  }

  // `inert` is what takes the hidden panel out of the tab order and away from
  // the pointer. The class only fades it: a panel that is invisible but still
  // focusable would put a keyboard user inside a window that is not on screen.
  function hidePanel() {
    closePalette();
    closeMenu();
    panelEl.classList.add("is-hidden");
    panelEl.setAttribute("inert", "");
    if (hintEl) hintEl.hidden = false;
  }

  function togglePanel() {
    if (panelIsHidden()) showPanel(); else hidePanel();
  }

  // ------------------------------------------------------------ chips

  var themeChips = [];
  var menuChip = null;
  var paletteChip = null;

  function buildChips() {
    if (!chipsEl) return;
    chipsEl.textContent = "";
    themeChips = [];

    themes.forEach(function (theme, index) {
      var chip = document.createElement("button");
      chip.type = "button";
      chip.className = "chip";
      chip.textContent = theme.title;
      chip.setAttribute("aria-pressed", index === 0 ? "true" : "false");
      chip.addEventListener("click", function () { setTheme(index); });
      themeChips.push(chip);
      chipsEl.appendChild(chip);
    });

    menuChip = document.createElement("button");
    menuChip.type = "button";
    menuChip.className = "chip";
    menuChip.textContent = "Menu";
    menuChip.setAttribute("aria-haspopup", "true");
    menuChip.setAttribute("aria-expanded", "false");
    menuChip.addEventListener("click", function () {
      if (menuEl) closeMenu();
      else openMenuNearPanel(menuChip);
    });
    chipsEl.appendChild(menuChip);

    paletteChip = document.createElement("button");
    paletteChip.type = "button";
    paletteChip.className = "chip";
    paletteChip.textContent = "Palette ⌃⌥K";
    paletteChip.setAttribute("aria-haspopup", "dialog");
    paletteChip.setAttribute("aria-expanded", "false");
    paletteChip.addEventListener("click", function () { togglePalette(paletteChip); });
    chipsEl.appendChild(paletteChip);
  }

  function syncChips() {
    themeChips.forEach(function (chip, index) {
      chip.setAttribute("aria-pressed", index === themeIndex ? "true" : "false");
    });
  }

  // ------------------------------------------------- the right-click menu

  // A re-creation of `AppDelegate.buildSettingsMenu`, in its order, including
  // the rows this page cannot honestly perform. Those are marked `inert` and
  // drawn dimmed: the menu is the whole settings surface in the app — there is
  // no preferences window and no menu bar item — so a visitor deciding whether
  // to install needs to see everything that is in it, not just the parts a web
  // page can imitate.
  //
  // Rebuilt on every open, the way the app rebuilds the NSMenu on every
  // right-click, so the checkmarks always show the state as it is now.
  var menuEl = null;
  var menuOpener = null;

  function menuSpec() {
    return [
      {
        title: "Theme", submenu: themes.map(function (theme, index) {
          return {
            title: theme.title, radio: true, checked: index === themeIndex,
            act: function () { setTheme(index); }
          };
        })
      },
      {
        title: "Font Size", submenu: FONT_PRESETS.map(function (size) {
          return {
            title: size + "pt", radio: true, checked: size === fontSize,
            act: function () { setFontSize(size); }
          };
        })
      },
      {
        title: "Opacity", submenu: OPACITY_PRESETS.map(function (preset) {
          return {
            title: Math.round(preset * 100) + "%", radio: true,
            checked: preset === opacity,
            act: function () { setOpacity(preset); }
          };
        })
      },
      { sep: true },
      {
        title: "New Tab", key: "⌃⌥N",
        act: function () { showPanel(); addTab(); }
      },
      {
        title: "Quick Commands", submenu: QUICK_COMMANDS.map(function (command) {
          return {
            title: command.title, key: command.hotkey,
            act: function () { runQuickCommand(command); }
          };
        }).concat([
          { sep: true },
          {
            title: "Show Palette…", key: "⌃⌥K",
            act: function () { openPalette(menuOpener); }
          }
        ])
      },
      { sep: true },
      { title: "Launch at Login", checkbox: true, checked: false, inert: true },
      { title: "Reset Position", inert: true },
      { title: "Edit Configuration…", inert: true },
      { title: "Check for Updates…", inert: true },
      { sep: true },
      { version: true },
      { title: "Quit Driftwood", inert: true }
    ];
  }

  function buildMenu(items, label) {
    var menu = document.createElement("div");
    menu.className = "dw-menu";
    menu.setAttribute("role", "menu");
    menu.setAttribute("aria-label", label);

    items.forEach(function (spec) {
      if (spec.sep) {
        var sep = document.createElement("div");
        sep.className = "dw-menu-sep";
        sep.setAttribute("role", "separator");
        menu.appendChild(sep);
        return;
      }

      if (spec.version) {
        var version = document.createElement("div");
        version.className = "dw-menu-version";
        version.setAttribute("role", "none");
        version.textContent = "Driftwood " + (window.DRIFTWOOD_VERSION || "");
        menu.appendChild(version);

        // The one sentence that says which of these rows are real. It sits
        // here, in the menu, rather than in a caption beside it, because this
        // is where a visitor is when the question comes up.
        var note = document.createElement("div");
        note.className = "dw-menu-note";
        note.setAttribute("role", "none");
        note.textContent = "Dimmed rows do nothing on this page.";
        menu.appendChild(note);
        return;
      }

      var item = document.createElement("button");
      item.type = "button";
      item.className = "dw-menuitem";
      item.setAttribute("role",
        spec.radio ? "menuitemradio" : spec.checkbox ? "menuitemcheckbox" : "menuitem");
      if (spec.radio || spec.checkbox) {
        item.setAttribute("aria-checked", spec.checked ? "true" : "false");
      }
      if (spec.inert) item.setAttribute("aria-disabled", "true");
      item.tabIndex = -1;

      var title = document.createElement("span");
      title.textContent = spec.title;
      item.appendChild(title);

      if (spec.key) {
        var key = document.createElement("span");
        key.className = "dw-menu-key";
        key.textContent = spec.key;
        item.appendChild(key);
      }

      if (!spec.submenu) {
        item.addEventListener("click", function () {
          if (spec.inert) return;                  // drawn, dimmed, and does nothing
          closeMenu();
          if (spec.act) spec.act();
        });
        menu.appendChild(item);
        return;
      }

      // A row with a submenu: the two live in a wrapper so the submenu can be
      // positioned against its parent row rather than against the whole menu.
      var wrap = document.createElement("div");
      wrap.className = "dw-menuwrap";
      wrap.setAttribute("role", "none");

      item.setAttribute("aria-haspopup", "true");
      item.setAttribute("aria-expanded", "false");
      var arrow = document.createElement("span");
      arrow.className = "dw-menu-key";
      arrow.textContent = "▸";
      item.appendChild(arrow);

      var sub = buildMenu(spec.submenu, spec.title);
      sub.classList.add("dw-submenu");
      sub.hidden = true;
      item.addEventListener("click", function () { openSubmenu(item, true); });
      item.addEventListener("mouseenter", function () { openSubmenu(item, false); });

      wrap.appendChild(item);
      wrap.appendChild(sub);
      menu.appendChild(wrap);
    });

    // Hovering a row moves focus to it, the way a pointer moves the highlight
    // in a real menu, so the arrow keys carry on from wherever the mouse left
    // off instead of jumping back to the top.
    menu.addEventListener("mouseover", function (e) {
      var row = e.target.closest(".dw-menuitem");
      if (row && menu.contains(row)) row.focus();
    });

    return menu;
  }

  function menuItemsOf(menu) {
    return Array.prototype.filter.call(
      menu.querySelectorAll(".dw-menuitem"),
      function (item) { return item.closest(".dw-menu") === menu; }
    );
  }

  // The submenu belonging to a row, or null when the row has none. It must
  // check the class and not just take `nextElementSibling`: a row with no
  // submenu is followed by the *next row of the menu*, and closing "the
  // submenu" of an ordinary row therefore hid the row underneath it. That is
  // what made Quick Commands disappear from the menu the first time a submenu
  // was opened.
  function submenuOf(item) {
    var next = item.nextElementSibling;
    return next && next.classList.contains("dw-submenu") ? next : null;
  }

  function openSubmenu(item, focusFirst) {
    var sub = submenuOf(item);
    if (!sub) return;
    closeSiblingSubmenus(item);
    sub.hidden = false;
    item.setAttribute("aria-expanded", "true");

    // Flip to the left when the submenu would run off the stage. Measured
    // after unhiding, because a hidden element has no width to measure.
    var stageRect = stage.getBoundingClientRect();
    var rect = sub.getBoundingClientRect();
    if (rect.right > stageRect.right) {
      sub.style.left = "auto";
      sub.style.right = "100%";
    }
    if (focusFirst) {
      var items = menuItemsOf(sub);
      if (items.length) items[0].focus();
    }
  }

  function closeSubmenu(item) {
    var sub = submenuOf(item);
    if (!sub) return;
    sub.hidden = true;
    sub.style.left = "";
    sub.style.right = "";
    item.setAttribute("aria-expanded", "false");
  }

  function closeSiblingSubmenus(item) {
    var parent = item.closest(".dw-menu");
    if (!parent) return;
    menuItemsOf(parent).forEach(function (other) {
      if (other !== item) closeSubmenu(other);
    });
  }

  // `left` and `top` are in stage coordinates. Clamped to the stage where the
  // menu fits, and pinned to the top where it does not — the app's menu can
  // spill past its window onto the desktop, and this one cannot.
  function openMenu(left, top, opener) {
    closeMenu();
    menuOpener = opener || null;
    menuEl = buildMenu(menuSpec(), "Driftwood settings");
    menuEl.style.left = "0px";
    menuEl.style.top = "0px";
    stage.appendChild(menuEl);

    var width = menuEl.offsetWidth;
    var height = menuEl.offsetHeight;
    menuEl.style.left = Math.max(4, Math.min(left, stage.clientWidth - width - 4)) + "px";
    menuEl.style.top = Math.max(4, Math.min(top, stage.clientHeight - height - 4)) + "px";

    if (menuChip) menuChip.setAttribute("aria-expanded", "true");
    var items = menuItemsOf(menuEl);
    if (items.length) items[0].focus();

    document.addEventListener("mousedown", onDocumentMouseDown, true);
    menuEl.addEventListener("keydown", onMenuKeyDown);
  }

  function openMenuNearPanel(opener) {
    var panelRect = panelEl.getBoundingClientRect();
    var stageRect = stage.getBoundingClientRect();
    openMenu(panelRect.left - stageRect.left + 36,
             panelRect.top - stageRect.top + 28, opener);
  }

  function closeMenu(restoreFocus) {
    if (!menuEl) return;
    document.removeEventListener("mousedown", onDocumentMouseDown, true);
    menuEl.removeEventListener("keydown", onMenuKeyDown);
    menuEl.remove();
    menuEl = null;
    if (menuChip) menuChip.setAttribute("aria-expanded", "false");
    if (restoreFocus && menuOpener) menuOpener.focus();
    menuOpener = null;
  }

  function onDocumentMouseDown(e) {
    if (menuEl && !menuEl.contains(e.target) && e.target !== menuChip) closeMenu();
  }

  function onMenuKeyDown(e) {
    var item = document.activeElement;
    if (!item || !item.classList.contains("dw-menuitem")) return;
    var menu = item.closest(".dw-menu");
    var items = menuItemsOf(menu);
    var index = items.indexOf(item);
    var inSubmenu = menu.classList.contains("dw-submenu");

    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        items[(index + 1) % items.length].focus();
        break;
      case "ArrowUp":
        e.preventDefault();
        items[(index - 1 + items.length) % items.length].focus();
        break;
      case "Home":
        e.preventDefault();
        items[0].focus();
        break;
      case "End":
        e.preventDefault();
        items[items.length - 1].focus();
        break;
      case "ArrowRight":
        if (item.getAttribute("aria-haspopup") === "true") {
          e.preventDefault();
          openSubmenu(item, true);
        }
        break;
      case "ArrowLeft":
        if (inSubmenu) {
          e.preventDefault();
          var parent = menu.previousElementSibling;
          closeSubmenu(parent);
          parent.focus();
        }
        break;
      case "Escape":
        e.preventDefault();
        // Escape in a submenu closes only that submenu, which is what a real
        // menu does; a second press then closes the menu itself.
        if (inSubmenu) {
          var owner = menu.previousElementSibling;
          closeSubmenu(owner);
          owner.focus();
        } else {
          closeMenu(true);
        }
        break;
      case " ":
      case "Enter":
        e.preventDefault();
        item.click();
        break;
      default:
        break;
    }
  }

  // ------------------------------------------------- the command palette

  // Three sample commands, shaped like the `quickCommands` array in
  // config.json. One runs, one types, and one has no hotkey at all — which is
  // legal, and leaves the command reachable from the palette and the menu.
  var QUICK_COMMANDS = [
    {
      id: "logs", title: "Tail logs", command: "tail -f /tmp/app.log",
      hotkey: "⌃⌥1", run: false
    },
    {
      id: "status", title: "Git status", command: "git status",
      hotkey: "⌃⌥2", run: true
    },
    { id: "list", title: "List files", command: "ls", hotkey: null, run: false }
  ];

  // The difference the palette exists to make visible. `run: false` — the
  // default, and a safety decision rather than a style one — types the command
  // at the prompt and leaves it there to be read before it is run.
  function runQuickCommand(command) {
    showPanel();
    if (command.run) {
      submit(command.command);
    } else {
      inputEl.value = command.command;
      if (current()) current().input = command.command;
      typedEl.textContent = command.command;
    }
    inputEl.focus();
  }

  var paletteEl = null;
  var paletteFilter = null;
  var paletteList = null;
  var paletteOpener = null;
  var paletteMatches = [];
  var paletteSelection = -1;

  function openPalette(opener) {
    if (paletteEl) return;
    paletteOpener = opener || null;

    paletteEl = document.createElement("div");
    paletteEl.className = "dw-palette";
    paletteEl.setAttribute("role", "dialog");
    paletteEl.setAttribute("aria-modal", "true");
    paletteEl.setAttribute("aria-label", "Quick commands");

    paletteFilter = document.createElement("input");
    paletteFilter.type = "text";
    paletteFilter.className = "dw-palette-filter";
    paletteFilter.placeholder = "Run a command…";
    paletteFilter.setAttribute("aria-label", "Filter quick commands");
    paletteFilter.setAttribute("autocomplete", "off");
    paletteFilter.setAttribute("role", "combobox");
    paletteFilter.setAttribute("aria-expanded", "true");
    paletteFilter.setAttribute("aria-controls", "dw-palette-list");
    paletteEl.appendChild(paletteFilter);

    paletteList = document.createElement("ul");
    paletteList.className = "dw-palette-list";
    paletteList.id = "dw-palette-list";
    paletteList.setAttribute("role", "listbox");
    paletteEl.appendChild(paletteList);

    // The filter only re-arms the selection on a keystroke that changed the
    // text. The app needs an explicit guard for that, because SwiftUI's
    // TextField writes the same string back on every re-render and re-arming
    // there discards the row the user moved to — ⏎ then runs a command other
    // than the highlighted one. A DOM `input` event fires only on a real
    // change, so the event *is* the guard; the hazard is the same and it is
    // worth knowing it was handled rather than absent.
    paletteFilter.addEventListener("input", function () { renderPalette(true); });
    paletteFilter.addEventListener("keydown", onPaletteKeyDown);

    stage.appendChild(paletteEl);
    renderPalette(true);
    paletteFilter.focus();
    if (paletteChip) paletteChip.setAttribute("aria-expanded", "true");
  }

  function closePalette(restoreFocus) {
    if (!paletteEl) return;
    paletteEl.remove();
    paletteEl = null;
    paletteFilter = null;
    paletteList = null;
    paletteMatches = [];
    paletteSelection = -1;
    if (paletteChip) paletteChip.setAttribute("aria-expanded", "false");
    if (restoreFocus && paletteOpener) paletteOpener.focus();
    else if (restoreFocus && !panelIsHidden()) inputEl.focus();
    paletteOpener = null;
  }

  function togglePalette(opener) {
    // ⌃⌥K toggles, as it does in the app: re-presenting an open palette would
    // reset the highlighted row under someone mid-type.
    if (paletteEl) closePalette(true); else openPalette(opener);
  }

  // Case-insensitive substring match against the title *and* the command, the
  // way PaletteModel.matches does: a command saved as "Deploy" is found by
  // typing "deploy", and one whose title you have forgotten is found by typing
  // part of the command itself.
  function paletteMatchesFor(filter) {
    var needle = filter.toLowerCase();
    if (!needle) return QUICK_COMMANDS.slice();
    return QUICK_COMMANDS.filter(function (command) {
      return command.title.toLowerCase().indexOf(needle) >= 0
          || command.command.toLowerCase().indexOf(needle) >= 0;
    });
  }

  function renderPalette(rearm) {
    paletteMatches = paletteMatchesFor(paletteFilter.value);
    if (rearm) paletteSelection = paletteMatches.length ? 0 : -1;
    paletteList.textContent = "";

    if (!paletteMatches.length) {
      var empty = document.createElement("li");
      empty.className = "dw-palette-empty";
      empty.setAttribute("role", "none");
      empty.textContent = "No match";
      paletteList.appendChild(empty);
      paletteFilter.removeAttribute("aria-activedescendant");
      return;
    }

    paletteMatches.forEach(function (command, index) {
      var row = document.createElement("li");
      row.className = "dw-palette-row" + (index === paletteSelection ? " is-selected" : "");
      row.id = "dw-palette-row-" + index;
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", index === paletteSelection ? "true" : "false");

      var text = document.createElement("span");
      text.className = "dw-palette-title";
      var title = document.createElement("span");
      title.textContent = command.title;
      var cmd = document.createElement("span");
      cmd.className = "dw-palette-cmd";
      cmd.textContent = command.command;
      text.appendChild(title);
      text.appendChild(cmd);
      row.appendChild(text);

      // Says out loud what ⏎ will do, exactly as the app's row does. A command
      // that types itself and one that executes on the spot are the same
      // keystroke away, and the difference is not recoverable afterwards.
      var tag = document.createElement("span");
      tag.className = "dw-palette-tag";
      tag.textContent = command.run ? "runs" : "types";
      row.appendChild(tag);

      if (command.hotkey) {
        var hotkey = document.createElement("span");
        hotkey.className = "dw-palette-hotkey";
        hotkey.textContent = command.hotkey;
        row.appendChild(hotkey);
      }

      row.addEventListener("click", function () { firePalette(command); });
      paletteList.appendChild(row);
    });

    if (paletteSelection >= 0) {
      paletteFilter.setAttribute("aria-activedescendant",
                                 "dw-palette-row-" + paletteSelection);
    }
  }

  // Firing always dismisses, and it is one function because there are two ways
  // to fire — ⏎ and a click on a row. In the app both used to leave the
  // palette sitting open over the terminal the command had just been typed
  // into.
  function firePalette(command) {
    closePalette();
    runQuickCommand(command);
  }

  function onPaletteKeyDown(e) {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (!paletteMatches.length) return;
      var step = e.key === "ArrowDown" ? 1 : -1;
      paletteSelection =
        Math.min(Math.max(paletteSelection + step, 0), paletteMatches.length - 1);
      renderPalette(false);
      return;
    }
    if (e.key === "Enter") {
      e.preventDefault();
      if (paletteMatches[paletteSelection]) firePalette(paletteMatches[paletteSelection]);
      return;
    }
    if (e.key === "Escape") {
      e.preventDefault();
      closePalette(true);
      return;
    }
    // The palette holds focus while it is open: the filter field is its only
    // focusable element, so trapping is one line rather than a ring of
    // sentinels.
    if (e.key === "Tab") e.preventDefault();
  }

  // ------------------------------------------------------------ wiring

  inputEl.addEventListener("input", function () {
    if (inputEl.value.length > MAX_LINE) {
      inputEl.value = inputEl.value.slice(0, MAX_LINE);
    }
    current().input = inputEl.value;
    typedEl.textContent = inputEl.value;
  });

  inputEl.addEventListener("keydown", function (e) {
    if (e.key !== "Enter") return;
    e.preventDefault();
    submit(inputEl.value);
  });

  inputEl.addEventListener("focus", function () {
    termEl.classList.add("is-focused");
  });
  inputEl.addEventListener("blur", function () {
    termEl.classList.remove("is-focused");
  });

  // Clicking anywhere in the terminal puts the keyboard at the prompt, the way
  // clicking a terminal window does. On mouseup rather than mousedown, and
  // skipped when text is selected, so a drag to select output is not undone by
  // the focus call that follows it.
  termEl.addEventListener("mouseup", function () {
    var selection = window.getSelection();
    if (selection && selection.toString()) return;
    inputEl.focus();
  });

  newTabEl.addEventListener("click", addTab);

  // Right-clicking anywhere in the panel opens Driftwood's settings menu, and
  // the browser's own context menu is suppressed for the same reason
  // ChromeView.hitTest claims right-clicks: without that, the terminal's menu
  // appears instead and there is no way left to change a theme.
  panelEl.addEventListener("contextmenu", function (e) {
    e.preventDefault();
    var rect = stage.getBoundingClientRect();
    openMenu(e.clientX - rect.left, e.clientY - rect.top, inputEl);
  });

  if (hintBtn) hintBtn.addEventListener("click", showPanel);

  // ------------------------------------------------------- page shortcuts

  // The app's own bindings, on the page. ⌘T and ⌘W are deliberately absent:
  // a browser keeps both for its own tabs and does not let a page have them,
  // so binding them would either do nothing or close the page. `e.code` rather
  // than `e.key`, because ⌥ with a letter produces a different character on a
  // Mac and the physical key is what the app registers.
  document.addEventListener("keydown", function (e) {
    if (!e.ctrlKey || !e.altKey || e.metaKey) return;
    var handled = true;
    switch (e.code) {
      case "KeyT": togglePanel(); break;            // hotkeys.toggle
      case "KeyK": togglePalette(null); break;      // hotkeys.commands
      case "KeyN": showPanel(); addTab(); break;    // hotkeys.newTab
      case "Digit1": runQuickCommand(QUICK_COMMANDS[0]); break;
      case "Digit2": runQuickCommand(QUICK_COMMANDS[1]); break;
      default: handled = false;
    }
    if (handled) e.preventDefault();
  });

  // ------------------------------------------------ the shortcut list

  // Hover alone reaches neither a touch screen nor a keyboard, so the button
  // also toggles. CSS handles hover and focus; this handles the click.
  var keyhint = document.getElementById("keyhint");
  if (keyhint) {
    keyhint.addEventListener("click", function () {
      var open = keyhint.getAttribute("aria-expanded") === "true";
      keyhint.setAttribute("aria-expanded", open ? "false" : "true");
    });
    document.addEventListener("click", function (e) {
      if (e.target !== keyhint) keyhint.setAttribute("aria-expanded", "false");
    });
  }

  // -------------------------------------------------- the demos below

  // Each button drives the hero rather than describing it, and scrolls the
  // hero into view first: a control that changes something off-screen looks
  // like a control that did nothing. They start hidden in the markup so the
  // section has no dead buttons in it with scripting off.
  function scrollToStage() {
    var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    stage.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
  }

  var demoActions = {
    toggle: togglePanel,
    tab: function () { showPanel(); addTab(); },
    "close-tab": function () { if (tabs.length) closeTab(active); },
    theme: function () { setTheme((themeIndex + 1) % themes.length); },
    menu: function () { showPanel(); openMenuNearPanel(null); }
  };

  Array.prototype.forEach.call(
    document.querySelectorAll(".demo-btn"),
    function (button) {
      var action = demoActions[button.dataset.demo];
      if (!action) return;
      button.hidden = false;
      button.addEventListener("click", function () {
        scrollToStage();
        action();
      });
    }
  );

  renderTabs();
  renderTerm();
  buildChips();
})();

// ---------------------------------------------------------------------------
// The guide's theme swatches.
//
// A second IIFE rather than part of the hero's, because the hero's returns
// early when there is no #stage — which is every page but index.html. This one
// runs on guide.html, where there is no panel and no shell, and does nothing on
// index.html, where there is no #theme-swatches.
//
// Both pages load the same two files. themes.js is generated by `make site`
// from TerminalTheme.swift, so a palette here cannot drift from the app's, and
// `make check` fails when the checked-in copy is stale.
(function () {
  "use strict";

  var host = document.getElementById("theme-swatches");
  var themes = window.DRIFTWOOD_THEMES;
  if (!host || !themes || !themes.length) return;

  // The five roles a theme carries besides the sixteen ANSI colors, in the
  // order TerminalTheme declares them.
  var ROLES = ["background", "foreground", "cursor", "selection", "tabBarText"];

  // A swatch is a color block plus the role name plus the hex value, and the
  // hex is real text rather than a title attribute: a swatch that conveys its
  // value by color alone conveys nothing to a screen reader, and nothing to
  // anyone who wants to copy the value into their own config.
  function swatch(role, hex) {
    var cell = document.createElement("div");
    cell.className = "swatch";

    // Two elements, not one: the outer tile carries the checkerboard that makes
    // an alpha visible, and the inner one carries the color. A single element
    // cannot do both — an inline `background` would drop the checkerboard, and
    // a background image paints over the background color rather than under it.
    var chip = document.createElement("span");
    chip.className = "swatch-chip";
    var fill = document.createElement("span");
    // The one place on this site that sets a color from theme data outside
    // panel.css. The value comes from themes.js, never from anything typed.
    fill.style.backgroundColor = hex;
    chip.appendChild(fill);
    cell.appendChild(chip);

    var name = document.createElement("span");
    name.className = "swatch-role";
    name.textContent = role;
    cell.appendChild(name);

    var value = document.createElement("code");
    value.className = "swatch-hex";
    value.textContent = hex;
    cell.appendChild(value);

    return cell;
  }

  host.textContent = "";                 // drops the scripting-off fallback

  themes.forEach(function (theme) {
    var block = document.createElement("div");
    block.className = "swatch-block";

    var heading = document.createElement("h3");
    heading.textContent = theme.title;
    var id = document.createElement("code");
    id.textContent = theme.id;
    heading.appendChild(id);
    block.appendChild(heading);

    var grid = document.createElement("div");
    grid.className = "swatch-grid";
    theme.ansi.forEach(function (hex, index) {
      grid.appendChild(swatch("ansi" + index, hex));
    });
    ROLES.forEach(function (role) {
      if (theme[role]) grid.appendChild(swatch(role, theme[role]));
    });
    block.appendChild(grid);

    host.appendChild(block);
  });
})();
