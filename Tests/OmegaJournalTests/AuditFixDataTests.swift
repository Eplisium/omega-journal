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

// MARK: - DATA-1

@Suite("Audit fix data: FTS plaintext purge (DATA-1)", .serialized)
@MainActor
struct AuditFixDataFTSTests {
    init() { MASDataTestEnv.ensureIsolated() }

    /// Writes the FTS state a pre-V8 build left behind: the body text was
    /// indexed, then deleted with a plain DELETE (what V8/V9 did).
    static func plantLegacyFTSResidue(_ db: DatabaseManager, id: String, title: String, secret: String) {
        // Journals from those builds never had FTS5 secure-delete on.
        #expect(db.exec("INSERT INTO entries_fts(entries_fts, rank) VALUES('secure-delete', 0);"))
        #expect(db.exec("DELETE FROM entries_fts;"))
        #expect(db.exec("DELETE FROM entries_fts_map;"))
        #expect(db.exec("INSERT INTO entries_fts(entry_id, title, body, tags) VALUES ('\(id)', '\(title)', '\(secret)', '');"))
    }

    @Test("upgrading a pre-V8 journal leaves no plaintext body words in the database file")
    func preV8FTSPlaintextPurged() throws {
        let (root, path, first) = AuditFixDataEnv.tempDB("fts-v7")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "quokkasecretalpha zebrasecretbeta"
        var id = ""
        do {
            let db = first
            var e = JournalEntry.new()
            e.title = "Upgrade probe"
            e.body = "placeholder"
            #expect(db.saveEntry(e))
            id = e.id
            db.legacyPlaintextForTesting(id: id, body: secret)
            Self.plantLegacyFTSResidue(db, id: id, title: "Upgrade probe", secret: secret)
            #expect(db.exec("UPDATE schema_version SET version = 7 WHERE id = 1;"))
            db.checkpointForTesting()
            #expect(try AuditFixDataEnv.fileContains(path, "quokkasecretalpha"), "setup: the old index should hold the body")
        }
        let db2 = AuditFixDataEnv.reopen(root)
        #expect(db2.isReadOnly == false)
        #expect(db2.getSchemaVersion() == DatabaseManager.currentSchemaVersion)
        #expect(db2.fetchEntry(id: id)?.body == secret)
        db2.checkpointForTesting()
        #expect(try !AuditFixDataEnv.fileContains(path, "quokkasecretalpha"), "plaintext body token still in DB file")
        #expect(try !AuditFixDataEnv.fileContains(path, "zebrasecretbeta"), "plaintext body token still in DB file")
        // Title search still works after the rebuild.
        #expect(db2.fullTextSearch("Upgrade").contains { $0.id == id })
    }

