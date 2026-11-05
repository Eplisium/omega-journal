import Foundation
import Testing
import SQLite3
import CryptoKit
import Security
import OmegaJournalCore
@testable import OmegaJournal

// Data-track audit fixes (DATA-1…7, browse-3). Every test uses a private
// DatabaseManager in a UUID temp dir and in-memory fake key stores; the real
// journal and the real Keychain are never touched.

enum AuditFixDataEnv {
    static func tempDB(_ label: String) -> (root: URL, path: String, db: DatabaseManager) {
        MASDataTestEnv.ensureIsolated()
        let root = MASDataTestEnv.tempDir("auditfix-data-\(label)")
        let path = root.appendingPathComponent("omega_journal.sqlite3").path
        let db = DatabaseManager(databasePath: path, attachmentsPath: root.appendingPathComponent("attachments").path)
        return (root, path, db)
    }

    static func reopen(_ root: URL) -> DatabaseManager {
        DatabaseManager(databasePath: root.appendingPathComponent("omega_journal.sqlite3").path,
                        attachmentsPath: root.appendingPathComponent("attachments").path)
    }

    static func fileContains(_ path: String, _ token: String) throws -> Bool {
        var found = false
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: path + suffix) {
            let raw = try Data(contentsOf: URL(fileURLWithPath: path + suffix))
            if raw.range(of: Data(token.utf8)) != nil { found = true }
        }
        return found
    }

    static func words(_ n: Int, _ word: String = "word") -> String {
        Array(repeating: word, count: n).joined(separator: " ")
    }
}

// MARK: - DATA-2 / browse-3

@Suite("Audit fix data: writing goals mask hidden and future entries (DATA-2, browse-3)", .serialized)
@MainActor
struct AuditFixDataGoalTests {
    init() { MASDataTestEnv.ensureIsolated() }

    @Test("writing goals do not count locked hidden entries' words")
    func goalsExcludeLockedHidden() throws {
        let (root, _, db) = AuditFixDataEnv.tempDB("goals-hidden")
        defer { try? FileManager.default.removeItem(at: root) }
        // The shared session is read by the editor goal ring's default
        // arguments; restore whatever a parallel suite had (this test never
        // suspends, so nobody observes the intermediate states).
        let sharedWasUnlocked = BiometricAuth.shared.isAuthenticated
        defer { BiometricAuth.shared.setAuthenticatedForTesting(sharedWasUnlocked) }
        BiometricAuth.shared.setAuthenticatedForTesting(false)
        let auth = BiometricAuth(forTesting: (), db: db)
        var e = JournalEntry.new()
        e.title = "Secret"
        e.body = AuditFixDataEnv.words(400, "secretword")
        e.isHidden = true
        #expect(db.saveEntry(e))
        var visible = JournalEntry.new()
        visible.body = AuditFixDataEnv.words(7)
        #expect(db.saveEntry(visible))
        let goals = GoalManager(db: db, auth: auth)
        #expect(goals.goals.first { $0.type == .dailyWords }?.current == 7)
        #expect(goals.goals.first { $0.type == .weeklyWords }?.current == 7)
        #expect(goals.goals.first { $0.type == .dailyEntries }?.current == 1)
        #expect(goals.goals.first { $0.type == .weeklyEntries }?.current == 1)
        // The editor goal ring's call (default arguments) is session-aware too.
        #expect(db.wordCountSum(since: Calendar.current.startOfDay(for: Date())) == 7)
        BiometricAuth.shared.setAuthenticatedForTesting(true)
        #expect(db.wordCountSum(since: Calendar.current.startOfDay(for: Date())) == 407)
        auth.setAuthenticatedForTesting(true)
        #expect(GoalManager(db: db, auth: auth).goals.first { $0.type == .dailyWords }?.current == 407)
    }

