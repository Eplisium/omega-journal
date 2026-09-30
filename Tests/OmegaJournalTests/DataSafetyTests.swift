import Foundation
import Testing
import UserNotifications
import SQLite3
@testable import OmegaJournal

/// Data-layer safety net (audit findings #1, #3, #4, #5, #8, #11, #14, #15, #16, #17, #23).
/// Every test uses its own DatabaseManager(databasePath:) in a unique temp dir,
/// so nothing here touches the user's journal or the shared singleton.
@Suite("Data safety", .serialized)
@MainActor
struct DataSafetyTests {

    // MARK: Helpers

    nonisolated static func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-datasafety-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func makeDB(root: URL = tempRoot()) -> (root: URL, db: DatabaseManager) {
        let db = DatabaseManager(
            databasePath: root.appendingPathComponent("j.sqlite3").path,
            attachmentsPath: root.appendingPathComponent("attachments").path)
        return (root, db)
    }

    nonisolated static func run(_ path: String, _ sql: String) {
        var h: OpaquePointer?
        precondition(sqlite3_open(path, &h) == SQLITE_OK)
        defer { sqlite3_close(h) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
            fatalError("test SQL failed: \(err.map { String(cString: $0) } ?? "?")")
        }
    }

    /// Builds a schema-V7 database by hand (plaintext bodies, no body_enc).
    nonisolated static func buildV7(at path: String, extraSchemaVersion: Int = 7) {
        run(path, """
        CREATE TABLE schema_version (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL DEFAULT 0);
        INSERT INTO schema_version VALUES (1, \(extraSchemaVersion));
        CREATE TABLE entries (
            id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '',
            mood INTEGER DEFAULT 3, tags TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
            updated_at REAL NOT NULL, is_pinned INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0,
            deleted_at REAL, is_archived INTEGER NOT NULL DEFAULT 0, word_count INTEGER NOT NULL DEFAULT 0,
            is_hidden INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL);
        CREATE TABLE entry_tags (entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE, PRIMARY KEY (entry_id, tag_id));
        CREATE VIRTUAL TABLE entries_fts USING fts5(entry_id UNINDEXED, title, body, tags);
        CREATE TABLE attachments (id TEXT PRIMARY KEY, entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            filename TEXT NOT NULL, mime_type TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL);
        CREATE TABLE templates (id TEXT PRIMARY KEY, name TEXT NOT NULL, body TEXT NOT NULL DEFAULT '',
            tags TEXT NOT NULL DEFAULT '', icon TEXT NOT NULL DEFAULT 'doc.text', sort_order INTEGER NOT NULL DEFAULT 0);
        INSERT INTO entries (id, title, body, tags, created_at, updated_at, word_count)
            VALUES ('a1', 'Alpha walk', 'secret plaintext alpha body', 'walk', 1000, 1000, 4),
                   ('b2', 'Beta note', 'second legacy body', '', 2000, 2000, 3);
        INSERT INTO tags (name) VALUES ('walk');
        INSERT INTO entry_tags SELECT 'a1', id FROM tags WHERE name = 'walk';
        INSERT INTO entries_fts (entry_id, title, body, tags) VALUES ('a1', 'Alpha walk', 'secret plaintext alpha body', 'walk');
        INSERT INTO entries_fts (entry_id, title, body, tags) VALUES ('b2', 'Beta note', 'second legacy body', '');
        """)
    }

