import AppKit
import Foundation
import SwiftUI
import Testing
import OmegaJournalCore
@testable import OmegaJournal

// MARK: - Meta line candidates (pure)

@Suite("Wave 4 rows: meta line layout candidates")
struct Wave4RowsMetaLayoutTests {
    let tags = ["gratitude", "running", "health", "family", "work"]

    @Test("richest first: date+time, words, three chips, rest folded into +N")
    func richestFirst() throws {
        let c = try #require(RowsMetaLayout.candidates(tags: tags, canShowContent: true, hasWordCount: true).first)
        #expect(c.dateStyle == .dateAndTime)
        #expect(c.showsWordCount)
        #expect(c.visibleTags == ["gratitude", "running", "health"])
        #expect(c.hiddenTags == ["family", "work"])
        #expect(RowsMetaLayout.overflowText(c.overflowCount) == "+2")
    }

    @Test("every candidate accounts for every tag (chips + '+N'), in entry order")
    func noTagSilentlyDropped() {
        let all = RowsMetaLayout.candidates(tags: tags, canShowContent: true, hasWordCount: true)
        for c in all.dropLast() {
            #expect(c.visibleTags + c.hiddenTags == tags)
        }
    }

    @Test("detail is dropped in a fixed order: chips, then time, then word count")
    func dropOrder() {
        let all = RowsMetaLayout.candidates(tags: tags, canShowContent: true, hasWordCount: true)
        let firstDateOnly = all.firstIndex { $0.dateStyle == .dateOnly }!
        // Every date+time candidate still shows at least one chip and the word count.
        #expect(all[..<firstDateOnly].allSatisfy { $0.showsWordCount && !$0.visibleTags.isEmpty })
        #expect(all[..<firstDateOnly].map(\.visibleTags.count) == [3, 2, 1])
        // Once the time is gone it never comes back.
        #expect(all[firstDateOnly...].allSatisfy { $0.dateStyle == .dateOnly })
        // Last resort: mood + short date, nothing else.
        #expect(all.last == RowsMetaLayout.Candidate(dateStyle: .dateOnly, showsWordCount: false,
                                                      visibleTags: [], hiddenTags: []))
        #expect(Set(all.map { "\($0)" }).count == all.count, "no duplicate candidates")
    }

    @Test("a single tag never becomes '+1' while a chip still fits; '+N' alone keeps the hint")
    func singleTag() {
        let all = RowsMetaLayout.candidates(tags: ["extraordinarilylongtagnamewithoutanybreaks"],
                                            canShowContent: true, hasWordCount: false)
        #expect(all.first?.visibleTags.count == 1)
        #expect(all.first?.hiddenTags.isEmpty == true)
        #expect(all.contains { $0.visibleTags.isEmpty && $0.overflowCount == 1 })
    }

    @Test("untagged entries only trade the time and word count")
    func noTags() {
        let all = RowsMetaLayout.candidates(tags: [], canShowContent: true, hasWordCount: true)
        #expect(all.map(\.dateStyle) == [.dateAndTime, .dateOnly, .dateOnly])
        #expect(all.map(\.showsWordCount) == [true, true, false])
        #expect(all.allSatisfy { $0.visibleTags.isEmpty && $0.hiddenTags.isEmpty })
    }

    @Test("locked hidden entry: no tags, no '+N', no word count in ANY candidate")
    func lockedNeverShowsTags() {
        let all = RowsMetaLayout.candidates(tags: tags, canShowContent: false, hasWordCount: true)
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { $0.visibleTags.isEmpty && $0.hiddenTags.isEmpty && !$0.showsWordCount })
    }

    @Test("'+N' label lists only the hidden tags, and only when unlocked")
    func overflowLabel() {
        #expect(RowsMetaLayout.overflowAccessibilityLabel(hiddenTags: ["family", "work"], canShowContent: true)
                == "2 more tags: family, work")
        #expect(RowsMetaLayout.overflowAccessibilityLabel(hiddenTags: ["work"], canShowContent: true)
                == "1 more tag: work")
        #expect(RowsMetaLayout.overflowAccessibilityLabel(hiddenTags: ["family", "work"], canShowContent: false) == nil)
        #expect(RowsMetaLayout.overflowAccessibilityLabel(hiddenTags: [], canShowContent: true) == nil)
    }
}

// MARK: - Hosted row + clear search

@Suite("Wave 4 rows: hosted row layout and clear search", .serialized)
@MainActor
struct Wave4RowsHostedTests {
    private func makeVM() -> JournalViewModel {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-rows-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", dir.appendingPathComponent("db.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", dir.appendingPathComponent("att").path, 1)
        let db = DatabaseManager(databasePath: dir.appendingPathComponent("private.sqlite3").path,
                                 attachmentsPath: dir.appendingPathComponent("private-att").path)
        return JournalViewModel(database: db)
    }

    private func rowHeight(_ vm: JournalViewModel, _ entry: JournalEntry, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: EntryRow(vm: vm, entry: entry, isTrash: false).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The 280pt list column leaves ~240pt for a row. The old meta line
    /// wrapped the date onto two lines and broke chips inside words
    /// ("gratitu/de"), making narrow rows taller; now every row keeps one
    /// meta line at any width.
    @Test("narrow rows are exactly as tall as wide rows (no wrapped date or chips)",
          arguments: [["gratitude", "running"],
                      ["gratitude-and-appreciation", "mindfulness-practice", "personal-growth"],
                      ["running", "health", "gratitude", "family", "work", "travel", "reading"],
                      ["extraordinarilylongtagnamewithoutanybreaks"]])
    func narrowRowKeepsOneMetaLine(tags: [String]) throws {
        let vm = makeVM()
        UserDefaults.standard.removeObject(forKey: ListDensity.storageKey) // comfortable
        var entry = JournalEntry.new()
        entry.title = "Row"
        entry.body = String(repeating: "word ", count: 1234)
        entry.tags = tags
        let wide = rowHeight(vm, entry, width: 600)
        for width: CGFloat in [200, 240, 252, 360] {
            #expect(abs(rowHeight(vm, entry, width: width) - wide) < 0.5, "width \(width)")
        }
    }

    @Test("clear search drops a composing (marked) run and empties the field editor")
    func clearSearchSettlesComposition() throws {
        let vm = makeVM()
        vm.searchText = "zzqq"
        vm.refreshQuery()
        #expect(vm.searchResults != nil)

        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.string = "zzqq"
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        // ⌥E dead key: "´" stays marked until the next keystroke.
        editor.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())

        EntryListView.clearSearchText(in: vm, fieldEditor: editor)

        #expect(!editor.hasMarkedText())
        #expect(editor.string.isEmpty)
        #expect(vm.searchText.isEmpty)
        #expect(vm.searchResults == nil)
    }

    @Test("clear search with no field editor still clears the model")
    func clearSearchWithoutEditor() {
        let vm = makeVM()
        vm.searchText = "abc"
        vm.refreshQuery()
        vm.searchTextChanged()
        EntryListView.clearSearchText(in: vm, fieldEditor: nil)
        #expect(vm.searchText.isEmpty)
        #expect(vm.searchResults == nil)
        #expect(vm.searchDebounce?.isCancelled ?? true)
    }

    @Test("composition helper leaves a plain editor's text cleared and reports no marked text")
    func helperOnPlainEditor() {
        _ = NSApplication.shared
        let editor = NSTextView()
        editor.string = "query"
        #expect(SearchFieldComposition.clear(editor) == false)
        #expect(editor.string.isEmpty)
        #expect(SearchFieldComposition.clear(nil) == false)
    }
}
