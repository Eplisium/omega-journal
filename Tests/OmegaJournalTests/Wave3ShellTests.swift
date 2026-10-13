import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
import OmegaJournalCore
@testable import OmegaJournal

@Suite("Wave 3 shell: one persistent split structure")
struct Wave3ShellColumnsTests {
    static let allItems: [SidebarItem] = [
        .today, .all, .favorites, .thisWeek, .mood(.good), .insights, .calendar, .onThisDay,
        .archive, .hidden, .trash, .tag("work"), .smartFolder("x"),
    ]

    @Test("collection destinations get list + detail, reflective ones a full page")
    func columnsPerDestination() {
        for item in Self.allItems {
            let columns = ShellColumns.forWorkspace(usesEntryCollection: item.workspace.usesEntryCollection)
            switch item {
            case .today, .calendar, .insights, .onThisDay: #expect(columns == .page, "\(item)")
            default: #expect(columns == .listAndDetail, "\(item)")
            }
        }
    }

    @Test("the pane right of the sidebar has one minimum for every workspace, leaving the sidebar room at 940pt")
    func paneMinimum() {
        #expect(ShellListColumn.paneMinWidth == 280 + 1 + 414)
        // Window minimum 940 minus the 1pt split divider: the sidebar may be
        // dragged to 244pt in ANY workspace, so no switch has to shrink it.
        let sidebarRoom = 940 - 1 - ShellListColumn.paneMinWidth
        #expect(sidebarRoom == 244)
        #expect(sidebarRoom >= 200) // sidebar column minimum
    }
}

@Suite("Wave 3 shell: entry list column width")
struct Wave3ShellListWidthTests {
    @Test("the stored width is used when there is room")
    func roomy() {
        // 1500pt window, 232pt sidebar → 1267pt right of the sidebar.
        #expect(ShellListColumn.width(stored: ShellListColumn.idealWidth, available: 1267) == 340)
        #expect(ShellListColumn.width(stored: 411, available: 1267) == 411)
    }

    @Test("at the 940pt minimum the list yields so the detail keeps 414pt (old three-column result)")
    func narrowWindow() {
        // 940 - 232 sidebar - 1 divider = 707 → list 292, detail 414: same as
        // the previous NavigationSplitView content column produced.
        #expect(ShellListColumn.width(stored: 340, available: 707) == 292)
        #expect(707 - 1 - ShellListColumn.width(stored: 460, available: 707) == 414)
        // Sidebar dragged to its 244pt cap: list hits its 280pt minimum.
        #expect(ShellListColumn.width(stored: 340, available: 695) == 280)
    }

    @Test("width is clamped to 280…460 and never below the minimum")
    func clamping() {
        #expect(ShellListColumn.width(stored: 10, available: 2000) == 280)
        #expect(ShellListColumn.width(stored: 9000, available: 2000) == 460)
        #expect(ShellListColumn.width(stored: 340, available: 100) == 280)
        #expect(ShellListColumn.clampStored(.nan) == ShellListColumn.idealWidth)
        #expect(ShellListColumn.clampStored(.infinity) == ShellListColumn.idealWidth)
    }

    @Test("dragging follows the pointer and stops where the layout stops (no dead zone)")
    func dragging() {
        #expect(ShellListColumn.dragged(from: 340, by: 71, available: 1267) == 411)
        #expect(ShellListColumn.dragged(from: 411, by: -105, available: 1267) == 306)
        // Past the detail minimum at 940: stops at 292, so dragging back
        // left moves the divider immediately.
        let stopped = ShellListColumn.dragged(from: 292, by: 200, available: 707)
        #expect(stopped == 292)
        #expect(ShellListColumn.dragged(from: stopped, by: -10, available: 707) == 282)
        #expect(ShellListColumn.dragged(from: 300, by: -500, available: 1267) == 280)
        #expect(ShellListColumn.dragged(from: 300, by: 500, available: 2000) == 460)
    }

    @Test("list width persists under its own key")
    func storageKey() {
        #expect(ShellListColumn.storageKey == "shell.listColumnWidth")
        #expect(ShellListColumn.storageKey != ShellSidebarPrefs.showAllTagsKey)
    }
}

