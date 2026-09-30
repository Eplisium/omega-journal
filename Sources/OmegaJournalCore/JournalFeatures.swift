import Foundation

// MARK: - Saved searches

/// A named search + tag/mood filter the user can re-apply from the sidebar.
public struct SavedSearch: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var query: String
    public var tag: String?
    public var mood: String?

    public init(id: String = UUID().uuidString, name: String, query: String, tag: String? = nil, mood: String? = nil) {
        self.id = id
        self.name = name
        self.query = query
        self.tag = tag
        self.mood = mood
    }
}

public enum SavedSearchStore {
    public static let settingKey = "saved_searches_v1"
    public static let maxCount = 50

    public static func decode(_ raw: String) -> [SavedSearch] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return [] }
        return list
    }

    public static func encode(_ list: [SavedSearch]) -> String {
        guard let data = try? JSONEncoder().encode(list), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Appends `new`, replacing an existing search of the same name (case-insensitive).
    /// Blank names fall back to the query/tag; a search with nothing to run is rejected.
    public static func adding(_ new: SavedSearch, to list: [SavedSearch]) -> [SavedSearch] {
        var s = new
        s.name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        s.query = s.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.name.isEmpty { s.name = s.query.isEmpty ? (s.tag.map { "#\($0)" } ?? s.mood ?? "") : s.query }
        guard !s.name.isEmpty, !(s.query.isEmpty && s.tag == nil && s.mood == nil) else { return list }
        var out = list.filter { $0.name.caseInsensitiveCompare(s.name) != .orderedSame }
        out.append(s)
        return Array(out.suffix(maxCount))
    }
}

// MARK: - Wiki links / backlinks

/// Lightweight entry value for link analysis.
public struct LinkableEntry: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let isHidden: Bool
    public init(id: String, title: String, body: String, isHidden: Bool = false) {
        self.id = id; self.title = title; self.body = body; self.isHidden = isHidden
    }
}

public struct ResolvedWikiLink: Equatable, Sendable {
    public let title: String
    /// Id of the entry whose title matches (case-insensitive), nil when unresolved.
    public let entryId: String?
}

public enum WikiLinks {
    /// Text with fenced code blocks and inline code spans blanked out.
    static func stripCode(_ text: String) -> String {
        var out: [Substring] = []
        var inFence = false
        var fenceMarker = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let marker = trimmed.hasPrefix("```") ? "```" : (trimmed.hasPrefix("~~~") ? "~~~" : "")
            if inFence {
                if !marker.isEmpty && marker == fenceMarker { inFence = false }
                continue
            }
            if !marker.isEmpty { inFence = true; fenceMarker = marker; continue }
            out.append(line)
        }
        var joined = out.joined(separator: "\n")
        joined = joined.replacingOccurrences(of: "`[^`\\n]*`", with: "", options: .regularExpression)
        return joined
    }

    /// Titles referenced as `[[Title]]` (or `[[Title|alias]]`), in order, code excluded.
    public static func linkTitles(in text: String) -> [String] {
        let stripped = stripCode(text)
        guard stripped.contains("[["),
              let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\[\\]\\n]+?)\\]\\]") else { return [] }
        let ns = stripped as NSString
        return regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var inner = ns.substring(with: m.range(at: 1))
            if let bar = inner.firstIndex(of: "|") { inner = String(inner[..<bar]) }
            let t = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }

    private static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Entries whose body links to `title`. Hidden sources are excluded unless `includeHidden`.
    public static func backlinks(toTitle title: String, in entries: [LinkableEntry], excludingId: String? = nil,
                                 includeHidden: Bool = false) -> [LinkableEntry] {
        let target = key(title)
        guard !target.isEmpty else { return [] }
        return entries.filter { e in
            if e.id == excludingId { return false }
            if e.isHidden && !includeHidden { return false }
            return linkTitles(in: e.body).contains { key($0) == target }
        }
    }

    /// Resolves every `[[link]]` in `text` against `entries` (hidden targets ignored unless `includeHidden`).
    public static func resolveWikiLinks(in text: String, entries: [LinkableEntry], includeHidden: Bool = false) -> [ResolvedWikiLink] {
        var byTitle: [String: String] = [:]
        for e in entries where includeHidden || !e.isHidden {
            let k = key(e.title)
            if !k.isEmpty, byTitle[k] == nil { byTitle[k] = e.id }
        }
        return linkTitles(in: text).map { ResolvedWikiLink(title: $0, entryId: byTitle[key($0)]) }
    }
}

// MARK: - Weekly / monthly review

public enum ReviewPeriod: String, CaseIterable, Sendable, Identifiable {
    case week, month
    public var id: String { rawValue }
    public var label: String { self == .week ? "Weekly review" : "Monthly review" }
}

