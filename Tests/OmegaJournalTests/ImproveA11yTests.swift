import AppKit
import Foundation
import SwiftUI
import Testing
import OmegaJournalCore
@testable import OmegaJournal

/// A11y track: VoiceOver labels/values/actions for Browse and Reading, and the
/// privacy rule that a locked hidden entry announces title/mood/date only.
@Suite("Improve A11y — Core descriptions")
struct ImproveA11yCoreTests {
    static let secretTags = ["therapy", "health/meds", "money", "family"]

    static func summary(locked: Bool, hidden: Bool = true) -> A11yEntrySummary {
        A11yEntrySummary(title: "Monday", moodLabel: "Good", dateText: "Oct 3, 2026",
                         isPinned: true, isFavorite: true, isHidden: hidden,
                         canShowContent: ContentMasking.canShowContent(isHidden: hidden, hiddenLocked: locked),
                         wordCount: 412, tags: secretTags, attachmentCount: 2)
    }

    @Test("locked hidden row label: title, flags, mood and date only")
    func lockedRowMasksBodyDerivedData() {
        let label = A11yDescriptions.entryRowLabel(Self.summary(locked: true))
        #expect(label == "Monday, pinned, favorite, hidden, locked, Good, Oct 3, 2026")
        for tag in Self.secretTags { #expect(!label.contains(tag)) }
        #expect(!label.contains("412"))
        #expect(!label.contains("word"))
        #expect(!label.contains("attachment"))
        #expect(!label.contains("tags"))
    }

    @Test("unlocked hidden row label adds words, attachments and capped tags")
    func unlockedRowAddsDetails() {
        let label = A11yDescriptions.entryRowLabel(Self.summary(locked: false))
        #expect(label.hasPrefix("Monday, pinned, favorite, hidden, unlocked, Good, Oct 3, 2026"))
        #expect(label.contains("412 words"))
        #expect(label.contains("2 attachments"))
        #expect(label.contains("tags therapy, health/meds, money, +1 more"))
        #expect(!label.contains("family"))
    }

    @Test("plain row omits hidden state; empty title reads Untitled; singulars")
    func plainRow() {
        let s = A11yEntrySummary(title: "  ", moodLabel: "Okay", dateText: "Today",
                                 wordCount: 1, tags: ["a"], attachmentCount: 1)
        #expect(A11yDescriptions.entryRowLabel(s) == "Untitled, Okay, Today, 1 word, 1 attachment, tags a")
    }

    @Test("a not-hidden entry is never masked, even while hidden entries are locked")
    func visibleEntryUnaffectedByLock() {
        let label = A11yDescriptions.entryRowLabel(Self.summary(locked: true, hidden: false))
        #expect(label.contains("412 words"))
        #expect(!label.contains("hidden"))
    }

    @Test("row value and hint follow selection mode")
    func valueAndHint() {
        #expect(A11yDescriptions.entryRowValue(isSelected: true, isBulkSelecting: false, isBulkSelected: false) == "selected")
        #expect(A11yDescriptions.entryRowValue(isSelected: false, isBulkSelecting: false, isBulkSelected: false) == "")
        #expect(A11yDescriptions.entryRowValue(isSelected: true, isBulkSelecting: true, isBulkSelected: false) == "unchecked")
        #expect(A11yDescriptions.entryRowValue(isSelected: false, isBulkSelecting: true, isBulkSelected: true) == "checked")
        for bulk in [true, false] {
            for trash in [true, false] {
                #expect(!A11yDescriptions.entryRowHint(isBulkSelecting: bulk, isTrash: trash).lowercased().contains("double tap"))
            }
        }
    }

    @Test("row actions mirror the hover quick actions and context menu")
    func rowActions() {
        #expect(A11yEntryRowAction.available(isTrash: false) == [.edit, .togglePin, .toggleFavorite, .toggleArchive, .moveToTrash])
        #expect(A11yEntryRowAction.available(isTrash: true) == [.restore, .deleteForever])
        #expect(A11yEntryRowAction.togglePin.title(isPinned: true, isFavorite: false, isArchived: false) == "Unpin")
        #expect(A11yEntryRowAction.togglePin.title(isPinned: false, isFavorite: false, isArchived: false) == "Pin")
        #expect(A11yEntryRowAction.toggleFavorite.title(isPinned: false, isFavorite: true, isArchived: false) == "Unfavorite")
        #expect(A11yEntryRowAction.toggleArchive.title(isPinned: false, isFavorite: false, isArchived: true) == "Unarchive")
    }

    @Test("reader meta chips: locked shows mood and date only")
    func readerChipsMasked() {
        let locked = A11yDescriptions.readerMetaChips(mood: "🙂 Good", date: "October 3, 2026", wordCount: 412,
                                                      readingTime: "2 min read", stampSummary: "Paris · Sunny",
                                                      canShowContent: false)
        #expect(locked == ["🙂 Good", "October 3, 2026"])
        let open = A11yDescriptions.readerMetaChips(mood: "🙂 Good", date: "October 3, 2026", wordCount: 412,
                                                    readingTime: "2 min read", stampSummary: "Paris · Sunny",
                                                    canShowContent: true)
        #expect(open == ["🙂 Good", "October 3, 2026", "412 words", "2 min read", "📍 Paris · Sunny"])
        let noStamp = A11yDescriptions.readerMetaChips(mood: "m", date: "d", wordCount: 1, readingTime: "r",
                                                       stampSummary: "", canShowContent: true)
        #expect(noStamp == ["m", "d", "1 word", "r"])
    }

    @Test("filter chip and palette strings")
    func chipAndPaletteStrings() {
        #expect(A11yDescriptions.filterChipLabel(kind: "mood", name: "Great") == "Great mood filter")
        #expect(A11yDescriptions.filterChipLabel(kind: "", name: "Favorites") == "Favorites filter")
        #expect(A11yDescriptions.filterChipValue(isOn: true) == "on")
        #expect(A11yDescriptions.filterChipValue(isOn: false) == "off")
        #expect(A11yDescriptions.paletteResultCount(1) == "1 result")
        #expect(A11yDescriptions.paletteResultCount(0) == "0 results")
    }
}

/// View-level wiring: the real EntryRow feeds the Core builder masked data.
@Suite("Improve A11y — EntryRow wiring", .serialized)
@MainActor
struct ImproveA11yRowTests {
    private func makeVM() throws -> JournalViewModel {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-a11y-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
        BiometricAuth.shared.setAuthenticatedForTesting(false)
        return JournalViewModel()
    }

