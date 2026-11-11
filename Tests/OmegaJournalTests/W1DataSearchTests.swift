import Foundation
import Testing
@testable import OmegaJournalCore
@testable import OmegaJournal

// Wave 1 / data-perf: the indexed search path must give exactly the answers
// of `SearchQuery.contains` / `SearchQuery.matches` (Foundation,
// case- and diacritic-insensitive), only faster.

// Pure and CPU-heavy (hundreds of thousands of Foundation comparisons):
// nonisolated so it runs on the cooperative pool. On the main actor (the
// test target's default isolation) it held main for seconds and starved
// suites that poll main-queue notifications.
@Suite("W1Data search index: identical to Foundation matching")
nonisolated struct W1DataIndexSearchTests {
    static let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    static let printableASCII: [String] = (0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) }

    @Test("every inert scalar is invisible to ASCII terms on this OS")
    func inertSetHolds() {
        var checked = 0
        for range in SearchHaystack.inertRanges {
            for value in range {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let c = String(scalar)
                checked += 1
                // Never matches (or folds to) any ASCII character…
                for a in Self.printableASCII where c.range(of: a, options: Self.opts) != nil {
                    Issue.record("U+\(String(value, radix: 16)) matches \(a.debugDescription)")
                }
                let folded = c.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                #expect(!folded.unicodeScalars.contains { $0.isASCII }, "U+\(String(value, radix: 16)) folds to ASCII")
                // …is not ignorable between two letters…
                #expect("x\(c)y".range(of: "xy", options: Self.opts) == nil, "U+\(String(value, radix: 16)) is ignorable")
                // …and does not absorb a neighbouring letter.
                #expect("ab\(c)".range(of: "b", options: Self.opts) != nil)
                #expect("\(c)ba".range(of: "b", options: Self.opts) != nil)
            }
        }
        #expect(checked > 1_000)
        #expect("\u{2026}".range(of: "...", options: Self.opts) == nil)
    }

    @Test("ASCII pairs fold exactly like ASCII lower-casing")
    func asciiPairs() {
        for x in Self.printableASCII {
            for y in Self.printableASCII {
                let foundation = x.range(of: y, options: Self.opts) != nil
                #expect(SearchHaystack(x).contains(SearchNeedle(y)) == foundation, "\(x) / \(y)")
            }
        }
    }

    @Test("known non-ASCII cases take the exact path")
    func nonASCIIFallback() {
        let cases: [(String, String, Bool)] = [
            ("Straße", "STRASSE", true), ("Café", "cafe", true), ("Résumé", "RESUME", true),
            ("x\u{FE0F}y", "xy", true), ("e\u{301}t\u{E9}", "ete", true), ("a\r\nb", "\n", false),
            ("I like 🍎 and 🍐", "and", true), ("❤️ love", "love", true), ("—dash—", "dash", true),
            ("İstanbul", "istanbul", "İstanbul".range(of: "istanbul", options: Self.opts) != nil),
        ]
        for (hay, needle, expected) in cases {
            #expect(SearchQuery.contains(hay, needle) == expected, "\(hay) / \(needle)")
            #expect(SearchHaystack(hay).contains(SearchNeedle(needle)) == expected, "\(hay) / \(needle)")
        }
        #expect(SearchHaystack("plain ‘quoted’ text — fine…").isASCIIFoldable)
        #expect(!SearchHaystack("Café").isASCIIFoldable)
        #expect(!SearchHaystack("x\u{FE0F}").isASCIIFoldable)
        #expect(!SearchHaystack("👍🏽").isASCIIFoldable)
        #expect(SearchNeedle("").asciiLower == nil)
        #expect(!SearchHaystack("abc").contains(SearchNeedle("")))
    }

    /// Deterministic generator (SplitMix64).
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
    }

    @Test("fuzz: haystack.contains agrees with SearchQuery.contains")
    func fuzzContains() {
        var rng = Rng(state: 42)
        let hayAlphabet: [String] = Array("abcABCxyz .,'\"-!?:#[]()").map(String.init)
            + ["\u{2019}", "\u{201C}", "\u{2014}", "\u{2026}", "\u{00A0}", "\n", "\r\n", "\t", "é", "É", "ß",
               "\u{301}", "\u{FE0F}", "😄", "🏽", "\u{200D}", "ﬁ", "ǅ", "Å", "ﬀ"]
        let needleAlphabet: [String] = Array("abcABCxyz .,'-!?ss").map(String.init) + ["é", "ß", "fi"]
        var mismatches = 0
        for _ in 0..<60_000 {
            let hay = (0..<rng.int(0...14)).map { _ in rng.pick(hayAlphabet) }.joined()
            let needle = (0..<rng.int(1...3)).map { _ in rng.pick(needleAlphabet) }.joined()
            let expected = SearchQuery.contains(hay, needle)
            if SearchHaystack(hay).contains(SearchNeedle(needle)) != expected {
                mismatches += 1
                if mismatches < 5 { Issue.record("mismatch: \(hay.debugDescription) / \(needle.debugDescription)") }
            }
        }
        #expect(mismatches == 0)
    }

    @Test("fuzz: prepared queries match exactly like SearchQuery.matches")
    func fuzzQueries() {
        var rng = Rng(state: 7)
        let words = ["rain", "Rain", "walk", "café", "cafe", "straße", "long", "work", "night", "x"]
        let queries = ["rain", "rain walk", #""long walk""#, "-work", "rain -work", "cafe", "strasse",
                       "tag:travel", "#travel rain", "mood:good", "has:link", "has:task", "-\"long walk\"",
                       "RAIN -Night", "x", "walk tag:travel/italy", "zzz"]
        for _ in 0..<3_000 {
            let body = (0..<rng.int(0...8)).map { _ in rng.pick(words) }.joined(separator: rng.pick([" ", "—", "\n", " https://a.b "]))
                + rng.pick(["", " - [ ] task", "![img](x.png)"])
            let record = SearchQuery.Record(
                id: UUID().uuidString, title: rng.pick(["", "Rain", "Long walk", "Café"]), body: body,
                tags: rng.pick([[], ["travel"], ["travel/italy", "work"], ["Rainy"]]),
                moodName: rng.pick(["Good", "Bad"]), moodValue: rng.int(1...5), createdAt: Date(),
                attachmentCount: rng.int(0...1), hasImage: body.contains("!["), wordCount: 3,
                isHidden: rng.int(0...3) == 0)
            let indexed = IndexedSearchRecord(record)
            for raw in queries {
                let q = SearchQuery.parse(raw)
                for locked in [false, true] {
                    #expect(PreparedSearchQuery(q).matches(indexed, hiddenLocked: locked)
                            == q.matches(record, hiddenLocked: locked), "\(raw) locked=\(locked)")
                }
            }
        }
    }
}

