// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Driftwood",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Driftwood",
            dependencies: ["SwiftTerm"],
            path: "Sources/Driftwood",
            // Driftwood is the one repo of this family not built in Swift 6
            // language mode. SwiftTerm 1.15 predates `Sendable` annotation:
            // `TerminalView`, `LocalProcessTerminalView` and
            // `LocalProcessTerminalViewDelegate` carry no global-actor
            // isolation, so conforming a `@MainActor` type to that delegate is
            // an actor-isolation error under Swift 6 checking rather than a
            // warning. `@preconcurrency import SwiftTerm` was tried first and
            // does not cover it — it silences Sendable diagnostics, not the
            // isolation mismatch on a protocol witness. Language mode 5 keeps
            // those as warnings. Revisit when SwiftTerm annotates its AppKit
            // views; the rest of the codebase is written as if Swift 6 mode
            // were on (every UI type is `@MainActor`), so the switch should be
            // a one-line change here.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
