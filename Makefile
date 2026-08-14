APP     := Driftwood
VERSION := 0.4.0
CONFIG  ?= debug
BUILD   := .build
BUNDLE  := $(BUILD)/$(APP).app
DMG     := $(BUILD)/$(APP).dmg

.PHONY: build bundle run check clean dmg icon favicons site site-gen release-check

# The website's theme data, generated from the app's own palettes.
SITE_GEN := $(BUILD)/make-site-themes

# Runtime checks in lieu of a test target (Command Line Tools ship no
# XCTest — see CONTRIBUTING.md). Compiles the check harness against the
# pure sources it exercises and runs it. Only AppKit-free, SwiftTerm-free
# files can appear here; anything that touches the panel or the terminal
# view is out of reach and gets a manual smoke test instead.
check: site-gen
	mkdir -p $(BUILD)
	swiftc -parse-as-library -o $(BUILD)/driftwood-check Checks/main.swift \
		Sources/$(APP)/Terminal/TerminalTheme.swift \
		Sources/$(APP)/Terminal/TerminalMetrics.swift \
		Sources/$(APP)/Support/Config.swift \
		Sources/$(APP)/Support/AppState.swift \
		Sources/$(APP)/Support/PanelGeometry.swift \
		Sources/$(APP)/Support/QuickCommands.swift \
		Sources/$(APP)/Support/Hotkeys.swift \
		Sources/$(APP)/Support/DebugLog.swift
	$(BUILD)/driftwood-check
	@# docs/themes.js is generated from TerminalTheme.swift and checked in, so
	@# the site's palettes cannot be edited into disagreeing with the app's.
	@# Regenerate to a scratch path and diff rather than trusting the file.
	@$(SITE_GEN) $(BUILD)/themes-drift.js $(VERSION) >/dev/null
	@diff -u docs/themes.js $(BUILD)/themes-drift.js \
		|| { echo "docs/themes.js is stale — run 'make site'"; exit 1; }
	@# Both pages print the version in their footer. Nothing generates that
	@# line — the site is hand-written — so a bump that misses one page ships a
	@# download button next to a stale version number.
	@for page in docs/index.html docs/guide.html; do \
		grep -q ">$(VERSION)</a>" $$page \
			|| { echo "$$page's footer names a release other than $(VERSION) — it states the version by hand"; exit 1; }; \
	done
	@# Every local file the two pages name must exist. A missing stylesheet or
	@# script is loud, but a missing og-image.png is silent: the page renders,
	@# and only a link unfurler somewhere else shows the gap. Absolute URLs,
	@# fragments and directory links are somebody else's problem and are
	@# skipped; a bare filename with an extension is ours.
	@missing=$$(grep -oE '(href|src|content)="[A-Za-z0-9._-]+\.[A-Za-z0-9]+(#[A-Za-z0-9_-]+)?"' \
		docs/index.html docs/guide.html \
		| sed -E 's/^[^:]*:[a-z]+="//; s/"$$//; s/#.*$$//' \
		| sort -u \
		| while read -r ref; do test -f "docs/$$ref" || echo "  $$ref"; done); \
	test -z "$$missing" || { \
		echo "docs/index.html or docs/guide.html names local files that are not there:"; \
		echo "$$missing"; \
		exit 1; }
	@test "$$(plutil -extract CFBundleShortVersionString raw \
		Resources/Info.plist)" = "$(VERSION)" \
		|| { echo "Resources/Info.plist stamps $$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist), not $(VERSION) — its own comment promises they stay in step"; exit 1; }
	@grep -q "in the Makefile ($(VERSION))" CLAUDE.md \
		|| { echo "CLAUDE.md's intro names a release other than $(VERSION) — it restates VERSION by hand, so it drifts on every bump unless this catches it"; exit 1; }
	@# The SwiftTerm pin is a fact two doc comments depend on:
	@# `TerminalMetrics.estimatedCellHeight` mirrors a calculation private to
	@# that version, and `TerminalTheme.swiftTermPaletteSize` states what
	@# `installColors` requires. A silent bump past this line is exactly the
	@# change that would invalidate them, so the version is asserted here
	@# rather than trusted.
	@grep -q '"version" : "$(SWIFTTERM_VERSION)"' Package.resolved \
		|| { echo "Package.resolved no longer pins SwiftTerm $(SWIFTTERM_VERSION) — recheck TerminalMetrics.estimatedCellHeight against SwiftTerm's own cell metrics before moving this line"; exit 1; }
	@# CLAUDE.md's tripwire index cites a symbol per entry instead of restating
	@# the rationale, which lives in the doc comment on that symbol. A rename
	@# or deletion would leave the pointer dangling and silently cost the
	@# account it points at, so every one must still resolve.
	@# `exit 1` inside the loop would only leave the pipeline's subshell, so
	@# collect the dangling pointers and let the recipe's own shell fail on them.
	@dangling=$$(grep -o 'Sources/Driftwood/[A-Za-z/]*\.swift:[A-Za-z_][A-Za-z0-9_]*' CLAUDE.md \
		| sort -u \
		| while IFS=: read -r file symbol; do \
			test -f "$$file" || { echo "  $$file:$$symbol (no such file)"; continue; }; \
			grep -qw "$$symbol" "$$file" || echo "  $$file:$$symbol (symbol gone)"; \
		done); \
	test -z "$$dangling" || { \
		echo "CLAUDE.md's tripwire index has pointers that no longer resolve:"; \
		echo "$$dangling"; \
		echo "Each stands in for a rationale that lives in that symbol's doc comment — repoint it or restore the symbol."; \
		exit 1; }

