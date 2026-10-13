import Foundation

// MARK: - Entry list grouping
//
// The entry list used to bucket entries with two incompatible rank schemes
// (relative buckets ranked 0…3, month buckets ranked 1000 - (year*12+month))
// and then sort ascending — which pushed every month bucket ABOVE "Earlier
// This Month", so a Sept 30 entry rendered below August. This version never
// re-sorts: the caller hands over entries already in the user's chosen order
// and sections are emitted in first-appearance order, so the section order
// always agrees with the list order (newest-first and oldest-first alike).

public struct EntryGroupItem: Equatable, Sendable {
    public let id: String
    public let date: Date
    public let isPinned: Bool

    public init(id: String, date: Date, isPinned: Bool) {
        self.id = id
        self.date = date
        self.isPinned = isPinned
    }
}

public struct EntryGroupSection: Equatable, Sendable, Identifiable {
    public let title: String
    public var ids: [String]
    /// The leading pinned section. Use this, never `title == "Pinned"`, so a
    /// collection that happens to be named "Pinned" is not mistaken for it.
    public let isPinned: Bool

    /// Stable, unique identity: the pinned section and a same-titled
    /// collection/date bucket can never collide.
    public var id: String { isPinned ? "pinned" : "section:" + title }

    public init(title: String, ids: [String], isPinned: Bool = false) {
        self.title = title
        self.ids = ids
        self.isPinned = isPinned
    }
}

public enum EntryGrouping {
    public static let pinnedTitle = "Pinned"
    /// Bucket for entries dated after today (e.g. back-dated into the future).
    public static let upcomingTitle = "Upcoming"

    /// Sections for an already-sorted list. Pinned entries always lead.
    /// - Parameter groupByDate: true for date sorts; any other sort (title,
    ///   length, mood, recently edited) is shown as one continuous section so
    ///   the advertised order is global rather than per-date-bucket.
    public static func sections(
        for items: [EntryGroupItem],
        groupByDate: Bool,
        fallbackTitle: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [EntryGroupSection] {
        var result: [EntryGroupSection] = []
        let pinned = items.filter(\.isPinned).map(\.id)
        if !pinned.isEmpty { result.append(EntryGroupSection(title: pinnedTitle, ids: pinned, isPinned: true)) }

        let rest = items.filter { !$0.isPinned }
        guard !rest.isEmpty else { return result }

        guard groupByDate else {
            result.append(EntryGroupSection(title: fallbackTitle, ids: rest.map(\.id)))
            return result
        }

        let formatter = monthFormatter(calendar: calendar)
        var indexByTitle: [String: Int] = [:]
        for item in rest {
            let title = bucketTitle(for: item.date, now: now, calendar: calendar, monthFormatter: formatter)
            if let idx = indexByTitle[title] {
                result[idx].ids.append(item.id)
            } else {
                indexByTitle[title] = result.count
                result.append(EntryGroupSection(title: title, ids: [item.id]))
            }
        }
        return result
    }

    /// Human bucket label. Relative buckets are rolling windows and are named
    /// as such ("Previous 30 Days"), not "Earlier This Month", which was wrong
    /// for anything that crossed a month boundary.
    public static func bucketTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        bucketTitle(for: date, now: now, calendar: calendar, monthFormatter: monthFormatter(calendar: calendar))
    }

    private static func bucketTitle(for date: Date, now: Date, calendar: Calendar, monthFormatter: DateFormatter) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        // "Today" is bounded by the start of tomorrow; later dates are Upcoming.
        let startOfTomorrow = calendar.dateInterval(of: .day, for: now)?.end
            ?? startOfToday.addingTimeInterval(86_400)
        if date >= startOfTomorrow { return upcomingTitle }
        if date >= startOfToday { return "Today" }
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday), date >= startOfYesterday {
            return "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday), date >= weekAgo {
            return "Previous 7 Days"
        }
        if let monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday), date >= monthAgo {
            return "Previous 30 Days"
        }
        return monthFormatter.string(from: date)
    }

    private static func monthFormatter(calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? .current
        f.setLocalizedDateFormatFromTemplate("MMMMy")
        return f
    }
}