@Suite("Wave 3 shell: header subtitle beside the notebook pill")
struct Wave3ShellHeaderTextTests {
    @Test("without a notebook scope the text matches the wave 2 header")
    func unscoped() {
        for (search, filters) in [(false, 0), (true, 0), (false, 2), (true, 1)] {
            #expect(ShellHeaderText.subtitle(isSearching: search, filterCount: filters, notebookName: nil,
                                             scopePillVisible: false)
                    == ShellCollectionHeader.subtitle(isSearching: search, filterCount: filters, notebookName: nil))
        }
    }

    @Test("with the pill on screen the notebook name is not repeated")
    func scopedWithPill() {
        let long = "Work Notebook With A Long Name"
        #expect(ShellHeaderText.subtitle(isSearching: false, filterCount: 0, notebookName: long,
                                         scopePillVisible: true) == "In one notebook")
        #expect(ShellHeaderText.subtitle(isSearching: true, filterCount: 1, notebookName: long,
                                         scopePillVisible: true) == "Search results · 1 filter")
        #expect(ShellHeaderText.subtitle(isSearching: false, filterCount: 2, notebookName: long,
                                         scopePillVisible: true) == "2 filters")
        for search in [false, true] {
            #expect(!ShellHeaderText.subtitle(isSearching: search, filterCount: 1, notebookName: long,
                                              scopePillVisible: true).contains(long))
        }
    }

    @Test("without the pill the notebook is named")
    func scopedWithoutPill() {
        #expect(ShellHeaderText.subtitle(isSearching: false, filterCount: 0, notebookName: "Work",
                                         scopePillVisible: false) == "Only entries in Work")
        #expect(ShellHeaderText.subtitle(isSearching: true, filterCount: 0, notebookName: "Work",
                                         scopePillVisible: false) == "Search results in Work")
    }
}

@Suite("Wave 3 shell: list header wiring", .serialized)
@MainActor
struct Wave3ShellListHeaderWiringTests {
    final class SelectionBox { var value: SidebarItem? }

    private static func isolate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-journal-w3shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    /// Filter, search and notebook scope persist in the shared test
    /// database; leave all three as found.
    private func reset(_ vm: JournalViewModel) {
        vm.filter = .empty
        vm.searchText = ""
        vm.refreshQuery()
        vm.setActiveJournal(nil)
    }

    @Test("a notebook-scoped list names the scope in the pill, not again in the subtitle")
    func scopedSubtitle() throws {
        try Self.isolate()
        _ = NSApplication.shared
        let vm = JournalViewModel()
        reset(vm)
        defer { reset(vm) }
        let box = SelectionBox(); box.value = .favorites
        let view = EntryListView(vm: vm, selection: Binding(get: { box.value }, set: { box.value = $0 }))
        #expect(view.collectionSubtitle == "Across all notebooks")
        vm.setActiveJournal(JournalDefaults.defaultJournalId)
        let name = try #require(vm.activeJournal?.name)
        #expect(view.collectionSubtitle == "In one notebook")
        vm.searchText = "w3shell"
        vm.filter.favoritesOnly = true
        #expect(view.collectionSubtitle == "Search results · 1 filter")
        #expect(!view.collectionSubtitle.contains(name))
        // The recovery copy still names the notebook it is limited to.
        #expect(view.recoveryState?.subtitle.contains(name) == true)
        #expect(view.recoveryState?.actions.contains(.showAllNotebooks) == true)
    }

    @Test("the workspace pane is built for both kinds of destination")
    func workspacePaneBuilds() throws {
        try Self.isolate()
        _ = NSApplication.shared
        let vm = JournalViewModel()
        for item: SidebarItem in [.all, .today, .calendar, .trash] {
            let box = SelectionBox(); box.value = item
            let binding = Binding(get: { box.value }, set: { box.value = $0 })
            let host = NSHostingView(rootView: ContentView.workspacePane(vm: vm, selection: binding)
                .frame(width: 1000, height: 700))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0)
        }
    }
}
