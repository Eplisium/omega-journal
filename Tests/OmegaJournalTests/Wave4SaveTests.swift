import AppKit
import Foundation
import SwiftUI
import Testing
import OmegaJournalCore
@testable import OmegaJournal

/// Injected write failure. Its message embeds the body so privacy checks can
/// prove the body never reaches user-facing text.
private struct Wave4InjectedError: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// Writer installed through `saveWriterOverride`. When `failing` is false it
/// delegates to the real database write.
@MainActor
private final class Wave4Writer {
    var failing = true
    var attempts = 0
    func install(on vm: JournalViewModel) {
        vm.saveWriterOverride = { [unowned self, unowned vm] entry in
            self.attempts += 1
            if self.failing { throw Wave4InjectedError(text: "Save failed: disk I/O error [\(entry.body)]") }
            try vm.db.saveEntryChecked(entry)
        }
    }
}

@Suite("Wave 4 save: persistent unsaved indicator, tag rewrites, undecryptable body", .serialized)
@MainActor
struct Wave4SaveTests {
    /// Private database per test: these tests keep unsaved entries alive.
    private func makeVM() -> JournalViewModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-w4save-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = DatabaseManager(databasePath: dir.appendingPathComponent("private.sqlite3").path,
                                 attachmentsPath: dir.appendingPathComponent("private-att").path)
        return JournalViewModel(database: db)
    }

    private func edit(_ vm: JournalViewModel, id: String, body: String) throws {
        var e = try #require(vm.entry(id: id))
        e.body = body
        vm.autoSave(e)
    }

    // MARK: (1) Persistent indicator

    @Test("unsaved entries are published per entry and as a count until a retry lands")
    func unsavedCountIsPublished() throws {
        let vm = makeVM()
        let a = vm.createEntry(title: "A", body: "a").id
        let b = vm.createEntry(title: "B", body: "b").id
        let writer = Wave4Writer(); writer.install(on: vm)
        #expect(vm.unsavedEntryCount == 0)
        #expect(!vm.hasUnsavedChanges(entryId: a))
        try edit(vm, id: a, body: "a unsaved")
        vm.stopEditing()
        #expect(vm.unsavedEntryCount == 1)
        #expect(vm.unsavedEntryIds == [a])
        #expect(vm.hasUnsavedChanges(entryId: a))
        #expect(!vm.hasUnsavedChanges(entryId: b))
        #expect(vm.unsavedFailureReason(entryId: a) == .writeFailed)
        #expect(vm.unsavedFailureReason(entryId: b) == nil)
        writer.failing = false
        #expect(vm.retryFailedSaves())
        #expect(vm.unsavedEntryCount == 0)
        #expect(!vm.hasUnsavedChanges(entryId: a))
        #expect(vm.unsavedFailureReason(entryId: a) == nil)
    }

    @Test("the per-entry reason survives a later failure of another entry")
    func perEntryReason() throws {
        let vm = makeVM()
        let a = vm.createEntry(title: "A", body: "a").id
        let b = vm.createEntry(title: "B", body: "b").id
        var failure = "Save failed: database or disk is full"
        vm.saveWriterOverride = { _ in throw Wave4InjectedError(text: failure) }
        try edit(vm, id: a, body: "a2")
        vm.flushPendingSave()
        failure = "Commit failed: database is locked"
        // Only b is written fresh; a is retried and fails with the new error.
        try edit(vm, id: b, body: "b2")
        vm.flushPendingSave()
        #expect(vm.unsavedEntryCount == 2)
        #expect(vm.unsavedFailureReason(entryId: b) == .databaseBusy)
        #expect(vm.unsavedFailureReason(entryId: a) != nil)
    }

    @Test("banner and count wording carry the reason only, never the body")
    func bannerWording() {
        let secret = "my secret diary sentence"
        for reason in SaveFailureReason.allCases {
            let text = SaveUnsavedPresentation.bannerText(reason)
            #expect(text.hasPrefix("Not saved · "))
            #expect(text.contains(reason.message))
            #expect(!text.contains(secret))
            #expect(SaveUnsavedPresentation.bannerAccessibilityLabel(reason).contains(reason.message))
        }
        #expect(SaveUnsavedPresentation.countLabel(0) == nil)
        #expect(SaveUnsavedPresentation.countLabel(1) == "1 entry not saved")
        #expect(SaveUnsavedPresentation.countLabel(3) == "3 entries not saved")
    }

    @Test("reader banner shows Not saved, the reason and Retry at narrow widths", arguments: [320.0, 720.0])
    func readerBannerVisible(width: Double) throws {
        _ = NSApplication.shared
        final class Box { var frame: CGRect? }
        let box = Box()
        let banner = UnsavedEntryBanner(reason: .diskFull, onRetry: {}, onFrame: { box.frame = $0 })
        let hosting = NSHostingView(rootView: banner.frame(width: width))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        let f = try #require(box.frame, "Retry button never laid out at width \(width)")
        #expect(f.width > 20)
        #expect(f.minX >= -0.5 && f.maxX <= width + 0.5, "Retry clipped: \(f) in \(width)")
        _ = window
    }

    @Test("quit: retry first, then warn only while snapshots remain")
    func quitDecision() throws {
        #expect(SaveQuitDecision.decide(unsavedCount: 0) == .terminate)
        #expect(SaveQuitDecision.decide(unsavedCount: 2) == .confirm(unsavedCount: 2))
        let msg = SaveUnsavedPresentation.quitAlertMessage(unsavedCount: 2)
        #expect(msg.contains("2 entries"))
        #expect(SaveUnsavedPresentation.quitAlertTitle == "Quit without saving?")

        let vm = makeVM()
        let id = vm.createEntry(title: "Q", body: "q").id
        let writer = Wave4Writer(); writer.install(on: vm)
        try edit(vm, id: id, body: "queued, not yet flushed")
        // A queued debounce is written by the quit check itself.
        #expect(vm.quitDecision() == .confirm(unsavedCount: 1))
        #expect(vm.unsavedSnapshots[id]?.body == "queued, not yet flushed")
        writer.failing = false
        #expect(vm.quitDecision() == .terminate)
        #expect(vm.db.fetchEntry(id: id)?.body == "queued, not yet flushed")
    }

    // MARK: (2) Tag rename / delete rewrite unsaved snapshots

    @Test("renaming a tag rewrites it inside unsaved snapshots; the retry cannot resurrect it")
    func renameRewritesSnapshots() throws {
        let vm = makeVM()
        let id = vm.createEntry(title: "T", body: "t", tags: ["old", "old/kid", "keep"]).id
        let writer = Wave4Writer(); writer.install(on: vm)
        try edit(vm, id: id, body: "unsaved words")
        vm.flushPendingSave()
        #expect(vm.unsavedSnapshots[id]?.tags.contains("old") == true)

        vm.renameTagTree("old", to: "new")
        #expect(vm.unsavedSnapshots[id]?.tags == ["new", "new/kid", "keep"])
        #expect(vm.entry(id: id)?.tags.sorted() == ["keep", "new", "new/kid"], "reload re-applied the stale tag")
        #expect(vm.lastTagRewrite == .rename(from: "old", to: "new"))

        writer.failing = false
        #expect(vm.retryFailedSaves())
        let stored = try #require(vm.db.fetchEntry(id: id))
        #expect(stored.body == "unsaved words")
        #expect(Set(stored.tags) == ["new", "new/kid", "keep"])
        #expect(!vm.db.allTagNames().contains("old"))
        #expect(!vm.db.allTagNames().contains("old/kid"))
    }

    @Test("deleting a tag removes it (and its children) from unsaved snapshots")
    func deleteRewritesSnapshots() throws {
        let vm = makeVM()
        let id = vm.createEntry(title: "D", body: "d", tags: ["gone", "gone/kid", "keep"]).id
        let writer = Wave4Writer(); writer.install(on: vm)
        try edit(vm, id: id, body: "unsaved words")
        vm.flushPendingSave()

        vm.deleteTagEverywhere("gone")
        #expect(vm.unsavedSnapshots[id]?.tags == ["keep"])
        #expect(vm.entry(id: id)?.tags == ["keep"])
        #expect(vm.lastTagRewrite == .delete("gone"))

        writer.failing = false
        #expect(vm.retryFailedSaves())
        let stored = try #require(vm.db.fetchEntry(id: id))
        #expect(stored.tags == ["keep"])
        #expect(!vm.db.allTagNames().contains("gone"))
        #expect(!vm.db.allTagNames().contains("gone/kid"))
    }

    @Test("tag rewrite rules match the database's rename/delete",
          arguments: [
            (SaveTagRewrite.rename(from: "a", to: "b"), ["a", "a/x", "ab", "c"], ["b", "b/x", "ab", "c"]),
            (.rename(from: "a", to: "c"), ["a", "c"], ["c"]),
            (.rename(from: "a", to: "b"), ["A"], ["A"]),
            (.delete("a"), ["a", "A/x", "ab", "c"], ["ab", "c"]),
            (.delete("a"), [], []),
          ])
    func rewriteRules(rewrite: SaveTagRewrite, input: [String], expected: [String]) {
        #expect(rewrite.apply(to: input) == expected)
    }

    // MARK: (3) Undecryptable stored body

    @Test("undecryptable stored body: a reported-success write surfaces as failed and keeps the text")
    func undecryptableBodyIsFailed() throws {
        let vm = makeVM()
        let id = vm.createEntry(title: "Sealed", body: "original").id
        // Replace the ciphertext with bytes no key can open (id is a UUID).
        #expect(vm.db.exec("UPDATE entries SET body_enc = X'00112233445566778899AABBCCDDEEFF00112233445566778899' WHERE id = '\(id)';"))
        #expect(vm.db.existingBodyState(id: id).unreadable)
        // Injected writer that delegates to the real write: saveEntry keeps the
        // undecryptable body, commits only metadata and returns success.
        let writer = Wave4Writer(); writer.failing = false; writer.install(on: vm)
        let secret = "new words that must not be lost"
        try edit(vm, id: id, body: secret)
        vm.flushPendingSave()
        #expect(writer.attempts >= 1)
        #expect(vm.saveState == .failed(.undecryptable))
        #expect(vm.unsavedSnapshots[id]?.body == secret)
        #expect(vm.entry(id: id)?.body == secret)
        #expect(vm.hasUnsavedChanges(entryId: id))
        #expect(vm.db.existingBodyState(id: id).unreadable, "the original ciphertext must be preserved")
        #expect(vm.toast?.isError == true)
        #expect(vm.toast?.message.contains(secret) == false)
        #expect(!SaveStatusPresentation.accessibilityLabel(vm.saveState).contains(secret))
    }
}
