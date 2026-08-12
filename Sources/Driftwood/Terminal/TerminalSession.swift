import AppKit
import SwiftTerm

/// One shell: a `LocalProcessTerminalView` and the process running inside it.
///
/// Exposes closures rather than a delegate protocol of its own, matching
/// Chestnut's window types — the owner is always `AppDelegate`, and a protocol
/// with one conformer is indirection without a second implementation to
/// justify it.
@MainActor
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let view: LocalProcessTerminalView

    /// The title the shell last reported via the OSC 0/2 escape sequence, or
    /// nil if it has reported none.
    private(set) var reportedTitle: String?
    /// The working directory the shell last reported via OSC 7, or nil.
    ///
    /// Nil is the common case, not the error case: OSC 7 is emitted by the
    /// shell's prompt hook, and a stock zsh with no framework never sends it.
    /// Everything that reads this needs a fallback for that reason.
    private(set) var reportedDirectory: String?
    private(set) var hasExited = false

    var onTitleChange: (() -> Void)?
    var onExit: (() -> Void)?

    /// What the tab strip shows: the shell's reported title, else the working
    /// directory's last path component, else the shell's own name.
    var title: String {
        if let reportedTitle, !reportedTitle.isEmpty { return reportedTitle }
        if let reportedDirectory, !reportedDirectory.isEmpty {
            return (reportedDirectory as NSString).lastPathComponent
        }
        return shellName
    }

    private let shellName: String

    init(frame: NSRect, shell: String) {
        view = LocalProcessTerminalView(frame: frame)
        shellName = (shell as NSString).lastPathComponent
        super.init()
        view.processDelegate = self
        // The panel's blur and tint are what the user sees behind the text;
        // an opaque terminal background would cover both.
        view.nativeBackgroundColor = .clear
        view.layer?.backgroundColor = NSColor.clear.cgColor
        // Unlike Starboard, which recomputed the terminal's frame by hand on
        // every Dock tick, the view resizes with the panel and SwiftTerm
        // recomputes its own rows and columns — including the `TIOCSWINSZ`
        // ioctl and the `SIGWINCH` that tells a running `vim` or `htop` to
        // reflow. `TerminalMetrics.contentFrame` still centers the leftover
        // sub-row slack; that is layout, not sizing.
        view.autoresizingMask = [.width, .height]
        hideScroller()
    }

    /// Hide the `NSScroller` SwiftTerm pins along the terminal's right edge.
    ///
    /// It is not a scroll indicator in this panel — it is a grey stripe. With
    /// an empty terminal SwiftTerm leaves the scroller *disabled*
    /// (`setupScroller` sets `isEnabled = false`), and a disabled scroller in
    /// the legacy style draws its full-height track with no knob. With
    /// scrollback to move through it draws nothing at all, not even while you
    /// scroll. So it is visible exactly when there is nothing to scroll.
    ///
    /// This became visible in 0.2.0 and was not a SwiftTerm change. Until then
    /// the terminal was a subview of the panel's `NSVisualEffectView`, whose
    /// vibrancy blended the track into the blur behind it. Clipping the
    /// effect view's own edge stroke (see `AppDelegate.buildPanel`) moved the
    /// terminal out to a plain view, where the track draws at full contrast.
    ///
    /// Reaching into another view's subviews is not how this should be done,
    /// and there is no alternative: `scroller` is private and SwiftTerm's only
    /// public control is `scrollerStyle`, which chooses *which* scroller to
    /// draw, never none. Nothing in SwiftTerm sets `isHidden` back to false, so
    /// hiding it once at construction holds for the session's life. Scrolling
    /// itself is untouched — wheel, trackpad and ⇧⌘Page keys all still work.
    private func hideScroller() {
        for case let scroller as NSScroller in view.subviews {
            scroller.isHidden = true
        }
    }

    /// Launch the login shell. A persistent process, not one per command, so
    /// `cd` and shell variables survive between commands the way they do in a
    /// normal terminal tab.
    func start(
        shell: String, arguments: [String], environment: [String], directory: String
    ) {
        view.startProcess(
            executable: shell,
            args: arguments,
            environment: environment,
            currentDirectory: directory
        )
    }

    /// Type text into the shell, as if it had been typed at the keyboard.
    func send(text: String) {
        view.send(txt: text)
    }

    /// Call `body` once the shell has drawn something, or after `timeout`.
    ///
    /// **Typing into a shell that has not started yet echoes twice.** The
    /// pseudo-terminal opens in canonical mode with echo on, so characters
    /// written before the shell takes over the line discipline are echoed by
    /// the tty at the top of the screen; the shell then reads the same line and
    /// draws it again at its prompt. Both the stray line and the real one are
    /// visible, one above the other, and with `run: true` the command runs
    /// once — the input is never lost, it is only shown twice. That is what a
    /// quick command with `newTab` did before this existed.
    ///
    /// Readiness is the cursor having moved off (0, 0), which any prompt does.
    /// SwiftTerm publishes no "process started" or "data received" callback to
    /// wait on — `LocalProcessTerminalViewDelegate` carries four methods and
    /// none of them is about output — so this polls the terminal's own cursor
    /// position, which is public. `pollInterval` is short enough to be
    /// invisible next to a shell start.
    ///
    /// The timeout matters as much as the wait: a login shell sourcing a slow
    /// profile must not swallow the command, so after `timeout` the text is
    /// sent regardless and the worst case is the double echo above. A session
    /// whose shell exited while we waited gets nothing.
    func whenReady(
        timeout: TimeInterval = 2.0, pollInterval: TimeInterval = 0.02,
        _ body: @escaping () -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        // A `Task` on the main actor rather than a `DispatchQueue.asyncAfter`
        // that re-schedules itself: the recursive version has to hand a local
        // function to another actor's queue, which is a `Sendable` warning this
        // repo cannot afford — a clean build emits exactly one warning and it
        // is a different one (see `Package.swift`).
        Task { @MainActor [weak self] in
            while true {
                // Held weakly: a tab closed while its command waited takes the
                // session with it, and there is nothing left to type into.
                guard let self, !hasExited else { return }
                let cursor = view.getTerminal().getCursorLocation()
                if cursor.x != 0 || cursor.y != 0 { break }
                guard Date() < deadline else {
                    DebugLog.log(
                        "session \(id.uuidString.prefix(8)): "
                        + "no output after \(timeout)s, sending anyway"
                    )
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
            body()
        }
    }

    /// The working directory a new tab should inherit from this one: the
    /// reported directory when there is one, else the caller's fallback.
    func inheritableDirectory(fallback: String) -> String {
        guard let reportedDirectory, !reportedDirectory.isEmpty else { return fallback }
        return reportedDirectory
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        DebugLog.log("session \(id.uuidString.prefix(8)): resized to \(newCols)x\(newRows)")
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        reportedTitle = title
        onTitleChange?()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Arrives as a file URL when the shell follows the OSC 7 convention
        // (`file://host/path`), and as a bare path when it doesn't. Both are
        // accepted; the URL form is unwrapped so the tab title is a directory
        // name rather than a hostname.
        if let directory, let url = URL(string: directory), url.scheme == "file" {
            reportedDirectory = url.path
        } else {
            reportedDirectory = directory
        }
        onTitleChange?()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        hasExited = true
        DebugLog.log("session \(id.uuidString.prefix(8)): exited (\(exitCode.map(String.init) ?? "no code"))")
        onExit?()
    }
}
