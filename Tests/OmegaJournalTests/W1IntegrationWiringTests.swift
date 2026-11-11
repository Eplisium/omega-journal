import CryptoKit
import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// Wave-1 integration hook-ups: map destination, Add context card, mood faces,
/// strict body decoding, What's new highlights.
@Suite("W1 integration: wiring")
@MainActor
struct W1IntegrationWiringTests {
    @Test("Map is a reflective destination that restores and routes like Calendar")
    func mapDestination() {
        #expect(SidebarItem.map.title == "Map")
        #expect(SidebarItem.map.icon == "map")
        #expect(SidebarItem(storageKey: "map") == .map)
        #expect(SidebarItem.map.workspace == .map)
        #expect(JournalWorkspace.map.isReflective)
        #expect(!JournalWorkspace.map.usesEntryCollection)
    }

    @Test("Add context has its own Writing card that owns the context switches")
    func contextCard() {
        #expect(SettingsCardID.context.group == .writing)
        #expect(SettingsCatalog.cards(in: .writing).contains(.context))
        #expect(SettingsCardID.context.title == "Add Context")
        for key in [ContextSettings.placeKey, ContextSettings.calendarKey, ContextSettings.photosKey, ContextSettings.autoKey] {
            #expect(SettingsCatalog.card(forStorageKey: key) == .context, "\(key)")
        }
    }

    @Test("every mood uses the one face table; Bad is a frown")
    func moodFaces() {
        #expect(Mood.bad.emoji == "🙁")
        for m in Mood.allCases { #expect(m.emoji == m.face) }
        #expect(ReviewGenerator.moodEmoji.dropFirst().elementsEqual(UIMoodGlyph.faces))
    }

    @Test("a body that isn't valid UTF-8 is reported unreadable, not shown with replacement characters")
    func strictUTF8() throws {
        let key = SymmetricKey(size: .bits256)
        let good = try #require(try AES.GCM.seal(Data("Grüße".utf8), using: key).combined)
        #expect(try JournalCrypto.decryptString(good, using: key) == "Grüße")
        let bad = try #require(try AES.GCM.seal(Data([0x66, 0xFF, 0xFE, 0x6F]), using: key).combined)
        #expect(throws: (any Error).self) { try JournalCrypto.decryptString(bad, using: key) }
        #expect(DatabaseManager.openBody(bad, key: key) == nil)
    }

    @Test("What's new names the headline features of this wave")
    func whatsNew() {
        let titles = WhatsNewView.items.map(\.1).joined(separator: " | ")
        #expect(titles.contains("Ask your journal"))
        #expect(titles.contains("Apple Journal"))
        #expect(titles.contains("Map"))
        #expect(WhatsNewView.items.count <= 6)
    }
}
