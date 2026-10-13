import AppKit
import Foundation
import Testing
@testable import OmegaJournal
import OmegaJournalCore

@Suite("Improve Settings: layout catalog")
@MainActor
struct ImproveSettingsCatalogTests {
    @Test("every card appears in exactly one pane, in a stable order")
    func everyCardPlacedOnce() {
        let placed = SettingsGroup.allCases.flatMap { SettingsCatalog.cards(in: $0) }
        #expect(placed.count == SettingsCardID.allCases.count)
        #expect(Set(placed).count == placed.count)
        for group in SettingsGroup.allCases {
            #expect(!SettingsCatalog.cards(in: group).isEmpty, "\(group) pane is empty")
        }
    }

    @Test("card headings are unique — no two cards called “Quick Capture”")
    func uniqueTitles() {
        let titles = SettingsCardID.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.filter { $0 == "Quick Capture" }.count == 1)
    }

    @Test("privacy controls live in Privacy, capture controls in Writing")
    func grouping() {
        #expect(SettingsCardID.appLock.group == .privacy)
        #expect(SettingsCardID.hiddenEntries.group == .privacy)
        #expect(SettingsCardID.quickCapture.group == .writing)
        #expect(SettingsCardID.backups.group == .data)
        #expect(!SettingsCatalog.cards(in: .data).contains(.appLock))
        #expect(!SettingsCatalog.cards(in: .appearance).contains(.quickCapture))
        // Backups lead the Data pane; destructive action is last.
        #expect(SettingsCatalog.cards(in: .data).first == .backups)
        #expect(SettingsCatalog.cards(in: .data).last == .dangerZone)
    }

    /// Every persisted preference the Settings window edits must still be
    /// reachable from exactly one card after the regroup (no lost values).
    @Test("every stored preference key maps to exactly one card")
    func storedKeysReachable() {
        let appKeys = [
            ReadingPreferences.fontDesignKey, ReadingPreferences.showCoverKey, ReadingPreferences.maxWidthKey,
            QuickCapture.insertedKey, GlobalHotkey.enabledKey,
            SmartAssist.enabledKey,
            AppLockManager.enabledKey, AppLockManager.timeoutKey,
            ShellPrefs.lockOnResignKey, SpotlightIndexer.enabledKey,
        ]
        for key in appKeys {
            let owners = SettingsCardID.allCases.filter { $0.storageKeys.contains(key) }
            #expect(owners.count == 1, "\(key) is edited by \(owners)")
        }
        let catalogKeys = SettingsCardID.allCases.flatMap(\.storageKeys)
        #expect(Set(catalogKeys) == Set(appKeys), "catalog lists a key the app no longer defines")
        #expect(SettingsCatalog.card(forStorageKey: AppLockManager.enabledKey) == .appLock)
        #expect(SettingsCatalog.card(forStorageKey: QuickCapture.insertedKey) == .quickCapture)
    }

    @Test("each Settings sidebar section maps to its own pane")
    func sectionsMapToGroups() {
        let groups = SettingsSection.allCases.map(\.group)
        #expect(Set(groups).count == SettingsSection.allCases.count)
        #expect(Set(groups) == Set(SettingsGroup.allCases))
        #expect(SettingsSection.privacy.subtitle.localizedCaseInsensitiveContains("app lock"))
    }

    @Test("every card has a symbol and a heading")
    func iconsAndTitles() {
        for card in SettingsCardID.allCases {
            #expect(!card.icon.isEmpty)
            #expect(!card.title.isEmpty)
            #expect(NSImage(systemSymbolName: card.icon, accessibilityDescription: nil) != nil, "\(card.icon)")
        }
    }
}

@Suite("Improve Settings: journal location", .serialized)
@MainActor
struct ImproveSettingsStorageLocationTests {
    @Test("folder under home is shown with ~")
    func tildeAbbreviation() {
        #expect(SettingsStorageLocation.displayFolder(
            forDatabasePath: "/Users/kim/Library/Application Support/OmegaJournal/omega_journal.sqlite3",
            home: "/Users/kim") == "~/Library/Application Support/OmegaJournal")
        #expect(SettingsStorageLocation.displayFolder(forDatabasePath: "/Users/kim/j.sqlite3", home: "/Users/kim/") == "~")
        // A sibling home with a shared prefix must not be abbreviated.
        #expect(SettingsStorageLocation.displayFolder(forDatabasePath: "/Users/kimberly/x/j.sqlite3", home: "/Users/kim")
                == "/Users/kimberly/x")
        #expect(SettingsStorageLocation.displayFolder(forDatabasePath: "/Volumes/Ext/OJ/j.sqlite3", home: "/Users/kim")
                == "/Volumes/Ext/OJ")
    }

    /// The Storage card used to print and reveal the hard-coded default folder
    /// even when the window's journal lives elsewhere (test/QA databases).
    @Test("Storage card describes the database this view model actually uses")
    func followsLiveDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImproveSettings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("journal.sqlite3").path
        let db = DatabaseManager(databasePath: dbPath, attachmentsPath: root.appendingPathComponent("att").path)
        let shown = SettingsStorageLocation.displayFolder(forDatabasePath: db.dbPath)
        #expect(!shown.contains("Application Support/OmegaJournal"))
        #expect(shown.hasSuffix(root.lastPathComponent))
    }
}
