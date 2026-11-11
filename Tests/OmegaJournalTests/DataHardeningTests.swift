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

enum DataHardeningEnv {
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

@Suite("Data: FTS plaintext purge (DATA-1)", .serialized)
@MainActor
struct DataHardeningFTSTests {
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
        let (root, path, first) = DataHardeningEnv.tempDB("fts-v7")
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
            #expect(try DataHardeningEnv.fileContains(path, "quokkasecretalpha"), "setup: the old index should hold the body")
        }
        let db2 = DataHardeningEnv.reopen(root)
        #expect(db2.isReadOnly == false)
        #expect(db2.getSchemaVersion() == DatabaseManager.currentSchemaVersion)
        #expect(db2.fetchEntry(id: id)?.body == secret)
        db2.checkpointForTesting()
        #expect(try !DataHardeningEnv.fileContains(path, "quokkasecretalpha"), "plaintext body token still in DB file")
        #expect(try !DataHardeningEnv.fileContains(path, "zebrasecretbeta"), "plaintext body token still in DB file")
        // Title search still works after the rebuild.
        #expect(db2.fullTextSearch("Upgrade").contains { $0.id == id })
    }

    @Test("a journal already on V12 that carries old body postings is purged by the next migration")
    func alreadyUpgradedJournalPurged() throws {
        let (root, path, first) = DataHardeningEnv.tempDB("fts-v12")
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
            #expect(try DataHardeningEnv.fileContains(path, "wombatsecretgamma"), "setup: residue should be on disk")
        }
        let db2 = DataHardeningEnv.reopen(root)
        #expect(db2.getSchemaVersion() == DatabaseManager.currentSchemaVersion)
        db2.checkpointForTesting()
        #expect(try !DataHardeningEnv.fileContains(path, "wombatsecretgamma"), "old FTS postings survived the purge migration")
        #expect(db2.fetchEntry(id: id)?.body == "encrypted at rest")
        #expect(db2.fullTextSearch("Residue").contains { $0.id == id })
        #expect(db2.fullTextSearch("keepme").contains { $0.id == id })
    }

    @Test("rebuilding the index (tag rename) also purges old postings, and still works mid-transaction")
    func reindexPurgesAndToleratesOpenStatements() throws {
        let (root, path, db) = DataHardeningEnv.tempDB("fts-rename")
        defer { try? FileManager.default.removeItem(at: root) }
        var e = JournalEntry.new()
        e.title = "Rename probe"
        e.tags = ["oldtagname"]
        #expect(db.saveEntry(e))
        Self.plantLegacyFTSResidue(db, id: e.id, title: "Rename probe", secret: "dingosecretdelta")
        #expect(db.exec("DELETE FROM entries_fts;"))
        db.checkpointForTesting()
        #expect(try DataHardeningEnv.fileContains(path, "dingosecretdelta"), "setup: residue should be on disk")
        // renameTag holds stepped statements while it rebuilds the index.
        db.renameTag(from: "oldtagname", to: "newtagname")
        #expect(db.fetchEntry(id: e.id)?.tags == ["newtagname"])
        #expect(db.fullTextSearch("newtagname").contains { $0.id == e.id })
        #expect(db.fullTextSearch("Rename").contains { $0.id == e.id })
        db.vacuumForTesting()
        db.checkpointForTesting()
        #expect(try !DataHardeningEnv.fileContains(path, "dingosecretdelta"))
    }

    @Test("FTS5 secure-delete is on exactly when this system's SQLite supports it, and search keeps working")
    func secureDeleteMatchesSystemSupport() throws {
        let (root, _, db) = DataHardeningEnv.tempDB("fts-secure")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(db.ftsSecureDeleteEnabled == DatabaseManager.systemSupportsFTSSecureDelete)
        // A journal whose option was off (older OS, or before this fix) gets it at the next launch.
        #expect(db.exec("INSERT INTO entries_fts(entries_fts, rank) VALUES('secure-delete', 0);"))
        #expect(!db.ftsSecureDeleteEnabled)
        let reopened = DataHardeningEnv.reopen(root)
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
        let (root, _, db) = DataHardeningEnv.tempDB("fts-idem")
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

@Suite("Data: writing goals mask hidden and future entries (DATA-2, browse-3)", .serialized, .lockState)
@MainActor
struct DataHardeningGoalTests {
    init() { MASDataTestEnv.ensureIsolated() }

    @Test("writing goals do not count locked hidden entries' words")
    func goalsExcludeLockedHidden() throws {
        let (root, _, db) = DataHardeningEnv.tempDB("goals-hidden")
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
        e.body = DataHardeningEnv.words(400, "secretword")
        e.isHidden = true
        #expect(db.saveEntry(e))
        var visible = JournalEntry.new()
        visible.body = DataHardeningEnv.words(7)
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
        let (root, _, db) = DataHardeningEnv.tempDB("goals-future")
        defer { try? FileManager.default.removeItem(at: root) }
        var future = JournalEntry.new()
        future.title = "Next week plan"
        future.body = DataHardeningEnv.words(200, "plan")
        future.createdAt = Calendar.current.date(byAdding: .day, value: 5, to: Date())!
        #expect(db.saveEntry(future))
        var tomorrow = JournalEntry.new()
        tomorrow.body = DataHardeningEnv.words(30)
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
        let (root, _, db) = DataHardeningEnv.tempDB("goals-session")
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = BiometricAuth(forTesting: (), db: db)
        var hidden = JournalEntry.new()
        hidden.body = DataHardeningEnv.words(50)
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
        let (root, _, db) = DataHardeningEnv.tempDB("goals-day")
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = BiometricAuth(forTesting: (), db: db)
        let goals = GoalManager(db: db, auth: auth)
        #expect(goals.goals.first { $0.type == .dailyWords }?.current == 0)
        // Written behind GoalManager's back (as the day rolls over, yesterday's
        // number must be replaced without any save notification).
        var e = JournalEntry.new()
        e.body = DataHardeningEnv.words(12)
        #expect(db.saveEntry(e))
        #expect(goals.goals.first { $0.type == .dailyWords }?.current == 0)
        // Posted off the main thread, like the system does.
        await Task.detached { NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil) }.value
        await Self.waitUntil { goals.goals.first { $0.type == .dailyWords }?.current == 12 }
        #expect(goals.goals.first { $0.type == .dailyWords }?.current == 12)
    }

    @Test("explicit goal windows: an until bound and includeHidden override the defaults")
    func explicitWindowParameters() throws {
        let (root, _, db) = DataHardeningEnv.tempDB("goals-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let today = Calendar.current.startOfDay(for: Date())
        var hidden = JournalEntry.new()
        hidden.body = DataHardeningEnv.words(5)
        hidden.isHidden = true
        #expect(db.saveEntry(hidden))
        var later = JournalEntry.new()
        later.body = DataHardeningEnv.words(9)
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

@Suite("Data: stored word counts match the editor (DATA-3)", .serialized)
@MainActor
struct DataHardeningWordCountTests {
    init() { MASDataTestEnv.ensureIsolated() }

    static func stampedBody(_ rest: String) -> String {
        EntryStampCodec.join(stamp: EntryStamp(location: "New York, NY", weather: "Sunny 21°"), rest: rest)
    }

    @Test("stored word_count matches the displayed word count for a stamped entry")
    func storedWordCountExcludesStamp() throws {
        let (root, _, db) = DataHardeningEnv.tempDB("words")
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
        let (root, _, first) = DataHardeningEnv.tempDB("words-backfill")
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
        let db2 = DataHardeningEnv.reopen(root)
        #expect(db2.getSchemaVersion() == DatabaseManager.currentSchemaVersion)
        #expect(db2.scalarIntForTesting("SELECT word_count FROM entries WHERE id = '\(stamped.id)';") == 3)
        #expect(db2.scalarIntForTesting("SELECT word_count FROM entries WHERE id = '\(plain.id)';") == 2)
        #expect(db2.fetchEntry(id: stamped.id)?.body == stamped.body)
    }
}

// MARK: - DATA-4

@Suite("Data: legacy import keeps a pre-import snapshot (DATA-4)", .serialized)
@MainActor
struct DataHardeningLegacyImportTests {
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

@Suite("Data: a minted App Store key is mirrored to the login keychain (DATA-5)")
struct DataHardeningKeyMirrorTests {
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

// MARK: - DATA-6

@Suite("Data: failed key lookups are remembered briefly (DATA-6)")
struct DataHardeningKeyFailureCacheTests {
    struct Locked: Error {}

    @Test("a failed lookup is not retried on every row, and is retried after the interval")
    func failureCachedThenRetried() throws {
        var cache = JournalCrypto.KeyFailureCache(retryInterval: 5)
        var calls = 0
        var keychainUnlocked = false
        let key = SymmetricKey(size: .bits256)
        func load() throws -> SymmetricKey {
            calls += 1
            guard keychainUnlocked else { throw Locked() }
            return key
        }
        // Launch with the keychain locked: first row asks, the next 999 don't.
        for _ in 0..<1000 {
            #expect(throws: Locked.self) { try JournalCrypto.resolveKey(failures: &cache, now: 100, load: load) }
        }
        #expect(calls == 1)
        // Still within the window a moment later.
        #expect(throws: Locked.self) { try JournalCrypto.resolveKey(failures: &cache, now: 104.9, load: load) }
        #expect(calls == 1)
        // The user unlocks the keychain; once the window passes the session recovers.
        keychainUnlocked = true
        let got = try JournalCrypto.resolveKey(failures: &cache, now: 105, load: load)
        #expect(calls == 2)
        #expect(got.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
        #expect(cache.activeFailure(now: 105) == nil)
    }

    @Test("an explicit retry clears the remembered failure immediately")
    func explicitRetryClears() throws {
        var cache = JournalCrypto.KeyFailureCache(retryInterval: 5)
        var calls = 0
        var fail = true
        func load() throws -> SymmetricKey {
            calls += 1
            if fail { throw JournalCrypto.KeyError.keyMissing }
            return SymmetricKey(size: .bits256)
        }
        #expect(throws: JournalCrypto.KeyError.keyMissing) { try JournalCrypto.resolveKey(failures: &cache, now: 0, load: load) }
        fail = false
        cache.clear()  // what restore/verify/import and adoptPrefetchedKey do
        _ = try JournalCrypto.resolveKey(failures: &cache, now: 1, load: load)
        #expect(calls == 2)
    }

    @Test("a clock that moves backwards never pins the failure")
    func backwardsClockDoesNotPin() throws {
        var cache = JournalCrypto.KeyFailureCache(retryInterval: 5)
        var calls = 0
        func load() throws -> SymmetricKey { calls += 1; throw Locked() }
        _ = try? JournalCrypto.resolveKey(failures: &cache, now: 50, load: load)
        _ = try? JournalCrypto.resolveKey(failures: &cache, now: 10, load: load)
        #expect(calls == 2)
        #expect(JournalCrypto.keyFailureRetryInterval > 0 && JournalCrypto.keyFailureRetryInterval <= 10)
    }
}

// MARK: - DATA-7

@Suite("Data: decrypted copies stay out of the shared temp folder (DATA-7)", .serialized)
@MainActor
struct DataHardeningTempFileTests {
    init() { MASDataTestEnv.ensureIsolated() }

    /// Source of a file in this package (`Tests/OmegaJournalTests/x.swift` → `Sources/…`).
    static func packageSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The body of `func <name>(` up to the next top-level member.
    static func functionBody(_ source: String, _ signature: String) -> String? {
        guard let start = source.range(of: signature) else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ") ?? rest.range(of: "\n    @discardableResult") ?? rest.range(of: "\n}")
        return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
    }

    @Test("an .ojenc import decodes the decrypted JSON in memory, never via a temp file")
    func ojencImportInMemory() throws {
        let (root, _, db) = DataHardeningEnv.tempDB("ojenc")
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = JournalViewModel(database: db)
        var e = JournalEntry.new()
        e.title = "Exported"
        e.body = "kangaroosecretomega"
        let file = root.appendingPathComponent("export.ojenc")
        try ExportManager.exportEncrypted([e], to: file, passphrase: "correct horse", iterations: 1_000)
        #expect(vm.importEncryptedExport(from: file, passphrase: "correct horse") == 1)
        #expect(db.fetchEntry(id: e.id)?.body == "kangaroosecretomega")
        #expect(vm.importEncryptedExport(from: file, passphrase: "wrong") == 0)
        // The in-memory entry point the .ojenc path uses: plain bytes in, no URL.
        var other = JournalEntry.new()
        other.title = "From bytes"
        let json = try ExportManager.jsonData([other], db: db)
        #expect(vm.importJSON(data: json) == 1)
        #expect(db.fetchEntry(id: other.id)?.title == "From bytes")
        #expect(vm.importJSON(data: json) == 0)   // ids are never overwritten
        // Guard: the decrypted export (every body, hidden ones too) must not be
        // staged as a plaintext file a crash would leave in the temp folder.
        let source = try Self.packageSource("Sources/OmegaJournal/Data/ImportService.swift")
        let body = try #require(Self.functionBody(source, "func importEncryptedExport("))
        #expect(!body.contains("temporaryDirectory") && !body.contains(".write(to:"))
    }

    @Test("verifying a backup stages its decrypted copy next to the journal and removes it")
    func verifyBackupStagesNextToJournal() throws {
        let (root, _, db) = DataHardeningEnv.tempDB("verify")
        defer { try? FileManager.default.removeItem(at: root) }
        var e = JournalEntry.new()
        e.body = "verify me"
        #expect(db.saveEntry(e))
        let backup = try #require(db.backupNow())
        let staging = db.backupVerificationStagingURL()
        #expect(staging.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(staging.lastPathComponent.hasPrefix(DatabaseManager.verifyStagingPrefix))
        let result = try db.verifyBackup(at: backup)
        #expect(result.entryCount == 1)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(!leftovers.contains { $0.hasPrefix(DatabaseManager.verifyStagingPrefix) })
        // Guard: verifyBackup uses that seam, not the shared system temp folder.
        let source = try Self.packageSource("Sources/OmegaJournal/Data/BackupFolder.swift")
        let body = try #require(Self.functionBody(source, "func verifyBackup("))
        #expect(body.contains("backupVerificationStagingURL()"))
        #expect(!body.contains("temporaryDirectory"))
    }

    @Test("crash leftovers of decrypted copies are swept: system temp names and journal-folder staging files")
    func crashSweepCoversAllPrefixes() throws {
        let dir = MASDataTestEnv.tempDir("auditfix-data-sweep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let uuid = UUID().uuidString
        let legacy = ["omega-open-\(uuid)-photo.jpg", "ojimport-\(uuid).json",
                      "verify-\(uuid).sqlite3", "verify-\(uuid).sqlite3-wal", "verify-\(uuid).sqlite3-shm"]
        let unrelated = ["ojimport-notes.json", "verify-report.sqlite3", "other-app.json"]
        for n in legacy + unrelated { fm.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data("x".utf8)) }
        JournalCrypto.removeLegacyDecryptedFiles(in: dir)
        let left = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        #expect(left == Set(unrelated))

        // Journal-folder staging copies: old ones go, fresh ones (a live
        // operation in another process) and the journal itself stay.
        let journalDir = MASDataTestEnv.tempDir("auditfix-data-staging")
        defer { try? FileManager.default.removeItem(at: journalDir) }
        let old = Date().addingTimeInterval(-3600)
        let stale = ["restore-staging-\(uuid).sqlite3", "verify-staging-\(uuid).sqlite3-wal"]
        for n in stale {
            let path = journalDir.appendingPathComponent(n).path
            fm.createFile(atPath: path, contents: Data("x".utf8))
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        let importDir = journalDir.appendingPathComponent("import-staging-\(uuid)", isDirectory: true)
        try fm.createDirectory(at: importDir, withIntermediateDirectories: true)
        fm.createFile(atPath: importDir.appendingPathComponent("omega_journal.sqlite3").path, contents: Data("x".utf8))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: importDir.path)
        let fresh = "verify-staging-\(UUID().uuidString).sqlite3"
        fm.createFile(atPath: journalDir.appendingPathComponent(fresh).path, contents: Data("x".utf8))
        fm.createFile(atPath: journalDir.appendingPathComponent("omega_journal.sqlite3").path, contents: Data("x".utf8))
        let removed = DatabaseManager.removeStagingLeftovers(in: journalDir)
        #expect(Set(removed) == Set(stale + [importDir.lastPathComponent]))
        let remaining = Set((try? fm.contentsOfDirectory(atPath: journalDir.path)) ?? [])
        #expect(remaining == [fresh, "omega_journal.sqlite3"])
    }
}
