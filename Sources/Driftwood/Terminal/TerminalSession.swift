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
