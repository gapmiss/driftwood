import AppKit

// `MainActor.assumeIsolated` rather than a bare call, because Driftwood builds
// in Swift 5 language mode (see the comment in Package.swift). Swift 6 makes
// top-level code `@MainActor` implicitly, which is why Chestnut's identical
// `main.swift` needs none of this; in language mode 5 top-level code is
// nonisolated, so constructing a `@MainActor` delegate here is an error rather
// than a warning. The assumption is sound: this file only ever runs on the
// process's main thread, before `NSApplication.run` starts the run loop.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // LSUIElement covers the bundled app; this covers `swift run` on the bare
    // binary.
    app.setActivationPolicy(.accessory)
    // `NSApplication.delegate` is a weak reference, so `delegate` above is the
    // only strong one. It stays in scope because `run()` does not return until
    // the app terminates.
    app.run()
}
