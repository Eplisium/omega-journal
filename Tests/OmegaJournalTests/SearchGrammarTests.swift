import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

// Issue #9: one query grammar (`SearchQuery`) for the journal list, Archive /
// Hidden / Trash, the command palette and smart folders, with exact phrases
// and `-exclusion`.

@Suite("Search grammar: parsing")
struct SearchGrammarParseTests {
    @Test("free words, phrases and exclusions are separated")
    func parsesTermsAndExclusions() {
        let q = SearchQuery.parse(#"rain "long walk" -work -"day job" tag:travel"#)
        #expect(q.terms == ["rain", "long walk"])
        #expect(q.excluded == ["work", "day job"])
        #expect(q.tags == ["travel"])
        #expect(!q.isEmpty)
    }

    @Test("an exclusion on its own is a real query; a lone dash is ignored")
    func exclusionOnlyAndLoneDash() {
        let onlyExclusion = SearchQuery.parse("-work")
        #expect(onlyExclusion.terms.isEmpty)
        #expect(onlyExclusion.excluded == ["work"])
        #expect(!onlyExclusion.isEmpty)

        let dash = SearchQuery.parse("rain - walk")
        #expect(dash.terms == ["rain", "walk"])
        #expect(dash.excluded.isEmpty)
        #expect(SearchQuery.parse("-").isEmpty)
        #expect(SearchQuery.parse(#"-"""#).isEmpty)
    }

    @Test("repeated exclusions are kept once; hyphenated words are not exclusions")
    func duplicatesAndHyphens() {
        let q = SearchQuery.parse("-Work -work well-being")
        #expect(q.excluded == ["Work"])
        #expect(q.terms == ["well-being"])
    }

    @Test("an unclosed quote still reads as one phrase")
    func unclosedQuote() {
        #expect(SearchQuery.parse(#""long walk"#).terms == ["long walk"])
    }
}

@Suite("Search grammar: matching")
struct SearchGrammarMatchTests {
    static func record(_ title: String, _ body: String, tags: [String] = [], hidden: Bool = false) -> SearchQuery.Record {
        SearchQuery.Record(id: UUID().uuidString, title: title, body: body, tags: tags, moodName: "okay",
                           moodValue: 3, createdAt: Date(), isHidden: hidden)
    }

    @Test("every free word must appear, in any order and any field")
    func allWordsAnyOrder() {
        let r = Self.record("Morning", "A long walk in the rain", tags: ["outdoors"])
        #expect(SearchQuery.parse("rain walk").matches(r, hiddenLocked: false))
        #expect(SearchQuery.parse("morning outdoors").matches(r, hiddenLocked: false))
        #expect(!SearchQuery.parse("rain snow").matches(r, hiddenLocked: false))
    }

    @Test("a quoted phrase must appear as written")
    func phraseIsContiguous() {
        let r = Self.record("", "We took a long walk home")
        #expect(SearchQuery.parse(#""long walk""#).matches(r, hiddenLocked: false))
        #expect(!SearchQuery.parse(#""walk long""#).matches(r, hiddenLocked: false))
        // The same words unquoted still match, in any order.
        #expect(SearchQuery.parse("walk long").matches(r, hiddenLocked: false))
    }

    @Test("matching ignores case and accents")
    func caseAndDiacritics() {
        let r = Self.record("Café notes", "Résumé done")
        #expect(SearchQuery.parse("cafe RESUME").matches(r, hiddenLocked: false))
        #expect(!SearchQuery.parse("-resume").matches(r, hiddenLocked: false))
    }

    @Test("an exclusion in the title, body or tags drops the entry")
    func exclusionEverywhere() {
        let inTitle = Self.record("Work day", "fine")
        let inBody = Self.record("Day", "busy at work")
        let inTag = Self.record("Day", "fine", tags: ["work"])
        let clean = Self.record("Day", "a quiet day off")
        let q = SearchQuery.parse("day -work")
        #expect(!q.matches(inTitle, hiddenLocked: false))
        #expect(!q.matches(inBody, hiddenLocked: false))
        #expect(!q.matches(inTag, hiddenLocked: false))
        #expect(q.matches(clean, hiddenLocked: false))
        #expect(!SearchQuery.parse(#"-"day off""#).matches(clean, hiddenLocked: false))
        #expect(SearchQuery.parse(#"-"off day""#).matches(clean, hiddenLocked: false))
    }

