import AppKit
import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// DateFix track: entries dated after "now" must stay visible in the Calendar
/// (and resolvable by the drill-through sheet) without being counted as past
/// writing by Today, On This Day, streaks or Insights. Every test pins a fixed
/// reference date; the "far future" entry is future relative to both the
/// reference and the real clock, so Calendar assertions never depend on `Date()`.
@Suite("Wave 2 DateFix — future-dated entries", .serialized)
@MainActor
struct Wave2DateFixTests {
    nonisolated static func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    nonisolated static func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        utc().date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    /// Fixed "today" for reflective accessors.
    static let reference = date(2026, 6, 15)

    static func entry(_ title: String, hidden: Bool = false, at createdAt: Date) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title
        e.body = "secret body words for \(title)"
        e.tags = ["datefix"]
        e.isHidden = hidden
        e.createdAt = createdAt
        e.updatedAt = createdAt
        return e
    }

    /// In-memory VM over an isolated temp database; entries are assigned
    /// directly so nothing is persisted and nothing needs cleanup.
    private func makeVM(_ entries: [JournalEntry]) throws -> JournalViewModel {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-datefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
        BiometricAuth.shared.setAuthenticatedForTesting(false)
        let vm = JournalViewModel()
        vm.saveDebounce?.cancel()
        vm.entries = entries.sorted { $0.createdAt > $1.createdAt }
        return vm
    }

    // Shared fixture.
    static let past = entry("past", at: date(2026, 6, 10))
    static let today = entry("today", at: date(2026, 6, 15, hour: 8))
    static let nearFuture = entry("near future", at: date(2026, 6, 20))
    static let farFuture = entry("far future", at: date(2100, 1, 1))
    static let hiddenFuture = entry("hidden future", hidden: true, at: date(2100, 1, 2))
    static var all: [JournalEntry] { [past, today, nearFuture, farFuture, hiddenFuture] }

    // MARK: Calendar + drill-through include future entries

    @Test("a future-dated entry is in the calendar list and resolvable by drill-through id")
    func futureEntryVisibleInCalendar() throws {
        let vm = try makeVM(Self.all)
        let ids = Set(vm.calendarEntries.map(\.id))
        #expect(ids.contains(Self.farFuture.id))
        #expect(ids.contains(Self.nearFuture.id))
        #expect(ids.contains(Self.past.id))

        let resolved = EntryDrillThroughSheet.resolveEntry(id: Self.farFuture.id, in: vm, isAuthenticated: false)
        #expect(resolved?.id == Self.farFuture.id)
    }

    @Test("the calendar month snapshot places a future entry on its day")
    func futureEntryInMonthSnapshot() throws {
        let cal = Self.utc()
        let vm = try makeVM(Self.all)
        let snap = CalendarMonthSnapshot(scopedEntries: vm.calendarEntries, journal: vm.entries,
                                         anchorMonth: Self.date(2100, 1, 1), visibility: .visibleOnly,
                                         reference: Self.reference, calendar: cal)
        #expect(snap.entries(on: Self.date(2100, 1, 1), calendar: cal).map(\.id) == [Self.farFuture.id])
        #expect(snap.writingDays == [cal.startOfDay(for: Self.farFuture.createdAt)])
    }

    // MARK: Reflective surfaces exclude future entries

    @Test("Today recents use the reflective scope and never show future entries")
    func futureExcludedFromTodayRecents() throws {
        let vm = try makeVM(Self.all)
        let recents = vm.recentReflectiveEntries(limit: 3, relativeTo: Self.reference)
        #expect(recents.map(\.id) == [Self.today.id, Self.past.id])
        let reflective = Set(vm.reflectiveEntries(relativeTo: Self.reference).map(\.id))
        #expect(!reflective.contains(Self.nearFuture.id) && !reflective.contains(Self.farFuture.id))
    }

    @Test("streaks count only writing days up to today")
    func futureExcludedFromStreak() throws {
        let cal = Self.utc()
        // Past run of 2 days ending today, plus 10 consecutive future days.
        var days: Set<Date> = [Self.date(2026, 6, 14), Self.date(2026, 6, 15)]
        for offset in 1...10 { days.insert(cal.date(byAdding: .day, value: offset, to: Self.date(2026, 6, 15))!) }
        let past = JournalViewModel.pastWritingDays(days, relativeTo: Self.reference, calendar: cal)
        #expect(past == [cal.startOfDay(for: Self.date(2026, 6, 14)), cal.startOfDay(for: Self.date(2026, 6, 15))])

        let summary = JournalViewModel.reflectiveStreakSummary(writingDays: days, mode: .dailyWithRest,
                                                               relativeTo: Self.reference, calendar: cal)
        #expect(summary.current == 2)
        #expect(summary.longest == 2) // the 10 future days must not inflate the record
        #expect(summary.daysSinceLastEntry == 0)
    }

    @Test("On This Day and Insights ignore future-dated entries")
    func futureExcludedFromOnThisDayAndInsights() throws {
        let cal = Self.utc()
        let lastYear = Self.entry("last year", at: Self.date(2025, 6, 15))
        let nextYear = Self.entry("next year", at: Self.date(2027, 6, 15))
        let vm = try makeVM(Self.all + [lastYear, nextYear])

        // Same month/day next year is not a memory.
        let memories = JournalViewModel.onThisDay(in: vm.entries, reference: Self.reference, calendar: cal)
        #expect(memories.map(\.id) == [lastYear.id])
        let reflective = vm.reflectiveOnThisDay(relativeTo: Self.reference, calendar: cal)
        #expect(reflective.map(\.id) == [lastYear.id])

        // Insights scope (all time) stops at the end of the reference day.
        let scoped = Set(vm.reflectionEntries(period: .allTime, relativeTo: Self.reference).map(\.id))
        #expect(scoped == [Self.past.id, Self.today.id, lastYear.id])
    }

    // MARK: Privacy unchanged

    @Test("a locked hidden future entry stays masked in calendar and drill-through")
    func lockedHiddenFutureEntryStaysMasked() throws {
        let cal = Self.utc()
        let vm = try makeVM(Self.all)
        vm.analyticsVisibility = .includePrivate // opted in, but the session is locked
        #expect(!vm.calendarEntries.contains { $0.id == Self.hiddenFuture.id })
        #expect(EntryDrillThroughSheet.resolveEntry(id: Self.hiddenFuture.id, in: vm, isAuthenticated: false) == nil)

        // The month only reports that a private entry exists (count), never its content.
        let snap = CalendarMonthSnapshot(scopedEntries: vm.calendarEntries, journal: vm.entries,
                                         anchorMonth: Self.date(2100, 1, 1), visibility: vm.effectiveAnalyticsVisibility,
                                         reference: Self.reference, calendar: cal)
        #expect(snap.excludedPrivateCount == 1)
        #expect(!snap.monthEntries.contains { $0.id == Self.hiddenFuture.id })
        #expect(snap.monthWordCount == Self.farFuture.wordCount)

        // Unlocked + opted in: the future private entry appears in the calendar.
        BiometricAuth.shared.setAuthenticatedForTesting(true)
        defer { BiometricAuth.shared.setAuthenticatedForTesting(false) }
        #expect(vm.calendarEntries.contains { $0.id == Self.hiddenFuture.id })
        #expect(EntryDrillThroughSheet.resolveEntry(id: Self.hiddenFuture.id, in: vm, isAuthenticated: true)?.id
                == Self.hiddenFuture.id)
    }
}
