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
