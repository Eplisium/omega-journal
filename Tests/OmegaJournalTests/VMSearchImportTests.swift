import Darwin
import Foundation
import Testing
@testable import OmegaJournal

@Suite("VM search, import, undo", .serialized)
@MainActor
struct VMSearchImportTests {
    private static func isolate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-journal-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    @MainActor
    private func cleanup(_ vm: JournalViewModel, titles: Set<String>? = nil) {
        // The DB singleton is shared with other suites running in parallel:
        // only remove what this suite created (identified by marker below).
        for e in vm.db.fetchAllEntriesForExport() where Self.owns(e) { vm.db.hardDeleteEntry(id: e.id) }
    }

    private static func owns(_ e: JournalEntry) -> Bool {
        e.tags.contains("vmtest") || e.title.hasPrefix("VM ") || e.title == "Hello"
    }

    @MainActor
    @Test("search finds body-only match even when another entry matches title")
    func bodyAndTitleUnion() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        let a = vm.createEntry(title: "VM Garden plans", body: "tomatoes")
        let b = vm.createEntry(title: "VM Monday", body: "I visited the garden today")
        let c = vm.createEntry(title: "VM Unrelated", body: "nothing")
        vm.searchText = "garden"
        vm.refreshQuery()
        let ids = Set((vm.searchResults ?? []).map(\.id))
        #expect(ids == [a.id, b.id])
        #expect(!ids.contains(c.id))
        cleanup(vm)
    }

    @MainActor
    @Test("pure search matcher: locked hidden entries match title only")
    func lockedHidden() {
        var e = JournalEntry.new()
        e.title = "Secret"; e.body = "needle"; e.tags = ["needle"]; e.isHidden = true
        #expect(JournalViewModel.searchMatches([e], query: "needle", unlocked: false).isEmpty)
        #expect(JournalViewModel.searchMatches([e], query: "needle", unlocked: true).count == 1)
        #expect(JournalViewModel.searchMatches([e], query: "secret", unlocked: false).count == 1)
    }

    @MainActor
    @Test("importJSON never overwrites a trashed entry")
    func importDoesNotOverwriteTrashed() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        let e = vm.createEntry(title: "VM Keep me", body: "original")
        vm.stopEditing()
        vm.deleteEntry(e)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString).json")
        var changed = e; changed.body = "REPLACED"; changed.deletedAt = nil
        try ExportManager.exportJSON([changed], to: file)
        let added = vm.importJSON(from: file)
        #expect(added == 0)
        let stored = vm.db.fetchEntry(id: e.id)
        #expect(stored?.body == "original")
        #expect(stored?.isTrashed == true)
        cleanup(vm)
    }

    @MainActor
    @Test("markdown import reports unreadable files and skips duplicates")
    func markdownReport() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = dir.appendingPathComponent("good.md")
        try "# Hello\n\nworld".write(to: good, atomically: true, encoding: .utf8)
        let bad = dir.appendingPathComponent("bad.md")
        try Data([0xFF, 0xFE, 0xFD]).write(to: bad)
        let r1 = vm.importMarkdownReport(from: [good, bad])
        #expect(r1.added == 1)
        #expect(r1.skipped == ["bad.md"])
        let r2 = vm.importMarkdownReport(from: [good])
        #expect(r2.added == 0)
        #expect(r2.duplicates == 1)
        cleanup(vm)
    }

    @MainActor
    @Test("sort order and filter persist across view models")
    func persistedViewState() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        vm.setSortOrder(.titleAsc)
        vm.filter.favoritesOnly = true
        let vm2 = JournalViewModel()
        #expect(vm2.sortOrder == .titleAsc)
        #expect(vm2.filter.favoritesOnly)
    }

    @MainActor
    @Test("undo stack is bounded and undo message is honest")
    func undoBounded() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        for i in 0..<(JournalViewModel.maxUndoDepth + 10) {
            let e = vm.createEntry(title: "VM t\(i)", body: "b")
            vm.stopEditing()
            vm.deleteEntry(e)
        }
        #expect(vm.undoDepth == JournalViewModel.maxUndoDepth)
        #expect(JournalViewModel.undoMessage(verb: "Restored", count: 1, requested: 3) == "Restored 1 of 3 entries")
        #expect(JournalViewModel.undoMessage(verb: "Restored", count: 0, requested: 1).hasPrefix("Nothing"))
        cleanup(vm)
    }

    @MainActor
    @Test("export JSON carries formatVersion and real appVersion")
    func exportMetadata() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString).json")
        try ExportManager.exportJSON([JournalEntry.new()], to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"formatVersion\" : \(ExportManager.formatVersion)"))
        #expect(!text.contains("\"appVersion\" : \"1.0\""))
    }
}
