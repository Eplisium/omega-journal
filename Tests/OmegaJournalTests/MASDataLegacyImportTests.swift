import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

/// "Import existing journal…" — every test uses private
/// `DatabaseManager(databasePath:attachmentsPath:)` instances in temp dirs, so
/// the shared singleton database (and the user's journal) is never touched.
@Suite("MAS data: import an existing journal folder", .serialized)
@MainActor
struct MASDataLegacyImportTests {
    init() { MASDataTestEnv.ensureIsolated() }

    static let dbName = "omega_journal.sqlite3"

    /// Builds an old journal folder with `count` entries, one attachment file
    /// and its automatic backup; the database is closed on return.
    static func makeSourceJournal(entries count: Int, corrupt: Bool = false) -> (folder: URL, ids: [String]) {
        let folder = MASDataTestEnv.tempDir("source").appendingPathComponent("OmegaJournal", isDirectory: true)
        var ids: [String] = []
        do {
            let db = DatabaseManager(databasePath: folder.appendingPathComponent(dbName).path,
                                     attachmentsPath: folder.appendingPathComponent("attachments").path)
            for i in 0..<count {
                var e = JournalEntry.new()
                e.title = "Old entry \(i)"
                e.body = "secret body \(i)"
                _ = db.saveEntry(e)
                ids.append(e.id)
                if corrupt { db.corruptBodyForTesting(id: e.id) } // simulates another Mac's key
            }
        }
        try? Data("sealed-attachment".utf8).write(to: folder.appendingPathComponent("attachments/att-1.bin"))
        return (folder, ids)
    }

    static func makeTarget() -> (root: URL, db: DatabaseManager) {
        let root = MASDataTestEnv.tempDir("target")
        let db = DatabaseManager(databasePath: root.appendingPathComponent(dbName).path,
                                 attachmentsPath: root.appendingPathComponent("attachments").path)
        return (root, db)
    }

    static func cleanup(_ urls: URL...) {
        for u in urls { try? FileManager.default.removeItem(at: u) }
    }

    static func isolatedDefaults() -> UserDefaults {
        let name = "MASDataLegacyImportTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("success: entries, attachments and backups land in the empty journal and decrypt")
    func success() throws {
        let (source, ids) = Self.makeSourceJournal(entries: 3)
        let (root, db) = Self.makeTarget()
        defer { Self.cleanup(source.deletingLastPathComponent(), root) }
        let sourceBytes = try Data(contentsOf: source.appendingPathComponent(Self.dbName))

        let vm = JournalViewModel(database: db)
        #expect(vm.entries.isEmpty)
        let defaults = Self.isolatedDefaults()
        #expect(vm.importLegacyJournal(from: source, defaults: defaults))

        #expect(vm.entries.count == 3)
        #expect(Set(vm.entries.map(\.id)) == Set(ids))
        for id in ids {
            let e = try #require(db.fetchEntry(id: id))
            #expect(e.body.hasPrefix("secret body"))
            #expect(!db.isEntryUnreadable(id))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("attachments/att-1.bin").path))
        let importedBackups = try FileManager.default.contentsOfDirectory(atPath: source.appendingPathComponent("backups").path)
        let targetBackups = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path)
        #expect(!importedBackups.isEmpty)
        #expect(Set(importedBackups).isSubset(of: Set(targetBackups)))
        // No leftovers from the swap.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("pre-import") || $0.hasPrefix("import-staging") }
        #expect(leftovers.isEmpty)
        // The source folder is only read.
        #expect(try Data(contentsOf: source.appendingPathComponent(Self.dbName)) == sourceBytes)
        // The one-time offer is now handled.
        #expect(defaults.bool(forKey: MASDataLegacyImportOffer.dismissedDefaultsKey))
        #expect(!vm.shouldOfferLegacyImport(defaults: defaults, isSandboxed: true))
        // Still writable after the swap.
        var fresh = JournalEntry.new(); fresh.body = "written after import"
        #expect(db.saveEntry(fresh))
        #expect(db.fetchEntry(id: fresh.id)?.body == "written after import")
    }

    @Test("picking Application Support (the parent) finds the OmegaJournal folder")
    func parentFolderPick() throws {
        let (source, _) = Self.makeSourceJournal(entries: 1)
        let (root, db) = Self.makeTarget()
        defer { Self.cleanup(source.deletingLastPathComponent(), root) }
        let summary = try db.importLegacyJournal(from: source.deletingLastPathComponent())
        #expect(summary.entries == 1)
        #expect(summary.attachments == 1)
    }

    @Test("refuses to overwrite a journal that already has entries")
    func refusesNonEmptyJournal() throws {
        let (source, _) = Self.makeSourceJournal(entries: 2)
        let (root, db) = Self.makeTarget()
        defer { Self.cleanup(source.deletingLastPathComponent(), root) }
        var mine = JournalEntry.new(); mine.body = "my new entry"
        _ = db.saveEntry(mine)
        #expect(!db.isJournalEmptyForImport())

        #expect(throws: DatabaseManager.LegacyImportError.journalNotEmpty) {
            try db.importLegacyJournal(from: source)
        }
        #expect(db.fetchEntry(id: mine.id)?.body == "my new entry")
        #expect(db.entryCount(scope: .all) == 1)

        // Even an entry in the Trash counts.
        db.trashEntry(id: mine.id)
        #expect(!db.isJournalEmptyForImport())

        // VM path: friendly error toast, nothing changed.
        let vm = JournalViewModel(database: db)
        #expect(!vm.importLegacyJournal(from: source, defaults: Self.isolatedDefaults()))
        #expect(vm.toast?.isError == true)
        #expect(vm.toast?.message.contains("already has entries") == true)
        #expect(!vm.shouldOfferLegacyImport(defaults: Self.isolatedDefaults(), isSandboxed: true))
    }

