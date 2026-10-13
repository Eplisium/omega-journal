import Foundation
import OmegaJournalCore

// MARK: - Calendar month snapshot (computed once per render)
//
// CalendarView used to re-derive `vm.calendarEntries` (a full-journal filter)
// and the month slice from several computed properties per render — the
// month summary alone filtered the journal three times and re-tokenised every
// body for word counts — and sorted each day's entries again per grid cell.
// Everything the month grid, agenda, summary and inspector need is now built
// here once.

struct CalendarMonthSnapshot {
    /// Start of the displayed month.
    let month: Date
    /// Scoped entries per start-of-day, each day sorted oldest → newest.
    let entriesByDay: [Date: [JournalEntry]]
    /// Entries in the displayed month (scoped), oldest → newest.
    let monthEntries: [JournalEntry]
    let monthWordCount: Int
    /// Writing days in the displayed month, ascending.
    let writingDays: [Date]
    let averageMood: Mood?
    /// Private entries in this month the current scope leaves out (date-only).
    let excludedPrivateCount: Int

    init(
        scopedEntries: [JournalEntry],
        journal: [JournalEntry],
        anchorMonth: Date,
        visibility: AnalyticsVisibility,
        reference: Date = Date(),
        calendar: Calendar = .current
    ) {
        let interval = calendar.dateInterval(of: .month, for: anchorMonth)
        month = interval?.start ?? calendar.startOfDay(for: anchorMonth)

        var byDay: [Date: [JournalEntry]] = [:]
        for entry in scopedEntries {
            byDay[calendar.startOfDay(for: entry.createdAt), default: []].append(entry)
        }
        for key in byDay.keys { byDay[key]?.sort { $0.createdAt < $1.createdAt } }
        entriesByDay = byDay

        let inMonth: (Date) -> Bool = { date in
            guard let interval else { return false }
            return date >= interval.start && date < interval.end
        }
        writingDays = byDay.keys.filter(inMonth).sorted()
        monthEntries = writingDays.flatMap { byDay[$0] ?? [] }
        monthWordCount = monthEntries.reduce(0) { $0 + $1.wordCount }
        averageMood = Self.averageMood(monthEntries)

        if visibility == .visibleOnly {
            // Same "through today" bound the reflective scope applies.
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)) ?? reference
            excludedPrivateCount = journal.filter {
                $0.isHidden && inMonth($0.createdAt) && $0.createdAt < endOfToday
            }.count
        } else {
            excludedPrivateCount = 0
        }
    }

    func entries(on day: Date, calendar: Calendar = .current) -> [JournalEntry] {
        entriesByDay[calendar.startOfDay(for: day)] ?? []
    }

    static func averageMood(_ entries: [JournalEntry]) -> Mood? {
        guard !entries.isEmpty else { return nil }
        let total = entries.reduce(0) { $0 + $1.mood.rawValue }
        return Mood(rawValue: Int((Double(total) / Double(entries.count)).rounded())) ?? .neutral
    }
}