    func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)))!.addingTimeInterval(3600)
    }

    // MARK: #1 backup gate

    @Test("automatic backup runs once per calendar day and keeps 7")
    func backupOncePerDayKeepSeven() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = db.listBackups().count // launch-time backup for today (real clock)

        #expect(db.autoBackup(now: day(0)) == true)
        #expect(db.autoBackup(now: day(0).addingTimeInterval(600)) == false) // same day
        #expect(db.listBackups().count == before + 1)
        #expect(db.getSetting("lastBackupDate") == DatabaseManager.backupDayStamp(day(0)))
        // stamp is a plain day, not a timestamp
        #expect(db.getSetting("lastBackupDate").count == 10)

        for d in 1...9 { #expect(db.autoBackup(now: day(d)) == true) }
        let daily = db.listBackups().filter { $0.lastPathComponent.hasPrefix("omega_journal_") }
        #expect(daily.count == 7)
    }

    // MARK: #3 unreadable body

    @Test("undecryptable body is flagged and its ciphertext is never overwritten")
    func unreadableBodyPreserved() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        var e = JournalEntry.new()
        e.title = "Keep me"; e.body = "precious words"
        #expect(db.saveEntry(e))
        db.corruptBodyForTesting(id: e.id)
        let corrupted = try #require(db.rawBodyEncForTesting(id: e.id))

        var loaded = try #require(db.fetchEntry(id: e.id))
        #expect(loaded.body == "")
        #expect(db.isEntryUnreadable(e.id))

        // Autosave of the empty/unreadable model, plus a metadata change.
        loaded.isPinned = true
        var errors: [String] = []
        db.onError = { errors.append($0) }
        defer { db.onError = nil }
        _ = db.saveEntry(loaded)
        #expect(db.rawBodyEncForTesting(id: e.id) == corrupted)
        #expect(db.fetchEntry(id: e.id)?.isPinned == true) // metadata still saved

        // Typing new text must not clobber it either, and the user is told.
        loaded.body = "typed over it"
        _ = db.saveEntry(loaded)
        #expect(db.rawBodyEncForTesting(id: e.id) == corrupted)
        #expect(errors.contains { $0.contains("NOT saved") })
        db.hardDeleteEntry(id: e.id)
    }

    // MARK: #4 key handling

    @Test("a missing key is never minted when encrypted data exists")
    func missingKeyNotMinted() throws {
        let service = "com.omegajournal.tests.\(UUID().uuidString)"
        defer { JournalCrypto.deleteKeyForTesting(service: service, account: "k") }
        #expect(throws: JournalCrypto.KeyError.keyMissing) {
            _ = try JournalCrypto.loadOrCreateKey(service: service, account: "k", allowCreate: { false })
        }
        // Nothing was stored by the refused attempt…
        #expect(throws: JournalCrypto.KeyError.keyMissing) {
            _ = try JournalCrypto.loadOrCreateKey(service: service, account: "k", allowCreate: { false })
        }
        // …but with no data at risk, first use still creates one, stably.
        let k1 = try JournalCrypto.loadOrCreateKey(service: service, account: "k", allowCreate: { true })
        let k2 = try JournalCrypto.loadOrCreateKey(service: service, account: "k", allowCreate: { false })
        #expect(k1.withUnsafeBytes { Data($0) } == k2.withUnsafeBytes { Data($0) })
    }

    // MARK: #5 / #17 / migration

    @Test("V7 database migrates: bodies encrypted, snapshot taken, version bumped")
    func migratesHandBuiltV7() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("j.sqlite3").path
        Self.buildV7(at: path)

        let db = DatabaseManager(databasePath: path, attachmentsPath: root.appendingPathComponent("att").path)
        #expect(!db.isReadOnly)
        #expect(db.schemaVersion == DatabaseManager.currentSchemaVersion)
        let a = try #require(db.fetchEntry(id: "a1"))
        #expect(a.body == "secret plaintext alpha body")
        #expect(a.tags == ["walk"])
        #expect(db.fetchEntry(id: "b2")?.body == "second legacy body")
        #expect(db.scalarIntForTesting("SELECT COUNT(*) FROM entries WHERE body_enc IS NULL") == 0)
        #expect(db.scalarIntForTesting("SELECT COUNT(*) FROM entries WHERE body != ''") == 0)
        // Pre-migration snapshot exists.
        #expect(db.listBackups().contains { $0.lastPathComponent.hasPrefix("pre-migration_v7") })
        // Title search still works via the rebuilt FTS.
        #expect(db.fetchAllEntries(search: "Alpha").map(\.id) == ["a1"])
        // Plaintext is gone from the file.
        db.checkpointForTesting()
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(raw.range(of: Data("secret plaintext alpha body".utf8)) == nil)
    }

    @Test("migration is idempotent across relaunches and V8→V9 works from a V8 file")
    func v9IdempotentFromV8() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("j.sqlite3").path
        Self.buildV7(at: path)
        do { // first launch migrates fully
            let db = DatabaseManager(databasePath: path, attachmentsPath: root.appendingPathComponent("att").path)
            #expect(db.schemaVersion == DatabaseManager.currentSchemaVersion)
        }
        // Wind the file back to a V8 state: no FTS map, version 8.
        Self.run(path, "DROP TABLE entries_fts_map; UPDATE schema_version SET version = 8;")
        for _ in 0..<2 { // re-open twice: V9 must be re-runnable
            let db = DatabaseManager(databasePath: path, attachmentsPath: root.appendingPathComponent("att").path)
            #expect(db.schemaVersion == 9)
            #expect(db.scalarIntForTesting("SELECT COUNT(*) FROM entries_fts_map") == 2)
            #expect(db.scalarIntForTesting("SELECT COUNT(*) FROM entries_fts") == 2)
            #expect(db.fetchAllEntries(search: "Beta").map(\.id) == ["b2"])
            #expect(db.fetchEntry(id: "a1")?.body == "secret plaintext alpha body") // never double-encrypted
        }
    }

    @Test("legacy plaintext row (body_enc NULL) still reads via the plaintext column")
    func plaintextFallback() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        var e = JournalEntry.new(); e.body = "encrypted first"
        db.saveEntry(e)
        db.legacyPlaintextForTesting(id: e.id, body: "legacy plain text")
        #expect(db.fetchEntry(id: e.id)?.body == "legacy plain text")
        #expect(!db.isEntryUnreadable(e.id))
    }

    @Test("a database newer than the app is opened read-only, not downgraded")
    func refusesNewerSchema() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("j.sqlite3").path
        Self.buildV7(at: path, extraSchemaVersion: 99)
        let db = DatabaseManager(databasePath: path, attachmentsPath: root.appendingPathComponent("att").path)
        #expect(db.isReadOnly)
        #expect(db.startupError?.contains("newer") == true)
        #expect(db.schemaVersion == 99)
        var e = JournalEntry.new(); e.title = "nope"
        #expect(db.saveEntry(e) == false)
        #expect(db.fetchEntry(id: e.id) == nil)
        // The untouched V7 shape: no body_enc column was added.
        #expect(db.scalarIntForTesting("SELECT COUNT(*) FROM pragma_table_info('entries') WHERE name = 'body_enc'") == 0)
    }

    // MARK: #8 hard delete

    @Test("hardDelete removes attachment files only after commit")
    func hardDeleteFilesAfterCommit() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        var e = JournalEntry.new(); e.title = "with file"
        db.saveEntry(e)
        let att = try #require(db.saveAttachment(entryId: e.id, data: Data("x".utf8), filename: "f.txt"))
        let dir = root.appendingPathComponent("attachments").appendingPathComponent(att.id).path

        // Failing delete (entries table sabotaged) must roll back and keep the file.
        db.onError = { _ in }
        db.sabotageTableForTesting("entries")
        db.hardDeleteEntry(id: e.id)
        db.restoreTableForTesting("entries")
        db.onError = nil
        #expect(FileManager.default.fileExists(atPath: dir))
        #expect(db.fetchAttachments(entryId: e.id).count == 1) // row restored by rollback
        #expect(db.readAttachmentData(att) == Data("x".utf8))

        db.hardDeleteEntry(id: e.id)
        #expect(!FileManager.default.fileExists(atPath: dir))
        #expect(db.fetchEntry(id: e.id) == nil)
    }

    // MARK: #11 FTS

    @Test("FTS follows save, rename and delete through the rowid map")
    func ftsLifecycle() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        var e = JournalEntry.new(); e.title = "Zebra crossing"; e.tags = ["safari"]
        db.saveEntry(e)
        #expect(db.fetchAllEntries(search: "zebra").count == 1)
        e.title = "Giraffe height"
        db.saveEntry(e)
        #expect(db.fetchAllEntries(search: "zebra").isEmpty)
        #expect(db.fetchAllEntries(search: "giraffe").count == 1)
        #expect(db.scalarIntForTesting("SELECT COUNT(*) FROM entries_fts") == 1) // no duplicates
        db.renameTag(from: "safari", to: "savanna")
        #expect(db.fetchAllEntries(search: "savanna").count == 1)
        db.hardDeleteEntry(id: e.id)
        #expect(db.scalarIntForTesting("SELECT COUNT(*) FROM entries_fts") == 0)
        #expect(db.scalarIntForTesting("SELECT COUNT(*) FROM entries_fts_map") == 0)
    }

    // MARK: #14 checked variants

    @Test("checked save/setting variants report failure and stay source-compatible")
    func checkedVariants() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        var e = JournalEntry.new(); e.title = "ok"
        db.saveEntry(e) // discardable
        try db.saveEntryChecked(e)
        #expect(db.setSetting("k", value: "v") == true)
        #expect(db.getSetting("k") == "v")

        db.onError = { _ in }
        db.sabotageTableForTesting("entries")
        #expect(db.saveEntry(e) == false)
        #expect(throws: (any Error).self) { try db.saveEntryChecked(e) }
        db.restoreTableForTesting("entries")
        db.sabotageTableForTesting("settings")
        #expect(db.setSetting("k", value: "w") == false)
        db.restoreTableForTesting("settings")
        db.onError = nil
        #expect(db.getSetting("k") == "v")
    }

    // MARK: #15 temp files

    @Test("decrypted attachment copies live in a private dir and are cleaned up")
    func temporaryCopies() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root); JournalCrypto.cleanupTemporaryFiles() }
        var e = JournalEntry.new(); db.saveEntry(e)
        let att = try #require(db.saveAttachment(entryId: e.id, data: Data("hello".utf8), filename: "a.txt"))
        let temp = try #require(db.openAttachmentExternally(att))
        #expect(temp.path.hasPrefix(JournalCrypto.temporaryDirectory.path))
        #expect(try Data(contentsOf: temp) == Data("hello".utf8))
        let perms = try FileManager.default.attributesOfItem(atPath: JournalCrypto.temporaryDirectory.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
        JournalCrypto.cleanupTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        e.title = "x"
    }

    // MARK: Restore

    @Test("restoreBackup validates, snapshots the current DB, and swaps")
    func restoreRoundTrip() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        var keep = JournalEntry.new(); keep.title = "in backup"; keep.body = "kept body"
        db.saveEntry(keep)
        let backup = try #require(db.backupDatabase())
        var later = JournalEntry.new(); later.title = "after backup"
        db.saveEntry(later)
        #expect(db.listBackups().contains { $0.lastPathComponent == backup.lastPathComponent })

        // Garbage is rejected and leaves the live DB alone.
        let junk = root.appendingPathComponent("junk.sqlite3")
        try Data("not a database".utf8).write(to: junk)
        #expect(throws: (any Error).self) { try db.restoreBackup(from: junk) }
        #expect(db.fetchEntry(id: later.id) != nil)

        try db.restoreBackup(from: backup)
        #expect(db.fetchEntry(id: later.id) == nil)
        #expect(db.fetchEntry(id: keep.id)?.body == "kept body")
        #expect(db.listBackups().contains { $0.lastPathComponent.hasPrefix("pre-restore_") })
        // Still writable after the swap.
        var again = JournalEntry.new(); again.title = "post restore"
        #expect(db.saveEntry(again))
        #expect(db.fetchAllEntries(search: "post").count == 1)
    }

    // MARK: #16 idle relock

    @Test("noteActivity pushes the idle relock deadline out")
    func idleRelockRearms() async throws {
        let auth = BiometricAuth(forTesting: ())
        auth.idleSecondsOverride = 0.5
        auth.activityThrottle = 0
        auth.setAuthenticatedForTesting(true)
        defer { auth.idleSecondsOverride = nil; auth.activityThrottle = 1; auth.lock() }
        var fired = false
        let token = NotificationCenter.default.addObserver(forName: .lockHiddenEntries, object: nil, queue: .main) { _ in fired = true }
        defer { NotificationCenter.default.removeObserver(token) }

        auth.scheduleIdleRelock()
        try await Task.sleep(nanoseconds: 300_000_000)
        auth.noteActivity()                      // deadline moves to ~0.8s
        try await Task.sleep(nanoseconds: 350_000_000) // t=0.65 — original would have fired
        #expect(!fired)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(fired)
    }

    // MARK: #23 notifications

    @Test("reminders are a rolling set of one-shot requests with varied prompts")
    func reminderRequests() throws {
        var n = 0
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reqs = NotificationManager.buildReminderRequests(after: now, hour: 20, minute: 0, prompt: { n += 1; return "prompt \(n)" })
        #expect(reqs.count == NotificationManager.upcomingReminderCount)
        #expect(Set(reqs.map(\.identifier)).count == reqs.count)
        #expect(Set(reqs.map(\.content.body)).count == reqs.count)
        for r in reqs {
            let t = try #require(r.trigger as? UNCalendarNotificationTrigger)
            #expect(t.repeats == false)
        }
        let comps = NotificationManager.upcomingReminderComponents(after: now, hour: 20, minute: 0)
        #expect(comps.count == NotificationManager.upcomingReminderCount)
        let first = try #require(Calendar.current.date(from: comps[0]))
        #expect(first > now)
    }
}
