import AppKit
import SwiftUI

/// The quick-command picker: a filter field over the saved commands, ⏎ fires
/// the highlighted one.
///
/// Ported from Chestnut's `PetPanel`, keeping the parts that were measured
/// there — the one-time sizing, the key monitor, the hover arming and the
/// VoiceOver announcement. Each has a doc comment saying what goes wrong
/// without it.
@MainActor
final class CommandPalette: NSPanel {
    /// Fired with the chosen command's id.
    var onRun: ((String) -> Void)?
    var onClose: (() -> Void)?

    private var isClosing = false
    private var paletteKeyMonitor: Any?
    private var openingAnnouncement: Task<Void, Never>?
    private let model = PaletteModel()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Losing key focus deliberately does not dismiss: a half-typed filter
        // survives a stray click into another app.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    /// Present the palette over `panelFrame`, filled with `commands`.
    func present(commands: [QuickCommand], above panelFrame: NSRect) {
        model.commands = commands
        model.filter = ""
        model.selection = commands.isEmpty ? -1 : 0
        // Running always dismisses, and it is centralised here because there
        // are three ways to fire a command — ⏎ through the key monitor, ⏎
        // through the field's own `onSubmit`, and a click on a row. Two of
        // those used to run the command and leave the palette sitting open
        // over the terminal the command had just been typed into.
        model.onRun = { [weak self] id in
            self?.onRun?(id)
            self?.dismiss()
        }

        host(PaletteView(model: model))
        installKeyMonitor()
        show(above: panelFrame)

        announceOnOpen(
            model.selection >= 0
                ? "Quick commands. \(commands.count) available. \(commands[model.selection].title) selected."
                : "Quick commands. None configured.",
            skipIf: { [weak self] in !(self?.model.filter.isEmpty ?? true) }
        )
    }

    /// Host `view` at its fitting size and pin the panel to that size for
    /// good.
    ///
    /// A filtering palette's content shrinks as the query narrows and
    /// collapses hardest when nothing matches — the list is replaced by one
    /// line of text. An `NSHostingView` left to drive the window pushes that
    /// collapsed measurement into the window's content min/max size, AppKit
    /// clamps the panel down to it, and backspacing grows the *content* back
    /// but never the window: the full list returns into a slot two rows too
    /// short, scrollbar and all. Sizing is a one-time decision here, so
    /// SwiftUI must not keep voting on it.
    ///
    /// **Order matters.** A hosting view with no sizing options stops
    /// reporting a fitting size at all — it answers 0×0, and the panel opens
    /// invisible. Measure while it still will, then take the vote away.
    private func host(_ view: some View) {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        hosting.frame.size = size
        contentView = hosting
        setContentSize(size)
    }

    /// Anchor above the terminal panel, clamped to the screen it is on, and
    /// flipped below when it would run off the top.
    private func show(above panelFrame: NSRect) {
        var origin = NSPoint(x: panelFrame.midX - frame.width / 2, y: panelFrame.maxY + 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(panelFrame) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
            if origin.y + frame.height > visible.maxY {
                origin.y = panelFrame.minY - frame.height - 4
            }
        }
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
    }

