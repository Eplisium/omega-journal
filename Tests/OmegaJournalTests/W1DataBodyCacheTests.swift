import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

// Wave 1 / data-perf: the decrypted-body cache and batched decryption must
// never change what a read returns — only how often AES runs.

@Suite("W1Data body cache: same answers, fewer decrypts", .serialized)
@MainActor
struct W1DataBodyCacheTests {
    init() { TestSharedEnvironment.pin() }

    private func entry(_ title: String, _ body: String) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title
        e.body = body
        return e
    }

    @Test("a cached body is reused only for the exact same ciphertext")
    func cacheFollowsCiphertext() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        var e = entry("One", "first words")
        #expect(db.saveEntry(e))
        #expect(db.fetchAllEntries().first?.body == "first words")
        #expect(db.bodyCache[e.id]?.body == "first words")

        // A rewrite seals with a fresh nonce: new bytes, cache miss, new text.
        e.body = "second words"
        #expect(db.saveEntry(e))
        #expect(db.fetchAllEntries().first?.body == "second words")
        #expect(db.fetchEntry(id: e.id)?.body == "second words")
    }

    @Test("a row corrupted after it was cached reads as unreadable, never as the old text")
    func corruptionAfterCaching() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = entry("Keep", "precious words")
        #expect(db.saveEntry(e))
        #expect(db.fetchAllEntries().first?.body == "precious words")
        db.corruptBodyForTesting(id: e.id)
        let corrupted = try #require(db.rawBodyEncForTesting(id: e.id))

        let loaded = try #require(db.fetchAllEntries().first)
        #expect(loaded.body == "")
        #expect(db.isEntryUnreadable(e.id))
        #expect(db.bodyCache[e.id] == nil)
        // …so a save of the empty model cannot overwrite the ciphertext.
        _ = db.saveEntry(loaded)
        #expect(db.rawBodyEncForTesting(id: e.id) == corrupted)
    }

    @Test("another connection's write is seen on the next read")
    func externalWriteIsSeen() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        var e = entry("Shared", "before")
        #expect(db.saveEntry(e))
        #expect(db.fetchAllEntries().first?.body == "before")
        let other = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                    attachmentsPath: root.appendingPathComponent("attachments").path)
        e.body = "after"
        #expect(other.saveEntry(e))
        #expect(db.fetchAllEntries().first?.body == "after")
    }

    @Test("reopening the connection forgets every cached body")
    func reopenClearsCache() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(db.saveEntry(entry("A", "alpha")))
        _ = db.fetchAllEntries()
        #expect(!db.bodyCache.isEmpty)
        db.openDatabase()
        #expect(db.bodyCache.isEmpty)
        #expect(db.fetchAllEntries().first?.body == "alpha")
    }

    @Test("hard delete drops the cached plaintext")
    func hardDeleteForgets() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = entry("Gone", "secret")
        #expect(db.saveEntry(e))
        _ = db.fetchAllEntries()
        db.hardDeleteEntry(id: e.id)
        #expect(db.bodyCache[e.id] == nil)
    }

    @Test("a large batch decrypts in parallel with identical results and word counts")
    func parallelBatch() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = DatabaseManager.parallelDecryptThreshold * 3
        var expected: [String: String] = [:]
        #expect(db.inTransaction {
            for i in 0..<count {
                let e = entry("Entry \(i)", "body number \(i) " + String(repeating: "word ", count: i % 7))
                expected[e.id] = e.body
                db.performSave(e)
            }
        })
        let loaded = db.fetchAllEntries()
        #expect(loaded.count == count)
        for e in loaded {
            #expect(e.body == expected[e.id])
            #expect(e.derived.isPrimed)
            #expect(e.wordCount == JournalEntry.countWords(e.body))
        }
        // Second pass is served from the cache with the same answers.
        let again = db.fetchAllEntries()
        #expect(again.map(\.body) == loaded.map(\.body))
    }

    @Test("the word-count memo follows the body and never affects equality")
    func memoSemantics() {
        var a = entry("T", "one two three")
        #expect(a.wordCount == 3)
        let b = a
        a.body = "one two"
        #expect(a.wordCount == 2)
        #expect(b.wordCount == 3)
        var c = b
        c.derived = EntryDerivedMemo()
        #expect(c == b)
        #expect(c.hashValue == b.hashValue)
    }

    @Test("the hidden list equals the old hidden-scope fetch")
    func hiddenDerivedMatchesFetch() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<12 {
            var e = entry("E\(i)", "b\(i)")
            e.createdAt = base.addingTimeInterval(Double(i * 7 % 12) * 60)
            e.isHidden = i % 2 == 0
            e.isArchived = i % 3 == 0
            e.isPinned = i % 5 == 0
            if i % 4 == 0 { e.deletedAt = base }
            #expect(db.saveEntry(e))
        }
        for order in SortOrder.allCases {
            let active = db.fetchAllEntries(sort: order, scope: .active)
            let archived = db.fetchAllEntries(sort: order, scope: .archived)
            let fetched = db.fetchAllEntries(sort: .dateDesc, scope: .hidden)
            #expect(JournalViewModel.hiddenScope(active: active, archived: archived).map(\.id) == fetched.map(\.id))
        }
    }
}