@Suite("W1Data search: off-main typing path and FTS ids", .serialized)
@MainActor
struct W1DataSearchVMTests {
    init() { TestSharedEnvironment.pin() }

    @Test("ftsRankedIds returns the same ids, in order, as fullTextSearch")
    func rankedIdsMatchFullTextSearch() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        for (i, title) in ["rain walk", "rain", "walk in the rain rain", "sun"].enumerated() {
            var e = JournalEntry.new()
            e.title = title
            e.body = "body \(i)"
            e.tags = i == 3 ? ["rain"] : []
            db.saveEntry(e)
        }
        #expect(db.ftsRankedIds("rain") == db.fullTextSearch("rain").map(\.id))
        #expect(db.ftsRankedIds("rain").count == 4)
        #expect(db.ftsRankedIds("\"(") == db.fullTextSearch("\"(").map(\.id))
    }

    @Test("typing path publishes the same results as refreshQuery")
    func backgroundSearchAgrees() async {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = JournalViewModel(database: db)
        defer { vm.searchText = ""; vm.refreshQuery() }
        vm.createEntry(title: "Sunday", body: "A long walk in the rain — lovely")
        vm.createEntry(title: "Monday", body: "Rain again, long day at work")
        vm.createEntry(title: "Café", body: "Résumé finished")
        vm.stopEditing()
        for query in ["rain", "rain -work", #""long walk""#, "cafe resume", "nothing-here"] {
            vm.searchText = query
            vm.refreshQuery()
            let expected = vm.searchResults?.map(\.id)
            vm.searchResults = nil
            await vm.refreshQueryInBackground()
            #expect(vm.searchResults?.map(\.id) == expected, "\(query)")
        }
    }

    @Test("a background search never publishes for an older query or library")
    func staleBackgroundSearchIsDropped() async {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = JournalViewModel(database: db)
        defer { vm.searchText = ""; vm.refreshQuery() }
        vm.createEntry(title: "alpha", body: "one")
        vm.createEntry(title: "beta", body: "two")
        vm.stopEditing()
        vm.searchText = "alpha"
        let task = Task { await vm.refreshQueryInBackground() }
        await Task.yield()
        // The query changes before the background match can publish.
        vm.searchText = "beta"
        vm.refreshQuery()
        await task.value
        #expect(vm.searchResults?.map(\.title) == ["beta"])

        // The library changes while a match runs: the result is recomputed.
        vm.searchText = "gamma"
        let racing = Task { await vm.refreshQueryInBackground() }
        await Task.yield()
        vm.createEntry(title: "gamma", body: "three")
        vm.stopEditing()
        await racing.value
        #expect(vm.searchResults?.map(\.title) == ["gamma"])
    }

    @Test("searchTextChanged debounces, then searches off the main actor")
    func debouncedTypingPath() async throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = JournalViewModel(database: db)
        defer { vm.searchText = ""; vm.refreshQuery() }
        vm.createEntry(title: "lantern", body: "harbor at night")
        vm.stopEditing()
        vm.searchText = "harb"
        vm.searchTextChanged()
        vm.searchText = "harbor"
        vm.searchTextChanged()
        let pending = try #require(vm.searchDebounce)
        await pending.value
        #expect(vm.searchResults?.map(\.title) == ["lantern"])
        #expect(vm.recentSearches.first == "harbor")
    }
}