    @Test("a journal already on V12 that carries old body postings is purged by the next migration")
    func alreadyUpgradedJournalPurged() throws {
        let (root, path, first) = AuditFixDataEnv.tempDB("fts-v12")
        defer { try? FileManager.default.removeItem(at: root) }
        var id = ""
        do {
            let db = first
            var e = JournalEntry.new()
            e.title = "Residue probe"
            e.body = "encrypted at rest"
            e.tags = ["keepme"]
            #expect(db.saveEntry(e))
            id = e.id
            // A V12 journal whose index still holds a body token from before V8,
            // followed by the V9-style DELETE + title/tags-only reinsert.
            Self.plantLegacyFTSResidue(db, id: id, title: "Residue probe", secret: "wombatsecretgamma")
            // V9's rebuild exactly: DELETE, then reinsert title/tags with body ''.
            #expect(db.exec("DELETE FROM entries_fts;"))
            #expect(db.exec("INSERT INTO entries_fts_map (entry_id) SELECT id FROM entries;"))
            #expect(db.exec("""
                INSERT INTO entries_fts(rowid, entry_id, title, body, tags)
                SELECT m.fts_rowid, e.id, e.title, '', e.tags FROM entries e JOIN entries_fts_map m ON m.entry_id = e.id;
                """))
            #expect(db.exec("UPDATE schema_version SET version = 12 WHERE id = 1;"))
            db.checkpointForTesting()
            #expect(try AuditFixDataEnv.fileContains(path, "wombatsecretgamma"), "setup: residue should be on disk")
        }
        let db2 = AuditFixDataEnv.reopen(root)
        #expect(db2.getSchemaVersion() == DatabaseManager.currentSchemaVersion)
        db2.checkpointForTesting()
        #expect(try !AuditFixDataEnv.fileContains(path, "wombatsecretgamma"), "old FTS postings survived the purge migration")
        #expect(db2.fetchEntry(id: id)?.body == "encrypted at rest")
        #expect(db2.fullTextSearch("Residue").contains { $0.id == id })
        #expect(db2.fullTextSearch("keepme").contains { $0.id == id })
    }

    @Test("rebuilding the index (tag rename) also purges old postings, and still works mid-transaction")
    func reindexPurgesAndToleratesOpenStatements() throws {
        let (root, path, db) = AuditFixDataEnv.tempDB("fts-rename")
        defer { try? FileManager.default.removeItem(at: root) }
        var e = JournalEntry.new()
        e.title = "Rename probe"
        e.tags = ["oldtagname"]
        #expect(db.saveEntry(e))
        Self.plantLegacyFTSResidue(db, id: e.id, title: "Rename probe", secret: "dingosecretdelta")
        #expect(db.exec("DELETE FROM entries_fts;"))
        db.checkpointForTesting()
        #expect(try AuditFixDataEnv.fileContains(path, "dingosecretdelta"), "setup: residue should be on disk")
        // renameTag holds stepped statements while it rebuilds the index.
        db.renameTag(from: "oldtagname", to: "newtagname")
        #expect(db.fetchEntry(id: e.id)?.tags == ["newtagname"])
        #expect(db.fullTextSearch("newtagname").contains { $0.id == e.id })
        #expect(db.fullTextSearch("Rename").contains { $0.id == e.id })
        db.vacuumForTesting()
        db.checkpointForTesting()
        #expect(try !AuditFixDataEnv.fileContains(path, "dingosecretdelta"))
    }

    @Test("FTS5 secure-delete is on exactly when this system's SQLite supports it, and search keeps working")
    func secureDeleteMatchesSystemSupport() throws {
        let (root, _, db) = AuditFixDataEnv.tempDB("fts-secure")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(db.ftsSecureDeleteEnabled == DatabaseManager.systemSupportsFTSSecureDelete)
        // A journal whose option was off (older OS, or before this fix) gets it at the next launch.
        #expect(db.exec("INSERT INTO entries_fts(entries_fts, rank) VALUES('secure-delete', 0);"))
        #expect(!db.ftsSecureDeleteEnabled)
        let reopened = AuditFixDataEnv.reopen(root)
        #expect(reopened.ftsSecureDeleteEnabled == DatabaseManager.systemSupportsFTSSecureDelete)
        var e = JournalEntry.new()
        e.title = "Ocelot evening"
        #expect(reopened.saveEntry(e))
        e.title = "Lynx morning"
        #expect(reopened.saveEntry(e))
        #expect(reopened.fullTextSearch("Lynx").map(\.id) == [e.id])
        #expect(reopened.fullTextSearch("Ocelot").isEmpty)
        reopened.hardDeleteEntry(id: e.id)
        #expect(reopened.fullTextSearch("Lynx").isEmpty)
        #expect(reopened.scalarIntForTesting("SELECT COUNT(*) FROM entries_fts;") == 0)
    }

    @Test("the purge migration is idempotent and keeps every entry searchable")
    func purgeMigrationIdempotent() throws {
        let (root, _, db) = AuditFixDataEnv.tempDB("fts-idem")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids: [String] = []
        for i in 0..<5 {
            var e = JournalEntry.new()
            e.title = "Idem \(i)"
            e.tags = ["batch"]
            #expect(db.saveEntry(e))
            ids.append(e.id)
        }
        for _ in 0..<2 {
            db.beginTransaction()
            #expect(db.migrateToV13())
            #expect(db.endTransaction())
        }
        #expect(Set(db.fullTextSearch("batch").map(\.id)) == Set(ids))
        #expect(db.scalarIntForTesting("SELECT COUNT(*) FROM entries_fts;") == 5)
        #expect(db.scalarIntForTesting("SELECT COUNT(*) FROM entries_fts_map;") == 5)
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

// MARK: - DATA-3

@Suite("Audit fix data: stored word counts match the editor (DATA-3)", .serialized)
@MainActor
struct AuditFixDataWordCountTests {
    init() { MASDataTestEnv.ensureIsolated() }

    static func stampedBody(_ rest: String) -> String {
        EntryStampCodec.join(stamp: EntryStamp(location: "New York, NY", weather: "Sunny 21°"), rest: rest)
    }

    @Test("stored word_count matches the displayed word count for a stamped entry")
    func storedWordCountExcludesStamp() throws {
        let (root, _, db) = AuditFixDataEnv.tempDB("words")
        defer { try? FileManager.default.removeItem(at: root) }
        var e = JournalEntry.new()
        e.body = Self.stampedBody("hello world")
        #expect(e.wordCount == 2)
        #expect(db.saveEntry(e))
        #expect(db.scalarIntForTesting("SELECT word_count FROM entries WHERE id = '\(e.id)';") == 2)
        #expect(db.wordCountSum(since: Calendar.current.startOfDay(for: Date()), includeHidden: false) == e.wordCount)
    }

    @Test("existing rows saved with the old count are corrected once by a migration")
    func existingRowsBackfilled() throws {
        let (root, _, first) = AuditFixDataEnv.tempDB("words-backfill")
        defer { try? FileManager.default.removeItem(at: root) }
        var stamped = JournalEntry.new()
        stamped.body = Self.stampedBody("one two three")
        var plain = JournalEntry.new()
        plain.body = "four five"
        do {
            let db = first
            #expect(db.saveEntry(stamped))
            #expect(db.saveEntry(plain))
            // What every earlier build stored: raw whitespace tokens, stamp included.
            let old = stamped.body.split(whereSeparator: { $0.isWhitespace }).count
            #expect(old > 3)
            #expect(db.exec("UPDATE entries SET word_count = \(old) WHERE id = '\(stamped.id)';"))
            #expect(db.exec("UPDATE schema_version SET version = 12 WHERE id = 1;"))
        }
        let db2 = AuditFixDataEnv.reopen(root)
        #expect(db2.getSchemaVersion() == DatabaseManager.currentSchemaVersion)
        #expect(db2.scalarIntForTesting("SELECT word_count FROM entries WHERE id = '\(stamped.id)';") == 3)
        #expect(db2.scalarIntForTesting("SELECT word_count FROM entries WHERE id = '\(plain.id)';") == 2)
        #expect(db2.fetchEntry(id: stamped.id)?.body == stamped.body)
    }
}

// MARK: - DATA-4

@Suite("Audit fix data: legacy import keeps a pre-import snapshot (DATA-4)", .serialized)
@MainActor
struct AuditFixDataLegacyImportTests {
    init() { MASDataTestEnv.ensureIsolated() }

    /// Decrypts a sealed backup and returns the ids in `table`.
    static func ids(in table: String, ofSealedBackup url: URL) throws -> Set<String> {
        let plain = try JournalCrypto.decrypt(Data(contentsOf: url))
        let tmp = MASDataTestEnv.tempDir("auditfix-data-snapcheck")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("snap.sqlite3")
        try plain.write(to: file)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h = handle else {
            sqlite3_close(handle); return []
        }
        defer { sqlite3_close(h) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, "SELECT id FROM \(table);", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }

    @Test("the import summary names the kept snapshot, which lists as a restorable 'Before import' backup")
    func summaryReportsSnapshot() throws {
        let (source, _) = MASDataLegacyImportTests.makeSourceJournal(entries: 1)
        let (root, db) = MASDataLegacyImportTests.makeTarget()
        defer { MASDataLegacyImportTests.cleanup(source.deletingLastPathComponent(), root) }
        let summary = try db.importLegacyJournal(from: source)
        let snapshot = try #require(summary.preImportSnapshot)
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        #expect(snapshot.deletingLastPathComponent().standardizedFileURL == db.backupsDirectory.standardizedFileURL)
        #expect(snapshot.lastPathComponent.hasPrefix(DatabaseManager.preImportBackupPrefix))
        // Sealed with the journal key, not plaintext SQLite.
        let raw = try Data(contentsOf: snapshot)
        #expect(!raw.starts(with: Data("SQLite format 3\0".utf8)))
        // The imported entry is present; the snapshot itself holds no entries.
        #expect(db.fetchAllEntries().count == 1)
        #expect(try Self.ids(in: "entries", ofSealedBackup: snapshot).isEmpty)
        #expect(BackupInfo(url: snapshot, date: Date(), bytes: 0, isExternal: false).kind == "Before import")
    }

    @Test("legacy import keeps the replaced journal's notebooks and templates in a backup")
    func legacyImportKeepsTargetOrganization() throws {
        let (source, _) = MASDataLegacyImportTests.makeSourceJournal(entries: 1)
        let (root, db) = MASDataLegacyImportTests.makeTarget()
        defer { MASDataLegacyImportTests.cleanup(source.deletingLastPathComponent(), root) }
        let notebook = try #require(db.createJournal(name: "Work notebook"))
        let template = EntryTemplate(id: UUID().uuidString, name: "My custom template", body: "## Wins", tags: [], icon: "doc.text", sortOrder: 99)
        #expect(db.saveTemplate(template))
        #expect(db.isJournalEmptyForImport())
        _ = try db.importLegacyJournal(from: source)
        let snapshots = try FileManager.default.contentsOfDirectory(at: db.backupsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pre-import_") }
        let snapshot = try #require(snapshots.first, "no pre-import snapshot of the replaced journal was kept")
        #expect(try Self.ids(in: "journals", ofSealedBackup: snapshot).contains(notebook.id))
        #expect(try Self.ids(in: "templates", ofSealedBackup: snapshot).contains(template.id))
    }
}

// MARK: - DATA-5

@Suite("Audit fix data: a minted App Store key is mirrored to the login keychain (DATA-5)")
struct AuditFixDataKeyMirrorTests {
    static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    @Test("a direct build that adopts the App Store journal can read its key")
    func directBuildCanReadMASMintedKey() throws {
        let sharedLogin = MASDataFakeKeyStore()                    // login keychain (both builds)
        let masDataProtection = MASDataFakeKeyStore()              // App Store build's access group
        // 1. Fresh App Store install: empty journal → key minted (the app's path).
        let minted = try JournalCrypto.loadOrCreateKey(
            using: MASDataKeyResolver(preferred: masDataProtection, legacy: sharedLogin), allowCreate: { true })
        #expect(masDataProtection.stored == Self.bytes(minted))
        // 2. Later the user runs the direct build: the legacy folder has no DB, the container does.
        let legacyDir = URL(fileURLWithPath: "/tmp/legacy/OmegaJournal")
        let containerDir = URL(fileURLWithPath: "/tmp/container/OmegaJournal")
        let dir = MASDataJournalLocation.resolveDirectory(isSandboxed: false, legacyDir: legacyDir, containerDir: containerDir,
                                                          fileExists: { $0.hasPrefix(containerDir.path) })
        #expect(dir == containerDir)
        // 3. Direct build: data-protection keychain unavailable (no entitlement), encrypted rows exist.
        let direct = MASDataKeyResolver(preferred: MASDataFakeKeyStore(readStatus: -34018, addStatus: -34018), legacy: sharedLogin)
        let key = try? direct.resolve(allowCreate: { false })
        #expect(key.map { Self.bytes($0.key) } == Self.bytes(minted),
                "direct build opens the App Store journal but the key is unreachable")
        #expect(key?.origin == .legacyOnly)
    }

    @Test("a failing login-keychain mirror never fails the mint")
    func mirrorFailureDoesNotFailMint() throws {
        let preferred = MASDataFakeKeyStore()
        let legacy = MASDataFakeKeyStore(addStatus: errSecInteractionNotAllowed)
        let key = try JournalCrypto.loadOrCreateKey(using: MASDataKeyResolver(preferred: preferred, legacy: legacy), allowCreate: { true })
        #expect(preferred.stored == Self.bytes(key))
        #expect(legacy.stored == nil)
        // An unreadable login keychain: the mirror reports it and writes nothing.
        // (The resolver itself already refuses to mint in that state.)
        let lockedLegacy = MASDataFakeKeyStore(readStatus: errSecInteractionNotAllowed)
        let resolver = MASDataKeyResolver(preferred: MASDataFakeKeyStore(), legacy: lockedLegacy)
        #expect(resolver.mirrorMintedKeyToLegacy(SymmetricKey(size: .bits256)) == errSecInteractionNotAllowed)
        #expect(lockedLegacy.adds == 0)
    }

    @Test("the mirror never overwrites an existing login-keychain item")
    func mirrorNeverOverwrites() throws {
        let other = Data(repeating: 7, count: 32)
        let legacy = MASDataFakeKeyStore(stored: other)
        let resolver = MASDataKeyResolver(preferred: MASDataFakeKeyStore(), legacy: legacy)
        #expect(resolver.mirrorMintedKeyToLegacy(SymmetricKey(size: .bits256)) == errSecDuplicateItem)
        #expect(legacy.stored == other)
        #expect(legacy.adds == 0)
    }

    @Test("only a key minted into the data-protection keychain is mirrored")
    func onlyPreferredMintsAreMirrored() throws {
        // Unentitled build: minted straight into the login keychain — one add, no mirror.
        let legacy = MASDataFakeKeyStore()
        let unentitled = MASDataKeyResolver(preferred: MASDataFakeKeyStore(readStatus: -34018, addStatus: -34018), legacy: legacy)
        _ = try JournalCrypto.loadOrCreateKey(using: unentitled, allowCreate: { true })
        #expect(legacy.adds == 1)
        // Existing preferred key: found, nothing minted, nothing mirrored.
        let found = MASDataFakeKeyStore()
        let existing = MASDataKeyResolver(preferred: MASDataFakeKeyStore(stored: Data(repeating: 1, count: 32)), legacy: found)
        _ = try JournalCrypto.loadOrCreateKey(using: existing, allowCreate: { true })
        #expect(found.adds == 0)
    }
}

