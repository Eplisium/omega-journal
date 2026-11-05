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

// MARK: - browse-5

@Suite("Audit fix browse: toasts are hosted at the window level", .serialized)
@MainActor
struct AuditFixBrowseToastHostTests {
    @Test("the detail pane no longer hosts its own toast (it would show twice)")
    func detailViewHasNoToast() throws {
        let (vm, _) = try AuditFixBrowseSupport.makeVM()
        var selection: SidebarItem? = .all
        let detail = DetailView(vm: vm, selection: Binding(get: { selection }, set: { selection = $0 }))
        let typeName = String(describing: type(of: detail.body))
        #expect(!typeName.contains("ToastView"))
        #expect(!typeName.contains("WindowToastHost"))
    }

    @Test("the window and the Settings sheet both host the toast")
    func windowAndSettingsHostToast() throws {
        let (vm, _) = try AuditFixBrowseSupport.makeVM()
        let content = ContentView(viewModel: vm)
        #expect(String(describing: type(of: content.body)).contains("WindowToastHost"))
        let settings = SettingsView(vm: vm)
        #expect(String(describing: type(of: settings.body)).contains("WindowToastHost"))
    }

    @Test("only the frontmost host for a window draws the toast")
    func frontmostHostOnly() {
        let stack = ToastHostStack()
        let windowVM = NSObject(), otherWindowVM = NSObject()
        let window = UUID(), settings = UUID(), other = UUID()
        stack.push(window, owner: ObjectIdentifier(windowVM))
        stack.push(other, owner: ObjectIdentifier(otherWindowVM))
        #expect(stack.isFrontmost(window, owner: ObjectIdentifier(windowVM)))
        // Settings sheet opens over the window: it takes over, nothing twice.
        stack.push(settings, owner: ObjectIdentifier(windowVM))
        #expect(stack.isFrontmost(settings, owner: ObjectIdentifier(windowVM)))
        #expect(!stack.isFrontmost(window, owner: ObjectIdentifier(windowVM)))
        // Another window's own host is unaffected.
        #expect(stack.isFrontmost(other, owner: ObjectIdentifier(otherWindowVM)))
        // Sheet closes: the window host draws again.
        stack.remove(settings, owner: ObjectIdentifier(windowVM))
        #expect(stack.isFrontmost(window, owner: ObjectIdentifier(windowVM)))
        stack.remove(window, owner: ObjectIdentifier(windowVM))
        #expect(!stack.isFrontmost(window, owner: ObjectIdentifier(windowVM)))
    }

    @Test("dismissing a toast with an action runs Undo")
    func undoStaysWired() throws {
        let (vm, _) = try AuditFixBrowseSupport.makeVM()
        let e = vm.createEntry(title: "BRF undo", body: "x")
        vm.stopEditing()
        vm.deleteEntry(e)
        let toast = try #require(vm.toast)
        #expect(toast.actionLabel == "Undo")
        WindowToastHost.handleAction(toast, vm: vm)
        #expect(vm.db.fetchEntry(id: e.id)?.isTrashed == false)
        #expect(vm.toast?.id != toast.id)
    }
}

// MARK: - browse-11

@Suite("Audit fix browse: Today rolls over")
@MainActor
struct AuditFixBrowseTodayRolloverTests {
    let cal = AuditFixBrowseSupport.calendar()

    @Test("the Today schedule ticks at midnight and at every greeting change")
    func boundaries() {
        let d = { AuditFixBrowseSupport.date(2026, 11, $0, $1, $2, cal: cal) }
        #expect(TodayRolloverSchedule.nextBoundary(after: d(5, 23, 58), calendar: cal) == d(6, 0, 0))
        #expect(TodayRolloverSchedule.nextBoundary(after: d(6, 0, 0), calendar: cal) == d(6, 5, 0))
        #expect(TodayRolloverSchedule.nextBoundary(after: d(6, 6, 30), calendar: cal) == d(6, 12, 0))
        #expect(TodayRolloverSchedule.nextBoundary(after: d(6, 12, 0), calendar: cal) == d(6, 17, 0))
        #expect(TodayRolloverSchedule.nextBoundary(after: d(6, 21, 59), calendar: cal) == d(6, 22, 0))
        let ticks = Array(TodayRolloverSchedule(calendar: cal).entries(from: d(5, 23, 58), mode: .normal).prefix(4))
        #expect(ticks == [d(5, 23, 58), d(6, 0, 0), d(6, 5, 0), d(6, 12, 0)])
    }

    @Test("a skipped midnight (DST) still rolls the day over")
    func dstMidnight() {
        let sp = AuditFixBrowseSupport.calendar("America/Sao_Paulo")
        // 2018-11-04 00:00 did not exist in São Paulo (clocks jumped to 01:00).
        let before = AuditFixBrowseSupport.date(2018, 11, 3, 23, 30, cal: sp)
        let next = TodayRolloverSchedule.nextBoundary(after: before, calendar: sp)
        #expect(next > before)
        #expect(!sp.isDate(next, inSameDayAs: before))
    }

    @Test("greeting, date and today's entry follow the clock, not the first render")
    func followsTheClock() {
        let late = AuditFixBrowseSupport.date(2026, 11, 5, 23, 58, cal: cal)
        let morning = AuditFixBrowseSupport.date(2026, 11, 6, 8, 0, cal: cal)
        #expect(TodayView.greeting(at: late, calendar: cal) == "Still awake?")
        #expect(TodayView.greeting(at: morning, calendar: cal) == "Good morning")
        let yesterday = AuditFixBrowseSupport.entry(title: "late night", createdAt: late.addingTimeInterval(-60))
        #expect(TodayView.todaysEntry(in: [yesterday], now: late, calendar: cal)?.id == yesterday.id)
        #expect(TodayView.todaysEntry(in: [yesterday], now: morning, calendar: cal) == nil)
    }

    @Test("the Today page is driven by the rollover schedule")
    func todayUsesTimeline() throws {
        let (vm, _) = try AuditFixBrowseSupport.makeVM()
        let view = TodayView(vm: vm, openJournal: {}, openCalendar: {}, openInsights: {}, openEntry: { _ in })
        #expect(String(describing: type(of: view.body)).contains("TodayRolloverSchedule"))
    }
}

