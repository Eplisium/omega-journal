// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OmegaJournal",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "OmegaJournal",
            path: "Sources/OmegaJournal"
        )
    ]
)
