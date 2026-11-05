import Foundation

// MARK: - Launch activation

/// Whether the app should pull itself to the front when it finishes launching.
///
/// `applicationDidFinishLaunching` used to call `NSApp.activate(ignoringOtherApps:)`
/// unconditionally (next to `setActivationPolicy(.regular)`). That is for the raw
/// SwiftPM binary (`swift run`, `.build/out/Products/Debug/OmegaJournal` started
/// from a shell for tests and QA): it is not an app bundle and LaunchServices did
/// not launch it, so nothing else brings its window forward.
///
/// A bundled app that LaunchServices launched (through launchd, pid 1) leaves the
/// decision to the system: Finder, the Dock, `open`, widget taps and intents that
/// open the app activate it anyway, and a background launch must stay in the
/// background. Shortcuts or Siri running "Today's Writing Progress"
/// (`openAppWhenRun = false`) launches the app only to run the intent; forcing
/// activation brought the journal window to the front for a spoken word count.
nonisolated enum LaunchActivation {
    static func shouldForceActivate(bundleURL: URL, parentProcessID: pid_t) -> Bool {
        let isAppBundle = bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        let launchedByLaunchServices = parentProcessID == 1
        return !(isAppBundle && launchedByLaunchServices)
    }

    /// The decision for this process.
    static var shouldForceActivateThisLaunch: Bool {
        shouldForceActivate(bundleURL: Bundle.main.bundleURL, parentProcessID: getppid())
    }
}
