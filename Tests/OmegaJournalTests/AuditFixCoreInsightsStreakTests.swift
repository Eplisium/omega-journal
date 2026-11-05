import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// core-5: Insights "Current rhythm" is the Today streak over the all-time
/// reflective scope, not capped by the selected period.
@Suite("Audit fix core: Insights current streak", .serialized)
@MainActor
struct AuditFixCoreInsightsStreakTests {
    static func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.firstWeekday = 2
        return c
    }

    private func entry(_ date: Date, hidden: Bool = false) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = "S"; e.body = "words here"; e.createdAt = date; e.isHidden = hidden
        return e
    }

    private func streak(journal: [JournalEntry], period: AnalyticsPeriod, visibility: AnalyticsVisibility = .visibleOnly,
                        reference: Date, calendar c: Calendar) -> Int {
        let records = journal.map { AnalyticsRecord(id: $0.id, date: $0.createdAt, isPrivate: $0.isHidden) }
        let ids = Set(OmegaAnalytics.filteredRecords(records, period: period, visibility: visibility,
                                                     relativeTo: reference, calendar: c).map(\.id))
        return InsightsSnapshot(journal: journal, entries: journal.filter { ids.contains($0.id) }, period: period,
                                visibility: visibility, reference: reference, calendar: c).streak
    }

    @Test("core-5 a 20-day streak reads 20 under every period, across a DST jump")
    func notCappedByPeriod() {
        let c = Self.cal("America/Santiago")
        let reference = c.date(from: DateComponents(year: 2019, month: 9, day: 15, hour: 18))!
        let journal = (0..<20).map { entry(c.date(byAdding: .day, value: -$0, to: reference)!) }
        for period in AnalyticsPeriod.allCases {
            #expect(streak(journal: journal, period: period, reference: reference, calendar: c) == 20, "\(period)")
        }
    }

    @Test("core-5 uses Today's rule (one rest day per 7) at the reference date and calendar")
    func sameRuleAsToday() {
        let c = Self.cal("UTC")
        let reference = c.date(from: DateComponents(year: 2026, month: 1, day: 3, hour: 9))!
        // Wrote every day for 12 days except 3 days ago; nothing yet today.
        let offsets = [1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        let journal = offsets.map { entry(c.date(byAdding: .day, value: -$0, to: reference)!) }
        let today = JournalViewModel.reflectiveStreakSummary(writingDays: Set(journal.map(\.createdAt)),
                                                             mode: .dailyWithRest, relativeTo: reference, calendar: c)
        #expect(today.current == 11)
        #expect(streak(journal: journal, period: .year, reference: reference, calendar: c) == today.current)
        #expect(streak(journal: journal, period: .sevenDays, reference: reference, calendar: c) == today.current)
    }

    @Test("core-5 privacy scope and future-dated entries")
    func privacyAndFuture() {
        let c = Self.cal("UTC")
        let reference = c.date(from: DateComponents(year: 2026, month: 4, day: 10, hour: 12))!
        let visible = (0..<5).map { entry(c.date(byAdding: .day, value: -$0, to: reference)!) }
        let hidden = (5..<10).map { entry(c.date(byAdding: .day, value: -$0, to: reference)!, hidden: true) }
        let planned = entry(c.date(byAdding: .day, value: 1, to: reference)!)
        let journal = visible + hidden + [planned]
        #expect(streak(journal: journal, period: .sevenDays, reference: reference, calendar: c) == 5)
        #expect(streak(journal: journal, period: .sevenDays, visibility: .includePrivate, reference: reference, calendar: c) == 10)
        // A planned entry alone is not a streak.
        #expect(streak(journal: [planned], period: .allTime, reference: reference, calendar: c) == 0)
    }

    @Test("core-5 InsightsSnapshot.make(vm:) is not truncated to the 7-day period")
    func viewModelPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oj-fixcore-streak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        TestSharedEnvironment.pin()
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("att").path)
        let vm = JournalViewModel(database: db)
        let now = Date()
        for k in 0..<20 {
            db.saveEntry(entry(Calendar.current.date(byAdding: .day, value: -k, to: now)!))
        }
        vm.reload()
        vm.analyticsPeriod = .sevenDays
        #expect(InsightsSnapshot.make(vm: vm, reference: now).streak == 20)
        #expect(InsightsSnapshot.make(vm: vm, reference: now).entries.count == 7)
    }
}
