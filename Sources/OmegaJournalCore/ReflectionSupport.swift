import Foundation

// MARK: - Reflection surface support (Calendar, Heatmap, Insights)
//
// Pure, privacy-safe helpers for the reflective workspaces. They only ever
// see `AnalyticsRecord`s (id, date, private flag) or plain numbers, so they
// can never leak a private entry's body, tags or word count.

/// What a reflective surface should communicate about its current scope.
public enum ReflectionDataState: Equatable, Sendable {
    /// Nothing written anywhere in the active journal — invite a first entry.
    case noEntries
    /// The journal has writing, but none in the selected period.
    case emptyPeriod
    /// The period only contains private entries, and they are excluded.
    case privateExcluded(count: Int)
    /// Some writing, but too little for patterns to mean anything yet.
    case sparse(writingDays: Int)
    /// Enough writing for charts and patterns.
    case populated

    /// Fewer distinct writing days than this reads as "sparse".
    public static let sparseWritingDayThreshold = 3

    /// True when the surface has no included entries to chart.
    public var isEmpty: Bool {
        switch self {
        case .noEntries, .emptyPeriod, .privateExcluded: true
        case .sparse, .populated: false
        }
    }

    /// Classifies a reflective scope. `records` is the whole active journal
    /// (including private entries, which only contribute their date/flag);
    /// the period and visibility rule are the ones the surface communicates.
    /// The inclusion rule itself is `OmegaAnalytics.filteredRecords` —
    /// unchanged — so this can never widen what a surface shows.
    public static func classify(
        records: [AnalyticsRecord],
        period: AnalyticsPeriod,
        visibility: AnalyticsVisibility,
        relativeTo reference: Date = Date(),
        calendar: Calendar = .current
    ) -> ReflectionDataState {
        guard !records.isEmpty else { return .noEntries }
        let included = OmegaAnalytics.filteredRecords(
            records, period: period, visibility: visibility,
            relativeTo: reference, calendar: calendar
        )
        if included.isEmpty {
            let excluded = privateExcludedCount(
                records: records, period: period, visibility: visibility,
                relativeTo: reference, calendar: calendar
            )
            return excluded > 0 ? .privateExcluded(count: excluded) : .emptyPeriod
        }
        let days = Set(included.map { calendar.startOfDay(for: $0.date) }).count
        return days < sparseWritingDayThreshold ? .sparse(writingDays: days) : .populated
    }

    /// Private entries inside the period that the current visibility hides.
    /// Zero whenever private entries are already included.
    public static func privateExcludedCount(
        records: [AnalyticsRecord],
        period: AnalyticsPeriod,
        visibility: AnalyticsVisibility,
        relativeTo reference: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        guard visibility == .visibleOnly else { return 0 }
        return OmegaAnalytics.filteredRecords(
            records.filter(\.isPrivate), period: period, visibility: .includePrivate,
            relativeTo: reference, calendar: calendar
        ).count
    }
}

// MARK: - Compact privacy scope copy

/// One-line privacy scope message shared by Calendar and Insights.
public enum ReflectionScopeCopy {
    /// e.g. "Private entries excluded · 2 hidden in this period".
    public static func line(visibility: AnalyticsVisibility, excludedCount: Int, scopeNoun: String) -> String {
        switch visibility {
        case .includePrivate:
            return "Private entries included"
        case .visibleOnly:
            guard excludedCount > 0 else { return "Private entries excluded" }
            let noun = excludedCount == 1 ? "entry" : "entries"
            return "Private entries excluded · \(excludedCount) private \(noun) in \(scopeNoun)"
        }
    }
}

// MARK: - Selected-day metrics

/// The consolidated metric line for a selected day (Calendar inspector).
public enum ReflectionDayMetrics {
    /// "2 entries · 340 words · 2 min read" — nil for an empty day so the
    /// inspector shows a single empty message instead of a grid of zeros.
    public static func summary(entryCount: Int, words: Int, readingMinutes: Int) -> String? {
        guard entryCount > 0 else { return nil }
        let entries = entryCount == 1 ? "1 entry" : "\(entryCount) entries"
        let wordText = words == 1 ? "1 word" : "\(words.formatted()) words"
        return "\(entries) · \(wordText) · \(max(readingMinutes, 1)) min read"
    }
}

