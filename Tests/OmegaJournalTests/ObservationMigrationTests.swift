import AppKit
import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

/// Guards the semantics the Combine pipelines had before the move to
/// `@Observable`: view state persists only on a real change after `init`,
/// and tag counts re-derive when the biometric session really changes.
@Suite("Observation migration semantics", .serialized, .lockState)
@MainActor
struct ObservationMigrationTests {
    private static func makeVM() throws -> (JournalViewModel, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-observation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Not into `root`: it is deleted after each test, and a `.shared`
        // opened by another suite in between would point at a deleted file.
        TestSharedEnvironment.pin()
        let db = DatabaseManager(databasePath: root.appendingPathComponent("private.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("private-att", isDirectory: true).path)
        return (JournalViewModel(database: db), root)
    }

    private static let sentinel = "untouched"

    @Test("sort order persists on a real change only, never while loading")
    func sortOrderPersistsOnRealChange() throws {
        let (vm, root) = try Self.makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        vm.setSortOrder(.titleAsc)
        #expect(vm.db.getSetting(JournalViewModel.sortOrderSettingKey) == SortOrder.titleAsc.rawValue)

        // A new VM loads the saved order without writing it back.
        vm.db.setSetting(JournalViewModel.sortOrderSettingKey, value: SortOrder.titleAsc.rawValue)
        let reloaded = JournalViewModel(database: vm.db)
        #expect(reloaded.sortOrder == .titleAsc)
        vm.db.setSetting(JournalViewModel.sortOrderSettingKey, value: Self.sentinel)
        reloaded.sortOrder = .titleAsc          // equal value: no write
        #expect(vm.db.getSetting(JournalViewModel.sortOrderSettingKey) == Self.sentinel)
        reloaded.sortOrder = .dateAsc           // real change: written synchronously
        #expect(vm.db.getSetting(JournalViewModel.sortOrderSettingKey) == SortOrder.dateAsc.rawValue)
    }

    @Test("filter persists on a real change only")
    func filterPersistsOnRealChange() throws {
        let (vm, root) = try Self.makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        vm.db.setSetting(JournalViewModel.filterSettingKey, value: Self.sentinel)
        vm.filter = vm.filter                   // equal value: no write
        #expect(vm.db.getSetting(JournalViewModel.filterSettingKey) == Self.sentinel)

        var changed = vm.filter
        changed.favoritesOnly.toggle()
        vm.filter = changed
        let stored = vm.db.getSetting(JournalViewModel.filterSettingKey)
        let decoded = try JSONDecoder().decode(EntryFilter.self, from: Data(stored.utf8))
        #expect(decoded == changed)
    }

    @Test("tag counts re-derive after a real lock-state change")
    func tagCountsFollowLockState() async throws {
        let (vm, root) = try Self.makeVM()
        defer {
            BiometricAuth.shared.setAuthenticatedForTesting(false)
            try? FileManager.default.removeItem(at: root)
        }
        BiometricAuth.shared.setAuthenticatedForTesting(true)
        let entry = vm.createEntry(title: "Observation hidden", body: "x", tags: ["obs-secret"], isHidden: true)
        vm.stopEditing()
        vm.refreshTagCounts()
        #expect(vm.allTags.contains { $0.tag == "obs-secret" })

        // Locking without going through the VM still re-derives counts.
        // BiometricAuth.shared is process-global and parallel suites flip it
        // while this test waits, so a poll that doesn't see the wanted counts
        // makes a real change into the wanted state again (a redundant set is
        // not a change and notifies nobody). Only the session observer
        // re-derives the counts; the test never calls refreshTagCounts here.
        #expect(await Self.waitUntil {
            if !vm.allTags.contains(where: { $0.tag == "obs-secret" }) { return true }
            Self.changeSession(to: false)
            return false
        })

        #expect(await Self.waitUntil {
            if vm.allTags.contains(where: { $0.tag == "obs-secret" }) { return true }
            Self.changeSession(to: true)
            return false
        })
        vm.db.hardDeleteEntry(id: entry.id)
    }

    @Test("every tag rewrite bumps the generation, even a repeated one")
    func tagRewriteGenerationBumps() throws {
        let (vm, root) = try Self.makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = vm.tagRewriteGeneration
        vm.applyTagRewriteToUnsavedSnapshots(.delete("obs-gone"))
        vm.applyTagRewriteToUnsavedSnapshots(.delete("obs-gone"))
        #expect(vm.tagRewriteGeneration == start + 2)
        #expect(vm.lastTagRewrite == .delete("obs-gone"))
    }

    /// Forces a real lock-state change that ends in `authenticated`.
    private static func changeSession(to authenticated: Bool) {
        BiometricAuth.shared.setAuthenticatedForTesting(!authenticated)
        BiometricAuth.shared.setAuthenticatedForTesting(authenticated)
    }

    private static func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
