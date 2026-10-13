import AppKit
import Foundation
import SwiftUI
import Testing
import OmegaJournalCore
@testable import OmegaJournal

/// A write failure the VM's injected save seam throws. The message deliberately
/// contains the entry body so the privacy test can prove it never surfaces.
private struct InjectedSaveError: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// Toggleable failing writer installed through `JournalViewModel.saveWriterOverride`.
/// When `failing` is false it delegates to the real database.
@MainActor
private final class FlakyWriter {
    var failing = true
    var attempts = 0
    var message = "Save failed: disk I/O error"
    func install(on vm: JournalViewModel) {
        vm.saveWriterOverride = { [unowned self, unowned vm] entry in
            self.attempts += 1
            if self.failing { throw InjectedSaveError(text: "\(self.message) [\(entry.body)]") }
            try vm.db.saveEntryChecked(entry)
        }
    }
}

@Suite("Wave 3 save failures are visible and never lose text", .serialized)
@MainActor
struct Wave3SaveFailureTests {
    private func makeVM() -> JournalViewModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-save-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", dir.appendingPathComponent("db.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", dir.appendingPathComponent("att").path, 1)
        // A private database: this suite holds unsaved entries across a debounce
        // window, which would leak into parallel suites sharing the singleton.
        let db = DatabaseManager(databasePath: dir.appendingPathComponent("private.sqlite3").path,
                                 attachmentsPath: dir.appendingPathComponent("private-att").path)
        return JournalViewModel(database: db)
    }

    private func edit(_ vm: JournalViewModel, id: String, body: String) throws {
        var e = try #require(vm.entry(id: id))
        e.body = body
        vm.autoSave(e)
    }

    @Test("debounced autosave failure → failed state, snapshot retained, never 'saved'")
    func debouncedFailureIsVisible() async throws {
        let vm = makeVM()
        let id = vm.createEntry(title: "Fail", body: "original").id
        defer { vm.db.hardDeleteEntry(id: id) }
        let writer = FlakyWriter(); writer.install(on: vm)
        try edit(vm, id: id, body: "typed but not stored")
        #expect(vm.saveState == .pending)
        // Poll: under a loaded parallel test run the main actor can be busy
        // past the 700 ms window. Nothing else flushes here.
        for _ in 0..<50 where vm.saveState == .pending {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(writer.attempts >= 1)
        #expect(vm.saveState == .failed(.writeFailed))
        #expect(vm.saveState != .saved)
        #expect(vm.unsavedSnapshots[id]?.body == "typed but not stored")
        #expect(vm.entry(id: id)?.body == "typed but not stored")
        #expect(vm.db.fetchEntry(id: id)?.body == "original")
    }

    @Test("flushPendingSave never turns pending into saved after a failed write")
    func flushFailureStaysFailed() throws {
        let vm = makeVM()
        let id = vm.createEntry(title: "Flush", body: "a").id
        defer { vm.db.hardDeleteEntry(id: id) }
        let writer = FlakyWriter(); writer.install(on: vm)
        try edit(vm, id: id, body: "flush me")
        vm.flushPendingSave()
        #expect(vm.saveState.isFailed)
        #expect(vm.unsavedSnapshots[id]?.body == "flush me")
        // A second flush with nothing new must not clear the failure either.
        vm.flushPendingSave()
        #expect(vm.saveState.isFailed)
    }

    @Test("explicit Retry after the store recovers → saved, text in storage")
    func retrySucceeds() throws {
        let vm = makeVM()
        let id = vm.createEntry(title: "Retry", body: "a").id
        defer { vm.db.hardDeleteEntry(id: id) }
        let writer = FlakyWriter(); writer.install(on: vm)
        try edit(vm, id: id, body: "retry body")
        vm.flushPendingSave()
        #expect(vm.saveState.isFailed)
        #expect(vm.retryFailedSaves() == false)
        #expect(vm.saveState.isFailed)
        writer.failing = false
        #expect(vm.retryFailedSaves())
        #expect(vm.saveState == .saved)
        #expect(vm.unsavedSnapshots.isEmpty)
        #expect(vm.db.fetchEntry(id: id)?.body == "retry body")
    }

    @Test("the next edit retries automatically")
    func nextEditRetries() throws {
        let vm = makeVM()
        let id = vm.createEntry(title: "Next", body: "a").id
        defer { vm.db.hardDeleteEntry(id: id) }
        let writer = FlakyWriter(); writer.install(on: vm)
        try edit(vm, id: id, body: "first")
        vm.flushPendingSave()
        #expect(vm.saveState.isFailed)
        vm.toast = nil
        try edit(vm, id: id, body: "first again")
        #expect(vm.saveState.isFailed, "typing must not hide an unresolved failure behind 'Saving…'")
        vm.flushPendingSave()
        #expect(vm.saveState.isFailed)
        #expect(vm.toast == nil, "the failure toast is shown once per episode, not on every retry")
        writer.failing = false
        try edit(vm, id: id, body: "first second")
        vm.flushPendingSave()
        #expect(vm.saveState == .saved)
        #expect(vm.unsavedSnapshots.isEmpty)
        #expect(vm.db.fetchEntry(id: id)?.body == "first second")
    }

    @Test("switching entries with a failed save keeps the text, even across reload")
    func switchingKeepsText() throws {
        let vm = makeVM()
        let a = vm.createEntry(title: "A", body: "a").id
        let b = vm.createEntry(title: "B", body: "b").id
        defer { vm.db.hardDeleteEntry(id: a); vm.db.hardDeleteEntry(id: b) }
        let writer = FlakyWriter(); writer.install(on: vm)
        vm.startEditing(try #require(vm.entry(id: a)))
        try edit(vm, id: a, body: "A unsaved words")
        // Typing in B persists A's queued snapshot first — which fails.
        vm.startEditing(try #require(vm.entry(id: b)))
        try edit(vm, id: b, body: "B words")
        vm.flushPendingSave()
        #expect(vm.unsavedSnapshots[a]?.body == "A unsaved words")
        #expect(vm.saveState.isFailed)
        vm.reload()
        #expect(vm.entry(id: a)?.body == "A unsaved words", "reload must not replace unsaved text with stale storage")
        writer.failing = false
        #expect(vm.retryFailedSaves())
        #expect(vm.db.fetchEntry(id: a)?.body == "A unsaved words")
        #expect(vm.db.fetchEntry(id: b)?.body == "B words")
        #expect(vm.saveState == .saved)
    }

    @Test("stopEditing with a failed save keeps the text and the failed state")
    func stopEditingKeepsText() throws {
        let vm = makeVM()
        let id = vm.createEntry(title: "", body: "").id
        defer { vm.db.hardDeleteEntry(id: id) }
        let writer = FlakyWriter(); writer.install(on: vm)
        try edit(vm, id: id, body: "only copy of this text")
        vm.stopEditing()
        #expect(vm.editingEntryId == nil)
        #expect(vm.saveState.isFailed, "closing the editor must not reset a failure to idle")
        #expect(vm.unsavedSnapshots[id]?.body == "only copy of this text")
        #expect(vm.entry(id: id)?.body == "only copy of this text", "a failed entry must not be discarded as empty")
        writer.failing = false
        #expect(vm.retryFailedSaves())
        #expect(vm.db.fetchEntry(id: id)?.body == "only copy of this text")
    }

    @Test("retrying an old snapshot never reverts a later immediate mutation")
    func retryKeepsImmediateMutations() throws {
        let vm = makeVM()
        let id = vm.createEntry(title: "Pin", body: "a").id
        defer { vm.db.hardDeleteEntry(id: id) }
        let writer = FlakyWriter(); writer.install(on: vm)
        try edit(vm, id: id, body: "edited")
        vm.flushPendingSave()
        vm.togglePin(try #require(vm.entry(id: id)))
        vm.setMood(.great, for: try #require(vm.entry(id: id)))
        writer.failing = false
        vm.retryFailedSaves()
        let stored = try #require(vm.db.fetchEntry(id: id))
        #expect(stored.isPinned)
        #expect(stored.mood == .great)
        #expect(stored.body == "edited")
    }

    @Test("failure text and accessibility label never include the entry body")
    func failureTextIsPrivate() throws {
        let vm = makeVM()
        let id = vm.createEntry(title: "Private", body: "a").id
        defer { vm.db.hardDeleteEntry(id: id) }
        let writer = FlakyWriter(); writer.install(on: vm)
        writer.message = "Save failed: attempt to write a readonly database"
        let secret = "my secret diary sentence"
        try edit(vm, id: id, body: secret)
        vm.flushPendingSave()
        let status = vm.saveState
        #expect(status == .failed(.readOnly))
        for text in [SaveStatusPresentation.label(status), SaveStatusPresentation.accessibilityLabel(status),
                     SaveStatusPresentation.help(status) ?? "", vm.toast?.message ?? ""] {
            #expect(!text.contains(secret))
        }
        #expect(vm.toast?.isError == true)
    }

    @Test("reason classification maps low-level errors to fixed wording",
          arguments: [
            ("Save failed: attempt to write a readonly database", SaveFailureReason.readOnly),
            ("Could not encrypt entry body — save aborted: Keychain unavailable", .encryptionUnavailable),
            ("This entry's stored text can't be decrypted, so the new text was NOT saved", .undecryptable),
            ("Save failed: database or disk is full", .diskFull),
            ("Commit failed: database is locked", .databaseBusy),
            ("Save failed: constraint failed", .writeFailed),
          ])
    func classify(message: String, expected: SaveFailureReason) {
        #expect(SaveFailureReason.classify(message) == expected)
        #expect(!SaveFailureReason.classify(message).message.isEmpty)
    }

    @Test("failed indicator wording")
    func wording() {
        let failed = SaveStatus.failed(.diskFull)
        #expect(SaveStatusPresentation.label(failed) == "Not saved")
        #expect(SaveStatusPresentation.accessibilityLabel(failed).hasPrefix("Not saved. The disk is full."))
        #expect(SaveStatusPresentation.label(.pending) == "Saving…")
        #expect(SaveStatusPresentation.label(.saved) == "Saved")
        #expect(SaveStatusPresentation.help(.saved) == nil)
    }

    @Test("failed indicator and Retry stay visible in narrow columns and Zen",
          arguments: [(360.0, true), (360.0, false), (900.0, true)])
    func failedIndicatorVisible(width: Double, zen: Bool) throws {
        _ = NSApplication.shared
        final class Box { var frame: CGRect? }
        let box = Box()
        let footer = WritingFooterView(
            wordCount: 1234, charCount: 7890, selectionWords: 0, readingTime: "6 min read", attachmentCount: 2,
            sessionStart: Date(), sessionStartWords: 0,
            ring: WritingSessionMath.goalRing(otherWordsToday: 100, liveEntryWords: 50, target: 500),
            sprint: nil, sprintFinished: false, isZen: zen, saveState: .failed(.writeFailed),
            onStartSprint: { _ in }, onStopSprint: {}, onRetrySave: {},
            onSaveIndicatorFrame: { box.frame = $0 })
        let hosting = NSHostingView(rootView: footer.frame(width: width))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        let f = try #require(box.frame, "no save-state element (zen=\(zen), width=\(width))")
        // "Not saved" + Retry needs more room than the old checkmark.
        #expect(f.width > 60, "failed indicator squeezed to \(f.width)")
        #expect(f.minX >= -0.5 && f.maxX <= width + 0.5, "failed indicator clipped: \(f) in \(width)")
        _ = window
    }
}
