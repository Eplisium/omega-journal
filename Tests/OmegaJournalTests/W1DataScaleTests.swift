import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

// Wave 1 / data-perf: "it stays fast with 10,000 entries".
//
// A deterministic 10k-entry journal (≈300 words each, tags, moods, some
// hidden / archived / trashed) is seeded once per test process into a
// template file, then copied into a private directory for every test so the
// suites stay hermetic and parallel-safe. Timings are measured with
// `ContinuousClock` and printed (`[W1Data scale] …`) for the report; the
// `.timeLimit` guards are deliberately generous so slow CI runners pass.

@MainActor
enum W1DataScaleFixture {
    static let entryCount = 10_000
    static let vocabulary: [String] = """
    morning rain coffee walk river quiet garden letter friend school work meeting window evening \
    music dinner kitchen bread mountain train station winter summer autumn spring forest notebook \
    garden ocean harbor market lantern candle mirror bridge meadow pebble thunder harvest orchard \
    village journey memory picture blanket hallway library laughter silence promise question answer \
    yesterday tomorrow weekend holiday birthday sister brother mother father neighbor teacher doctor
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    static let tagPool = ["work", "family", "health", "travel", "ideas", "gratitude", "reading",
                          "projects/home", "projects/garden", "dreams", "fitness", "music"]

    /// Deterministic generator (SplitMix64) so every run seeds the same journal.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    static func makeEntries(count: Int = entryCount) -> [JournalEntry] {
        var rng = Rng(state: 0x0E6A_2026)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var out: [JournalEntry] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var words: [String] = []
            words.reserveCapacity(300)
            for _ in 0..<300 { words.append(vocabulary[rng.int(vocabulary.count)]) }
            // A unique marker word per entry makes single-hit searches exact.
            words[rng.int(300)] = "marker\(i)x"
            var e = JournalEntry(id: String(format: "w1data-%05d", i), title: "", body: "", mood: .neutral,
                                 tags: [], createdAt: base, updatedAt: base, isPinned: false, isFavorite: false,
                                 isArchived: false, deletedAt: nil, isHidden: false, attachments: [])
            e.title = "Day \(i) " + vocabulary[rng.int(vocabulary.count)]
            e.body = words.joined(separator: " ")
            e.tags = Array(Set((0..<rng.int(4)).map { _ in tagPool[rng.int(tagPool.count)] })).sorted()
            e.mood = Mood.allCases[rng.int(Mood.allCases.count)]
            e.createdAt = base.addingTimeInterval(Double(i) * 3_600)
            e.updatedAt = e.createdAt
            let roll = rng.int(100)
            e.isPinned = roll == 0
            e.isFavorite = roll < 10
            e.isHidden = roll >= 90 && roll < 93      // 3%
            e.isArchived = roll >= 93 && roll < 98    // 5%
            if roll >= 98 { e.deletedAt = Date().addingTimeInterval(-86_400) } // 2%, inside trash retention
            out.append(e)
        }
        return out
    }

    /// Seeds `entries` in ONE transaction through the real save path
    /// (encryption, tag junction rows, FTS), so the fixture is exactly what
    /// the app would have written.
    static func seed(_ db: DatabaseManager, entries: [JournalEntry]) -> Bool {
        db.inTransaction {
            for e in entries { db.performSave(e) }
        }
    }

    /// Template journal built once per test process; tests get a private copy.
    static let template: URL = {
        TestSharedEnvironment.pin()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("oj-w1data-template-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = DatabaseManager(databasePath: dir.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: dir.appendingPathComponent("att").path)
        let clock = ContinuousClock()
        let started = clock.now
        precondition(seed(db, entries: makeEntries()), "W1Data fixture seed failed")
        db.checkpointForTesting()
        report("seed \(entryCount) entries (one transaction)", clock.now - started)
        return dir
    }()

    /// A private copy of the seeded journal.
    static func copy() -> (root: URL, db: DatabaseManager) {
        let source = template
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oj-w1data-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: source.appendingPathComponent("j.sqlite3"),
                                          to: root.appendingPathComponent("j.sqlite3"))
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("att").path)
        return (root, db)
    }

    static func report(_ label: String, _ d: Duration) {
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        print("[W1Data scale] \(label): \(String(format: "%.1f", ms)) ms")
    }

    @discardableResult
    static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try body()
        let elapsed = clock.now - start
        report(label, elapsed)
        return (value, elapsed)
    }
}

@Suite("W1Data scale: 10,000 entries stay fast", .serialized)
@MainActor
struct W1DataScaleTests {
    init() { TestSharedEnvironment.pin() }

    @Test("the fixture really holds 10k entries across every scope", .timeLimit(.minutes(5)))
    func fixtureShape() {
        let (root, db) = W1DataScaleFixture.copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let total = db.scalarIntForTesting("SELECT COUNT(*) FROM entries;")
        #expect(total == W1DataScaleFixture.entryCount)
        #expect(db.entryCount(scope: .trashed) > 100)
        #expect(db.entryCount(scope: .archived) > 300)
        #expect(db.entryCount(scope: .hidden) > 200)
    }

    @Test("initial load", .timeLimit(.minutes(5)))
    func initialLoad() {
        let (root, db) = W1DataScaleFixture.copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let (vm, _) = W1DataScaleFixture.time("VM initial load") { JournalViewModel(database: db) }
        let active = db.entryCount(scope: .active)
        #expect(vm.entries.count == active)
        #expect(vm.trashedEntries.count == db.entryCount(scope: .trashed))
        #expect(vm.archivedEntries.count == db.entryCount(scope: .archived))
        #expect(vm.hiddenEntries.count == db.entryCount(scope: .hidden))
        #expect(vm.entries.allSatisfy { !$0.body.isEmpty })
    }

    @Test("reload and single-entry mutations", .timeLimit(.minutes(5)))
    func mutations() throws {
        let (root, db) = W1DataScaleFixture.copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = JournalViewModel(database: db)
        W1DataScaleFixture.time("full reload()") { vm.reload() }
        let target = try #require(vm.entries.first { !$0.isPinned && !$0.isHidden })
        W1DataScaleFixture.time("togglePin") { vm.togglePin(target) }
        W1DataScaleFixture.time("reload after pin") { vm.reload() }
        #expect(vm.entries.first?.id == target.id || vm.entries.first?.isPinned == true)
        let fav = try #require(vm.entries.first { $0.id == target.id })
        W1DataScaleFixture.time("toggleFavorite") { vm.toggleFavorite(fav) }
        let arch = try #require(vm.entries.first { $0.id == target.id })
        W1DataScaleFixture.time("toggleArchive") { vm.toggleArchive(arch) }
        #expect(vm.archivedEntries.contains { $0.id == target.id })
        let hide = try #require(vm.entries.first { !$0.isHidden && !$0.isPinned })
        W1DataScaleFixture.time("toggleHidden") { vm.toggleHidden(hide) }
        #expect(vm.hiddenEntries.contains { $0.id == hide.id })
        let trash = try #require(vm.entries.first { !$0.isPinned })
        W1DataScaleFixture.time("deleteEntry (trash)") { vm.deleteEntry(trash) }
        #expect(vm.trashedEntries.contains { $0.id == trash.id })
        let back = try #require(vm.trashedEntries.first { $0.id == trash.id })
        W1DataScaleFixture.time("restoreFromTrash") { vm.restoreFromTrash(back) }
        #expect(vm.entries.contains { $0.id == trash.id })
    }

    @Test("search keystrokes", .timeLimit(.minutes(5)))
    func search() {
        let (root, db) = W1DataScaleFixture.copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = JournalViewModel(database: db)
        defer { vm.searchText = ""; vm.refreshQuery() }
        vm.searchText = "marker4242x"
        W1DataScaleFixture.time("search keystroke (unique body word)") { vm.refreshQuery() }
        #expect(vm.searchResults?.map(\.id) == ["w1data-04242"])
        vm.searchText = "rain coffee"
        W1DataScaleFixture.time("search keystroke (two common words)") { vm.refreshQuery() }
        #expect((vm.searchResults?.count ?? 0) > 1_000)
        vm.searchText = "zzzznotthere"
        W1DataScaleFixture.time("search keystroke (no hit)") { vm.refreshQuery() }
        #expect(vm.searchResults?.isEmpty == true)
    }

    @Test("tag rename", .timeLimit(.minutes(5)))
    func tagRename() {
        let (root, db) = W1DataScaleFixture.copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = JournalViewModel(database: db)
        let before = vm.allTags.first { $0.tag == "gratitude" }?.count ?? 0
        #expect(before > 0)
        W1DataScaleFixture.time("tag rename (gratitude → thanks)") { vm.renameTagTree("gratitude", to: "thanks") }
        #expect(vm.allTags.first { $0.tag == "thanks" }?.count == before)
        #expect(!vm.allTags.contains { $0.tag == "gratitude" })
    }
}
