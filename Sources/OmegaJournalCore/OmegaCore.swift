import Foundation

/// Pure, dependency-free logic shared by the app and exercised by the test suite.
/// Anything in here must stay free of AppKit, SwiftUI, and SQLite so it can be
/// tested without a database or a running app.
public enum OmegaCore {

    // MARK: - Full-text search

    /// Turns arbitrary user input into a safe FTS5 MATCH expression.
    ///
    /// Raw input cannot be passed to MATCH: bare punctuation (`he-man`), unbalanced
    /// quotes, and the bare keywords AND/OR/NOT are all syntax errors. We keep only
    /// alphanumeric runs, quote each one, and add a prefix wildcard.
    /// Returns nil when nothing survives, signalling the caller to fall back to LIKE.
    public static func sanitizeFTSQuery(_ raw: String) -> String? {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - Markdown import

    /// Splits raw markdown into a title and body: a leading `# Heading` wins,
    /// otherwise the caller's fallback (usually the filename) is the title.
    public static func parseMarkdownImport(
        text: String,
        fallbackTitle: String
    ) -> (title: String, body: String) {
        var lines = text.components(separatedBy: "\n")
        var title = fallbackTitle
        if let first = lines.first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body)
    }

    // MARK: - Command palette

    /// Subsequence fuzzy match — "nte" matches "New Template".
    /// Consecutive hits and word-start hits score higher; shorter targets win ties.
    /// Returns nil when `needle` is not a subsequence of `haystack`.
    public static func fuzzyScore(_ needle: String, _ haystack: String) -> Int? {
        if needle.isEmpty { return 0 }
        let n = Array(needle.lowercased())
        let h = Array(haystack.lowercased())
        var ni = 0, score = 0, lastMatch = -1
        for (hi, ch) in h.enumerated() {
            guard ni < n.count else { break }
            if ch == n[ni] {
                if lastMatch == hi - 1 { score += 5 }
                if hi == 0 || h[hi - 1] == " " { score += 8 }
                score += 1
                lastMatch = hi
                ni += 1
            }
        }
        guard ni == n.count else { return nil }
        return score * 100 - h.count
    }

    // MARK: - Markdown block formatting

    /// Strips a competing block marker (heading, bullet, checkbox, number, quote)
    /// from the head of a line so a new one can replace it.
    public static func stripBlockMarker(_ line: String) -> String {
        line.replacingOccurrences(
            of: #"^(#{1,6}\s|[-*+]\s(\[[ xX]\]\s)?|\d+\.\s|>\s)"#,
            with: "", options: .regularExpression
        )
    }

    /// Applies (or toggles off) a line prefix across a block of lines — the logic
    /// behind the heading/list/quote commands. Toggles off only when every line
    /// already carries the prefix.
    public static func applyLinePrefix(_ prefix: String, to block: String) -> String {
        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }

        // A line only counts as prefixed when the prefix IS its whole marker —
        // otherwise "- [ ] x" reads as bulleted and toggling strips just "- ",
        // stranding the "[ ] ".
        let allPrefixed = !lines.isEmpty && lines.allSatisfy {
            $0.hasPrefix(prefix) && stripBlockMarker($0) == String($0.dropFirst(prefix.count))
        }
        lines = lines.map { line in
            allPrefixed ? String(line.dropFirst(prefix.count)) : prefix + stripBlockMarker(line)
        }
        var out = lines.joined(separator: "\n")
        if hadTrailingNewline { out += "\n" }
        return out
    }

    /// Wraps or unwraps a selection with inline markers (`**`, `*`, `` ` ``, `~~`).
    public static func toggleWrap(_ selected: String, open: String, close: String) -> String {
        if selected.hasPrefix(open), selected.hasSuffix(close),
           selected.count >= open.count + close.count {
            return String(selected.dropFirst(open.count).dropLast(close.count))
        }
        return open + selected + close
    }

    /// Empty drafts should not add fictional minutes to journal-wide reading
    /// totals. Non-empty writing is rounded up at a calm 220 words per minute.
    public static func readingMinutes(forWordCount wordCount: Int) -> Int {
        guard wordCount > 0 else { return 0 }
        return Int(ceil(Double(wordCount) / 220.0))
    }
}

// MARK: - Workspace presentation

/// The app's top-level spaces. Only the Journal workspace owns a collection
/// column; reflective spaces deliberately use the full content area.
public enum JournalWorkspace: String, CaseIterable, Hashable, Sendable {
    case today
    case journal
    case calendar
    case insights
    case onThisDay

    public var usesEntryCollection: Bool { self == .journal }

    public var isReflective: Bool {
        switch self {
        case .calendar, .insights, .onThisDay: true
        case .today, .journal: false
        }
    }
}

// MARK: - Bulk storage actions

/// The storage collection currently being acted on. This is deliberately
/// separate from UI routing so destructive semantics remain testable.
public enum BulkEntryStorage: Hashable, Sendable {
    case library
    case archive
    /// Hidden is a privacy view that may contain both active and archived
    /// entries, so it deliberately exposes both lifecycle transitions.
    case hidden
    case trash
}

