import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
import OmegaJournalCore
@testable import OmegaJournal

@Suite("Wave 2 shell: sidebar keyboard order")
struct Wave2ShellSidebarKeyboardTests {
    typealias G = ShellSidebarKeyboard.Group<SidebarItem>

    let groups: [G] = [
        G([.today]),
        G([.all, .favorites, .thisWeek], isExpanded: false),
        G([.calendar, .insights, .onThisDay]),
        G([.archive, .hidden, .trash]),
        G([.mood(.good), .mood(.bad)], isExpanded: true),
        G([.tag("work")], isExpanded: false),
    ]

    @Test("rows in collapsed sections are skipped")
    func collapsedSkipped() {
        let order = ShellSidebarKeyboard.order(groups, current: .today)
        #expect(order == [.today, .calendar, .insights, .onThisDay, .archive, .hidden, .trash, .mood(.good), .mood(.bad)])
        #expect(ShellSidebarKeyboard.step(1, from: .today, in: order) == .calendar)
    }

    @Test("expanded mood rows are reachable from the keyboard")
    func moodsReachable() {
        let order = ShellSidebarKeyboard.order(groups, current: nil)
        #expect(ShellSidebarKeyboard.step(1, from: .trash, in: order) == .mood(.good))
    }

    @Test("a selection inside a collapsed section keeps its slot and steps to visible neighbours")
    func selectionInCollapsedSection() {
        let order = ShellSidebarKeyboard.order(groups, current: .favorites)
        #expect(order.prefix(3) == [.today, .favorites, .calendar])
        #expect(ShellSidebarKeyboard.step(1, from: .favorites, in: order) == .calendar)
        #expect(ShellSidebarKeyboard.step(-1, from: .favorites, in: order) == .today)
        // Leaving it drops it again: .all/.thisWeek were never reachable.
        #expect(!order.contains(.all) && !order.contains(.thisWeek))
    }

    @Test("stepping clamps, and an empty or unknown selection lands on an end")
    func clamping() {
        let order = ShellSidebarKeyboard.order(groups, current: nil)
        #expect(ShellSidebarKeyboard.step(-1, from: .today, in: order) == .today)
        #expect(ShellSidebarKeyboard.step(1, from: .mood(.bad), in: order) == .mood(.bad))
        #expect(ShellSidebarKeyboard.step(1, from: nil, in: order) == .today)
        #expect(ShellSidebarKeyboard.step(-1, from: .smartFolder("gone"), in: order) == .mood(.bad))
        #expect(ShellSidebarKeyboard.step(1, from: SidebarItem.today, in: []) == nil)
    }

    @Test("duplicates across groups are listed once")
    func deduplicated() {
        let order = ShellSidebarKeyboard.order([G([.today, .all]), G([.all, .trash])], current: nil)
        #expect(order == [.today, .all, .trash])
    }

    @Test("show-all-tags preference has its own stable key")
    func showAllTagsKey() {
        #expect(ShellSidebarPrefs.showAllTagsKey == "shell.sidebar.showAllTags")
        #expect(ShellSidebarPrefs.showAllTagsKey != ShellPrefs.sidebarTagsExpanded)
    }
}

@Suite("Wave 2 shell: tag chip choices")
struct Wave2ShellTagChoiceTests {
    let ordered = ["a", "b", "c", "d", "e"]

    @Test("unselected lists are capped at the limit in usage order")
    func capped() {
        #expect(ShellTagChoices.visible(ordered, selected: [], limit: 3) == ["a", "b", "c"])
    }

    @Test("a selected tag beyond the limit is still shown, once")
    func selectedBeyondLimit() {
        #expect(ShellTagChoices.visible(ordered, selected: ["e", "a"], limit: 3) == ["a", "b", "c", "e"])
    }

    @Test("a selected tag no longer in the tag list stays removable")
    func selectedMissing() {
        #expect(ShellTagChoices.visible(ordered, selected: ["zeta", "gone"], limit: 2) == ["a", "b", "gone", "zeta"])
    }

    @Test("filter panel and smart-folder editor keep their limits")
    func viewLimits() {
        let many = (1...40).map { "t\($0)" }
        #expect(FilterBar.tagChoices(many, selected: []).count == 14)
        #expect(FilterBar.tagChoices(many, selected: ["t40"]).last == "t40")
        #expect(SmartFolderEditor.tagChoices(many, selected: []).count == 30)
        #expect(SmartFolderEditor.tagChoices(many, selected: ["t35", "t31"]) == Array(many.prefix(30)) + ["t31", "t35"])
    }
}

