import AppKit
import Foundation
import SwiftUI
import Testing
import OmegaJournalCore
@testable import OmegaJournal

/// Audit group B: view-model autosave, privacy and app-lifecycle regressions.
@Suite("Audit fixes B — autosave, privacy, lifecycle", .serialized)
@MainActor
struct AuditFixesBTests {
    private static func isolate() throws {
        // View structs below touch ThemeManager, which observes NSApp.
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-audit-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    /// Fresh VM with no pending state; every test removes the rows it made.
    private func makeVM() throws -> JournalViewModel {
        try Self.isolate()
        BiometricAuth.shared.setAuthenticatedForTesting(false)
        return JournalViewModel()
    }

    private func cleanup(_ vm: JournalViewModel) {
        vm.saveDebounce?.cancel()
        for e in vm.db.fetchAllEntriesForExport() where e.title.hasPrefix("AB ") || e.tags.contains("auditb") || e.tags.contains("review") || e.tags.contains(QuickCapture.tag) {
            vm.db.hardDeleteEntry(id: e.id)
        }
        BiometricAuth.shared.setAuthenticatedForTesting(false)
        vm.reload()
    }

    private func tempDB() -> (DatabaseManager, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omega-audit-b-lock-\(UUID().uuidString)")
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("a").path)
        return (db, root)
    }

    // MARK: 1. App lock enforced

    @Test("the ready launch root is wrapped in the app-lock gate")
    func launchRootIsGated() throws {
        let (db, root) = tempDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = AppLockManager(db: db, auth: BiometricAuth(forTesting: ()), observeApp: false)
        let typeName = String(describing: type(of: LaunchGateView.readyRoot(lock: lock)))
        #expect(typeName.contains("ContentView"))
        #expect(typeName.contains("AppLockGate"))
    }

    @Test("an enabled app lock is locked at launch and re-locks after leaving the app")
    func appLockLocksAtLaunchAndOnReturn() async throws {
        let (db, root) = tempDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = BiometricAuth(forTesting: ())
        var allow = true
        auth.evaluateOverride = { allow }
        db.setSetting(AppLockManager.enabledKey, value: "true")
        db.setSetting(AppLockManager.timeoutKey, value: "\(AppLockTimeout.immediately.rawValue)")

        let lock = AppLockManager(db: db, auth: auth, observeApp: true)
        #expect(lock.isLocked)
        #expect(lock.isObservingApp)
        #expect(await lock.unlock() && !lock.isLocked)

        // Real app notifications must drive the lock (observers installed).
        allow = false
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(lock.isLocked)
    }

    // MARK: 2. Autosave data loss

    @Test("A1: a pending edit survives createEntry + flush")
    func pendingEditSurvivesCreate() throws {
        let vm = try makeVM()
        defer { cleanup(vm) }
        let a = vm.createEntry(title: "AB A1", body: "original")
        vm.startEditing(a)
        var edited = try #require(vm.editingEntry)
        edited.body = "A1 edited text"
        vm.autoSave(edited)
        let b = vm.createEntry(title: "AB A1 other", body: "")
        vm.flushPendingSave()
        #expect(vm.db.fetchEntry(id: a.id)?.body == "A1 edited text")
        vm.db.hardDeleteEntry(id: b.id)
    }

    @Test("A2: a pending edit survives switching the editor to another entry")
    func pendingEditSurvivesSwitch() throws {
        let vm = try makeVM()
        defer { cleanup(vm) }
        let a = vm.createEntry(title: "AB A2", body: "original")
        let b = vm.createEntry(title: "AB A2 other", body: "b")
        vm.startEditing(a)
        var edited = try #require(vm.editingEntry)
        edited.body = "A2 edited text"
        vm.autoSave(edited)
        vm.startEditing(b)
        vm.flushPendingSave()
        #expect(vm.db.fetchEntry(id: a.id)?.body == "A2 edited text")
    }

    @Test("B: trashing an entry with a pending edit keeps the edit and stays trashed until undo")
    func trashKeepsPendingEdit() async throws {
        let vm = try makeVM()
        defer { cleanup(vm) }
        let a = vm.createEntry(title: "AB B", body: "original")
        vm.startEditing(a)
        var edited = try #require(vm.editingEntry)
        edited.body = "B edited text"
        vm.autoSave(edited)
        vm.deleteEntry(edited)
        // No resurrection: the flushed save happened before the trash.
        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(vm.db.fetchEntry(id: a.id)?.isTrashed == true)
        vm.performUndo()
        #expect(vm.db.fetchEntry(id: a.id)?.body == "B edited text")
        #expect(vm.entry(id: a.id)?.body == "B edited text")
    }