/// A batch operation the Journal can meaningfully offer for a storage context.
/// Moving to Trash is reversible; deleting forever is not.
public enum BulkEntryAction: Hashable, Sendable {
    case favorite
    case tag
    case archive
    case unarchive
    case moveToTrash
    case restoreFromTrash
    case deleteForever

    public var isIrreversible: Bool { self == .deleteForever }
}

public enum BulkEntryActions {
    public static func available(in storage: BulkEntryStorage) -> [BulkEntryAction] {
        switch storage {
        case .library:
            [.favorite, .tag, .archive, .moveToTrash]
        case .archive:
            [.unarchive, .moveToTrash]
        case .hidden:
            [.favorite, .tag, .archive, .unarchive, .moveToTrash]
        case .trash:
            [.restoreFromTrash, .deleteForever]
        }
    }
}

// MARK: - Analytics presentation

/// A user-facing period used consistently across reflective surfaces.
public enum AnalyticsPeriod: String, CaseIterable, Hashable, Sendable, Identifiable {
    case sevenDays
    case thirtyDays
    case threeMonths
    case year
    case allTime

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .threeMonths: "3 months"
        case .year: "Year"
        case .allTime: "All time"
        }
    }

    /// Inclusive lower boundary for a period, normalized to the user's calendar day.
    /// `nil` means the query intentionally has no lower bound.
    public func startDate(relativeTo reference: Date, calendar: Calendar = .current) -> Date? {
        let day = calendar.startOfDay(for: reference)
        switch self {
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -6, to: day)
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: day)
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: day)
        case .year:
            return calendar.dateInterval(of: .year, for: day)?.start
        case .allTime:
            return nil
        }
    }
}

/// Makes private-entry inclusion an explicit, explainable choice in analytics.
public enum AnalyticsVisibility: String, CaseIterable, Hashable, Sendable, Identifiable {
    case visibleOnly
    case includePrivate

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .visibleOnly: "Private entries excluded"
        case .includePrivate: "Private entries included"
        }
    }
}

/// The minimal, privacy-safe data shape needed to decide whether an entry
/// contributes to a reflective view. The app maps its richer entry model into
/// this type so the scope rule remains independently testable.
public struct AnalyticsRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let isPrivate: Bool

    public init(id: String, date: Date, isPrivate: Bool) {
        self.id = id
        self.date = date
        self.isPrivate = isPrivate
    }
}

public enum OmegaAnalytics {
    /// Filters records by the exact period and private-entry choice a reflective
    /// surface communicates to the user. Every period ends at the close of the
    /// reference day, so future-dated writing never appears in "through today"
    /// reflection—even when Calendar permits planning a future entry.
    public static func filteredRecords(
        _ records: [AnalyticsRecord],
        period: AnalyticsPeriod,
        visibility: AnalyticsVisibility,
        relativeTo reference: Date = Date(),
        calendar: Calendar = .current
    ) -> [AnalyticsRecord] {
        let start = period.startDate(relativeTo: reference, calendar: calendar)
        let referenceDay = calendar.startOfDay(for: reference)
        let end = calendar.date(byAdding: .day, value: 1, to: referenceDay) ?? reference
        return records.filter { record in
            let isInPeriod = start.map { record.date >= $0 } ?? true
            let isBeforeEnd = record.date < end
            let isVisible = visibility == .includePrivate || !record.isPrivate
            return isInPeriod && isBeforeEnd && isVisible
        }
    }
}

// MARK: - Tag normalization

extension OmegaCore {
    /// Trims, strips leading `#`, removes commas (the text-column separator),
    /// collapses inner whitespace, drops empties, and dedupes case-insensitively
    /// (first spelling wins, order preserved).
    public static func normalizeTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in raw {
            var t = tag.replacingOccurrences(of: ",", with: " ")
            t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            while t.hasPrefix("#") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }
}

// MARK: - Non-punitive streaks

/// How a writing streak is measured.
public enum StreakMode: String, CaseIterable, Sendable {
    /// Consecutive days, forgiving one missed day in any 7-day window.
    case dailyWithRest
    /// Consecutive calendar weeks that reached a target number of writing days.
    case weekly
}

public struct StreakSummary: Equatable, Sendable {
    public let current: Int
    public let longest: Int
    /// What `current`/`longest` count: "day" or "week".
    public let unit: String
    /// True when today has no entry yet but the streak is still safe.
    public let writtenToday: Bool
    /// Days since the most recent writing day (nil when there is none).
    public let daysSinceLastEntry: Int?

    public init(current: Int, longest: Int, unit: String, writtenToday: Bool, daysSinceLastEntry: Int?) {
        self.current = current
        self.longest = longest
        self.unit = unit
        self.writtenToday = writtenToday
        self.daysSinceLastEntry = daysSinceLastEntry
    }
}