    @Test("invalid folders are rejected and the journal is left alone")
    func invalidFolder() throws {
        let (root, db) = Self.makeTarget()
        let empty = MASDataTestEnv.tempDir("empty")
        let garbage = MASDataTestEnv.tempDir("garbage")
        defer { Self.cleanup(root, empty, garbage) }
        try Data("not a database at all".utf8).write(to: garbage.appendingPathComponent(Self.dbName))

        #expect(throws: DatabaseManager.LegacyImportError.notAJournalFolder) {
            try db.importLegacyJournal(from: empty)
        }
        do {
            try db.importLegacyJournal(from: garbage)
            Issue.record("garbage database was accepted")
        } catch let error as DatabaseManager.LegacyImportError {
            guard case .invalidDatabase = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(throws: DatabaseManager.LegacyImportError.sameFolder) {
            try db.importLegacyJournal(from: root)
        }
        #expect(db.isJournalEmptyForImport())
        var e = JournalEntry.new(); e.body = "still works"
        #expect(db.saveEntry(e))
    }

    @Test("undecryptable journal (another key) rolls back to the empty journal")
    func undecryptableRollsBack() throws {
        let (source, _) = Self.makeSourceJournal(entries: 2, corrupt: true)
        let (root, db) = Self.makeTarget()
        defer { Self.cleanup(source.deletingLastPathComponent(), root) }

        #expect(throws: DatabaseManager.LegacyImportError.undecryptable) {
            try db.importLegacyJournal(from: source)
        }
        #expect(db.isJournalEmptyForImport())
        #expect(!db.isReadOnly && !db.openFailed)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("attachments/att-1.bin").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("pre-import") || $0.hasPrefix("import-staging") }
        #expect(leftovers.isEmpty)
        var e = JournalEntry.new(); e.body = "after rollback"
        #expect(db.saveEntry(e))
        #expect(db.fetchEntry(id: e.id)?.body == "after rollback")

        // The user is pointed at the passphrase export.
        let msg = DatabaseManager.LegacyImportError.undecryptable.errorDescription ?? ""
        #expect(msg.contains("Password-Protected Export"))
    }

    @Test("VM rollback path: error toast and an empty, working library")
    func vmUndecryptable() throws {
        let (source, _) = Self.makeSourceJournal(entries: 1, corrupt: true)
        let (root, db) = Self.makeTarget()
        defer { Self.cleanup(source.deletingLastPathComponent(), root) }
        let vm = JournalViewModel(database: db)
        let defaults = Self.isolatedDefaults()
        #expect(!vm.importLegacyJournal(from: source, defaults: defaults))
        #expect(vm.entries.isEmpty)
        #expect(vm.toast?.isError == true)
        // A failed attempt doesn't silence the offer; the user may retry.
        #expect(!defaults.bool(forKey: MASDataLegacyImportOffer.dismissedDefaultsKey))
        #expect(vm.shouldOfferLegacyImport(defaults: defaults, isSandboxed: false) == false) // not sandboxed
    }
}
