import Foundation
import Testing
@testable import OmegaJournal

@Suite("Typed settings accessors", .serialized)
@MainActor
struct AppSettingsTests {
    @Test("bool/int round-trip and fall back to defaults when unset")
    func roundTrip() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(db.bool("flag") == false)
        #expect(db.bool("flag", default: true) == true)
        #expect(db.int("n", default: 7) == 7)

        db.setBool("flag", true)
        db.setInt("n", 42)
        #expect(db.bool("flag"))
        #expect(db.int("n", default: 7) == 42)
        #expect(db.getSetting("flag") == "true")

        db.setBool("flag", false, asDigit: true)
        #expect(db.getSetting("flag") == "0")
        #expect(db.bool("flag", default: true) == false)
    }

    @Test("legacy \"1\" and \"true\" spellings both read as true")
    func legacySpellings() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        db.setSetting("a", value: "1"); db.setSetting("b", value: "true"); db.setSetting("c", value: "0")
        #expect(db.bool("a")); #expect(db.bool("b")); #expect(!db.bool("c"))
    }

    @Test("injected GoalManager and NotificationManager read from the given database")
    func injectedManagers() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        db.setBool(SettingKey.reminderEnabled, true)
        db.setInt(SettingKey.reminderHour, 9)
        let n = NotificationManager(db: db)
        #expect(n.reminderEnabled)
        #expect(n.reminderHour == 9)
    }
}
