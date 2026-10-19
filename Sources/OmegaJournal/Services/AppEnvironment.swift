import Foundation

/// Facts about how this copy of the app was built and is running.
///
/// The same source ships two ways:
/// - **direct**: Developer ID signed + notarized DMG from GitHub Releases (not sandboxed).
/// - **appstore**: Mac App Store build (App Sandbox, Apple Distribution signed).
///
/// The packaging scripts write `OJDistributionChannel` into Info.plist; anything
/// without that key (local `swift build`, tests) counts as `.direct`.
enum AppEnvironment {
    enum Channel: String {
        case direct
        case appStore = "appstore"
    }

    static let productionBundleIdentifier = "com.eplisium.omega-journal"

    static var channel: Channel {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "OJDistributionChannel") as? String,
              let channel = Channel(rawValue: raw) else { return .direct }
        return channel
    }

    static var isAppStore: Bool { channel == .appStore }

    /// True when the App Sandbox is active for this process.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// The user's real home folder. Inside the App Sandbox `NSHomeDirectory()`
    /// returns the container (`~/Library/Containers/<id>/Data`), which is wrong
    /// for anything shown to the user or for locating pre-sandbox data.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Where pre-sandbox (direct / DMG) builds keep the journal.
    static var legacyJournalDirectory: URL {
        realHomeDirectory.appendingPathComponent("Library/Application Support/OmegaJournal", isDirectory: true)
    }

    /// Where the sandboxed App Store build keeps the journal, as seen from outside the sandbox.
    static var containerJournalDirectory: URL {
        realHomeDirectory.appendingPathComponent(
            "Library/Containers/\(productionBundleIdentifier)/Data/Library/Application Support/OmegaJournal",
            isDirectory: true)
    }
}

/// Public web pages the app links to. Hosted by Unknown Projects; the page
/// sources live in `docs/app-store/`.
enum AppLinks {
    static let support = URL(string: "https://unknownprojects.net/omega-journal/support")!
    static let privacyPolicy = URL(string: "https://unknownprojects.net/omega-journal/privacy")!
    /// Source code. Shown only in the direct (GitHub) build; the App Store build
    /// keeps users on the support page instead.
    static let sourceCode = URL(string: "https://github.com/Eplisium/omega-journal")!
    static let issues = URL(string: "https://github.com/Eplisium/omega-journal/issues")!
}