/// Lightweight entry value so the generator stays independent of the app's entry type.
public struct ReviewEntry: Equatable, Sendable {
    public let title: String
    public let body: String
    /// 1 (awful) … 5 (great)
    public let mood: Int
    public let tags: [String]
    public let createdAt: Date
    public let isFavorite: Bool
    public let isPinned: Bool
    public let isHidden: Bool
    public init(title: String, body: String, mood: Int, tags: [String], createdAt: Date,
                isFavorite: Bool = false, isPinned: Bool = false, isHidden: Bool = false) {
        self.title = title; self.body = body; self.mood = mood; self.tags = tags
        self.createdAt = createdAt; self.isFavorite = isFavorite; self.isPinned = isPinned; self.isHidden = isHidden
    }
}

public struct ReviewDraft: Equatable, Sendable {
    public let title: String
    public let body: String
    public let entryCount: Int
}

public enum ReviewGenerator {
    static let moodEmoji = ["", "😞", "😕", "😐", "🙂", "😄"]

    /// The period containing `reference` (week uses the calendar's first weekday).
    public static func interval(for period: ReviewPeriod, containing reference: Date, calendar: Calendar) -> DateInterval {
        let comp: Calendar.Component = period == .week ? .weekOfYear : .month
        return calendar.dateInterval(of: comp, for: reference)
            ?? DateInterval(start: calendar.startOfDay(for: reference), duration: 86_400)
    }

    public static func draft(period: ReviewPeriod, entries: [ReviewEntry], reference: Date = Date(),
                             includeHidden: Bool = false, calendar: Calendar = .current) -> ReviewDraft {
        let range = interval(for: period, containing: reference, calendar: calendar)
        let inRange = entries
            .filter { range.contains($0.createdAt) && (includeHidden || !$0.isHidden) }
            .sorted { $0.createdAt < $1.createdAt }

        let titleFmt = DateFormatter()
        titleFmt.calendar = calendar
        titleFmt.timeZone = calendar.timeZone
        titleFmt.locale = Locale(identifier: "en_US_POSIX")
        let dayFmt = DateFormatter()
        dayFmt.calendar = calendar; dayFmt.timeZone = calendar.timeZone; dayFmt.locale = titleFmt.locale
        dayFmt.dateFormat = "EEE MMM d"
        let lastDay = calendar.date(byAdding: .second, value: -1, to: range.end) ?? range.end
        let title: String
        if period == .month {
            titleFmt.dateFormat = "MMMM yyyy"
            title = "Monthly review: \(titleFmt.string(from: range.start))"
        } else {
            title = "Weekly review: \(dayFmt.string(from: range.start)) – \(dayFmt.string(from: lastDay))"
        }

        var lines: [String] = ["# \(title)", ""]
        let words = inRange.reduce(0) { $0 + $1.body.split(whereSeparator: { $0.isWhitespace }).count }
        let activeDays = Set(inRange.map { calendar.startOfDay(for: $0.createdAt) }).count
        if inRange.isEmpty {
            lines.append("No entries this \(period == .week ? "week" : "month") yet. That's fine. Write whatever feels right today.")
            return ReviewDraft(title: title, body: lines.joined(separator: "\n"), entryCount: 0)
        }
        lines.append("**\(inRange.count) \(inRange.count == 1 ? "entry" : "entries")** across \(activeDays) \(activeDays == 1 ? "day" : "days") · \(words) words")
        lines.append("")

        // Mood arc: one line per day with average mood.
        lines.append("## Mood arc")
        var perDay: [(Date, [Int])] = []
        for e in inRange {
            let d = calendar.startOfDay(for: e.createdAt)
            if let i = perDay.firstIndex(where: { $0.0 == d }) { perDay[i].1.append(e.mood) } else { perDay.append((d, [e.mood])) }
        }
        for (day, moods) in perDay {
            let avg = Double(moods.reduce(0, +)) / Double(moods.count)
            let idx = min(5, max(1, Int(avg.rounded())))
            lines.append("- \(dayFmt.string(from: day)): \(moodEmoji[idx]) \(String(format: "%.1f", avg))/5")
        }
        let overall = Double(inRange.reduce(0) { $0 + $1.mood }) / Double(inRange.count)
        lines.append("")
        lines.append("Average mood: \(String(format: "%.1f", overall))/5")
        lines.append("")

        // Top tags
        var counts: [String: Int] = [:]
        for e in inRange { for t in Set(e.tags) { counts[t, default: 0] += 1 } }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5)
        if !top.isEmpty {
            lines.append("## Top tags")
            for (t, c) in top { lines.append("- #\(t) (\(c))") }
            lines.append("")
        }

        // Favorites / pins
        let highlights = inRange.filter { $0.isFavorite || $0.isPinned }
        if !highlights.isEmpty {
            lines.append("## Highlights")
            for e in highlights {
                let name = e.title.isEmpty ? "Untitled" : e.title
                lines.append("- \(e.isFavorite ? "★" : "📌") [[\(name)]]")
            }
            lines.append("")
        }

        lines.append("## Reflection")
        lines.append("- What stood out this \(period == .week ? "week" : "month")?")
        lines.append("- What am I grateful for?")
        lines.append("- What do I want to carry forward?")
        return ReviewDraft(title: title, body: lines.joined(separator: "\n"), entryCount: inRange.count)
    }
}
