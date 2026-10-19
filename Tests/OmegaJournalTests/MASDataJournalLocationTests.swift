import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

@Suite("MAS data: journal location")
struct MASDataJournalLocationTests {
    let legacy = URL(fileURLWithPath: "/Users/kim/Library/Application Support/OmegaJournal", isDirectory: true)
    let container = URL(fileURLWithPath:
        "/Users/kim/Library/Containers/com.eplisium.omega-journal/Data/Library/Application Support/OmegaJournal",
        isDirectory: true)

    func db(_ dir: URL) -> String { dir.appendingPathComponent("omega_journal.sqlite3").path }

    @Test("sandboxed: always the container's Application Support folder")
    func sandboxed() {
        for existing in [Set<String>(), [db(legacy)], [db(container)], [db(legacy), db(container)]] {
            let dir = MASDataJournalLocation.resolveDirectory(
                isSandboxed: true, legacyDir: legacy, containerDir: container, fileExists: { existing.contains($0) })
            #expect(dir == container)
        }
    }

    @Test("unsandboxed with a legacy database: legacy (today), container never probed")
    func unsandboxedLegacyPresent() {
        var probed: [String] = []
        let dir = MASDataJournalLocation.resolveDirectory(
            isSandboxed: false, legacyDir: legacy, containerDir: container,
            fileExists: { probed.append($0); return $0 == db(legacy) || $0 == db(container) })
        #expect(dir == legacy)
        #expect(probed == [db(legacy)])
    }

    @Test("unsandboxed, no legacy database but the container has one: container")
    func unsandboxedContainerOnly() {
        let dir = MASDataJournalLocation.resolveDirectory(
            isSandboxed: false, legacyDir: legacy, containerDir: container, fileExists: { $0 == db(container) })
        #expect(dir == container)
    }

    @Test("unsandboxed, no database anywhere: legacy (fresh install)")
    func unsandboxedFresh() {
        let dir = MASDataJournalLocation.resolveDirectory(
            isSandboxed: false, legacyDir: legacy, containerDir: container, fileExists: { _ in false })
        #expect(dir == legacy)
    }

    @Test("full paths: database + attachments inside the chosen folder")
    func fullPaths() {
        let p = MASDataJournalLocation.resolvePaths(
            environment: [:], isSandboxed: false, legacyDir: legacy, containerDir: container,
            fileExists: { $0 == db(container) })
        #expect(p.databasePath == db(container))
        #expect(p.attachmentsPath == container.appendingPathComponent("attachments").path)
        #expect(!p.isTest)
        #expect(p.directory == container.path)
    }

    @Test("test-mode environment variables always win", arguments: [true, false])
    func testModeWins(sandboxed: Bool) {
        let env = ["OMEGA_JOURNAL_TEST_DATABASE_PATH": "/tmp/qa/j.sqlite3",
                   "OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH": "/tmp/qa/att"]
        let p = MASDataJournalLocation.resolvePaths(
            environment: env, isSandboxed: sandboxed, legacyDir: legacy, containerDir: container,
            fileExists: { _ in true })
        #expect(p == .init(databasePath: "/tmp/qa/j.sqlite3", attachmentsPath: "/tmp/qa/att", isTest: true))

        // Without an attachments override they sit beside the test database.
        let q = MASDataJournalLocation.resolvePaths(
            environment: ["OMEGA_JOURNAL_TEST_DATABASE_PATH": "/tmp/qa/j.sqlite3"], isSandboxed: sandboxed,
            legacyDir: legacy, containerDir: container, fileExists: { _ in true })
        #expect(q.attachmentsPath == "/tmp/qa/attachments")
        #expect(q.isTest)

        // An empty override is ignored.
        let r = MASDataJournalLocation.resolvePaths(
            environment: ["OMEGA_JOURNAL_TEST_DATABASE_PATH": ""], isSandboxed: sandboxed,
            legacyDir: legacy, containerDir: container, fileExists: { _ in false })
        #expect(!r.isTest)
    }

    @Test("this test process resolves to its test database, never a real journal")
    func liveDefaultPathsUseTestOverride() {
        MASDataTestEnv.ensureIsolated()
        let paths = DatabaseManager.defaultPaths()
        #expect(paths.isTest)
        #expect(!paths.db.contains("Library/Application Support/OmegaJournal"))
    }

    @Test("picked folder: the journal folder itself or its OmegaJournal subfolder")
    func pickedFolder() {
        let appSupport = legacy.deletingLastPathComponent()
        #expect(MASDataJournalLocation.journalFolder(inPicked: legacy, fileExists: { $0 == db(legacy) }) == legacy)
        #expect(MASDataJournalLocation.journalFolder(inPicked: appSupport, fileExists: { $0 == db(legacy) })?.path
                == legacy.path)
        #expect(MASDataJournalLocation.journalFolder(inPicked: appSupport, fileExists: { _ in false }) == nil)
    }

    @Test("one-time import offer: sandboxed, empty, not test mode, not dismissed")
    func importOffer() {
        #expect(MASDataLegacyImportOffer.shouldOffer(isSandboxed: true, isTestMode: false, journalIsEmpty: true, dismissed: false))
        #expect(!MASDataLegacyImportOffer.shouldOffer(isSandboxed: false, isTestMode: false, journalIsEmpty: true, dismissed: false))
        #expect(!MASDataLegacyImportOffer.shouldOffer(isSandboxed: true, isTestMode: true, journalIsEmpty: true, dismissed: false))
        #expect(!MASDataLegacyImportOffer.shouldOffer(isSandboxed: true, isTestMode: false, journalIsEmpty: false, dismissed: false))
        #expect(!MASDataLegacyImportOffer.shouldOffer(isSandboxed: true, isTestMode: false, journalIsEmpty: true, dismissed: true))
    }

    @Test("journal location row shows the real container path when sandboxed")
    func locationRowUsesRealHome() {
        let dbPath = db(container)
        // What NSHomeDirectory() returns inside the sandbox — misleading.
        let containerHome = "/Users/kim/Library/Containers/com.eplisium.omega-journal/Data"
        #expect(SettingsStorageLocation.displayFolder(forDatabasePath: dbPath, home: containerHome)
                == "~/Library/Application Support/OmegaJournal")
        // With the real home it names the folder that actually exists on disk.
        #expect(SettingsStorageLocation.displayFolder(forDatabasePath: dbPath, home: "/Users/kim")
                == "~/Library/Containers/com.eplisium.omega-journal/Data/Library/Application Support/OmegaJournal")
        #expect(SettingsStorageLocation.displayFolder(forDatabasePath: db(legacy), home: "/Users/kim")
                == "~/Library/Application Support/OmegaJournal")
    }
}

/// Shared isolation for MASData suites: guarantees this process runs in
/// test mode (ephemeral key, temp singleton database) even when a MASData
/// suite is the first thing to run. Never overrides a path another suite set.
enum MASDataTestEnv {
    static let root: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-masdata-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func ensureIsolated() {
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 0)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 0)
    }

    static func tempDir(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-masdata-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
