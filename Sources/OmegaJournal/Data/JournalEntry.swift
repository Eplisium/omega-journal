import Foundation
import SwiftUI
import os
import OmegaJournalCore

// MARK: - Attachment

nonisolated struct Attachment: Identifiable, Hashable {
    let id: String
    let entryId: String
    let filename: String
    let mimeType: String
    let createdAt: Date

    var isImage: Bool {
        mimeType.hasPrefix("image/")
    }
}

// MARK: - Journal Entry

nonisolated struct JournalEntry: Identifiable, Hashable {
    let id: String
    var title: String
    /// Replacing the body drops the derived-value memo (a copy keeps its own).
    var body: String { didSet { derived = EntryDerivedMemo() } }
    var mood: Mood
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var isFavorite: Bool
    var isArchived: Bool
    /// Non-nil when the entry is in the trash.
    var deletedAt: Date?
    /// Whether the entry is hidden (requires biometric/password to view).
    var isHidden: Bool
    var attachments: [Attachment]
    /// Notebook the entry belongs to (V11). Defaults to the migrated default journal.
    var journalId: String = JournalDefaults.defaultJournalId
    /// Memo for values derived from `body` (word count). Equality- and
    /// hash-neutral, so it never changes what two entries compare as.
    var derived = EntryDerivedMemo()

    static func new() -> JournalEntry {
        JournalEntry(id: UUID().uuidString, title: "", body: "", mood: .neutral,
                     tags: [], createdAt: Date(), updatedAt: Date(),
                     isPinned: false, isFavorite: false, isArchived: false,
                     deletedAt: nil, isHidden: false, attachments: [])
    }

    var isTrashed: Bool { deletedAt != nil }

    /// Counted once per body (sorting by words and every search record used
    /// to recount 10k bodies on each pass); see `EntryDerivedMemo`.
    var wordCount: Int { derived.wordCount(of: body) }

    /// Words in an entry body, excluding the trailing `<!-- stamp: ... -->`
    /// comment. Same whitespace semantics as the editor footer
    /// (`MarkdownLogic.wordCount`), so saved counts match what the user saw.
    static func countWords(_ body: String) -> Int {
        guard !body.isEmpty else { return 0 }
        return MarkdownLogic.wordCount(EntryStampCodec.split(body).rest)
    }
    var characterCount: Int { body.count }

    var readingMinutes: Int { OmegaCore.readingMinutes(forWordCount: wordCount) }
    var readingTime: String {
        let minutes = readingMinutes
        guard minutes > 0 else { return "No words yet" }
        return minutes == 1 ? "1 min read" : "\(minutes) min read"
    }

    var displayTitle: String { title.isEmpty ? "Untitled" : title }

    /// One-line list/card preview with Markdown syntax removed (headings,
    /// bullets, tasks, quotes, emphasis) so rows read as prose. Only the first
    /// few lines are processed — rows truncate to ~2 lines anyway.
    var preview: String {
        let text = MarkdownPlainPreview.lines(EntryStampCodec.split(body).rest, limit: 8)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No content" : text
    }

    var bodyAsAttributed: AttributedString {
        MarkdownRenderer.render(body)
    }

    /// Days elapsed since the entry was moved to the trash.
    var daysInTrash: Int {
        guard let deletedAt else { return 0 }
        return Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
    }
}

// MARK: - Derived-value memo

