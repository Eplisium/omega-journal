import Foundation
import Testing
import SQLite3
@testable import OmegaJournal

/// Coverage for audit item S1 — encryption at rest:
/// 1. JournalCrypto round-trips and produces byte-frames unlike plaintext.
/// 2. Bodies stored via saveEntry are ciphertext in the DB file on disk.
/// 3. Attachments are sealed on disk and decrypt to the original bytes.
/// 4. Auto-backups are sealed but recoverable via the documented decrypt path.
/// 5. The legacy plaintext upgrade path re-encrypts on next write.
@Suite("Encryption at rest", .serialized)
@MainActor
struct EncryptionAtRestTests {
    // DatabaseManager.shared is process-wide: the env-var override only takes
    // effect at first construction, so this suite uses ONE root for all tests
    // and reads the live paths back from the instance.
    private static let root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("omega-crypto-\(UUID().uuidString)", isDirectory: true)

    private static func makeIsolatedDatabase() throws -> DatabaseManager {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
        return DatabaseManager.shared
    }

    private static var databaseFileURL: URL {
        URL(fileURLWithPath: DatabaseManager.shared.databasePath)
    }

    /// Remove only the entries THIS suite created — the singleton DB is
    /// shared and a blanket wipe was deleting other suites' fixtures while
    /// their debounced saves were still in flight.
    private static func cleanup(ids: [String]) {
        let db = DatabaseManager.shared
        for id in ids { db.hardDeleteEntry(id: id) }
    }

    @Test("seal/open round-trips and ciphertext differs from plaintext")
    func sealOpenRoundTrip() throws {
        let secret = "Dear diary, today the audit finally landed. 🔐"
        let sealed = try JournalCrypto.encryptString(secret)
        #expect(sealed != Data(secret.utf8))
        #expect(!String(decoding: sealed, as: UTF8.self).contains("diary"))
        let opened = try JournalCrypto.decryptString(sealed)
        #expect(opened == secret)
        // Two seals of the same plaintext must differ (fresh nonce per GCM box).
        let secondSeal = try JournalCrypto.encryptString(secret)
        #expect(sealed != secondSeal)
        // Tampering must fail authentication, not return garbage.
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0xFF
        #expect(throws: (any Error).self) { try JournalCrypto.decrypt(tampered) }
    }

    @MainActor
    @Test("bodies are stored encrypted and never appear in the DB file")
    func bodiesEncryptedAtRest() throws {
        let db = try Self.makeIsolatedDatabase()
        let secret = "The treasure is buried under the oak at midnight."
        var entry = JournalEntry.new()
        entry.title = "Public title"
        entry.body = secret
        db.saveEntry(entry)

        let fetched = try #require(db.fetchEntry(id: entry.id))
        #expect(fetched.body == secret)

        // The database file itself must not carry the plaintext body.
        db.checkpointForTesting()
        let raw = try Data(contentsOf: Self.databaseFileURL)
        #expect(raw.range(of: Data(secret.utf8)) == nil)
        #expect(String(decoding: raw, as: UTF8.self).contains("Public title")) // title stays queryable

        Self.cleanup(ids: [entry.id])
    }

    @MainActor
    @Test("word_count still reflects encrypted bodies")
    func wordCountSurvivesEncryption() throws {
        let db = try Self.makeIsolatedDatabase()
        var entry = JournalEntry.new()
        entry.body = "one two three four five"
        db.saveEntry(entry)
        let fetched = try #require(db.fetchEntry(id: entry.id))
        #expect(fetched.wordCount == 5)
        Self.cleanup(ids: [entry.id])
    }

    @MainActor
    @Test("body search still matches words inside encrypted bodies")
    func bodySearchStillWorks() throws {
        let db = try Self.makeIsolatedDatabase()
        var entry = JournalEntry.new()
        entry.title = "Search probe"
        entry.body = "xylophone recital in the auditorium"
        db.saveEntry(entry)

        // SQL can't see ciphertext bodies; the Swift decrypt pass must.
        let results = db.fetchAllEntries(search: "xylophone")
        #expect(results.contains { $0.id == entry.id })
        Self.cleanup(ids: [entry.id])
    }

    @MainActor
    @Test("attachments are encrypted on disk and decrypt to the original bytes")
    func attachmentsEncryptedAtRest() throws {
        let db = try Self.makeIsolatedDatabase()
        var entry = JournalEntry.new()
        db.saveEntry(entry)

        let secret = Data("PNG-ish secret payload".utf8)
        let attachment = try #require(db.saveAttachment(
            entryId: entry.id, data: secret, filename: "note.txt", mimeType: "text/plain"))

        // On-disk bytes must not contain the plaintext.
        let fileURL = URL(fileURLWithPath: db.attachmentsDirectoryForTesting)
            .appendingPathComponent(attachment.id)
            .appendingPathComponent("note.txt")
        let raw = try Data(contentsOf: fileURL)
        #expect(raw != secret)
        #expect(String(decoding: raw, as: UTF8.self).contains("payload") == false)

        // And decrypt back to the original.
        #expect(db.readAttachmentData(attachment) == secret)

        Self.cleanup(ids: [entry.id])
    }

    @MainActor
    @Test("auto-backups are sealed but recoverable via decryptBackup")
    func backupsSealedAndRecoverable() throws {
        let db = try Self.makeIsolatedDatabase()
        let secret = "backup recovery probe"
        var entry = JournalEntry.new()
        entry.title = "Recovery title"
        entry.body = secret
        db.saveEntry(entry)

        let backupURL = try #require(db.backupDatabase())
        let raw = try Data(contentsOf: backupURL)
        #expect(String(decoding: raw, as: UTF8.self).contains(secret) == false)

        // Documented disaster-recovery path: decrypt to a plain SQLite file.
        // The recovered DB must open and carry the entry (bodies stay
        // encrypted inside the snapshot — titles are the plaintext anchor).
        let recovered = Self.root.appendingPathComponent("recovered.sqlite3")
        try JournalCrypto.decryptBackup(at: backupURL, to: recovered)
        let recoveredRaw = try Data(contentsOf: recovered)
        #expect(recoveredRaw.range(of: Data("Recovery title".utf8)) != nil)

        Self.cleanup(ids: [entry.id])
    }

    @MainActor
    @Test("legacy plaintext bodies upgrade to encrypted on next write")
    func legacyPlaintextBodyUpgrade() throws {
        let db = try Self.makeIsolatedDatabase()

        // Simulate a pre-V8 row: plaintext body, NULL body_enc. The save path
        // re-encrypts on the next write — the upgrade a real journal experiences.
        var entry = JournalEntry.new()
        entry.body = "plaintext from an old version"
        db.saveEntry(entry)
        db.legacyPlaintextForTesting(id: entry.id, body: "plaintext from an old version")

        // A save of the same entry re-encrypts the body.
        db.saveEntry(entry)
        let fetched = try #require(db.fetchEntry(id: entry.id))
        #expect(fetched.body == "plaintext from an old version")

        // The recovery artifact must not contain the plaintext: backups are
        // VACUUM INTO snapshots, freshly written, so a pre-upgrade body can't
        // ride along in them the way it can linger in reused pages of the
        // live file.
        let backupURL = try #require(db.backupDatabase())
        let decryptedBackup = Self.root.appendingPathComponent("upgraded-recovered.sqlite3")
        try JournalCrypto.decryptBackup(at: backupURL, to: decryptedBackup)
        let raw = try Data(contentsOf: decryptedBackup)
        #expect(raw.range(of: Data("plaintext from an old version".utf8)) == nil)

        Self.cleanup(ids: [entry.id])
    }
}
