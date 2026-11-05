import AppKit
import Foundation
import PDFKit
import SwiftUI
import Testing
import OmegaJournalCore
@testable import OmegaJournal

/// Regression tests for the browse-track audit fixes (Browse / Settings /
/// Today). Every DB test uses a private UUID temp database; the env vars keep
/// any `.shared` singleton off the real journal.
@MainActor
enum AuditFixBrowseSupport {
    static func makeVM() throws -> (JournalViewModel, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oj-fix-browse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("shared.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("shared-att").path, 1)
        let db = DatabaseManager(databasePath: root.appendingPathComponent("private.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("private-att").path)
        return (JournalViewModel(database: db), root)
    }

    static func entry(title: String = "T", body: String = "", hidden: Bool = false,
                      archived: Bool = false, trashed: Bool = false, createdAt: Date = Date()) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title
        e.body = body
        e.isHidden = hidden
        e.isArchived = archived
        e.deletedAt = trashed ? Date() : nil
        e.createdAt = createdAt
        return e
    }

    static func calendar(_ tz: String = "America/New_York") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
}

// MARK: - browse-4

@Suite("Audit fix browse: Today hero word count")
@MainActor
struct AuditFixBrowseTodayHeroTests {
    @Test("the hero card never shows a locked hidden entry's word count")
    func heroMasksWordCount() {
        let words = Array(repeating: "secret", count: 1_240).joined(separator: " ")
        let hidden = AuditFixBrowseSupport.entry(title: "Private", body: words, hidden: true)
        let locked = TodayHeroContent(entry: hidden, hiddenLocked: true)
        #expect(locked.isMasked)
        #expect(locked.wordCountText == nil, "locked hidden entry leaks its length: \(locked.wordCountText ?? "")")
        let unlocked = TodayHeroContent(entry: hidden, hiddenLocked: false)
        #expect(unlocked.wordCountText == "\(1_240.formatted()) words")
        let one = TodayHeroContent(entry: AuditFixBrowseSupport.entry(body: "hello"), hiddenLocked: true)
        #expect(one.wordCountText == "1 word")
    }
}