/// Caches values derived from one body: its word count, whether it holds
/// Markdown image syntax, and whether search may use the ASCII fast path
/// (`SearchHaystack.isASCIIFoldable`). `body`'s `didSet` installs a fresh
/// memo, so a memo only ever describes the body it travels with.
/// Thread-safe (the load and search passes fill it off the main thread).
/// Always equal and hashes nothing, so `JournalEntry`'s synthesized
/// `Hashable` is unchanged.
nonisolated final class EntryDerivedMemo: Hashable, Sendable {
    private struct State {
        var wordCount: Int?
        var hasImageMarkup: Bool?
        var searchFoldable: Bool?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    func wordCount(of body: String) -> Int {
        if let known = state.withLock({ $0.wordCount }) { return known }
        let counted = JournalEntry.countWords(body)
        state.withLock { $0.wordCount = counted }
        return counted
    }

    /// `body.contains("![")`, the search record's image test.
    func hasImageMarkup(in body: String) -> Bool {
        if let known = state.withLock({ $0.hasImageMarkup }) { return known }
        let found = body.contains("![")
        state.withLock { $0.hasImageMarkup = found }
        return found
    }

    func isSearchFoldable(_ body: String) -> Bool {
        if let known = state.withLock({ $0.searchFoldable }) { return known }
        let foldable = SearchHaystack.isASCIIFoldable(body)
        state.withLock { $0.searchFoldable = foldable }
        return foldable
    }

    /// Whether the word count is already known (tests, load pass).
    var isPrimed: Bool { state.withLock { $0.wordCount != nil } }

    /// Records a count computed elsewhere for the same body.
    func prime(wordCount: Int) { state.withLock { $0.wordCount = wordCount } }

    /// Records every derived value computed elsewhere for the same body.
    func prime(_ opened: OpenedBody) {
        state.withLock {
            $0.wordCount = opened.wordCount
            $0.hasImageMarkup = opened.hasImageMarkup
            $0.searchFoldable = opened.searchFoldable
        }
    }

    static func == (lhs: EntryDerivedMemo, rhs: EntryDerivedMemo) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

// MARK: - Entry Filter

/// Declarative description of everything the entry list is currently filtering on.
nonisolated struct EntryFilter: Equatable, Codable {
    enum DateRange: String, CaseIterable, Identifiable, Codable {
        case any = "Any time"
        case today = "Today"
        case last7 = "Last 7 days"
        case last30 = "Last 30 days"
        case thisMonth = "This month"
        case thisYear = "This year"
        var id: String { rawValue }

        /// Inclusive lower bound, or nil for "any time".
        var startDate: Date? { startDate(now: Date(), calendar: .current) }

        func startDate(now: Date, calendar cal: Calendar) -> Date? {
            switch self {
            case .any: return nil
            case .today: return cal.startOfDay(for: now)
            // Today counts as one of the N days (matches AnalyticsPeriod).
            case .last7: return cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))
            case .last30: return cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))
            case .thisMonth: return cal.dateInterval(of: .month, for: now)?.start
            case .thisYear: return cal.dateInterval(of: .year, for: now)?.start
            }
        }

        /// Exclusive upper bound, or nil for "any time": the start of tomorrow
        /// for the day windows, the end of the month / year otherwise, so an
        /// entry planned on a future day (Calendar) never matches "Today" or
        /// "Last 7 days" (same rule as `SmartFolder.DateRange.end`).
        func endDate(now: Date, calendar cal: Calendar) -> Date? {
            switch self {
            case .any: return nil
            case .today, .last7, .last30: return cal.dateInterval(of: .day, for: now)?.end
            case .thisMonth: return cal.dateInterval(of: .month, for: now)?.end
            case .thisYear: return cal.dateInterval(of: .year, for: now)?.end
            }
        }
    }

    var moods: Set<Mood> = []
    var tags: Set<String> = []
    var dateRange: DateRange = .any
    var favoritesOnly = false
    var pinnedOnly = false
    var withAttachmentsOnly = false
    var minWords: Int = 0

    static let empty = EntryFilter()

    var isActive: Bool { self != EntryFilter.empty }

    var activeCount: Int {
        var n = 0
        if !moods.isEmpty { n += 1 }
        if !tags.isEmpty { n += 1 }
        if dateRange != .any { n += 1 }
        if favoritesOnly { n += 1 }
        if pinnedOnly { n += 1 }
        if withAttachmentsOnly { n += 1 }
        if minWords > 0 { n += 1 }
        return n
    }

    /// Privacy: while `hiddenLocked`, a hidden entry exposes only title, mood
    /// and date (its masked card). Content-derived facets — tags, word count,
    /// attachments — must never match it, or the filter would leak them.
    func matches(_ entry: JournalEntry, hiddenLocked: Bool, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let masked = !ContentMasking.canShowContent(isHidden: entry.isHidden, hiddenLocked: hiddenLocked)
        if masked && (!tags.isEmpty || withAttachmentsOnly || minWords > 0) { return false }
        if !moods.isEmpty && !moods.contains(entry.mood) { return false }
        if !tags.isEmpty && tags.isDisjoint(with: Set(entry.tags)) { return false }
        if let start = dateRange.startDate(now: now, calendar: calendar), entry.createdAt < start { return false }
        if let end = dateRange.endDate(now: now, calendar: calendar), entry.createdAt >= end { return false }
        if favoritesOnly && !entry.isFavorite { return false }
        if pinnedOnly && !entry.isPinned { return false }
        if withAttachmentsOnly && entry.attachments.isEmpty { return false }
        if minWords > 0 && entry.wordCount < minWords { return false }
        return true
    }

    /// The sidebar `.tag` collection: entries carrying `tag` or a descendant
    /// (`work` → `work/alpha`, matching the badge count), never a locked
    /// hidden entry (its tags are private).
    static func entries(_ list: [JournalEntry], taggedWith tag: String, hiddenLocked: Bool) -> [JournalEntry] {
        list.filter { entry in
            ContentMasking.canShowContent(isHidden: entry.isHidden, hiddenLocked: hiddenLocked)
                && entry.tags.contains { TagPath.isSameOrDescendant($0, of: tag) }
        }
    }
}
