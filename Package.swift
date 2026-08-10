// swift-tools-version: 5.9
import PackageDescription

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
            path: "Sources/OmegaJournalCore"
        ),
        .executableTarget(
            name: "OmegaJournal",
            dependencies: ["OmegaJournalCore"],
            path: "Sources/OmegaJournal"
        ),
        .testTarget(
            name: "OmegaJournalTests",
            dependencies: ["OmegaJournalCore"],
            path: "Tests/OmegaJournalTests"
        )
    ]
)
