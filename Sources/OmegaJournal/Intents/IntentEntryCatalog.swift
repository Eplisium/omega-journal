import Foundation
import OmegaJournalCore

// MARK: - What Siri, Shortcuts and Apple Intelligence may see
//
// Pure, testable rules behind the entry/notebook/tag entities. They work on a
// small value snapshot (`IntentEntryRecord`), never on the database, so the
// privacy guarantees are unit-tested without a running journal:
//
// - Entries surface title, date, mood and tags only. Bodies are never returned.
// - A hidden entry surfaces title, date and mood only — never its tags — and is
//   never matched on body text, even while hidden entries are unlocked.
// - While hidden entries are locked, hidden entries are left out entirely.
// - While the whole-app lock is on (or the journal isn't open yet), nothing is
//   returned at all.
// - Trashed entries never appear.

nonisolated struct IntentEntryRecord: Equatable, Sendable {
    var id: String
    var title: String
    /// Searchable text: the body with its stamp removed. Empty for hidden entries.
    var searchText: String
    var createdAt: Date
    var mood: Int
    var moodName: String
    var tags: [String]
    var journalId: String
    var isHidden: Bool
    var isTrashed: Bool
    var isArchived: Bool

    init(id: String, title: String, searchText: String = "", createdAt: Date, mood: Int = 3, moodName: String = "neutral",
         tags: [String] = [], journalId: String = "", isHidden: Bool = false, isTrashed: Bool = false, isArchived: Bool = false) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.mood = mood; self.moodName = moodName
        self.journalId = journalId; self.isHidden = isHidden; self.isTrashed = isTrashed; self.isArchived = isArchived
        // Hidden entries never carry body text or tags out of the database layer.
        self.searchText = isHidden ? "" : searchText
        self.tags = isHidden ? [] : tags
    }
}

/// The fields an entity is allowed to show.
nonisolated struct IntentEntrySummary: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let date: Date
    let mood: Int
    let tags: [String]
    let isHidden: Bool
    let isArchived: Bool
    let journalId: String

    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title }
}

nonisolated struct IntentEntryFilter: Equatable, Sendable {
    var text: String?
    var tag: String?
    var journalId: String?
    var from: Date?
    var to: Date?
    var limit: Int = 20

    init(text: String? = nil, tag: String? = nil, journalId: String? = nil, from: Date? = nil, to: Date? = nil, limit: Int = 20) {
        self.text = text; self.tag = tag; self.journalId = journalId; self.from = from; self.to = to; self.limit = limit
    }
}

nonisolated enum IntentEntryCatalog {
    /// Entries that may be surfaced at all, newest first.
    static func visible(_ records: [IntentEntryRecord], hiddenLocked: Bool, appLocked: Bool) -> [IntentEntryRecord] {
        guard !appLocked else { return [] }
        return records
            .filter { !$0.isTrashed && !($0.isHidden && hiddenLocked) }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    static func summary(_ r: IntentEntryRecord) -> IntentEntrySummary {
        IntentEntrySummary(id: r.id, title: r.title, date: r.createdAt, mood: r.mood,
                           tags: r.isHidden ? [] : r.tags, isHidden: r.isHidden, isArchived: r.isArchived,
                           journalId: r.journalId)
    }

    static func entries(ids: [String], in records: [IntentEntryRecord], hiddenLocked: Bool, appLocked: Bool) -> [IntentEntrySummary] {
        let byId = Dictionary(visible(records, hiddenLocked: hiddenLocked, appLocked: appLocked).map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0].map(summary) }
    }

    /// Title search for the entity picker ("Open entry …"). Every word must
    /// appear in the title; matches whose title starts with the query come first.
    static func titleMatches(_ query: String, in records: [IntentEntryRecord], hiddenLocked: Bool, appLocked: Bool,
                             limit: Int = 30) -> [IntentEntrySummary] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let pool = visible(records, hiddenLocked: hiddenLocked, appLocked: appLocked)
        guard !words.isEmpty else { return Array(pool.prefix(limit)).map(summary) }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let hits = pool.filter { r in
            let t = r.title.lowercased()
            return words.allSatisfy { t.contains($0) }
        }
        let ranked = hits.filter { $0.title.lowercased().hasPrefix(q) } + hits.filter { !$0.title.lowercased().hasPrefix(q) }
        return Array(ranked.prefix(limit)).map(summary)
    }

    /// "Find entries": text uses the app's search grammar (all words, "phrases",
    /// -exclusions, tag:/mood:/before:/after: operators) over title + body for
    /// ordinary entries and title only for hidden ones. Dates are inclusive days.
    static func find(_ filter: IntentEntryFilter, in records: [IntentEntryRecord], hiddenLocked: Bool, appLocked: Bool,
                     calendar: Calendar = .current, now: Date = Date()) -> [IntentEntrySummary] {
        var pool = visible(records, hiddenLocked: hiddenLocked, appLocked: appLocked)
        if let j = filter.journalId, !j.isEmpty { pool = pool.filter { $0.journalId == j } }
        if let tag = filter.tag.map(normalizedTag), !tag.isEmpty {
            pool = pool.filter { !$0.isHidden && $0.tags.contains { TagPath.isSameOrDescendant($0, of: tag) } }
        }
        if let from = filter.from {
            let start = calendar.startOfDay(for: from)
            pool = pool.filter { $0.createdAt >= start }
        }
        if let to = filter.to {
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) ?? to
            pool = pool.filter { $0.createdAt < end }
        }
        if let text = filter.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let query = SearchQuery.parse(text, calendar: calendar, now: now)
            pool = pool.filter { r in
                query.matches(SearchQuery.Record(id: r.id, title: r.title, body: r.searchText, tags: r.tags,
                                                 moodName: r.moodName, moodValue: r.mood, createdAt: r.createdAt,
                                                 isHidden: r.isHidden),
                              hiddenLocked: true)
            }
        }
        return Array(pool.prefix(max(1, min(filter.limit, 200)))).map(summary)
    }

    static func normalizedTag(_ raw: String) -> String {
        OmegaCore.normalizeTags([raw.hasPrefix("#") ? String(raw.dropFirst()) : raw]).first ?? ""
    }

    /// Tags in use on visible, non-hidden entries, most used first.
    static func tags(in records: [IntentEntryRecord], hiddenLocked: Bool, appLocked: Bool) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in visible(records, hiddenLocked: hiddenLocked, appLocked: appLocked) where !r.isHidden {
            for t in Set(r.tags) { counts[t, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The entry "Append to today's entry" and "Log mood" act on: the newest
    /// ordinary entry written today (not hidden, archived or trashed). nil = make a new one.
    static func todaysEntryId(in records: [IntentEntryRecord], now: Date = Date(), calendar: Calendar = .current) -> String? {
        records
            .filter { !$0.isHidden && !$0.isTrashed && !$0.isArchived && calendar.isDate($0.createdAt, inSameDayAs: now) }
            .max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }?.id
    }

    /// `body` with `text` added as a new paragraph; a trailing place/weather
    /// stamp stays at the very end.
    static func appending(_ text: String, to body: String) -> String {
        let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return body }
        let (stamp, rest) = PlaceStampCodec.split(body)
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = trimmed.isEmpty ? addition : rest.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\n\n" + addition
        return PlaceStampCodec.join(stamp: stamp, rest: joined)
    }
}
