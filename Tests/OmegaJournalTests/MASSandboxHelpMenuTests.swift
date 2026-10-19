import Foundation
import Testing
@testable import OmegaJournal

@Suite("MAS sandbox: Help menu per channel")
struct MASSandboxHelpMenuTests {
    @Test("App Store Help menu: support + privacy, nothing on GitHub")
    func helpMenuAppStore() {
        let items = MASSandboxHelpMenu.items(for: .appStore)
        #expect(items.map(\.title) == ["Omega Journal Support", "Keyboard Shortcuts", "Privacy Policy"])
        #expect(items[0].action == .open(AppLinks.support))
        #expect(items[2].action == .open(AppLinks.privacyPolicy))
        for item in items {
            if case .open(let url) = item.action { #expect(url.host?.contains("github") != true) }
        }
    }

    @Test("direct Help menu keeps GitHub help/issues and adds the privacy policy")
    func helpMenuDirect() {
        let items = MASSandboxHelpMenu.items(for: .direct)
        #expect(items.map(\.title) == ["Omega Journal Help", "Keyboard Shortcuts", "Report an Issue…", "Privacy Policy"])
        #expect(items[0].action == .open(AppLinks.sourceCode))
        #expect(items[1].action == .showShortcuts)
        #expect(items[2].action == .open(AppLinks.issues))
        #expect(items[3].action == .open(AppLinks.privacyPolicy))
        #expect(Set(items.map(\.id)).count == items.count)
    }
}