@Suite("Wave 2 shell: collection header scope")
struct Wave2ShellHeaderTests {
    @Test("idle subtitle states the notebook scope")
    func idle() {
        #expect(ShellCollectionHeader.subtitle(isSearching: false, filterCount: 0, notebookName: nil) == "Across all notebooks")
        #expect(ShellCollectionHeader.subtitle(isSearching: false, filterCount: 0, notebookName: "Work") == "Only entries in Work")
    }

    @Test("search and filters are named together with the scope")
    func narrowed() {
        #expect(ShellCollectionHeader.subtitle(isSearching: true, filterCount: 0, notebookName: nil)
                == "Search results across all notebooks")
        #expect(ShellCollectionHeader.subtitle(isSearching: true, filterCount: 2, notebookName: "Work")
                == "Search results · 2 filters in Work")
        #expect(ShellCollectionHeader.subtitle(isSearching: false, filterCount: 1, notebookName: nil)
                == "1 filter across all notebooks")
    }

    @Test("the single Clear all control names what it clears")
    func clearAllLabel() {
        #expect(ShellListConstraints.clearAllLabel(hasSearch: true, filterCount: 2) == "Clear search and filters")
        #expect(ShellListConstraints.clearAllLabel(hasSearch: false, filterCount: 2) == "Clear all filters")
        #expect(ShellListConstraints.clearAllLabel(hasSearch: true, filterCount: 0) == "Clear search")
    }
}

@Suite("Wave 2 shell: no-results recovery")
struct Wave2ShellRecoveryTests {
    @Test("nothing narrowing the list defers to the collection's own empty state")
    func noConstraints() {
        #expect(ShellListRecovery.emptyState(query: "  ", filterCount: 0, isLibraryRoot: true,
                                             canWidenToLibrary: true, notebookName: nil) == nil)
        #expect(ShellListRecovery.emptyState(query: "", filterCount: 0, isLibraryRoot: false,
                                             canWidenToLibrary: true, notebookName: "Work") == nil)
    }

    @Test("search-only offers Clear search, and widening from a narrower collection")
    func searchOnly() throws {
        let root = try #require(ShellListRecovery.emptyState(query: "kite", filterCount: 0, isLibraryRoot: true,
                                                             canWidenToLibrary: true, notebookName: nil))
        #expect(root.title == "No matches")
        #expect(root.subtitle == "Nothing matches “kite”.")
        #expect(root.actions == [.clearSearch])

        let favorites = try #require(ShellListRecovery.emptyState(query: "kite", filterCount: 0, isLibraryRoot: false,
                                                                  canWidenToLibrary: true, notebookName: nil))
        #expect(favorites.actions == [.clearSearch, .searchAllEntries])

        // Archive/Hidden/Trash search their own store: no "search all entries".
        let trash = try #require(ShellListRecovery.emptyState(query: "kite", filterCount: 0, isLibraryRoot: false,
                                                              canWidenToLibrary: false, notebookName: nil))
        #expect(trash.actions == [.clearSearch])
    }

    @Test("search plus filters: one Clear all first, then keep-search option")
    func combined() throws {
        let state = try #require(ShellListRecovery.emptyState(query: "kite", filterCount: 2, isLibraryRoot: true,
                                                              canWidenToLibrary: true, notebookName: nil))
        #expect(state.actions.first == .clearAll)
        #expect(state.actions == [.clearAll, .clearFilters])
        #expect(state.subtitle.contains("2 filters"))
    }

    @Test("filters only")
    func filtersOnly() throws {
        let state = try #require(ShellListRecovery.emptyState(query: "", filterCount: 1, isLibraryRoot: true,
                                                              canWidenToLibrary: true, notebookName: nil))
        #expect(state.title == "No entries match your filters")
        #expect(state.subtitle == "Loosen or clear the 1 filter to see more.")
        #expect(state.actions == [.clearFilters])
    }

    @Test("a notebook scope is named and can be dropped")
    func notebookScope() throws {
        let state = try #require(ShellListRecovery.emptyState(query: "kite", filterCount: 0, isLibraryRoot: true,
                                                              canWidenToLibrary: true, notebookName: "Work"))
        #expect(state.subtitle.hasSuffix("Showing only Work."))
        #expect(state.actions.last == .showAllNotebooks)
    }

    @Test("every action has a visible title")
    func titles() {
        for action in ShellListRecovery.Action.allCases { #expect(!action.title.isEmpty) }
    }
}