// MARK: - Content fingerprint

/// Order-independent fingerprint of the entries feeding an expensive,
/// async-derived panel (e.g. on-device themes). Keying such work on the entry
/// COUNT misses edits and same-size scope swaps, leaving stale (possibly
/// formerly-included private) text on screen.
public enum ReflectionFingerprint {
    public static func make(_ items: [(id: String, updatedAt: Date)]) -> Int {
        var acc = Hasher()
        acc.combine(items.count)
        // XOR of per-item hashes keeps it independent of list order.
        var mix = 0
        for item in items {
            var h = Hasher()
            h.combine(item.id)
            h.combine(item.updatedAt.timeIntervalSinceReferenceDate)
            mix ^= h.finalize()
        }
        acc.combine(mix)
        return acc.finalize()
    }
}

// MARK: - Heatmap window

public enum ReflectionHeatmapWindow {
    /// Start of the stats window: the later of the grid's first day and the
    /// selected period's start, so a "7 days" Insights view doesn't report
    /// coverage across 26 weeks of days it never included.
    public static func statsStart(gridStart: Date, periodStart: Date?, calendar: Calendar = .current) -> Date {
        let grid = calendar.startOfDay(for: gridStart)
        guard let periodStart else { return grid }
        return max(grid, calendar.startOfDay(for: periodStart))
    }

    /// True when a grid day lies before the selected period (drawn dimmed).
    public static func isOutsidePeriod(_ day: Date, periodStart: Date?, calendar: Calendar = .current) -> Bool {
        guard let periodStart else { return false }
        return calendar.startOfDay(for: day) < calendar.startOfDay(for: periodStart)
    }
}

// MARK: - Empty / sparse copy

/// Copy and next-step actions for an empty Insights scope. Each empty reason
/// gets its own message and the action that actually changes it.
public struct ReflectionEmptyCopy: Equatable, Sendable {
    public enum Action: String, Hashable, Sendable {
        case write
        case showAllTime
        case includePrivate

        public var icon: String {
            switch self {
            case .write: "square.and.pencil"
            case .showAllTime: "calendar"
            case .includePrivate: "lock.open"
            }
        }

        public func title(isAuthenticated: Bool) -> String {
            switch self {
            case .write: "Write an entry"
            case .showAllTime: "Show all time"
            case .includePrivate: isAuthenticated ? "Include private entries" : "Unlock to include"
            }
        }
    }

    public let icon: String
    public let title: String
    public let message: String
    /// First action is the primary one.
    public let actions: [Action]

    public init(state: ReflectionDataState, period: AnalyticsPeriod, isAuthenticated: Bool) {
        let span = period == .allTime ? "your journal" : "the last \(period.label.lowercased())"
        switch state {
        case .noEntries:
            icon = "book.closed"
            title = "Your first entry starts the story"
            message = "Insights stay quiet until there is writing to reflect on."
            actions = [.write]
        case .emptyPeriod:
            icon = "calendar.badge.clock"
            title = period == .year ? "No writing this year yet" : "No writing in \(span)"
            message = "Your earlier writing is still here — widen the period or begin a new entry."
            actions = period == .allTime ? [.write] : [.showAllTime, .write]
        case .privateExcluded(let count):
            let noun = count == 1 ? "entry" : "entries"
            icon = "lock.fill"
            title = "Only private writing here"
            message = "\(count) private \(noun) in \(span) \(count == 1 ? "is" : "are") excluded from Insights."
                + (isAuthenticated ? "" : " Unlock to include them.")
            actions = [.includePrivate, .write]
        case .sparse, .populated:
            icon = "chart.bar"
            title = ""
            message = ""
            actions = []
        }
    }

    public static func sparseMessage(writingDays: Int) -> String {
        let dayWord = writingDays == 1 ? "day" : "days"
        return "Just getting started — \(writingDays) writing \(dayWord) so far. Patterns appear once you've written on \(ReflectionDataState.sparseWritingDayThreshold) days."
    }
}
