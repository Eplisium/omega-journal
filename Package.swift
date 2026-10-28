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
        // Privacy-safe widget snapshot model, deep links and App Group plumbing,
        // shared by the app, the widget extension and the tests. Foundation only.
        .target(
            name: "OmegaJournalShared",
            dependencies: ["OmegaJournalCore"],
            path: "Sources/OmegaJournalShared",
            swiftSettings: approachable
        ),
        // Widget SwiftUI views, kept out of the extension executable so tests can
        // render them (ImageRenderer) without linking an extension entry point.
        .target(
            name: "OmegaJournalWidgetUI",
            dependencies: ["OmegaJournalShared"],
            path: "Sources/OmegaJournalWidgetUI",
            swiftSettings: approachable
        ),
        .executableTarget(
            name: "OmegaJournal",
            dependencies: ["OmegaJournalCore", "OmegaJournalShared"],
            path: "Sources/OmegaJournal",
            swiftSettings: approachable + [.defaultIsolation(MainActor.self)]
        ),
        // WidgetKit extension. The packaging scripts wrap this binary into
        // Contents/PlugIns/OmegaJournalWidgets.appex. Linked like Xcode links
        // app extensions: extension-safe API only, entry point NSExtensionMain.
        .executableTarget(
            name: "OmegaJournalWidgets",
            dependencies: ["OmegaJournalShared", "OmegaJournalWidgetUI"],
            path: "Sources/OmegaJournalWidgets",
            swiftSettings: approachable + [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension",
                                           "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(
            name: "OmegaJournalTests",
            dependencies: ["OmegaJournalCore", "OmegaJournal", "OmegaJournalShared", "OmegaJournalWidgetUI"],
            path: "Tests/OmegaJournalTests",
            // Tests drive the main-actor app types directly.
            swiftSettings: approachable + [.defaultIsolation(MainActor.self)]
        )
    ],
    swiftLanguageModes: [.v6]
)
