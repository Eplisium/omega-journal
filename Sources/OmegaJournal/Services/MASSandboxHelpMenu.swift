import Foundation

/// Items of the Help menu, per distribution channel.
///
/// The App Store build must not send people to GitHub (the repo advertises the free
/// DMG), so it links to the support page instead. Both builds link the privacy
/// policy, which App Review (guideline 5.1.1) wants reachable from inside the app.
enum MASSandboxHelpMenu {
    enum Action: Equatable {
        case open(URL)
        case showShortcuts
    }

    struct Item: Equatable, Identifiable {
        let title: String
        let action: Action
        var id: String { title }
    }

    static func items(for channel: AppEnvironment.Channel) -> [Item] {
        let shortcuts = Item(title: "Keyboard Shortcuts", action: .showShortcuts)
        let privacy = Item(title: "Privacy Policy", action: .open(AppLinks.privacyPolicy))
        switch channel {
        case .appStore:
            return [
                Item(title: "Omega Journal Support", action: .open(AppLinks.support)),
                shortcuts,
                privacy,
            ]
        case .direct:
            return [
                Item(title: "Omega Journal Help", action: .open(AppLinks.sourceCode)),
                shortcuts,
                Item(title: "Report an Issue…", action: .open(AppLinks.issues)),
                privacy,
            ]
        }
    }
}
