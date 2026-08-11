import Foundation

/// Timestamp for the debug log. A value-type format style rather than a shared
/// `ISO8601DateFormatter`: `Date.ISO8601FormatStyle` is `Sendable` with no
/// shared state, so it needs no `nonisolated(unsafe)` promise of
/// thread-safety — one Foundation documents for `NSDateFormatter` but *not*
/// for `ISO8601DateFormatter`.
func iso8601Timestamp(_ date: Date = Date()) -> String {
    date.formatted(.iso8601)
}

/// Opt-in file log, off unless `config.debug` is true.
///
/// Driftwood has no window to print diagnostics into — the terminal panel
/// belongs to the user's shell, and feeding app messages there would put them
/// in the same stream as command output and shell history. `NSLog` reaches
/// Console.app but is awkward to read back for an `LSUIElement` app. This is
/// the third option: a file the user can `tail`.
@MainActor
enum DebugLog {
    private(set) static var enabled = false
    private static var handle: FileHandle?

    static func configure(enabled flag: Bool) {
        enabled = flag
        guard flag else { return }

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Driftwood")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let logURL = dir.appendingPathComponent("driftwood.log")
        let prevURL = dir.appendingPathComponent("driftwood.log.1")
        let fm = FileManager.default

        if fm.fileExists(atPath: logURL.path),
           let attrs = try? fm.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64, size > 1_048_576 {
            try? fm.removeItem(at: prevURL)
            try? fm.moveItem(at: logURL, to: prevURL)
        }

        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: logURL)
        handle?.seekToEndOfFile()

        fputs("driftwood: debug log at \(logURL.path)\n", stderr)
        log("--- session start ---")
    }

    static func log(_ message: String) {
        guard enabled, let handle else { return }
        handle.write(Data("\(iso8601Timestamp()) \(message)\n".utf8))
    }
}