public enum StreakCalculator {
    /// Grace rule: at most one missed day in any 7 consecutive days is forgiven.
    /// A missed day does not add to the count; it only fails to break it. Today
    /// without an entry is "not yet", never a miss.
    public static func dailyStreak(
        writingDays: Set<Date>,
        today: Date = Date(),
        calendar: Calendar = .current,
        graceWindow: Int = 7
    ) -> Int {
        let days = Set(writingDays.map { calendar.startOfDay(for: $0) })
        guard let earliest = days.min() else { return 0 }
        let todayStart = calendar.startOfDay(for: today)
        var date = todayStart
        var count = 0
        var lastMissOffset: Int?   // steps back from today of the most recent (newer) miss
        var step = 0
        while date >= earliest {
            if days.contains(date) {
                count += 1
            } else if date == todayStart {
                // Today is still open.
            } else {
                if let last = lastMissOffset, step - last < graceWindow { break }
                lastMissOffset = step
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
            step += 1
        }
        return count
    }

    public static func longestDailyStreak(
        writingDays: Set<Date>,
        calendar: Calendar = .current,
        graceWindow: Int = 7
    ) -> Int {
        let days = Set(writingDays.map { calendar.startOfDay(for: $0) })
        guard let earliest = days.min(), let latest = days.max() else { return 0 }
        var date = earliest
        var count = 0, best = 0
        var sinceMiss: Int?   // days since last forgiven miss inside this streak
        while date <= latest {
            if days.contains(date) {
                count += 1
                best = max(best, count)
                if let s = sinceMiss { sinceMiss = s + 1 }
            } else if count > 0 {
                if let s = sinceMiss, s < graceWindow - 1 {
                    count = 0
                    sinceMiss = nil
                } else {
                    sinceMiss = 0
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return best
    }

    /// Consecutive weeks (ending at the current week, which is still open and
    /// never breaks the streak) with at least `target` distinct writing days.
    public static func weeklyStreak(
        writingDays: Set<Date>,
        target: Int,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let counts = weekCounts(writingDays, calendar: calendar)
        guard target > 0, !counts.isEmpty,
              let currentWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let earliest = counts.keys.min() else { return 0 }
        var week = currentWeek
        var streak = 0
        if (counts[week] ?? 0) >= target { streak += 1 }
        while let prev = calendar.date(byAdding: .weekOfYear, value: -1, to: week), prev >= earliest {
            week = prev
            if (counts[week] ?? 0) >= target { streak += 1 } else { break }
        }
        return streak
    }

    public static func longestWeeklyStreak(
        writingDays: Set<Date>,
        target: Int,
        calendar: Calendar = .current
    ) -> Int {
        let counts = weekCounts(writingDays, calendar: calendar)
        guard target > 0, let first = counts.keys.min(), let last = counts.keys.max() else { return 0 }
        var week = first, run = 0, best = 0
        while week <= last {
            if (counts[week] ?? 0) >= target { run += 1; best = max(best, run) } else { run = 0 }
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week) else { break }
            week = next
        }
        return best
    }

    private static func weekCounts(_ days: Set<Date>, calendar: Calendar) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        for day in Set(days.map { calendar.startOfDay(for: $0) }) {
            if let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start {
                counts[start, default: 0] += 1
            }
        }
        return counts
    }

    public static func summary(
        writingDays: Set<Date>,
        mode: StreakMode,
        weeklyTarget: Int = 3,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> StreakSummary {
        let days = Set(writingDays.map { calendar.startOfDay(for: $0) })
        let todayStart = calendar.startOfDay(for: today)
        let since = days.filter { $0 <= todayStart }.max().flatMap {
            calendar.dateComponents([.day], from: $0, to: todayStart).day
        }
        switch mode {
        case .dailyWithRest:
            return StreakSummary(
                current: dailyStreak(writingDays: days, today: today, calendar: calendar),
                longest: longestDailyStreak(writingDays: days, calendar: calendar),
                unit: "day", writtenToday: days.contains(todayStart), daysSinceLastEntry: since)
        case .weekly:
            return StreakSummary(
                current: weeklyStreak(writingDays: days, target: weeklyTarget, today: today, calendar: calendar),
                longest: longestWeeklyStreak(writingDays: days, target: weeklyTarget, calendar: calendar),
                unit: "week", writtenToday: days.contains(todayStart), daysSinceLastEntry: since)
        }
    }
}

/// Gentle, non-guilt-inducing copy. Views should display these strings as-is.
public enum StreakCopy {
    public static func welcomeBack(daysAway: Int?) -> String {
        guard let d = daysAway else { return "Welcome. Your first entry starts the story." }
        switch d {
        case ...0: return "Nice to see you today."
        case 1: return "Welcome back. Pick up wherever you like."
        case 2...6: return "Welcome back. No pressure. Even a sentence counts."
        default: return "Welcome back. Your journal was here waiting. Start small."
        }
    }

    public static func streakLine(_ s: StreakSummary) -> String {
        if s.current == 0 { return "A fresh start is always available." }
        let noun = s.current == 1 ? s.unit : s.unit + "s"
        return "\(s.current) \(noun) of showing up"
    }
}