/// Wires the pure recovery logic into the real list view: no live UI, but the
/// actions mutate the same view-model state the buttons do.
@Suite("Wave 2 shell: list recovery wiring", .serialized)
@MainActor
struct Wave2ShellListWiringTests {
    final class SelectionBox { var value: SidebarItem? }

    private static func isolate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-journal-w2shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    /// The filter is persisted in the shared test database, so every test
    /// starts from and leaves behind an empty filter and search.
    private func reset(_ vm: JournalViewModel) {
        vm.filter = .empty
        vm.searchText = ""
        vm.refreshQuery()
    }

    private func makeView(_ vm: JournalViewModel, _ box: SelectionBox) -> EntryListView {
        _ = NSApplication.shared
        reset(vm)
        return EntryListView(vm: vm, selection: Binding(get: { box.value }, set: { box.value = $0 }))
    }

    @Test("destinations map to the right widening rules")
    func recoveryContext() {
        #expect(EntryListView.recoveryContext(for: .all) == (true, true))
        #expect(EntryListView.recoveryContext(for: nil) == (true, true))
        #expect(EntryListView.recoveryContext(for: .favorites) == (false, true))
        #expect(EntryListView.recoveryContext(for: .tag("work")) == (false, true))
        #expect(EntryListView.recoveryContext(for: .smartFolder("x")) == (false, true))
        #expect(EntryListView.recoveryContext(for: .trash) == (false, false))
        #expect(EntryListView.recoveryContext(for: .hidden) == (false, false))
    }

    @Test("Clear all clears the search together with the filters")
    func clearAll() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        let box = SelectionBox(); box.value = .all
        let view = makeView(vm, box)
        defer { reset(vm) }
        vm.searchText = "w2shell-no-such-word"
        vm.refreshQuery()
        vm.filter.favoritesOnly = true
        vm.filter.minWords = 100
        #expect(view.recoveryState?.actions.first == .clearAll)
        view.perform(.clearAll)
        #expect(vm.searchText.isEmpty)
        #expect(vm.searchResults == nil)
        #expect(!vm.filter.isActive)
        #expect(view.recoveryState == nil)
    }

    @Test("Clear filters keeps the search; Clear search keeps the filters")
    func partialClears() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        let box = SelectionBox(); box.value = .all
        let view = makeView(vm, box)
        defer { reset(vm) }
        vm.searchText = "w2shell-kite"
        vm.filter.pinnedOnly = true
        view.perform(.clearFilters)
        #expect(vm.searchText == "w2shell-kite")
        #expect(!vm.filter.isActive)
        vm.filter.pinnedOnly = true
        view.perform(.clearSearch)
        #expect(vm.searchText.isEmpty)
        #expect(vm.filter.pinnedOnly)
    }

    @Test("Search all entries widens a narrower collection and keeps the query")
    func searchAllEntries() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        let box = SelectionBox(); box.value = .favorites
        let view = makeView(vm, box)
        defer { reset(vm) }
        vm.searchText = "w2shell-kite"
        #expect(view.recoveryState?.actions.contains(.searchAllEntries) == true)
        view.perform(.searchAllEntries)
        #expect(box.value == .all)
        #expect(vm.searchText == "w2shell-kite")
        #expect(vm.selectedEntryId == nil)
    }

    @Test("the header title is the destination and the subtitle names search and filters")
    func header() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        let box = SelectionBox(); box.value = .favorites
        let view = makeView(vm, box)
        defer { reset(vm) }
        #expect(view.collectionTitle == "Favorites")
        vm.searchText = "w2shell"
        vm.filter.favoritesOnly = true
        let notebook = vm.activeJournal?.name
        #expect(view.collectionSubtitle == ShellCollectionHeader.subtitle(isSearching: true, filterCount: 1,
                                                                          notebookName: notebook))
        #expect(view.collectionSubtitle.hasPrefix("Search results · 1 filter"))
    }
}