    @Test("an entry dated in the future never counts toward today's or this week's goals")
    func goalsExcludeFutureDated() throws {
        let (root, _, db) = AuditFixDataEnv.tempDB("goals-future")
        defer { try? FileManager.default.removeItem(at: root) }
        var future = JournalEntry.new()
        future.title = "Next week plan"
        future.body = AuditFixDataEnv.words(200, "plan")
        future.createdAt = Calendar.current.date(byAdding: .day, value: 5, to: Date())!
        #expect(db.saveEntry(future))
        var tomorrow = JournalEntry.new()
        tomorrow.body = AuditFixDataEnv.words(30)
        tomorrow.createdAt = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        #expect(db.saveEntry(tomorrow))
        let goals = GoalManager(db: db, auth: BiometricAuth(forTesting: (), db: db))
        #expect(goals.goals.first { $0.type == .dailyWords }?.current == 0)
        #expect(goals.goals.first { $0.type == .weeklyWords }?.current == 0)
        #expect(goals.goals.first { $0.type == .dailyEntries }?.current == 0)
        #expect(goals.goals.first { $0.type == .weeklyEntries }?.current == 0)
        #expect(db.wordCountSum(since: Calendar.current.startOfDay(for: Date()), includeHidden: false) == 0)
        #expect(db.entryCount(since: Calendar.current.startOfDay(for: Date()), includeHidden: false) == 0)
    }

    /// Spins the main run loop until `condition` or the timeout.
    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test("goals reload when the hidden-entry session locks or unlocks")
    func goalsReloadOnSessionChange() async throws {
        let (root, _, db) = AuditFixDataEnv.tempDB("goals-session")
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = BiometricAuth(forTesting: (), db: db)
        var hidden = JournalEntry.new()
        hidden.body = AuditFixDataEnv.words(50)
        hidden.isHidden = true
        #expect(db.saveEntry(hidden))
        let goals = GoalManager(db: db, auth: auth)
        func daily() -> Int? { goals.goals.first { $0.type == .dailyWords }?.current }
        #expect(daily() == 0)
        auth.setAuthenticatedForTesting(true)
        await Self.waitUntil { daily() == 50 }
        #expect(daily() == 50, "unlocking should bring hidden words back")
        auth.lock()
        await Self.waitUntil { daily() == 0 }
        #expect(daily() == 0, "locking must drop hidden words from the visible goal")
    }

    @Test("goals reload when the calendar day changes")
    func goalsReloadOnDayChange() async throws {
        let (root, _, db) = AuditFixDataEnv.tempDB("goals-day")
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = BiometricAuth(forTesting: (), db: db)
        let goals = GoalManager(db: db, auth: auth)
        #expect(goals.goals.first { $0.type == .dailyWords }?.current == 0)
        // Written behind GoalManager's back (as the day rolls over, yesterday's
        // number must be replaced without any save notification).
        var e = JournalEntry.new()
        e.body = AuditFixDataEnv.words(12)
        #expect(db.saveEntry(e))
        #expect(goals.goals.first { $0.type == .dailyWords }?.current == 0)
        // Posted off the main thread, like the system does.
        await Task.detached { NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil) }.value
        await Self.waitUntil { goals.goals.first { $0.type == .dailyWords }?.current == 12 }
        #expect(goals.goals.first { $0.type == .dailyWords }?.current == 12)
    }

    @Test("explicit goal windows: an until bound and includeHidden override the defaults")
    func explicitWindowParameters() throws {
        let (root, _, db) = AuditFixDataEnv.tempDB("goals-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let today = Calendar.current.startOfDay(for: Date())
        var hidden = JournalEntry.new()
        hidden.body = AuditFixDataEnv.words(5)
        hidden.isHidden = true
        #expect(db.saveEntry(hidden))
        var later = JournalEntry.new()
        later.body = AuditFixDataEnv.words(9)
        later.createdAt = Calendar.current.date(byAdding: .day, value: 3, to: today)!
        #expect(db.saveEntry(later))
        let farEnd = Calendar.current.date(byAdding: .day, value: 10, to: today)!
        #expect(db.wordCountSum(since: today, until: farEnd, includeHidden: true) == 14)
        #expect(db.wordCountSum(since: today, until: farEnd, includeHidden: false) == 9)
        #expect(db.entryCount(since: today, until: farEnd, includeHidden: true) == 2)
        #expect(db.wordCountSum(since: today, includeHidden: true) == 5)
        let end = DatabaseManager.endOfToday()
        #expect(end > Date())
        #expect(end == Calendar.current.date(byAdding: .day, value: 1, to: today))
    }
}