    @Test("C: trashing another entry, undoing and finishing keeps the pending edit")
    func otherTrashUndoKeepsPendingEdit() throws {
        let vm = try makeVM()
        defer { cleanup(vm) }
        let b = vm.createEntry(title: "AB C other", body: "b")
        vm.stopEditing()
        let a = vm.createEntry(title: "AB C", body: "original")
        vm.startEditing(a)
        var edited = try #require(vm.editingEntry)
        edited.body = "C edited text"
        vm.autoSave(edited)
        vm.deleteEntry(b)
        vm.performUndo()
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: a.id)?.body == "C edited text")
    }

    @Test("bulk trash and reload flush the pending snapshot")
    func bulkTrashAndReloadFlush() throws {
        let vm = try makeVM()
        defer { cleanup(vm) }
        let a = vm.createEntry(title: "AB bulk", body: "original")
        vm.startEditing(a)
        var edited = try #require(vm.editingEntry)
        edited.body = "bulk edited"
        vm.autoSave(edited)
        vm.reload()
        #expect(vm.db.fetchEntry(id: a.id)?.body == "bulk edited")

        edited.body = "bulk edited twice"
        vm.autoSave(edited)
        vm.bulkSelection = [a.id]
        vm.bulkMoveToTrash()
        let stored = try #require(vm.db.fetchEntry(id: a.id))
        #expect(stored.body == "bulk edited twice")
        #expect(stored.isTrashed)
    }

    // MARK: 3. Zen editor identity

    @Test("the zen editor is keyed by entry id")
    func zenEditorIsKeyed() throws {
        let vm = try makeVM()
        defer { cleanup(vm) }
        let a = vm.createEntry(title: "AB zen", body: "x")
        let typeName = String(describing: type(of: ContentView.zenEditor(vm: vm, entry: a)))
        #expect(typeName.contains("IDView"))
        #expect(typeName.contains("EditorView"))
    }

    // MARK: 4. Stats privacy

    @Test("word statistics exclude hidden entries while locked")
    func statsExcludeLockedHidden() throws {
        let vm = try makeVM()
        defer { cleanup(vm) }
        _ = vm.createEntry(title: "AB visible", body: "one two three", tags: ["auditb"])
        vm.stopEditing()
        var secret = vm.createEntry(title: "AB secret", body: String(repeating: "secretword ", count: 400), tags: ["auditb"])
        vm.stopEditing()
        secret.isHidden = true
        vm.db.saveEntry(secret)
        vm.reload()

        let visible = vm.entries.filter { !$0.isHidden }
        let visibleWords = visible.reduce(0) { $0 + $1.wordCount }
        #expect(vm.totalWordCount == visibleWords)
        #expect(vm.averageWordsPerEntry == (visible.isEmpty ? 0 : visibleWords / visible.count))
        let visibleMinutes = visible.reduce(0) { $0 + $1.readingMinutes }
        #expect(vm.totalReadingTime == (visibleMinutes < 60 ? "\(visibleMinutes) min" : "\(visibleMinutes / 60)h \(visibleMinutes % 60)m"))
        #expect(vm.wordsPerDay(days: 1).reduce(0) { $0 + $1.words } < 400)

        BiometricAuth.shared.setAuthenticatedForTesting(true)
        #expect(vm.totalWordCount == vm.entries.reduce(0) { $0 + $1.wordCount })
        #expect(vm.totalWordCount >= visibleWords + 400)
    }

    // MARK: 5. Duplicate keeps privacy and notebook

    @Test("duplicating a hidden entry keeps it hidden and in its notebook")
    func duplicateKeepsHiddenAndJournal() async throws {
        let vm = try makeVM()
        defer {
            cleanup(vm)
            for j in vm.journals where j.name.hasPrefix("AB ") { vm.deleteJournal(j) }
        }
        let journal = try #require(vm.createJournal(name: "AB Dup \(UUID().uuidString.prefix(6))", colorHex: "#336699"))
        var secret = vm.createEntry(title: "AB dup secret", body: "private", tags: ["auditb"])
        vm.stopEditing()
        secret.isHidden = true
        secret.journalId = journal.id
        vm.db.saveEntry(secret)
        vm.reload()
        BiometricAuth.shared.setAuthenticatedForTesting(true)

        let copy = try #require(await vm.duplicate(secret).value)
        let stored = try #require(vm.db.fetchEntry(id: copy.id))
        #expect(stored.isHidden)
        #expect(stored.journalId == journal.id)
        vm.stopEditing()
    }

    // MARK: 6. Backlinks / review dedupe

    @Test("unlocked backlinks and reviews count a hidden entry once")
    func hiddenEntriesNotDoubleCounted() throws {
        let vm = try makeVM()
        defer { cleanup(vm) }
        let target = vm.createEntry(title: "AB link target", body: "t", tags: ["auditb"])
        vm.stopEditing()
        var linker = vm.createEntry(title: "AB hidden linker", body: "see [[AB link target]]", tags: ["auditb"])
        vm.stopEditing()
        linker.isHidden = true
        vm.db.saveEntry(linker)
        vm.reload()
        BiometricAuth.shared.setAuthenticatedForTesting(true)

        #expect(vm.backlinks(for: target).map(\.id) == [linker.id])

        let now = Date()
        let cal = Calendar.current
        let expected = Set(vm.entries.filter { cal.isDate($0.createdAt, equalTo: now, toGranularity: .month) }.map(\.id)).count
        let review = vm.createReviewEntry(period: .month, reference: now)
        #expect(review.body.contains("**\(expected) \(expected == 1 ? "entry" : "entries")**"))
        vm.stopEditing()
    }

    // MARK: 7. Notebook switch

    @Test("switching notebooks closes an out-of-scope editor after saving it")
    func notebookSwitchClosesEditor() throws {
        let vm = try makeVM()
        defer {
            vm.setActiveJournal(nil)
            cleanup(vm)
            for j in vm.journals where j.name.hasPrefix("AB ") { vm.deleteJournal(j) }
        }
        let other = try #require(vm.createJournal(name: "AB Other \(UUID().uuidString.prefix(6))", colorHex: "#993366"))
        let a = vm.createEntry(title: "AB notebook", body: "original", tags: ["auditb"])
        vm.startEditing(a)
        var edited = try #require(vm.editingEntry)
        edited.body = "notebook edited"
        vm.autoSave(edited)

        vm.setActiveJournal(other.id)
        #expect(vm.selectedEntryId == nil)
        #expect(vm.editingEntryId == nil)
        #expect(vm.db.fetchEntry(id: a.id)?.body == "notebook edited")
    }

    // MARK: 8. Review reminder

    @Test("a review reminder request saves the review as an entry")
    func reviewRequestCreatesEntry() throws {
        let vm = try makeVM()
        defer { cleanup(vm) }
        #expect(JournalViewModel.reviewPeriod(fromRequest: ["period": "month"]) == .month)
        #expect(JournalViewModel.reviewPeriod(fromRequest: ["period": "bogus"]) == nil)
        let entry = try #require(vm.handleReviewRequest(userInfo: ["period": ReviewPeriod.week.rawValue]))
        #expect(entry.tags.contains("review"))
        #expect(vm.db.fetchEntry(id: entry.id) != nil)
        #expect(vm.handleReviewRequest(userInfo: [:]) == nil)
    }

    // MARK: 9. Quick capture before the journal window exists

    @Test("quick captures queued before the shell exists are saved when it drains")
    func quickCaptureInboxDrains() throws {
        QuickCaptureInbox.removeAll()
        // Submitted before any view model exists (LaunchGate not ready yet).
        QuickCaptureInbox.submit(QuickCaptureItem(body: "AB early capture", mood: .good, tags: ["quick", "auditb"]))
        #expect(QuickCaptureInbox.pendingCount == 1)

        let vm = try makeVM()
        defer { cleanup(vm) }
        let created = vm.drainQuickCaptureInbox()
        #expect(QuickCaptureInbox.pendingCount == 0)
        #expect(created.count == 1)
        let first = try #require(created.first)
        let stored = try #require(vm.db.fetchEntry(id: first.id))
        #expect(stored.body == "AB early capture")
        #expect(stored.mood == .good)
        #expect(stored.tags.contains("auditb"))
        #expect(vm.drainQuickCaptureInbox().isEmpty)
    }
}
