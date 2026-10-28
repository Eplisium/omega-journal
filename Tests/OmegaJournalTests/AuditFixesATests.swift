import Darwin
import Foundation
import SQLite3
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// Regression tests for audit group A (data / import / export / backup).
/// Hermetic tests use their own `DatabaseManager(databasePath:attachmentsPath:)`;
/// VM tests share `DatabaseManager.shared` (temp paths via env) and only clean up
/// entries they created (title prefix "AFA ").
@Suite("Audit fixes A — data/import/export/backup", .serialized)
@MainActor
struct AuditFixesATests {

    // MARK: Helpers

    static func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-afa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Env-based isolation for the shared singleton (ephemeral key, no Keychain).
    static func isolate() {
        unsetenv("DATABASE_URL")
        if ProcessInfo.processInfo.environment["OMEGA_JOURNAL_TEST_DATABASE_PATH"]?.isEmpty ?? true {
            let root = tempRoot()
            setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
            setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
        }
    }

    static func makeDB() -> (root: URL, db: DatabaseManager) {
        isolate()
        let root = tempRoot()
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("attachments").path)
        return (root, db)
    }

    private func cleanup(_ vm: JournalViewModel) {
        for e in vm.db.fetchAllEntriesForExport() where e.title.hasPrefix("AFA ") {
            vm.db.hardDeleteEntry(id: e.id)
        }
        vm.reload()
    }

    private func entry(_ title: String, body: String = "", journalId: String = JournalDefaults.defaultJournalId) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title; e.body = body; e.journalId = journalId
        return e
    }

    // MARK: 1 — attachment path traversal

    @Test("saveAttachment cannot escape its directory via ../ filenames")
    func attachmentTraversalOnSave() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = entry("AFA traversal")
        #expect(db.saveEntry(e))
        let dbFile = root.appendingPathComponent("j.sqlite3")
        let payload = Data("pwned".utf8)
        let att = db.saveAttachment(entryId: e.id, data: payload, filename: "../../j.sqlite3")
        let header = try Data(contentsOf: dbFile).prefix(15)
        #expect(header == Data("SQLite format 3".utf8), "live database was overwritten")
        #expect(att?.filename == "j.sqlite3")
        if let att {
            #expect(db.readAttachmentData(att) == payload)
            let onDisk = root.appendingPathComponent("attachments/\(att.id)/j.sqlite3")
            #expect(FileManager.default.fileExists(atPath: onDisk.path))
        }
        for bad in ["..", ".", "", "/", "a/b:c"] {
            let name = DatabaseManager.sanitizedAttachmentFilename(bad)
            #expect(!name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":"))
        }
        #expect(DatabaseManager.sanitizedAttachmentFilename("..") == "attachment")
        #expect(DatabaseManager.sanitizedAttachmentFilename("") == "attachment")
    }

    @Test("reading a malicious existing attachment row is refused")
    func attachmentTraversalOnRead() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("secret.bin")
        try JournalCrypto.writeEncrypted(Data("secret".utf8), to: secret)
        let evilDir = UUID().uuidString
        try FileManager.default.createDirectory(at: root.appendingPathComponent("attachments/\(evilDir)"), withIntermediateDirectories: true)
        let evil = Attachment(id: evilDir, entryId: "x", filename: "../../secret.bin", mimeType: "", createdAt: Date())
        #expect(db.readAttachmentData(evil) == nil)
        #expect(db.openAttachmentExternally(evil) == nil)
        let evilId = Attachment(id: "..", entryId: "x", filename: "secret.bin", mimeType: "", createdAt: Date())
        #expect(db.readAttachmentData(evilId) == nil)
    }

    @Test("JSON import with a ../ attachment filename stays inside attachments")
    func jsonImportTraversal() throws {
        Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        let marker = "afa-evil-\(UUID().uuidString).txt"
        let attachmentsDir = URL(fileURLWithPath: vm.db.attachmentsDir)
        let json = """
        {"formatVersion":6,"exportDate":"2026-01-01T00:00:00Z","appVersion":"t","entryCount":1,"entries":[
         {"id":"\(UUID().uuidString)","title":"AFA evil import","body":"b","mood":3,"moodLabel":"Okay","tags":[],
          "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","isPinned":false,"isFavorite":false,
          "wordCount":1,"attachments":[{"filename":"../../\(marker)","mimeType":"text/plain","dataBase64":"\(Data("x".utf8).base64EncodedString())"}]}]}
        """
        let file = Self.tempRoot().appendingPathComponent("evil.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        #expect(vm.importJSON(from: file) == 1)
        let escaped = attachmentsDir.deletingLastPathComponent().appendingPathComponent(marker)
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        let imported = vm.db.fetchAllEntriesForExport().first { $0.title == "AFA evil import" }
        #expect(imported?.attachments.first?.filename == marker)
    }

    // MARK: 2 — pre-migration snapshot pruning

    @Test("pruning keeps the newest snapshots even when v10 sorts before v9 as text")
    func preMigrationPruneOrder() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("prune", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["pre-migration_v9_2026-01-01_10-00-00-000.sqlite3",
                     "pre-migration_v9_2026-01-02_10-00-00-000.sqlite3",
                     "pre-migration_v9_2026-01-03_10-00-00-000.sqlite3",
                     "pre-migration_v10_2026-01-04_10-00-00-000.sqlite3"]
        for (i, n) in names.enumerated() {
            let u = dir.appendingPathComponent(n)
            try Data("x".utf8).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 100)], ofItemAtPath: u.path)
        }
        db.cleanupOldBackups(in: dir, prefix: "pre-migration_", keep: 3)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left.contains(names[3]), "the just-taken v10 snapshot was pruned")
        #expect(!left.contains(names[0]))
        #expect(left.count == 3)
    }

    // MARK: 3 — Day One traversal

    @Test("Day One parser rejects non-hex md5 / odd type in photo paths")
    func dayOneParserSanitizes() throws {
        let json = """
        {"entries":[{"uuid":"U1","creationDate":"2026-01-01T00:00:00Z","text":"Hi",
          "photos":[{"md5":"../../etc/passwd","type":"jpeg"},{"md5":"abc","type":"png/../../x"},{"md5":"DEADbeef","type":"png"}]}]}
        """
        let r = try ImportParsers.parseDayOneJSON(Data(json.utf8))
        #expect(r.entries.first?.attachmentPaths == ["photos/DEADbeef.png"])
    }

    @Test("importRecords refuses attachment paths that resolve outside the import root")
    func importRecordsContainment() throws {
        Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        let parent = Self.tempRoot()
        let root = parent.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: parent.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"),
                                                   withDestinationURL: parent.appendingPathComponent("outside.png"))
        try Data("inside".utf8).write(to: root.appendingPathComponent("inside.png"))
        let rec = ImportedEntry(title: "AFA contain", body: "b", createdAt: Date(timeIntervalSince1970: 1_600_000_123),
                                attachmentPaths: ["../outside.png", "link.png", "inside.png"])
        let report = vm.importRecords([rec], attachmentRoot: root, extraTag: "afa")
        #expect(report.added == 1)
        #expect(report.attachments == 1)
    }

    // MARK: 4 — full export covers every notebook

    @Test("full export entries include every notebook, archived and trashed")
    func fullExportAllNotebooks() throws {
        Self.isolate()
        let vm = JournalViewModel()
        guard let j = vm.db.createJournal(name: "AFA nb \(UUID().uuidString.prefix(6))") else { Issue.record("no journal"); return }
        defer { vm.db.deleteJournal(id: j.id); vm.activeJournalId = nil; cleanup(vm) }
        let a = entry("AFA default nb")
        var b = entry("AFA other nb", journalId: j.id); b.isArchived = true
        var c = entry("AFA trashed other", journalId: j.id); c.deletedAt = Date()
        #expect(vm.db.saveEntry(a) && vm.db.saveEntry(b) && vm.db.saveEntry(c))
        vm.activeJournalId = JournalDefaults.defaultJournalId
        vm.reload()
        let ids = Set(ImportExportPanels.fullExportEntries(vm: vm).map(\.id))
        #expect(ids.isSuperset(of: [a.id, b.id, c.id]))
    }

    // MARK: 5 — restore refreshes organization state

    @Test("reloadAfterRestore refreshes journals, templates and drops a vanished active journal")
    func reloadAfterRestore() throws {
        Self.isolate()
        let vm = JournalViewModel()
        guard let j = vm.db.createJournal(name: "AFA restored \(UUID().uuidString.prefix(6))") else { Issue.record("no journal"); return }
        let t = EntryTemplate(name: "AFA template", body: "x")
        _ = vm.db.saveTemplate(t)
        defer { vm.db.deleteJournal(id: j.id); _ = vm.db.deleteTemplate(id: t.id); vm.activeJournalId = nil; cleanup(vm) }
        vm.activeJournalId = "gone-\(UUID().uuidString)"
        vm.reloadAfterRestore()
        #expect(vm.journals.contains { $0.id == j.id })
        #expect(vm.templates.contains { $0.id == t.id })
        #expect(vm.activeJournalId == nil || vm.journals.contains { $0.id == vm.activeJournalId })
    }

    // MARK: 6 — journal ids with punctuation

    @Test("journal filtering works for ids containing dots and quotes")
    func journalIdPunctuation() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        for jid in ["travel.2025", "o'brien"] {
            #expect(db.ensureJournal(id: jid, name: jid) == jid)
            var e = entry("AFA \(jid) zebra", body: "body")
            e.journalId = jid
            e.tags = ["t-\(jid.count)"]
            #expect(db.saveEntry(e))
            #expect(db.fetchAllEntries(scope: .active, journalId: jid).map(\.id) == [e.id])
            #expect(db.fetchAllEntries(search: "zebra", scope: .active, journalId: jid).map(\.id) == [e.id])
            #expect(db.entryCount(scope: .active, journalId: jid) == 1)
            #expect(db.fetchScopes([(.active, .dateDesc)], journalId: jid)[.active]?.map(\.id) == [e.id])
            #expect(db.fullTextSearch("zebra", scope: .active, journalId: jid).map(\.id) == [e.id])
            #expect(db.tagsWithCounts(journalId: jid).map(\.tag) == ["t-\(jid.count)"])
        }
    }

    // MARK: 7 — markdown folder re-import is idempotent

    @Test("front matter dates keep fractional seconds")
    func fractionalDates() {
        let d = Date(timeIntervalSince1970: 1_700_000_000.789)
        let ex = ExportableEntry(id: "x", title: "T", body: "b", mood: 3, moodLabel: "Okay", tags: [], createdAt: d, updatedAt: d)
        let parsed = ImportParsers.parseMarkdownNote(text: ExportFormats.markdownWithFrontMatter(ex), fallbackTitle: "f", fallbackDate: .distantPast)
        #expect(abs(parsed.createdAt.timeIntervalSince1970 - d.timeIntervalSince1970) < 0.002)
        #expect(ImportParsers.parseDate("2026-01-01T00:00:00Z") != nil)
        #expect(JournalViewModel.dupKey(title: "a", createdAt: Date(timeIntervalSince1970: 100.9))
                == JournalViewModel.dupKey(title: "a", createdAt: Date(timeIntervalSince1970: 100.0)))
    }

    @Test("exporting then re-importing a markdown folder adds nothing")
    func markdownFolderReimportIdempotent() throws {
        Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        var e = entry("AFA reimport", body: "hello")
        e.createdAt = Date(timeIntervalSince1970: 1_650_000_000.456)
        e.updatedAt = e.createdAt
        #expect(vm.db.saveEntry(e))
        let dir = Self.tempRoot().appendingPathComponent("md", isDirectory: true)
        try ExportManager.exportMarkdownFolder([e], to: dir)
        let report = vm.importNotesFolder(from: dir)
        #expect(report.added == 0)
        #expect(report.duplicates == 1)

        // A note whose front-matter id matches an existing (even trashed) entry is skipped.
        vm.db.trashEntry(id: e.id)
        let other = Self.tempRoot()
        try "---\nid: \(e.id)\ntitle: \"AFA renamed\"\ndate: 2001-01-01T00:00:00Z\n---\n\nx\n"
            .write(to: other.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
        let r2 = vm.importNotesFolder(from: other)
        #expect(r2.added == 0)
        #expect(r2.duplicates == 1)
    }

    // MARK: 8 — markdown folder export keeps attachments + links

    @Test("front-matter attachments list becomes attachmentPaths")
    func frontMatterAttachments() {
        let text = "---\ntitle: \"T\"\nattachments:\n  - attachments/abc-a.png\n---\n\nbody\n"
        let r = ImportParsers.parseMarkdownNote(text: text, fallbackTitle: "f", fallbackDate: Date())
        #expect(r.attachmentPaths == ["attachments/abc-a.png"])
    }

    @Test("markdown folder round trip keeps both same-named attachments and inline links")
    func markdownFolderAttachmentsRoundTrip() throws {
        Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        var e = entry("AFA attach rt")
        e.createdAt = Date(timeIntervalSince1970: 1_640_000_000)
        e.updatedAt = e.createdAt
        e.body = "Look:\n" + ImageRefs.markdown(alt: "", filename: "a b.png", width: 240) + "\nend"
        #expect(vm.db.saveEntry(e))
        let a1 = vm.db.saveAttachment(entryId: e.id, data: Data("one".utf8), filename: "a b.png", mimeType: "image/png")
        let a2 = vm.db.saveAttachment(entryId: e.id, data: Data("two".utf8), filename: "a b.png", mimeType: "image/png")
        #expect(a1 != nil && a2 != nil)
        guard let stored = vm.db.fetchEntry(id: e.id) else { Issue.record("missing"); return }
        let dir = Self.tempRoot().appendingPathComponent("md", isDirectory: true)
        try ExportManager.exportMarkdownFolder([stored], to: dir, attachmentData: { vm.db.readAttachmentData($0) })
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("attachments").path)
        #expect(files.count == 2)
        let mdName = try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasSuffix(".md") }!
        let md = try String(contentsOf: dir.appendingPathComponent(mdName), encoding: .utf8)
        #expect(!md.contains("omega-attachment://"))
        #expect(md.contains("](attachments/"))

        vm.db.hardDeleteEntry(id: e.id)
        let report = vm.importNotesFolder(from: dir)
        #expect(report.added == 1)
        #expect(report.attachments == 2)
        guard let back = vm.db.fetchAllEntriesForExport().first(where: { $0.title == "AFA attach rt" }) else {
            Issue.record("not reimported"); return
        }
        let refs = ImageRefs.refs(in: back.body)
        #expect(refs.count == 1)
        #expect(refs.first?.width == 240)
        if let name = refs.first?.filename {
            #expect(back.attachments.contains { $0.filename == name })
        }
        let datas = Set(back.attachments.compactMap { vm.db.readAttachmentData($0) })
        #expect(datas == [Data("one".utf8), Data("two".utf8)])
    }

    // MARK: 9 — .ojenc keeps revisions

    @Test("encrypted export carries revisions")
    func encryptedExportRevisions() throws {
        Self.isolate()
        let e = entry("AFA ojenc", body: "now")
        let rev = ExportManager.JSONRevision(createdAt: Date(timeIntervalSince1970: 1_600_000_000), title: "old", body: "then", isAuto: false)
        let url = Self.tempRoot().appendingPathComponent("x.ojenc")
        try ExportManager.exportEncrypted([e], to: url, passphrase: "passphrase!", attachmentData: nil,
                                          revisionData: { _ in [rev] }, iterations: 1_000)
        let plain = try PassphraseVault.open(Data(contentsOf: url), passphrase: "passphrase!")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let export = try dec.decode(ExportManager.JSONExport.self, from: plain)
        #expect(export.entries.first?.revisions == [rev])
    }

    // MARK: 10 / 11 — front matter escaping, empty title

    @Test("backslashes and quotes round-trip through front matter")
    func backslashRoundTrip() {
        let title = #"C:\path\to "x" \\ end"#
        let ex = ExportableEntry(id: "x", title: title, body: "b", mood: 3, moodLabel: "Okay", tags: [],
                                 createdAt: Date(), updatedAt: Date())
        let parsed = ImportParsers.parseMarkdownNote(text: ExportFormats.markdownWithFrontMatter(ex), fallbackTitle: "f", fallbackDate: Date())
        #expect(parsed.title == title)
    }

    @Test("untitled entry whose body starts with a heading keeps the heading")
    func emptyTitleKeepsHeading() {
        let ex = ExportableEntry(id: "x", title: "", body: "# Heading\nmore", mood: 3, moodLabel: "Okay", tags: [],
                                 createdAt: Date(), updatedAt: Date())
        let parsed = ImportParsers.parseMarkdownNote(text: ExportFormats.markdownWithFrontMatter(ex), fallbackTitle: "file", fallbackDate: Date())
        #expect(parsed.title == "")
        #expect(parsed.body.hasPrefix("# Heading\nmore"))
    }

    // MARK: 12 — single-file markdown import, CRLF

    @Test("parseMarkdownImport strips CR from CRLF files")
    func crlfMarkdownImport() {
        let p = OmegaCore.parseMarkdownImport(text: "# Title\r\nLine one\r\nLine two\r\n", fallbackTitle: "f")
        #expect(p.title == "Title")
        #expect(p.body == "Line one\nLine two")
        let d = try? ImportParsers.parseDayOneJSON(Data(#"{"entries":[{"creationDate":"2026-01-01T00:00:00Z","text":"T\r\n\r\nA\r\nB"}]}"#.utf8))
        #expect(d?.entries.first?.body.unicodeScalars.contains("\r") == false)
    }

    @Test("single .md import honors front matter and normalizes CRLF")
    func singleMarkdownFrontMatter() throws {
        Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        let file = Self.tempRoot().appendingPathComponent("note.md")
        let text = "---\r\ntitle: \"AFA single md\"\r\ndate: 2020-01-02T03:04:05Z\r\nmood: 5\r\ntags:\r\n  - afa-x\r\n---\r\n\r\nHello\r\nWorld\r\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        #expect(vm.importMarkdown(from: [file]) == 1)
        guard let e = vm.db.fetchAllEntriesForExport().first(where: { $0.title == "AFA single md" }) else {
            Issue.record("front-matter title not honored"); return
        }
        #expect(e.createdAt == Date(timeIntervalSince1970: 1_577_934_245))
        #expect(e.mood.rawValue == 5)
        #expect(e.tags.contains("afa-x"))
        #expect(e.body == "Hello\nWorld")
    }

    @Test("JSON import normalizes CRLF bodies")
    func jsonImportCRLF() throws {
        Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        var e = entry("AFA crlf json", body: "a\r\nb")
        e.createdAt = Date(timeIntervalSince1970: 1_610_000_000)
        let file = Self.tempRoot().appendingPathComponent("c.json")
        try ExportManager.exportJSON([e], to: file)
        #expect(vm.importJSON(from: file) == 1)
        #expect(vm.db.fetchEntry(id: e.id)?.body == "a\nb")
    }

    // MARK: 13 — chosen backup folder == local backups dir

    @Test("mirroring into the local backups folder never deletes the fresh backup")
    func mirrorSameFolder() throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = db.setSetting(DatabaseManager.backupFolderKey, value: db.backupsDirectory.path + "/")
        let url = db.backupNow()
        #expect(url != nil)
        if let url { #expect(FileManager.default.fileExists(atPath: url.path)) }
        db.setChosenBackupFolder(nil)
        db.setChosenBackupFolder(db.backupsDirectory)
        #expect(db.chosenBackupFolder == nil)
    }

    // MARK: 14 — revision import failure rolls back

    @Test("a failed revision import rolls the JSON import back")
    func revisionFailureRollsBack() throws {
        Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        let e = entry("AFA rev fail", body: "x")
        let file = Self.tempRoot().appendingPathComponent("r.json")
        try ExportManager.exportJSON([e], to: file, revisionData: { _ in
            [ExportManager.JSONRevision(createdAt: Date(timeIntervalSince1970: 1), title: "t", body: "b", isAuto: true)]
        })
        vm.db.sabotageTableForTesting("entry_revisions")
        let added = vm.importJSON(from: file)
        vm.db.restoreTableForTesting("entry_revisions")
        #expect(added == 0)
        #expect(vm.db.fetchEntry(id: e.id) == nil)
    }
}
