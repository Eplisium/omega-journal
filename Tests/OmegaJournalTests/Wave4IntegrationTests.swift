import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

private struct Wave4IntegrationInjectedError: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// Integration patches applied after wave 4: read-only open detection, Retry
/// feedback when a retry fails again, and the quit guard decision.
@Suite("Wave 4 integration: read-only open, repeat-retry feedback, quit guard", .serialized)
@MainActor
struct Wave4IntegrationTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-w4int-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("an unwritable journal file opens read-only with an explanation")
    func readOnlyFileIsDetected() throws {
        let dir = tempDir()
        let path = dir.appendingPathComponent("ro.sqlite3").path
        do {
            let db = DatabaseManager(databasePath: path, attachmentsPath: dir.appendingPathComponent("att").path)
            #expect(!db.isReadOnly)
        }
        // Make the file and its directory unwritable so SQLite must open it read-only.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            try? FileManager.default.removeItem(at: dir)
        }
        let reopened = DatabaseManager(databasePath: path, attachmentsPath: dir.appendingPathComponent("att").path)
        #expect(reopened.isReadOnly)
        #expect(reopened.startupError?.contains("Check its permissions") == true, "startupError=\(reopened.startupError ?? "nil")")
    }

    @Test("an explicit Retry that fails again shows feedback without the body")
    func repeatRetryGivesFeedback() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = DatabaseManager(databasePath: dir.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: dir.appendingPathComponent("att").path)
        let vm = JournalViewModel(database: db)
        let id = vm.createEntry(title: "T", body: "b").id
        let secret = "secret body sentence"
        vm.saveWriterOverride = { entry in
            throw Wave4IntegrationInjectedError(text: "Save failed: database or disk is full [\(entry.body)]")
        }
        var e = try #require(vm.entry(id: id))
        e.body = secret
        vm.autoSave(e)
        vm.flushPendingSave()
        #expect(vm.saveState.isFailed)
        vm.toast = nil
        #expect(!vm.retryFailedSaves())
        let toast = try #require(vm.toast)
        #expect(toast.isError)
        #expect(toast.message.hasPrefix("Still not saved"))
        #expect(!toast.message.contains(secret))
        #expect(vm.hasUnsavedChanges(entryId: id))
    }

    @Test("quit asks only while something is genuinely unsaved")
    func quitDecision() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = DatabaseManager(databasePath: dir.appendingPathComponent("q.sqlite3").path,
                                 attachmentsPath: dir.appendingPathComponent("att").path)
        let vm = JournalViewModel(database: db)
        let id = vm.createEntry(title: "Q", body: "q").id
        #expect(vm.quitDecision() == .terminate)
        vm.saveWriterOverride = { _ in throw Wave4IntegrationInjectedError(text: "Save failed: disk I/O error") }
        var e = try #require(vm.entry(id: id))
        e.body = "unsaved"
        vm.autoSave(e)
        #expect(vm.quitDecision() == .confirm(unsavedCount: 1))
        vm.saveWriterOverride = nil
        #expect(vm.quitDecision() == .terminate)
    }
}