    private func hiddenEntry() -> JournalEntry {
        var e = JournalEntry.new()
        e.title = "A11y secret"
        e.body = "The confidential body text goes here with several words"
        e.tags = ["private/therapy", "a11ysecret"]
        e.isHidden = true
        e.isPinned = true
        e.attachments = [Attachment(id: "a11y-att", entryId: e.id, filename: "scan.png",
                                    mimeType: "image/png", createdAt: Date())]
        return e
    }

    @Test("locked hidden row's VoiceOver label never contains tags, words or attachments")
    func lockedRowLabel() throws {
        let vm = try makeVM()
        defer { BiometricAuth.shared.setAuthenticatedForTesting(false) }
        let row = EntryRow(vm: vm, entry: hiddenEntry(), isTrash: false)

        BiometricAuth.shared.setAuthenticatedForTesting(false)
        let locked = row.accessibilityLabel
        #expect(locked.hasPrefix("A11y secret, pinned, hidden, locked"))
        #expect(!locked.contains("therapy"))
        #expect(!locked.contains("a11ysecret"))
        #expect(!locked.contains("confidential"))
        #expect(!locked.contains("word"))
        #expect(!locked.contains("attachment"))
        #expect(row.accessibilitySummary.tags.isEmpty)
        #expect(row.accessibilitySummary.wordCount == 0)

        BiometricAuth.shared.setAuthenticatedForTesting(true)
        let open = row.accessibilityLabel
        #expect(open.contains("hidden, unlocked"))
        #expect(open.contains("therapy"))
        #expect(open.contains("1 attachment"))
        #expect(open.contains("9 words"))
    }

    @Test("trash rows announce the deletion countdown and expose restore actions")
    func trashRow() throws {
        let vm = try makeVM()
        var e = JournalEntry.new()
        e.title = "Old"
        e.deletedAt = Date()
        let row = EntryRow(vm: vm, entry: e, isTrash: true)
        #expect(row.accessibilityLabel.contains(row.trashLabel))
        #expect(A11yEntryRowAction.available(isTrash: true).contains(.restore))
    }
}