    @Test("a locked hidden entry is judged on its title only, so -word can't reveal its body or tags")
    func exclusionRespectsMasking() {
        let hidden = Self.record("Private", "about work", tags: ["work"], hidden: true)
        // Body/tags are off limits while locked: excluding "work" must not make it vanish.
        #expect(SearchQuery.parse("-work").matches(hidden, hiddenLocked: true))
        // Unlocked, the body counts again.
        #expect(!SearchQuery.parse("-work").matches(hidden, hiddenLocked: false))
        // The title is visible either way.
        #expect(!SearchQuery.parse("-private").matches(hidden, hiddenLocked: true))
        // Positive words still match on the title only.
        #expect(!SearchQuery.parse("work").matches(hidden, hiddenLocked: true))
        #expect(SearchQuery.parse("private").matches(hidden, hiddenLocked: true))
    }

    @Test("smart folders follow the same grammar")
    func smartFolderUsesGrammar() {
        let folder = SmartFolder(name: "Walks", query: #""long walk" -rain"#)
        #expect(folder.matches(Self.record("", "a long walk at dusk"), hiddenLocked: false))
        #expect(!folder.matches(Self.record("", "a long walk in the rain"), hiddenLocked: false))
        #expect(!folder.matches(Self.record("", "walk, long and slow"), hiddenLocked: false))
    }
}

@Suite("Search grammar: every search surface agrees", .serialized)
@MainActor
struct SearchGrammarSurfaceTests {
    @Test("ranking only reorders matches and never adds one")
    func rankedFirst() {
        var a = JournalEntry.new(); a.title = "a"
        var b = JournalEntry.new(); b.title = "b"
        var c = JournalEntry.new(); c.title = "c"
        let out = JournalViewModel.rankedFirst([a, b, c], rankedIds: [c.id, "not-a-match", a.id, c.id])
        #expect(out.map(\.title) == ["c", "a", "b"])
        #expect(JournalViewModel.rankedFirst([a, b], rankedIds: []).map(\.title) == ["a", "b"])
    }

    @Test("list, Archive, palette and the pure matcher return the same entries for each query")
    func surfacesAgree() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = JournalViewModel(database: db)
        defer { vm.searchText = ""; vm.refreshQuery() }

        let walk = vm.createEntry(title: "Sunday", body: "A long walk in the rain")
        let work = vm.createEntry(title: "Monday", body: "Rain again, long day at work")
        let quiet = vm.createEntry(title: "Walk notes", body: "Quiet and long, no rain at all")
        vm.stopEditing()
        let all = [walk.id, work.id, quiet.id]

        // Same entries, archived, for the Archive path.
        for id in all { vm.toggleArchive(try #require(vm.entries.first { $0.id == id })) }
        #expect(vm.archivedEntries.count == 3)
        let archived = vm.archivedEntries
        for id in all { vm.toggleArchive(try #require(vm.archivedEntries.first { $0.id == id })) }
        #expect(vm.entries.count == 3)

        let cases: [(query: String, expected: Set<String>)] = [
            ("rain long", [walk.id, work.id, quiet.id]),
            (#""long walk""#, [walk.id]),
            ("walk", [walk.id, quiet.id]),
            ("rain -work", [walk.id, quiet.id]),
            (#"rain -"long walk""#, [work.id, quiet.id]),
            ("-rain", []),
            (#""rain at all""#, [quiet.id]),
        ]
        for c in cases {
            vm.searchText = c.query
            vm.refreshQuery()
            let list = Set((vm.searchResults ?? []).map(\.id))
            let palette = Set(vm.contentSearchHits(c.query, limit: 50).map(\.entry.id))
            let pure = Set(JournalViewModel.searchMatches(vm.entries, query: c.query, unlocked: true).map(\.id))
            let archive = Set(vm.entriesMatchingCurrentSearch(in: archived).map(\.id))
            #expect(list == c.expected, "list: \(c.query)")
            #expect(palette == c.expected, "palette: \(c.query)")
            #expect(pure == c.expected, "pure: \(c.query)")
            #expect(archive == c.expected, "archive: \(c.query)")
        }
    }
}
