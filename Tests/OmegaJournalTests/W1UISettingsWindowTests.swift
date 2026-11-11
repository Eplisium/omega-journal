import Foundation
import Testing
@testable import OmegaJournal
import OmegaJournalCore

@Suite("W1UI: native Settings window")
@MainActor
struct W1UISettingsWindowTests {
    @Test("Text size lives in Appearance; writing suggestions in Writing")
    func placement() {
        #expect(SettingsCardID.textSize.group == .appearance)
        #expect(SettingsCatalog.cards(in: .appearance).contains(.textSize))
        #expect(SettingsCardID.aiAssist.group == .writing)
        #expect(SettingsCardID.aiAssist.title == "Writing Suggestions")
        // Key and API unchanged.
        #expect(SettingsCardID.aiAssist.storageKeys == [SmartAssist.enabledKey])
    }

    @Test("writing suggestions copy")
    func copy() {
        #expect(AIAssistPanel.rowTitle == "Writing suggestions")
        #expect(AIAssistPanel.rowSubtitle
                == "Suggest titles, tags and follow-up questions with Apple Intelligence. Runs on this Mac.")
    }

    @Test("Settings is a tabbed pane view, not a sized sheet")
    func tabbed() throws {
        let (vm, _) = try BrowseSupport.makeVM()
        let typeName = String(describing: type(of: SettingsView(vm: vm).body))
        #expect(typeName.contains("TabView"))
        #expect(typeName.contains("WindowToastHost"))
    }

    @Test("panes have short, unique toolbar titles")
    func tabTitles() {
        let titles = SettingsSection.allCases.map(\.tabTitle)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { $0.count <= 12 })
    }

    @Test("navigation state picks the pane")
    func navigation() throws {
        let (vm, _) = try BrowseSupport.makeVM()
        let view = SettingsView(vm: vm, initialSection: .about)
        #expect(view.navigation.section == .about)
        #expect(view.navigation !== SettingsNavigation.shared)
        #expect(SettingsView(vm: vm).navigation === SettingsNavigation.shared)
    }

    @Test("the Settings window edits the most recently shown journal window")
    func host() throws {
        let host = SettingsHost()
        #expect(host.activeModel == nil)
        let (a, _) = try BrowseSupport.makeVM()
        let (b, _) = try BrowseSupport.makeVM()
        host.register(a)
        host.register(b)
        #expect(host.activeModel === b)
        host.register(a)
        #expect(host.activeModel === a)
        host.unregister(a)
        #expect(host.activeModel === b)
        host.unregister(b)
        #expect(host.activeModel == nil)
    }
}