    /// ↑/↓ move the selection while the filter field keeps key focus — the
    /// field editor would otherwise use them as caret moves. ⏎ runs the
    /// highlighted command and dismisses, unless a text view is first
    /// responder, where the event passes through so the field's own `onSubmit`
    /// runs it. ⏎ with nothing selected is consumed rather than passed on.
    /// Removed in `close()`.
    ///
    /// **Removes any monitor already installed first.** `present` can be called
    /// on a palette that is still on screen, and a second monitor on the same
    /// instance would leave the first one live and unreachable — the property
    /// holding it gets overwritten, so `close()` can only ever remove the last
    /// one. Every stacked monitor handles the same keystroke again, which turns
    /// one press of ↓ into several rows of movement and makes ⏎ fire a command
    /// other than the highlighted one.
    private func installKeyMonitor() {
        if let paletteKeyMonitor { NSEvent.removeMonitor(paletteKeyMonitor) }
        paletteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                switch event.keyCode {
                case 125:  // ↓
                    self.model.moveSelection(1)
                    return true
                case 126:  // ↑
                    self.model.moveSelection(-1)
                    return true
                case 36, 76:  // ⏎ / keypad enter
                    guard self.model.selectedCommand != nil else { return true }
                    if self.firstResponder is NSTextView { return false }
                    // `runSelected` dismisses through `model.onRun`.
                    self.model.runSelected()
                    return true
                default:
                    return false
                }
            }
            return consumed ? nil : event
        }
    }

    /// Speak the state the palette *opens* in, once VoiceOver has had its say.
    ///
    /// The preselected row governs what ⏎ does, and VoiceOver announces the
    /// *focused* element — focus stays in the filter field by design, so
    /// nothing says which row is armed. Chestnut measured the delay by ear at
    /// 1800ms: posted immediately it truncates, and moving the sentence onto
    /// the field's `.accessibilityLabel` was tried there and is silent,
    /// because focus lands on AppKit's field editor rather than the SwiftUI
    /// element carrying the label. `skipIf` drops the announcement when the
    /// user has already started typing, since they have left the state it
    /// describes.
    private func announceOnOpen(_ message: String, skipIf: @escaping @MainActor () -> Bool) {
        openingAnnouncement = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            guard let self, isVisible, !skipIf() else { return }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    override func close() {
        if let paletteKeyMonitor { NSEvent.removeMonitor(paletteKeyMonitor) }
        paletteKeyMonitor = nil
        openingAnnouncement?.cancel()
        openingAnnouncement = nil
        super.close()
    }

    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        close()
        onClose?()
        isClosing = false
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }
}

/// The palette's state, shared between the key monitor (which moves the
/// selection while focus stays in the text field) and SwiftUI.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var commands: [QuickCommand] = []
    @Published var filter = "" {
        didSet {
            // **The guard is the whole point of this block, not a shortcut.**
            // Swift runs `didSet` on any assignment, including one that writes
            // back an identical value, and SwiftUI's `TextField` is bound to
            // this property: every re-render pushes the field's current text
            // back through the binding. Moving the selection publishes a
            // change, SwiftUI re-renders, the field re-assigns the same string,
            // and without this guard the selection is reset to the first row
            // before the user can act on it. The visible highlight moved and
            // the model did not, so ⏎ ran whichever command was first —
            // silently, and in the case of a `run: true` command that is a
            // different shell command executing than the one on screen.
            guard filter != oldValue else { return }
            // Re-arm the selection on a real keystroke: the row that was
            // highlighted may not be in the filtered list any more, and a
            // stale index would make ⏎ run a command the user cannot see.
            selection = matches.isEmpty ? -1 : 0
        }
    }
    @Published var selection = -1

    var onRun: ((String) -> Void)?

    /// Case-insensitive substring match against the title and the command
    /// text. Both, because a command saved as "Deploy" is found by typing
    /// "deploy" and one whose title you have forgotten is found by typing part
    /// of the command itself.
    var matches: [QuickCommand] {
        guard !filter.isEmpty else { return commands }
        let needle = filter.lowercased()
        return commands.filter {
            $0.title.lowercased().contains(needle) || $0.command.lowercased().contains(needle)
        }
    }

    var selectedCommand: QuickCommand? {
        matches.indices.contains(selection) ? matches[selection] : nil
    }

    func moveSelection(_ offset: Int) {
        let list = matches
        guard !list.isEmpty else { return }
        selection = min(max(selection + offset, 0), list.count - 1)
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: list[selection].title,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    func runSelected() {
        guard let command = selectedCommand else { return }
        onRun?(command.id)
    }
}

private struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Run a command…", text: $model.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(10)
                .focused($filterFocused)
                .onSubmit { model.runSelected() }

            Divider()

            if model.matches.isEmpty {
                Text(model.commands.isEmpty
                     ? QuickCommands.emptyStateMessage
                     : "No match")
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.matches.enumerated()), id: \.element.id) { index, command in
                            row(command, selected: index == model.selection)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(width: 380)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { filterFocused = true }
    }

    private func row(_ command: QuickCommand, selected: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                Text(command.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Says out loud what ⏎ will do. A command that only types itself
            // and one that executes on the spot are the same click away, and
            // the difference is not recoverable after the fact.
            Text(command.runsImmediately ? "runs" : "types")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if let hotkey = command.hotkey, let display = HotkeySpec.display(hotkey) {
                Text(display).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.onRun?(command.id)
        }
    }
}

extension QuickCommand: Identifiable {}
