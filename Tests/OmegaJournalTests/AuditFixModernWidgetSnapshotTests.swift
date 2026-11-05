import Darwin
import Foundation
import Observation
import Testing
import OmegaJournalCore
import OmegaJournalShared
@testable import OmegaJournal

// Regression tests for audit finding MODERN-1 (widget snapshot followed the
// sidebar notebook selection).

/// Private DB per test; the env vars keep JournalCrypto on an ephemeral key
/// (never the real Keychain) and point `.shared` at a temp file too.
@MainActor
private func makeModernVM() -> (JournalViewModel, DatabaseManager) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-fix-modern-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    TestSharedEnvironment.pin()
    let db = DatabaseManager(databasePath: dir.appendingPathComponent("private.sqlite3").path,
                             attachmentsPath: dir.appendingPathComponent("private-att").path)
    return (JournalViewModel(database: db), db)
}

nonisolated private final class AuditFixModernChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var fired: Bool { lock.withLock { value } }
}

// MARK: - MODERN-1

/// The widget has no notebook context: its numbers (and the "Today's Writing
/// Progress" intent, which reads the same snapshot) cover the whole journal,
/// whatever notebook the sidebar shows.
@Suite("Audit fix modern: widget snapshot covers the whole journal", .serialized)
@MainActor
struct AuditFixModernWidgetSnapshotTests {
    @Test("a notebook switch leaves the snapshot, its fingerprint and the published file unchanged")
    func notebookSwitchDoesNotChangeSnapshot() throws {
        let (vm, db) = makeModernVM()
        defer { vm.setActiveJournal(nil) }
        let work = try #require(vm.createJournal(name: "Work", colorHex: "#336699"))
        vm.createEntry(title: "a", body: "one two three four five")          // default notebook, 5 words
        vm.createEntry(title: "b", body: "six seven eight", journalId: work.id) // Work, 3 words
        vm.stopEditing()
        let goals = GoalManager(db: db)
        let now = Date()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-fix-modern-pub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let publisher = WidgetSnapshotPublisher()
        publisher.storeOverride = WidgetSnapshotStore(directory: dir)
        var reloads = 0
        publisher.reloadTimelines = { reloads += 1 }

        let all = WidgetSnapshotPublisher.makeSnapshot(for: vm, goals: goals, now: now)
        let fingerprint = WidgetSnapshotPublisher.fingerprint(of: vm, goals: goals)
        #expect(all.days[0].words == 8)
        #expect(all.days[0].entries == 2)
        #expect(publisher.publishNow(vm, now: now) != nil)
        #expect(reloads == 1)

        // The user only clicks the Work notebook in the sidebar; nothing was written.
        vm.setActiveJournal(work.id)
        #expect(vm.entries.count == 1, "precondition: the sidebar list is scoped to Work")
        let scoped = WidgetSnapshotPublisher.makeSnapshot(for: vm, goals: goals, now: now)
        #expect(scoped.days[0].words == 8, "widget words dropped to \(scoped.days[0].words) after a notebook switch")
        #expect(scoped.days[0].entries == 2)
        #expect(WidgetSnapshotPublisher.sameContent(all, scoped))
        #expect(WidgetSnapshotPublisher.fingerprint(of: vm, goals: goals) == fingerprint,
                "a notebook switch must not look like a data change")
        #expect(publisher.publishNow(vm, now: now.addingTimeInterval(5)) == nil, "nothing to republish")
        #expect(reloads == 1)
        #expect(WidgetSnapshotStore(directory: dir).read()?.days.first?.words == 8)
    }

    @Test("an entry written outside the selected notebook moves the fingerprint and counts")
    func changesOutsideSelectedNotebookCount() throws {
        let (vm, db) = makeModernVM()
        defer { vm.setActiveJournal(nil) }
        let work = try #require(vm.createJournal(name: "Work", colorHex: "#336699"))
        vm.createEntry(title: "b", body: "six seven eight", journalId: work.id)
        vm.stopEditing()
        vm.setActiveJournal(work.id)
        let goals = GoalManager(db: db)
        let before = WidgetSnapshotPublisher.fingerprint(of: vm, goals: goals)

        // Stored in the default notebook (e.g. a capture) while Work is selected.
        var other = JournalEntry.new()
        other.journalId = JournalDefaults.defaultJournalId
        other.body = "nine ten"
        #expect(db.saveEntry(other))
        #expect(!vm.entries.contains { $0.id == other.id }, "precondition: not in the scoped list")

        #expect(WidgetSnapshotPublisher.fingerprint(of: vm, goals: goals) != before)
        let snapshot = WidgetSnapshotPublisher.makeSnapshot(for: vm, goals: goals)
        #expect(snapshot.days[0].words == 5)
        #expect(snapshot.days[0].entries == 2)
    }

    @Test("hidden, trashed and archived entries count nowhere, in any notebook; no text reaches the file")
    func excludesPrivateAndRemovedEntriesJournalWide() throws {
        let (vm, db) = makeModernVM()
        defer { vm.setActiveJournal(nil) }
        let work = try #require(vm.createJournal(name: "Work", colorHex: "#336699"))
        vm.createEntry(title: "Visible XYZZY", body: "visible PLUGH words")              // default, 3 words
        vm.createEntry(title: "Hidden FROBOZZ", body: "hidden GRUE text here", journalId: work.id, isHidden: true)
        let trashed = vm.createEntry(title: "Trashed", body: "trashed words count not", journalId: work.id)
        let archived = vm.createEntry(title: "Archived", body: "archived words do not count", journalId: work.id)
        vm.stopEditing()
        vm.deleteEntry(trashed)
        vm.toggleArchive(try #require(vm.entries.first { $0.id == archived.id }))
        vm.setActiveJournal(work.id)
        let goals = GoalManager(db: db)

        let snapshot = WidgetSnapshotPublisher.makeSnapshot(for: vm, goals: goals)
        #expect(snapshot.days[0].words == 3)
        #expect(snapshot.days[0].entries == 1)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-fix-modern-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WidgetSnapshotStore(directory: dir)
        try store.write(snapshot)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        for secret in ["XYZZY", "PLUGH", "FROBOZZ", "GRUE", "title", "body"] {
            #expect(!text.contains(secret), "snapshot leaked \(secret)")
        }
    }

    @Test("an edit still waiting for the autosave counts; a hidden one never does")
    func pendingEditCounts() throws {
        let (vm, db) = makeModernVM()
        let goals = GoalManager(db: db)
        let entry = vm.createEntry(title: "t", body: "one two")
        defer { vm.stopEditing() }
        let before = WidgetSnapshotPublisher.fingerprint(of: vm, goals: goals)
        var typed = try #require(vm.entries.first { $0.id == entry.id })
        typed.body = "one two three four"
        vm.autoSave(typed)
        #expect(vm.pendingSave != nil, "precondition: the write is still debounced")
        #expect(WidgetSnapshotPublisher.makeSnapshot(for: vm, goals: goals).days[0].words == 4)
        #expect(WidgetSnapshotPublisher.fingerprint(of: vm, goals: goals) != before)
        vm.flushPendingSave()

        let hidden = vm.createEntry(title: "h", body: "secret", isHidden: true)
        var hiddenTyped = try #require(vm.entries.first { $0.id == hidden.id })
        hiddenTyped.body = "secret secret secret secret secret"
        vm.autoSave(hiddenTyped)
        #expect(WidgetSnapshotPublisher.makeSnapshot(for: vm, goals: goals).days[0].words == 4)
        vm.flushPendingSave()
    }

    @Test("the fingerprint re-evaluates after a write in a notebook the sidebar doesn't show")
    func fingerprintObservesWholeLibrary() throws {
        let (vm, db) = makeModernVM()
        defer { vm.setActiveJournal(nil) }
        let work = try #require(vm.createJournal(name: "Work", colorHex: "#336699"))
        vm.setActiveJournal(work.id)
        let goals = GoalManager(db: db)
        let flag = AuditFixModernChangeFlag()
        // What ContentView's body does: the fingerprint's reads are its dependencies.
        withObservationTracking { _ = WidgetSnapshotPublisher.fingerprint(of: vm, goals: goals) } onChange: { flag.set() }
        var other = JournalEntry.new()
        other.journalId = JournalDefaults.defaultJournalId
        other.body = "nine ten"
        #expect(db.saveEntry(other))
        vm.reload() // every mutation path ends in a reload or a library update
        #expect(vm.entries.isEmpty, "precondition: the Work list itself did not change")
        #expect(flag.fired, "ContentView would never recompute the fingerprint")
    }
}
