import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

@Suite("W1Int Apple Journal import flow", .serialized)
@MainActor
struct W1IntAppleJournalImportTests {
    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("w1int-aj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func makeVM(_ root: URL) -> JournalViewModel {
        TestSharedEnvironment.pin()
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("att").path)
        return JournalViewModel(database: db)
    }

    /// Writes the synthetic export as a folder under `root` and returns it.
    private func writeExport(in root: URL, files: [String: Data] = W1IntAppleJournalRecordTests.files()) throws -> URL {
        for (path, data) in files where !path.hasPrefix("__MACOSX") {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return root.appendingPathComponent("AppleJournalEntries", isDirectory: true)
    }

    @Test func importsFolderOnceWithAttachmentsAndPlace() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = makeVM(root)
        let export = try writeExport(in: root.appendingPathComponent("src", isDirectory: true))

        var previews: [JournalViewModel.AppleJournalImportPreview] = []
        let report = vm.importAppleJournal(from: export) { previews.append($0); return true }
        #expect(report.added == 2)
        #expect(report.attachments == 1)
        #expect(report.skipped.count == 1)
        #expect(previews.first?.new == 2)
        #expect(previews.first?.attachments == 1)

        let stored = vm.db.fetchAllEntriesForExport()
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { !$0.isHidden && $0.tags.contains(AppleJournalImport.tag) })
        let walk = try #require(stored.first { $0.title == "Evening walk" })
        #expect(walk.mood == .great)
        #expect(EntryStampCodec.split(walk.body).stamp?.location == "Hyde Park")
        #expect(walk.attachments.count == 1)
        #expect(vm.db.readAttachmentData(walk.attachments[0]) == Data([1, 2, 3]))

        // Same export again: the preview says nothing is new and nothing is written.
        var again: JournalViewModel.AppleJournalImportPreview?
        let second = vm.importAppleJournal(from: export) { again = $0; return true }
        #expect(again?.new == 0)
        #expect(again?.duplicates == 2)
        #expect(second.added == 0)
        #expect(vm.db.fetchAllEntriesForExport().count == 2)
    }

    @Test func reimportRecognisesRenamedEntries() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = makeVM(root)
        let export = try writeExport(in: root.appendingPathComponent("src", isDirectory: true))
        vm.importAppleJournal(from: export)
        // The user renames an imported entry; a later re-import must not bring it back.
        var walk = try #require(vm.db.fetchAllEntriesForExport().first { $0.title == "Evening walk" })
        walk.title = "Walk in the park"
        vm.db.saveEntry(walk)
        let report = vm.importAppleJournal(from: export)
        #expect(report.added == 0)
        #expect(report.duplicates == 2)
    }

    @Test func cancellingThePreviewWritesNothing() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = makeVM(root)
        let export = try writeExport(in: root.appendingPathComponent("src", isDirectory: true))
        let report = vm.importAppleJournal(from: export) { _ in false }
        #expect(report == JournalViewModel.FolderImportReport())
        #expect(vm.db.fetchAllEntriesForExport().isEmpty)
    }

    @Test func importsTheZipFinderMakes() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = makeVM(root)
        var w = EPUBZipWriter()
        for (path, data) in W1IntAppleJournalRecordTests.files().sorted(by: { $0.key < $1.key }) { try w.add(path, data) }
        let zipURL = root.appendingPathComponent("AppleJournalEntries.zip")
        try w.finish().write(to: zipURL)
        let report = vm.importAppleJournal(from: zipURL)
        #expect(report.added == 2)
        #expect(report.attachments == 1)
    }

    @Test func pickingTheEntriesFolderWorksToo() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = makeVM(root)
        let export = try writeExport(in: root.appendingPathComponent("src", isDirectory: true))
        let report = vm.importAppleJournal(from: export.appendingPathComponent("Entries", isDirectory: true))
        #expect(report.added == 2)
    }

    @Test func rejectsThingsThatAreNotExports() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = makeVM(root)
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("# hi".utf8).write(to: notes.appendingPathComponent("a.md"))
        #expect(JournalViewModel.openAppleJournalExport(at: notes) == nil)
        try Data("not a zip".utf8).write(to: root.appendingPathComponent("x.zip"))
        #expect(JournalViewModel.openAppleJournalExport(at: root.appendingPathComponent("x.zip")) == nil)
        #expect(vm.importAppleJournal(from: notes).added == 0)
    }

    @Test func symlinkedResourcesOutsideTheExportAreIgnored() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = makeVM(root)
        var files = W1IntAppleJournalRecordTests.files()
        files["AppleJournalEntries/Resources/PH-1.heic"] = nil
        let export = try writeExport(in: root.appendingPathComponent("src", isDirectory: true), files: files)
        let secret = root.appendingPathComponent("secret.heic")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: export.appendingPathComponent("Resources/PH-1.heic"), withDestinationURL: secret)
        let report = vm.importAppleJournal(from: export)
        #expect(report.added == 2)
        #expect(report.attachments == 0)
    }

    @Test func previewSummaryReadsNaturally() {
        let p = JournalViewModel.AppleJournalImportPreview(total: 12, new: 9, duplicates: 3, attachments: 20, unreadable: 1)
        #expect(p.summary == "12 entries (3 already in your journal) with 20 photos and recordings; 1 page couldn't be read.")
        #expect(JournalViewModel.AppleJournalImportPreview(total: 1, new: 1).summary == "1 entry.")
    }
}
