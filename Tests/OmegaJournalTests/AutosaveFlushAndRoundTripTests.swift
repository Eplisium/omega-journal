import Foundation
import Testing
@testable import OmegaJournal

/// Regression coverage for the 2026-09-07 audit fixes:
/// 1. Immediate mutations (pin/archive/hide) must flush a pending debounced
///    autosave first — the debounce held a full pre-mutation entry snapshot
///    that used to land afterwards and silently revert the mutation.
/// 2. stopEditing must fold the pending autosave into the database itself —
///    EditorView's onDisappear flush runs after editingEntryId is already nil.
/// 3. The JSON export/import round-trip must preserve the hidden flag (v3
///    format) and keep importing old (v2) backups as visible entries.
/// 4. Renaming a tag to its own name must be a no-op — the merge path deletes
///    the old tag row, which for a self-rename is the only row.
@Suite("Autosave flush and export round-trip", .serialized)
struct AutosaveFlushAndRoundTripTests {
    private static func makeIsolatedDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    @MainActor
    @Test("pending autosave cannot revert pin, archive, or hide")
    func pendingAutosaveCannotRevertImmediateMutations() async throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()

        // Same shape as the trash-resurrection test: schedule the 700 ms
        // debounced save with the pre-mutation snapshot, then mutate before
        // it fires. The mutation must cancel/flush the debounce first.
        let pinned = vm.createEntry(title: "Race pin", body: "x")
        vm.autoSave(pinned)
        vm.togglePin(pinned)

        let archived = vm.createEntry(title: "Race archive", body: "x")
        vm.autoSave(archived)
        vm.toggleArchive(archived)

        let hidden = vm.createEntry(title: "Race hide", body: "x")
        vm.autoSave(hidden)
        vm.toggleHidden(hidden)

        // Wait past the debounce window; no stale snapshot may overwrite
        // the mutations.
        try await Task.sleep(nanoseconds: 1_200_000_000)

        #expect(vm.db.fetchEntry(id: pinned.id)?.isPinned == true)
        #expect(vm.db.fetchEntry(id: archived.id)?.isArchived == true)
        #expect(vm.db.fetchEntry(id: hidden.id)?.isHidden == true)

        // Keep the shared singleton database empty for the other suites.
        for id in [pinned.id, archived.id, hidden.id] { vm.db.hardDeleteEntry(id: id) }
    }

    @MainActor
    @Test("stopEditing persists the pending autosave synchronously")
    func stopEditingPersistsPendingAutosave() throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()
        let entry = vm.createEntry(title: "Flush on done", body: "")
        vm.startEditing(entry)

        var editing = try #require(vm.editingEntry)
        editing.body = "Final words typed right before Done."
        vm.autoSave(editing)
        vm.stopEditing()

        // stopEditing itself must have landed the save — no waiting for the
        // debounce, and no dependence on onDisappear flush ordering.
        #expect(vm.db.fetchEntry(id: entry.id)?.body == "Final words typed right before Done.")

        vm.db.hardDeleteEntry(id: entry.id)
    }

    @MainActor
    @Test("stopEditing discards a never-filled draft")
    func stopEditingDiscardsEmptyDraft() throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()
        let blank = vm.createEntry(title: "", body: "")
        vm.startEditing(blank)
        vm.stopEditing()

        #expect(vm.db.fetchEntry(id: blank.id) == nil)
    }

    @MainActor
    @Test("hidden state survives the JSON export/import round-trip")
    func hiddenStateSurvivesExportImportRoundTrip() throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()
        _ = vm.createEntry(title: "Visible entry", body: "x")
        let secret = vm.createEntry(title: "Secret entry", body: "shh")
        vm.toggleHidden(secret)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-export-\(UUID().uuidString).json")
        try ExportManager.exportJSON(vm.db.fetchAllEntriesForExport(), to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // The export file itself must carry the hidden flag.
        let exported = try JSONDecoder.dateWithISO8601.decode(
            ExportManager.JSONExport.self, from: Data(contentsOf: url))
        #expect(exported.entries.first { $0.title == "Secret entry" }?.isHidden == true)

        // Re-import under fresh IDs so the importer treats every row as new,
        // exercising the real importJSON path end to end.
        let remapped = ExportManager.JSONExport(
            exportDate: exported.exportDate,
            appVersion: exported.appVersion,
            entryCount: exported.entries.count,
            entries: exported.entries.map { je in
                ExportManager.JSONEntry(
                    id: UUID().uuidString, title: je.title, body: je.body,
                    mood: je.mood, moodLabel: je.moodLabel, tags: je.tags,
                    createdAt: je.createdAt, updatedAt: je.updatedAt,
                    isPinned: je.isPinned, isFavorite: je.isFavorite,
                    wordCount: je.wordCount, isArchived: je.isArchived,
                    deletedAt: je.deletedAt, isHidden: je.isHidden)
            })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reimportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-reimport-\(UUID().uuidString).json")
        try encoder.encode(remapped).write(to: reimportURL)
        defer { try? FileManager.default.removeItem(at: reimportURL) }

        let added = vm.importJSON(from: reimportURL)
        #expect(added == 2)
        #expect(vm.db.fetchAllEntries(scope: .all).first { $0.title == "Secret entry" }?.isHidden == true)
        #expect(vm.db.fetchAllEntries(scope: .all).first { $0.title == "Visible entry" }?.isHidden == false)

        // Keep the shared singleton database empty for the other suites.
        for e in vm.db.fetchAllEntries(scope: .all) where e.title.hasSuffix("entry") {
            vm.db.hardDeleteEntry(id: e.id)
        }
    }

    @MainActor
    @Test("old v2 backups without isHidden import as visible entries")
    func oldFormatBackupsImportAsVisible() throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()

        let oldJSON = """
        {"exportDate":"2026-09-07T12:00:00Z","appVersion":"1.0","entryCount":1,
         "entries":[{"id":"old-format-1","title":"Old backup entry","body":"b","mood":3,
         "moodLabel":"okay","tags":[],"createdAt":"2026-09-01T10:00:00Z",
         "updatedAt":"2026-09-01T10:00:00Z","isPinned":false,"isFavorite":false,
         "wordCount":1}]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-old-\(UUID().uuidString).json")
        try Data(oldJSON.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let added = vm.importJSON(from: url)
        #expect(added == 1)
        #expect(vm.db.fetchEntry(id: "old-format-1")?.isHidden == false)

        vm.db.hardDeleteEntry(id: "old-format-1")
    }

    @MainActor
    @Test("renaming a tag to its own name is a no-op")
    func renamingTagToItselfIsNoOp() throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()
        let entry = vm.createEntry(title: "Tag noop", body: "x", tags: ["solo"])

        vm.db.renameTag(from: "solo", to: "solo")

        #expect(vm.db.tagsWithCounts().contains { $0.tag == "solo" && $0.count == 1 })
        #expect(vm.db.fetchEntry(id: entry.id)?.tags.contains("solo") == true)

        vm.db.hardDeleteEntry(id: entry.id)
    }
}

private extension JSONDecoder {
    static let dateWithISO8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
