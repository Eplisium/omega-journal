import Foundation
import SQLite3
import Testing
import OmegaJournalCore
@testable import OmegaJournal

@Suite("Writing: revisions DB, export, templates, stamp", .serialized)
@MainActor
struct WritingRevisionTests {
    private func entry(_ title: String, body: String, tags: [String] = []) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title; e.body = body; e.tags = tags
        return e
    }

    @Test("V10 creates entry_revisions and the schema is at least 10")
    func migrationCreatesTable() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(db.tableExists("entry_revisions"))
        #expect(db.getSchemaVersion() >= 10)
        #expect(db.migrateToV10())          // idempotent
    }

    @Test("snapshots skip unchanged text, coalesce bursts, and keep spaced ones")
    func snapshotPolicy() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        var e = entry("T", body: "first")
        db.saveEntry(e)
        let t0 = Date()
        #expect(db.snapshotRevision(of: e, now: t0) == .insert)
        #expect(db.snapshotRevision(of: e, now: t0.addingTimeInterval(5)) == .skip)
        e.body = "first and more"
        #expect(db.snapshotRevision(of: e, now: t0.addingTimeInterval(60)) == .replaceLatest)
        #expect(db.revisionCount(entryId: e.id) == 1)
        e.body = "much later text"
        #expect(db.snapshotRevision(of: e, now: t0.addingTimeInterval(3600)) == .insert)
        let revs = db.revisions(entryId: e.id)
        #expect(revs.count == 2)
        #expect(db.revisionBody(id: revs[0].id) == "much later text")
        #expect(db.revisionBody(id: revs[1].id) == "first and more")
        // Empty bodies are never snapshotted.
        var blank = entry("Blank", body: "  ")
        db.saveEntry(blank)
        #expect(db.snapshotRevision(of: blank, now: t0) == .skip)
        blank.body = ""
        #expect(db.revisions(entryId: blank.id).isEmpty)
    }

    @Test("revision bodies are encrypted on disk and removed with their entry")
    func encryptedAndCascade() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "zebra-quartz-secret-\(UUID().uuidString)"
        let e = entry("Secret", body: secret)
        db.saveEntry(e)
        db.snapshotRevision(of: e)
        // Raw column must not contain the plaintext.
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(root.appendingPathComponent("j.sqlite3").path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(h) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(h, "SELECT body_enc FROM entry_revisions;", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        let n = Int(sqlite3_column_bytes(stmt, 0))
        let raw = Data(bytes: sqlite3_column_blob(stmt, 0), count: n)
        #expect(raw.range(of: Data(secret.utf8)) == nil)
        #expect(n > secret.utf8.count)

        db.hardDeleteEntry(id: e.id)
        #expect(db.revisionCount(entryId: e.id) == 0)
    }

    @Test("pruning removes ancient automatic revisions")
    func pruning() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = entry("P", body: "x")
        db.saveEntry(e)
        let now = Date()
        _ = db.importRevision(entryId: e.id, title: "P", body: "old", createdAt: now.addingTimeInterval(-500 * 86400), isAuto: true)
        _ = db.importRevision(entryId: e.id, title: "P", body: "recent", createdAt: now.addingTimeInterval(-3600), isAuto: true)
        db.pruneRevisions(entryId: e.id, now: now)
        let left = db.revisions(entryId: e.id)
        #expect(left.count == 1)
        #expect(db.revisionBody(id: left[0].id) == "recent")
    }

    @Test("JSON export includes revisions only when requested, and v5 files without them still decode")
    func exportRoundTrip() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = entry("R", body: "now")
        db.saveEntry(e)
        _ = db.importRevision(entryId: e.id, title: "R", body: "before", createdAt: Date(timeIntervalSince1970: 1_700_000_000), isAuto: false)
        let stored = try #require(db.fetchEntry(id: e.id))

        let plain = try ExportManager.jsonData([stored])
        let withRevs = try ExportManager.jsonData([stored], revisionData: { db.exportRevisions(for: $0) })
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        #expect(try dec.decode(ExportManager.JSONExport.self, from: plain).entries[0].revisions == nil)
        let file = try dec.decode(ExportManager.JSONExport.self, from: withRevs)
        #expect(file.formatVersion == ExportManager.formatVersion)
        let revs = try #require(file.entries[0].revisions)
        #expect(revs.count == 1 && revs[0].body == "before" && revs[0].isAuto == false)

        // Re-import into a fresh DB keeps timestamp + text.
        let (root2, db2) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root2) }
        db2.saveEntry(stored)
        for r in revs { #expect(db2.importRevision(entryId: stored.id, title: r.title, body: r.body, createdAt: r.createdAt, isAuto: r.isAuto ?? true)) }
        let got = try #require(db2.revisions(entryId: stored.id).first)
        #expect(got.createdAt == Date(timeIntervalSince1970: 1_700_000_000) && !got.isAuto)
        #expect(db2.revisionBody(id: got.id) == "before")

        // A v3-era file (no revisions key) decodes.
        let old = """
        {"exportDate":"2026-01-01T00:00:00Z","appVersion":"1","entryCount":1,"formatVersion":3,"entries":[
        {"id":"x","title":"t","body":"b","mood":3,"moodLabel":"Neutral","tags":[],"createdAt":"2026-01-01T00:00:00Z",
         "updatedAt":"2026-01-01T00:00:00Z","isPinned":false,"isFavorite":false,"wordCount":1,"isHidden":true}]}
        """
        let oldFile = try dec.decode(ExportManager.JSONExport.self, from: Data(old.utf8))
        #expect(oldFile.entries[0].revisions == nil && oldFile.entries[0].isHidden == true)
    }

    @Test("template save normalises default tags and reorder persists")
    func templateTagsAndOrder() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = EntryTemplate(id: "a", name: "A", body: "{{date}}", tags: [" #One", "one", "Two,Three"], sortOrder: 100)
        let b = EntryTemplate(id: "b", name: "B", body: "", tags: [], sortOrder: 101)
        db.saveTemplate(a); db.saveTemplate(b)
        #expect(db.templates().first { $0.id == "a" }?.tags == ["One", "Two", "Three"])
        db.reorderTemplates(ids: ["b", "a"])
        let ids = db.templates().map(\.id)
        #expect(ids.firstIndex(of: "b")! < ids.firstIndex(of: "a")!)
        db.deleteTemplate(id: "a"); db.deleteTemplate(id: "b")
    }

    @Test("stamp never leaks into previews")
    func stampHiddenFromPreview() {
        var e = JournalEntry.new()
        e.body = EntryStampCodec.join(stamp: EntryStamp(location: "Lisbon", weather: "sunny"), rest: "Hello world")
        #expect(e.preview == "Hello world")
    }

    @MainActor
    @Test("hidden entry revisions are gated while locked; restore keeps the old text as a kept version")
    func hiddenGatingAndRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omega-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
        let vm = JournalViewModel()
        var e = vm.createEntry(title: "H", body: "v1 text")
        defer { vm.db.hardDeleteEntry(id: e.id) }
        vm.snapshotRevision(of: e)
        let rev = try #require(vm.revisions(for: e).first)
        e.body = "v2 text, edited"
        e.updatedAt = Date()
        vm.db.saveEntry(e); vm.updateEntry(e)

        let restored = try #require(vm.restoreRevision(rev, for: e))
        #expect(restored.body == "v1 text")
        #expect(vm.db.fetchEntry(id: e.id)?.body == "v1 text")
        let revs = vm.revisions(for: e)
        #expect(revs.contains { !$0.isAuto })
        #expect(revs.contains { vm.db.revisionBody(id: $0.id) == "v2 text, edited" })

        // Hide it: while the session is locked nothing is readable or restorable.
        BiometricAuth.shared.lock()
        e.isHidden = true
        vm.db.saveEntry(e); vm.updateEntry(e)
        #expect(!vm.canViewRevisions(of: e))
        #expect(vm.revisions(for: e).isEmpty)
        #expect(vm.revisionBody(rev, for: e) == nil)
        #expect(vm.restoreRevision(rev, for: e) == nil)
    }
}