# The SwiftTerm release Driftwood is written against. Asserted by `check`
# against Package.resolved; see the comment there for why it is pinned in
# two places rather than one.
SWIFTTERM_VERSION := 1.15.0

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/$(CONFIG)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" \
		$(BUNDLE)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(shell git rev-list --count HEAD 2>/dev/null || echo 1)" \
		$(BUNDLE)/Contents/Info.plist
	@test -f Resources/AppIcon.icns && \
		cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns || true
	codesign --force --sign - $(BUNDLE)

run: bundle
	open $(BUNDLE)

dmg: CONFIG := release
dmg: bundle
	rm -f $(DMG)
	mkdir -p $(BUILD)/dmg-stage
	cp -R $(BUNDLE) $(BUILD)/dmg-stage/
	ln -sf /Applications $(BUILD)/dmg-stage/Applications
	hdiutil create -volname $(APP) -srcfolder $(BUILD)/dmg-stage \
		-ov -format UDZO $(DMG)
	rm -rf $(BUILD)/dmg-stage

# Compiles the theme exporter, shared by `site` and the staleness check in
# `check`. It links against the app's real TerminalTheme, which is possible
# only because that type is Foundation-only.
site-gen:
	mkdir -p $(BUILD)
	@# Config.swift comes along for `CustomTerminalTheme`, which
	@# TerminalTheme.register(_:) takes as its input type. DebugLog is what
	@# Config logs a rejected theme through. Both are Foundation-only, like
	@# TerminalTheme itself.
	swiftc -parse-as-library -o $(SITE_GEN) Tools/make-site-themes.swift \
		Sources/$(APP)/Terminal/TerminalTheme.swift \
		Sources/$(APP)/Support/Config.swift \
		Sources/$(APP)/Support/QuickCommands.swift \
		Sources/$(APP)/Support/Hotkeys.swift \
		Sources/$(APP)/Support/DebugLog.swift

# Regenerates the website's theme data. Like `icon`, deliberately not a
# dependency of `bundle`: it rewrites a tracked file, which should never be a
# side effect of building the app.
site: site-gen
	$(SITE_GEN) docs/themes.js $(VERSION)

# Regenerates Resources/AppIcon.icns from Tools/make-icon.swift. Not a
# dependency of `bundle`: the .icns is checked in, and rebuilding it on every
# bundle would rewrite a tracked binary as a side effect of building.
icon:
	rm -rf $(BUILD)/$(APP).iconset
	swift Tools/make-icon.swift $(BUILD)/$(APP).iconset
	iconutil -c icns $(BUILD)/$(APP).iconset -o Resources/AppIcon.icns
	rm -rf $(BUILD)/$(APP).iconset
	@echo "wrote Resources/AppIcon.icns"

# Regenerates the site's two raster icons from the same script that draws the
# app icon, so the tab icon and the Dock icon cannot drift apart. `sips` is
# only ever downscaling that script's own 512pt render. docs/favicon.svg is
# hand-written from the same coordinates and is not touched here — it says so
# in its own comment. Not a dependency of anything, for the reason `icon`
# gives.
favicons:
	rm -rf $(BUILD)/favicon.iconset
	swift Tools/make-icon.swift $(BUILD)/favicon.iconset
	cp $(BUILD)/favicon.iconset/icon_32x32.png docs/favicon.png
	sips -z 180 180 $(BUILD)/favicon.iconset/icon_512x512.png \
		--out docs/apple-touch-icon.png > /dev/null
	rm -rf $(BUILD)/favicon.iconset
	@echo "wrote docs/favicon.png docs/apple-touch-icon.png"

clean:
	swift package clean
	rm -rf $(BUNDLE) $(DMG)

# Release preflight: everything verifiable before the smoke test and the
# public steps. Cheap guards first, then checks, then the release DMG.
# Prints the sha256 a Homebrew cask would need.
release-check:
	@git diff --quiet && git diff --cached --quiet \
		|| { echo "FAIL: working tree not clean"; exit 1; }
	@test "$$(git branch --show-current)" = "main" \
		|| { echo "FAIL: not on main"; exit 1; }
	@! git rev-parse -q --verify "v$(VERSION)" >/dev/null \
		|| { echo "FAIL: v$(VERSION) already tagged"; exit 1; }
	@grep -q "^## \[$(VERSION)\] — 20" CHANGELOG.md \
		|| { echo "FAIL: CHANGELOG.md has no dated [$(VERSION)] section"; exit 1; }
	$(MAKE) check
	$(MAKE) dmg
	@test "$$(plutil -extract CFBundleShortVersionString raw \
		$(BUNDLE)/Contents/Info.plist)" = "$(VERSION)" \
		|| { echo "FAIL: bundle stamps $$(plutil -extract CFBundleShortVersionString raw $(BUNDLE)/Contents/Info.plist), not $(VERSION)"; exit 1; }
	@echo "sha256 for a Homebrew cask:"
	@shasum -a 256 $(DMG)
	@echo "OK — smoke test the app, then tag."
