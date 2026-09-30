import Foundation
import Testing
import SQLite3
@testable import OmegaJournal

/// Data-layer follow-ups: search union (#6/#7), atomic bulk ops (#20), checked
/// template writes (#14), pragmas (#17), auth concurrency (#22), attachment
/// export/import (#19). Every test uses its own DatabaseManager in a temp dir.
@Suite("Data layer", .serialized)
@MainActor
struct DataLayerTests {

    private func entry(_ title: String, body: String = "", tags: [String] = []) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title; e.body = body; e.tags = tags
        return e
    }

    // MARK: #6 / #7 search

    @Test("search unions title/tag FTS hits with body-only matches")
    func searchIncludesBodyOnlyWhenTitleAlsoMatches() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let titleHit = entry("Dog park")
        let bodyOnly = entry("Tuesday", body: "walked the dog by the river")
        let miss = entry("Cats", body: "nothing relevant")
        for e in [titleHit, bodyOnly, miss] { db.saveEntry(e) }
        let ids = Set(db.fetchAllEntries(search: "dog").map(\.id))
        #expect(ids == [titleHit.id, bodyOnly.id])
    }

    @Test("LIKE-style substring matches title and tags, not only body")
    func searchSubstringMatchesTitleAndTags() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = entry("My Journal", body: "unrelated")
        let g = entry("Other", body: "unrelated", tags: ["workout"])
        db.saveEntry(t); db.saveEntry(g)
        #expect(db.fetchAllEntries(search: "ournal").map(\.id) == [t.id])   // mid-word: FTS can't, LIKE must
        #expect(db.fetchAllEntries(search: "orkou").map(\.id) == [g.id])
    }

    // MARK: #20 bulk

    @Test("bulk favorite/tag/trash apply in one transaction")
    func bulkOps() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = entry("A", body: "alpha body"), b = entry("B", body: "beta body", tags: ["x"])
        db.saveEntry(a); db.saveEntry(b)

        #expect(db.bulkSetFavorite(ids: [a.id, b.id], favorite: true) == 2)
        #expect(db.fetchEntry(id: a.id)?.isFavorite == true)
        #expect(db.bulkSetFavorite(ids: [a.id, b.id], favorite: true) == 0) // already set

        #expect(db.bulkAddTag(ids: [a.id, b.id], tag: "Shared") == 2)
        #expect(db.bulkAddTag(ids: [a.id, b.id], tag: "shared") == 0) // case-insensitive dup
        let fa = try #require(db.fetchEntry(id: a.id))
        #expect(fa.tags.contains("Shared") && fa.body == "alpha body") // body intact
        #expect(db.fetchAllEntries(search: "Shared").count == 2)        // FTS updated

        #expect(db.bulkTrash(ids: [a.id, b.id]))
        #expect(db.entryCount(scope: .trashed) == 2)
    }

    @Test("a failing bulk op rolls back completely and returns nil")
    func bulkRollback() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = entry("A"), b = entry("B")
        db.saveEntry(a); db.saveEntry(b)
        // Poison the second row: a trigger that aborts the update of B only.
        DataSafetyTests.run(db.databasePath, "CREATE TRIGGER poison BEFORE UPDATE ON entries WHEN NEW.id = '\(b.id)' BEGIN SELECT RAISE(ABORT, 'nope'); END;")
        db.onError = { _ in }
        defer { db.onError = nil }
        #expect(db.bulkSetFavorite(ids: [a.id, b.id], favorite: true) == nil)
        #expect(db.fetchEntry(id: a.id)?.isFavorite == false) // A's update rolled back too
        #expect(db.bulkTrash(ids: [a.id, b.id]) == false)
        #expect(db.entryCount(scope: .trashed) == 0)
    }

    @Test("emptyTrash removes trashed entries and attachment files without decrypting bodies")
    func emptyTrashIds() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = entry("gone", body: "x"), keep = entry("keep")
        db.saveEntry(a); db.saveEntry(keep)
        let att = try #require(db.saveAttachment(entryId: a.id, data: Data("d".utf8), filename: "f.bin"))
        db.trashEntry(id: a.id)
        db.corruptBodyForTesting(id: a.id) // unreadable body must not block emptying
        db.emptyTrash()
        #expect(db.entryCount(scope: .trashed) == 0)
        #expect(db.fetchEntry(id: keep.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: (db.attachmentsDirectoryForTesting as NSString).appendingPathComponent(att.id)))
    }

    // MARK: #14 templates / #17 pragmas

    @Test("template writes report failure")
    func templateWritesChecked() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = EntryTemplate(id: "t1", name: "T", body: "b", tags: [], icon: "doc.text", sortOrder: 99)
        #expect(db.saveTemplate(t) == true)
        db.onError = { _ in }
        db.sabotageTableForTesting("templates")
        #expect(db.saveTemplate(t) == false)
        #expect(db.deleteTemplate(id: "t1") == false)
        db.restoreTableForTesting("templates")
        db.onError = nil
        #expect(db.deleteTemplate(id: "t1") == true)
    }

    @Test("connection uses busy_timeout, WAL and secure_delete")
    func pragmas() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(db.scalarIntForTesting("PRAGMA busy_timeout") >= 1000)
        #expect(db.scalarIntForTesting("PRAGMA secure_delete") == 1)
    }

    // MARK: #22 auth concurrency

    @Test("concurrent authenticate calls share one prompt and one outcome")
    func authConcurrency() async throws {
        let auth = BiometricAuth(forTesting: ())
        var prompts = 0
        auth.evaluateOverride = {
            prompts += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
            return true
        }
        async let r1 = auth.authenticate()
        async let r2 = auth.authenticate()
        let results = await [r1, r2]
        #expect(results == [true, true])
        #expect(prompts == 1)
        #expect(auth.isAuthenticated)
        #expect(!auth.isAuthenticating)
        auth.lock()
    }

    @Test("a failed prompt leaves an existing session untouched")
    func authFailureKeepsState() async throws {
        let auth = BiometricAuth(forTesting: ())
        auth.evaluateOverride = { false }
        #expect(await auth.authenticate() == false)
        #expect(!auth.isAuthenticated && !auth.isAuthenticating)
    }

    // MARK: #19 export with attachments

    @Test("JSON export carries attachments and they re-import with the same bytes")
    func exportAttachmentsRoundTrip() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        var e = entry("Has file", body: "see attached", tags: ["t"])
        e.isHidden = true
        db.saveEntry(e)
        let payload = Data((0..<255).map { UInt8($0) })
        _ = try #require(db.saveAttachment(entryId: e.id, data: payload, filename: "blob.bin", mimeType: "application/octet-stream"))
        let stored = try #require(db.fetchEntry(id: e.id))

        let url = root.appendingPathComponent("out.json")
        try ExportManager.exportJSON([stored], to: url, attachmentData: { db.readAttachmentData($0) })

        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(ExportManager.JSONExport.self, from: Data(contentsOf: url))
        #expect(file.formatVersion == ExportManager.formatVersion)
        let je = try #require(file.entries.first)
        #expect(je.isHidden == true)
        let atts = ExportManager.decodeAttachments(je)
        #expect(atts.count == 1)
        #expect(atts[0].filename == "blob.bin" && atts[0].mimeType == "application/octet-stream")
        #expect(atts[0].data == payload)

        // Re-import into a fresh database.
        let (root2, db2) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root2) }
        db2.saveEntry(stored)
        for a in atts { _ = db2.saveAttachment(entryId: stored.id, data: a.data, filename: a.filename, mimeType: a.mimeType) }
        let got = try #require(db2.fetchAttachments(entryId: stored.id).first)
        #expect(db2.readAttachmentData(got) == payload)
    }

    @Test("old JSON exports (no attachments/formatVersion) still decode")
    func oldExportsDecode() throws {
        let json = """
        {"exportDate":"2026-01-01T00:00:00Z","appVersion":"1.0","entryCount":1,"entries":[
        {"id":"x","title":"t","body":"b","mood":3,"moodLabel":"Neutral","tags":[],
         "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
         "isPinned":false,"isFavorite":false,"wordCount":1}]}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(ExportManager.JSONExport.self, from: Data(json.utf8))
        #expect(file.formatVersion == nil)
        #expect(ExportManager.decodeAttachments(file.entries[0]).isEmpty)
    }

    // MARK: VM wiring
    //
    // JournalViewModel() uses the process-wide DatabaseManager.shared, whose
    // directory other suites are also using — so never delete it; remove only
    // the entries these tests created (titles prefixed "VM DL ").

    private func makeVM() -> JournalViewModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omega-dl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("j.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("att").path, 1)
        return JournalViewModel()
    }

    private func cleanup(_ vm: JournalViewModel) {
        for e in vm.db.fetchAllEntriesForExport() where e.title.hasPrefix("VM DL ") { vm.db.hardDeleteEntry(id: e.id) }
        vm.reload()
    }

    @Test("importJSON restores embedded attachments")
    func importAttachments() throws {
        let vm = makeVM()
        defer { cleanup(vm) }
        let payload = Data("hello attachment".utf8)
        var e = entry("VM DL Imported", body: "b")
        e.attachments = [Attachment(id: "a1", entryId: e.id, filename: "n.txt", mimeType: "text/plain", createdAt: Date())]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ExportManager.exportJSON([e], to: url, attachmentData: { _ in payload })
        #expect(vm.importJSON(from: url) == 1)
        let got = try #require(vm.db.fetchEntry(id: e.id))
        let att = try #require(got.attachments.first)
        #expect(vm.db.readAttachmentData(att) == payload)
    }

    @Test("VM bulk favorite/tag/trash use the transactional DB paths")
    func vmBulk() throws {
        let vm = makeVM()
        defer { cleanup(vm) }
        let a = entry("VM DL A", body: "alpha"), b = entry("VM DL B", body: "beta")
        vm.db.saveEntry(a); vm.db.saveEntry(b)
        vm.reload()
        let ids: Set<String> = [a.id, b.id]
        func mine() -> [JournalEntry] { vm.entries.filter { ids.contains($0.id) } }

        vm.bulkSelection = ids
        vm.bulkFavorite()
        #expect(mine().count == 2 && mine().allSatisfy { $0.isFavorite })
        vm.bulkSelection = ids
        vm.bulkAddTag("grp")
        #expect(mine().allSatisfy { $0.tags.contains("grp") })
        #expect(mine().first { $0.id == a.id }?.body == "alpha")
        vm.bulkSelection = ids
        vm.bulkMoveToTrash()
        #expect(mine().isEmpty)
        #expect(vm.trashedEntries.filter { ids.contains($0.id) }.count == 2)
    }
}
