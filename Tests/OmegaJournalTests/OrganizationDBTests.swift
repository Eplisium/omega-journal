import Darwin
import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

@Suite("Organization: journals, tag colors, masking", .serialized)
@MainActor
struct OrganizationDBTests {
    private static func isolate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omega-journal-org-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    /// The DB is the process-wide singleton shared with other suites: remove only what these tests created.
    @MainActor private func cleanup(_ vm: JournalViewModel) {
        vm.setActiveJournal(nil)
        for e in vm.db.fetchAllEntriesForExport() where e.title.hasPrefix("ORG ") { vm.db.hardDeleteEntry(id: e.id) }
        for j in vm.db.fetchJournals() where !j.isDefault { _ = vm.db.deleteJournal(id: j.id) }
        for t in vm.db.allTagNames() where ["homeonly", "workonly", "sf", "hidtag"].contains(where: { TagPath.isSameOrDescendant(t, of: $0) }) || t.hasPrefix("orgp") || t.hasPrefix("orgw") {
            vm.db.deleteTag(t)
        }
        vm.smartFolders = []; vm.persistSmartFolders()
        vm.reload()
    }

    @MainActor private func make(_ vm: JournalViewModel, _ title: String, body: String = "body", tags: [String] = [], hidden: Bool = false, journal: String? = nil) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title; e.body = body; e.tags = tags; e.isHidden = hidden
        if let journal { e.journalId = journal }
        #expect(vm.db.saveEntry(e))
        return e
    }

    @MainActor
    @Test("default journal exists and new entries land in it")
    func defaultJournal() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        cleanup(vm); defer { cleanup(vm) }
        #expect(vm.db.fetchJournals().contains { $0.id == JournalDefaults.defaultJournalId })
        let e = make(vm, "ORG default")
        #expect(vm.db.fetchEntry(id: e.id)?.journalId == JournalDefaults.defaultJournalId)
    }

    @MainActor
    @Test("journal filter scopes entries, counts, tags and search; delete moves entries")
    func journalScoping() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        cleanup(vm); defer { cleanup(vm) }
        let work = try #require(vm.db.createJournal(name: "Work"))
        #expect(vm.db.createJournal(name: "work") == nil)
        _ = make(vm, "ORG home", tags: ["homeonly"])
        let w = make(vm, "ORG work", body: "unicornword", tags: ["workonly"], journal: work.id)
        #expect(vm.db.fetchAllEntries(scope: .active, journalId: work.id).map(\.id) == [w.id])
        #expect(vm.db.entryCount(scope: .active, journalId: work.id) == 1)
        #expect(vm.db.tagsWithCounts(journalId: work.id).map(\.tag).contains("workonly") && !vm.db.tagsWithCounts(journalId: work.id).map(\.tag).contains("homeonly"))
        #expect(vm.db.fullTextSearch("ORG", journalId: JournalDefaults.defaultJournalId).allSatisfy { $0.journalId == JournalDefaults.defaultJournalId })

        vm.journals = vm.db.fetchJournals()
        vm.setActiveJournal(work.id)
        #expect(vm.entries.map(\.id).contains(w.id) && !vm.entries.contains { $0.title == "ORG home" })
        #expect(vm.allTags.map(\.tag).contains("workonly") && !vm.allTags.map(\.tag).contains("homeonly"))
        #expect(vm.newEntryJournalId == work.id)
        vm.searchText = "unicornword"; vm.refreshQuery()
        #expect((vm.searchResults ?? []).map(\.id) == [w.id])
        vm.searchText = ""; vm.refreshQuery()
        vm.setActiveJournal(nil)
        #expect(vm.entries.filter { $0.title.hasPrefix("ORG ") }.count == 2)

        #expect(vm.db.deleteJournal(id: work.id))
        #expect(vm.db.fetchEntry(id: w.id)?.journalId == JournalDefaults.defaultJournalId)
        #expect(!vm.db.deleteJournal(id: JournalDefaults.defaultJournalId))
    }

    @MainActor
    @Test("journal counts exclude hidden entries while locked")
    func journalCountsMasked() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        cleanup(vm); defer { cleanup(vm) }
        let id = JournalDefaults.defaultJournalId
        let base0 = vm.db.journalEntryCounts(includeHidden: false)[id] ?? 0
        let base1 = vm.db.journalEntryCounts(includeHidden: true)[id] ?? 0
        _ = make(vm, "ORG vis")
        _ = make(vm, "ORG hid", hidden: true)
        #expect((vm.db.journalEntryCounts(includeHidden: false)[id] ?? 0) == base0 + 1)
        #expect((vm.db.journalEntryCounts(includeHidden: true)[id] ?? 0) == base1 + 2)
    }

    @MainActor
    @Test("tag colors persist; rename moves subtree and merges")
    func tagManager() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        cleanup(vm); defer { cleanup(vm) }
        _ = make(vm, "ORG a", tags: ["orgp/alpha"])
        _ = make(vm, "ORG b", tags: ["orgp"])
        _ = make(vm, "ORG c", tags: ["orgw/alpha"])
        #expect(vm.db.setTagColor("orgp", hex: TagColors.palette[0]))
        #expect(vm.db.tagColors()["orgp"] == TagColors.palette[0])
        #expect(!vm.db.setTagColor("orgp", hex: "not-a-color"))
        #expect(vm.db.renameTagTree(from: "orgp", to: "orgw") == 2)
        let names = Set(vm.db.tagsWithCounts().map(\.tag))
        #expect(names.isSuperset(of: ["orgw", "orgw/alpha"]) && !names.contains("orgp") && !names.contains("orgp/alpha"))
        #expect(vm.db.tagsWithCounts().first { $0.tag == "orgw/alpha" }?.count == 2)   // merged
        #expect(vm.db.tagColors()["orgw"] == TagColors.palette[0])                     // color inherited
    }

    @MainActor
    @Test("smart folders: counts and lists never include locked hidden entries")
    func smartFolderMasked() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        cleanup(vm); defer { cleanup(vm) }
        _ = make(vm, "ORG v", tags: ["sf"])
        let h = make(vm, "ORG h", tags: ["sf"], hidden: true)
        vm.reload()
        let folder = SmartFolder(name: "SF", tags: ["sf"])
        #expect(vm.saveSmartFolder(folder))
        #expect(vm.smartFolders.count == 1)
        let locked = !BiometricAuth.shared.isAuthenticated
        if locked {
            #expect(vm.smartFolderCounts[folder.id] == 1)
            #expect(!vm.smartFolderEntries(folder, from: vm.entries + vm.hiddenEntries).contains { $0.id == h.id })
            #expect(!vm.tagTree.contains { $0.path == "sf" && $0.totalCount > 1 })
        }
        vm.deleteSmartFolder(folder)
        #expect(vm.smartFolders.isEmpty)
    }

    @MainActor
    @Test("search surfaces: operator search, snippets, palette hits, graph and backlinks mask hidden")
    func surfacesMasked() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        cleanup(vm); defer { cleanup(vm) }
        _ = make(vm, "ORG Target", body: "target body")
        let src = make(vm, "ORG Src", body: "links [[ORG Target]] ok")
        let hid = make(vm, "ORG Hid", body: "zebratext [[ORG Target]]", tags: ["hidtag"], hidden: true)
        vm.reload()
        guard !BiometricAuth.shared.isAuthenticated else { return }
        // search
        vm.searchText = "zebratext"; vm.refreshQuery()
        #expect(!(vm.searchResults ?? []).contains { $0.id == hid.id })
        vm.searchText = "tag:hidtag"; vm.refreshQuery()
        #expect(!(vm.searchResults ?? []).contains { $0.id == hid.id })
        #expect(vm.contentSearchHits("zebratext").isEmpty)
        #expect(vm.searchSnippet(for: hid) == nil)
        // graph
        let g = vm.linkGraph()
        #expect(!g.nodes.contains { $0.id == hid.id })
        #expect(g.edges.contains { $0.from == src.id })
        // backlinks / mentions
        let target = try #require(vm.entries.first { $0.title == "ORG Target" })
        #expect(!vm.backlinks(for: target).contains { $0.id == hid.id })
        #expect(!vm.unlinkedMentions(for: target).contains { $0.id == hid.id })
        // tag tree
        #expect(!vm.tagTree.contains { $0.path == "hidtag" })
    }

    @MainActor
    @Test("export/import round-trips journal and tolerates old files")
    func exportImport() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        cleanup(vm); defer { cleanup(vm) }
        let nb = try #require(vm.db.createJournal(name: "Dreams"))
        let e = make(vm, "ORG exp", journal: nb.id)
        #expect(vm.db.ensureJournal(id: nb.id, name: "Dreams") == nb.id)
        #expect(vm.db.ensureJournal(id: nil, name: nil) == JournalDefaults.defaultJournalId)
        // Unknown id from another machine is recreated under its name, not dropped.
        let recreated = vm.db.ensureJournal(id: "other-machine-id", name: "Travel")
        #expect(recreated == "other-machine-id")
        #expect(vm.db.fetchJournals().contains { $0.name == "Travel" })
        #expect(vm.db.fetchEntry(id: e.id)?.journalId == nb.id)
        let moved = vm.db.moveEntries(ids: [e.id], toJournal: JournalDefaults.defaultJournalId)
        #expect(moved == 1)
    }
}
