// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode everywhere (full data-race checking).
//
// The app target uses "approachable concurrency": code is main-actor isolated
// unless it says otherwise (`nonisolated`, `@concurrent`, `Task.detached`).
// That matches how a SwiftUI app actually runs: views, view models and the
// SQLite connection all live on the main thread. Core stays nonisolated
// because it is pure logic that tests and background work call directly.
let approachable: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "OmegaJournal",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Core logic lives in a library so the test target can import it;
        // the executable is a thin shell around it.
        .target(
            name: "OmegaJournalCore",
            path: "Sources/OmegaJournalCore",
            swiftSettings: approachable
        ),
        .executableTarget(
            name: "OmegaJournal",
            dependencies: ["OmegaJournalCore"],
            path: "Sources/OmegaJournal",
            swiftSettings: approachable + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "OmegaJournalTests",
            dependencies: ["OmegaJournalCore", "OmegaJournal"],
            path: "Tests/OmegaJournalTests",
            // Tests drive the main-actor app types directly.
            swiftSettings: approachable + [.defaultIsolation(MainActor.self)]
        )
    ],
    swiftLanguageModes: [.v6]
)
