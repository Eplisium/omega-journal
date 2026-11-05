import Foundation
import Testing
import OmegaJournalCore
import OmegaJournalShared

// Regression tests for audit finding MODERN-2 (widget timeline policy).

// MARK: - MODERN-2

/// `.atEnd` with nothing ahead of `now` makes WidgetKit ask again right away,
/// over and over, for the same "Open the app to sync" card.
@Suite("Audit fix modern: widget timeline reload policy")
struct AuditFixModernTimelinePolicyTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// Wednesday 2026-10-28 15:00 New York.
    static let now: Date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15))!
    static let nextMidnight: Date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29))!

    static func snapshot(builtDaysAgo days: Int) -> WidgetSnapshot {
        let built = calendar.date(byAdding: .day, value: -days, to: now)!
        return WidgetSnapshotBuilder.build(facts: [WidgetEntryFact(createdAt: built, wordCount: 10, isHidden: false)],
                                           dailyWordGoal: 250, streakMode: .dailyWithRest,
                                           prompt: { _ in "p" }, now: built, calendar: calendar)
    }

    @Test("no snapshot yet: wait for the next midnight (the app reloads when it publishes)")
    func noSnapshot() {
        #expect(WidgetDisplay.timelineReload(for: nil, now: Self.now, calendar: Self.calendar) == .after(Self.nextMidnight))
    }

    @Test("expired snapshot: no row for today, so no spinning either")
    func expiredSnapshot() {
        let stale = Self.snapshot(builtDaysAgo: 30)
        #expect(WidgetDisplay.timelineDates(for: stale, now: Self.now, calendar: Self.calendar) == [Self.now])
        #expect(WidgetDisplay.timelineReload(for: stale, now: Self.now, calendar: Self.calendar) == .after(Self.nextMidnight))
    }

    @Test("today is the snapshot's last row: reload when that row runs out, at midnight")
    func lastRowToday() {
        let old = Self.snapshot(builtDaysAgo: WidgetSnapshotBuilder.defaultDaysAhead)
        #expect(WidgetDisplay.state(for: old, at: Self.now, calendar: Self.calendar).hasData)
        #expect(WidgetDisplay.timelineReload(for: old, now: Self.now, calendar: Self.calendar) == .after(Self.nextMidnight))
    }

    @Test("fresh snapshot with lookahead rows keeps .atEnd")
    func freshSnapshot() {
        let fresh = Self.snapshot(builtDaysAgo: 0)
        #expect(WidgetDisplay.timelineDates(for: fresh, now: Self.now, calendar: Self.calendar).count
                == WidgetSnapshotBuilder.defaultDaysAhead + 1)
        #expect(WidgetDisplay.timelineReload(for: fresh, now: Self.now, calendar: Self.calendar) == .atEnd)
    }
}
