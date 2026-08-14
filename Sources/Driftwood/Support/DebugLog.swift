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

        // **`O_APPEND`, not `FileHandle(forWritingTo:)` and
        // `seekToEndOfFile()`.** Those give a handle with its own file offset,
        // fixed at whatever the end was when it opened, so two Driftwood
        // processes logging to one file write on top of each other: the second
        // writer lands at an offset the first has already moved past, and the
        // earlier line is overwritten mid-file rather than appended after. That
        // is not hypothetical — a duplicate launch's own log line was lost this
        // way, which is how it was found. `O_APPEND` moves the offset to the
        // real end of the file inside each `write(2)`, so concurrent writers
        // interleave whole lines instead of clobbering.
        //
        // `O_CREAT` also replaces the explicit `createFile` this used to do.
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        handle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil

        fputs("driftwood: debug log at \(logURL.path)\n", stderr)
        log("--- session start ---")
    }

    static func log(_ message: String) {
        guard enabled, let handle else { return }
        handle.write(Data("\(iso8601Timestamp()) \(message)\n".utf8))
    }
}
