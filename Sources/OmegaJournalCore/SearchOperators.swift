import Foundation

// MARK: - Search operators (pure)
//
// `tag:work mood:good before:2026-03-01 after:2026-01-01 has:image "exact phrase" free words`
//
// Parsing and matching are independent of the app's entry type so the rules (and the hidden-entry
// masking policy) are unit-testable without a database.

public struct SearchQuery: Equatable, Sendable {
    public enum Has: String, CaseIterable, Sendable {
        case image, attachment, link, task
    }

    /// Operator keys the parser understands (also drives the suggestion chips in the UI).
    public static let operatorKeys = ["tag", "mood", "before", "after", "has"]

    /// Free text with operators removed (quotes around phrases dropped).
    public var text: String = ""
    public var tags: [String] = []
    public var moods: [String] = []
    /// Entries strictly before the start of this day.
    public var before: Date?
    /// Entries strictly after the end of this day.
    public var after: Date?
    public var has: [Has] = []

    public init() {}

    public var hasOperators: Bool {
        !tags.isEmpty || !moods.isEmpty || before != nil || after != nil || !has.isEmpty
    }
    public var isEmpty: Bool { text.isEmpty && !hasOperators }

    /// Free-text terms (whitespace separated; quoted phrases stay one term).
    public var terms: [String] { Self.splitTerms(text) }

    // MARK: Parsing

    static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for ch in raw {
            if ch == "\"" { inQuote.toggle(); current.append(ch); continue }
            if ch.isWhitespace && !inQuote {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func unquote(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits free text into terms, keeping `"quoted phrases"` together.
    static func splitTerms(_ text: String) -> [String] {
        tokenize(text).map(unquote).filter { !$0.isEmpty }
    }

    public static func parse(_ raw: String, calendar: Calendar = .current, now: Date = Date()) -> SearchQuery {
        var q = SearchQuery()
        var free: [String] = []
        for token in tokenize(raw) {
            if token.hasPrefix("#"), token.count > 1, !token.contains(":") {
                q.tags.append(unquote(String(token.dropFirst())))
                continue
            }
            guard let colon = token.firstIndex(of: ":") else {
                free.append(unquote(token)); continue
            }
            let key = token[..<colon].lowercased()
            let value = unquote(String(token[token.index(after: colon)...]))
            guard Self.operatorKeys.contains(key), !value.isEmpty else {
                free.append(unquote(token)); continue
            }
            switch key {
            case "tag":
                q.tags.append(value.hasPrefix("#") ? String(value.dropFirst()) : value)
            case "mood":
                q.moods.append(value.lowercased())
            case "before":
                if let d = parseDate(value, calendar: calendar, now: now) { q.before = d.start } else { free.append(token) }
            case "after":
                if let d = parseDate(value, calendar: calendar, now: now) { q.after = d.end } else { free.append(token) }
            case "has":
                if let h = Has(rawValue: value.lowercased()) ?? (value.lowercased() == "images" ? .image : nil) {
                    if !q.has.contains(h) { q.has.append(h) }
                } else { free.append(token) }
            default:
                free.append(token)
            }
        }
        q.text = free.filter { !$0.isEmpty }.joined(separator: " ")
        return q
    }

    /// `2026-03-04`, `2026-03`, `2026`, `today`, `yesterday`. Returns the covered interval.
    static func parseDate(_ value: String, calendar: Calendar, now: Date) -> (start: Date, end: Date)? {
        let lower = value.lowercased()
        let startToday = calendar.startOfDay(for: now)
        func dayInterval(_ d: Date) -> (Date, Date)? {
            let s = calendar.startOfDay(for: d)
            guard let e = calendar.date(byAdding: .day, value: 1, to: s) else { return nil }
            return (s, e)
        }
        if lower == "today" { return dayInterval(startToday) }
        if lower == "yesterday", let y = calendar.date(byAdding: .day, value: -1, to: startToday) { return dayInterval(y) }
        let parts = lower.split(separator: "-").map(String.init)
        guard (1...3).contains(parts.count), let year = Int(parts[0]), (1...9999).contains(year) else { return nil }
        var comps = DateComponents(year: year, month: 1, day: 1)
        var component: Calendar.Component = .year
        if parts.count >= 2 {
            guard let m = Int(parts[1]), (1...12).contains(m) else { return nil }
            comps.month = m; component = .month
        }
        if parts.count == 3 {
            guard let d = Int(parts[2]), (1...31).contains(d) else { return nil }
            comps.day = d; component = .day
        }
        guard let start = calendar.date(from: comps),
              calendar.dateComponents([.year, .month, .day], from: start).day == comps.day,
              let end = calendar.date(byAdding: component, value: 1, to: start) else { return nil }
        return (start, end)
    }

    // MARK: Matching

    /// Lightweight, UI-free view of an entry for matching.
    public struct Record: Equatable, Sendable {
        public var id: String
        public var title: String
        public var body: String
        public var tags: [String]
        public var moodName: String
        public var moodValue: Int
        public var createdAt: Date
        public var attachmentCount: Int
        public var hasImage: Bool
        public var wordCount: Int
        public var isHidden: Bool

        public init(id: String, title: String, body: String, tags: [String], moodName: String, moodValue: Int,
                    createdAt: Date, attachmentCount: Int = 0, hasImage: Bool = false, wordCount: Int = 0,
                    isHidden: Bool = false) {
            self.id = id; self.title = title; self.body = body; self.tags = tags
            self.moodName = moodName; self.moodValue = moodValue; self.createdAt = createdAt
            self.attachmentCount = attachmentCount; self.hasImage = hasImage
            self.wordCount = wordCount; self.isHidden = isHidden
        }
    }

    /// Whether `record` satisfies every part of the query.
    ///
    /// Privacy: while `hiddenLocked`, a hidden entry exposes only its title, mood and date (what its
    /// masked card already shows). Its body and tags never match, and `tag:` / `has:` operators
    /// cannot match it.
    public func matches(_ record: Record, hiddenLocked: Bool) -> Bool {
        let masked = record.isHidden && hiddenLocked
        if masked && (!tags.isEmpty || !has.isEmpty) { return false }

        for wanted in tags {
            if !record.tags.contains(where: { TagPath.isSameOrDescendant($0, of: wanted) }) { return false }
        }
        if !moods.isEmpty {
            let name = record.moodName.lowercased()
            if !moods.contains(where: { $0 == name || $0 == String(record.moodValue) }) { return false }
        }
        if let before, record.createdAt >= before { return false }
        if let after, record.createdAt < after { return false }
        for h in has {
            switch h {
            case .image: if !record.hasImage { return false }
            case .attachment: if record.attachmentCount == 0 { return false }
            case .link: if !Self.containsLink(record.body) { return false }
            case .task: if !record.body.contains("- [ ]") && !record.body.contains("- [x]") && !record.body.contains("- [X]") { return false }
            }
        }
        for term in terms {
            if Self.contains(record.title, term) { continue }
            if masked { return false }
            if Self.contains(record.body, term) { continue }
            if record.tags.contains(where: { Self.contains($0, term) }) { continue }
            return false
        }
        return true
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func containsLink(_ body: String) -> Bool {
        body.contains("http://") || body.contains("https://") || body.contains("](")
    }
}

// MARK: - Highlighted snippets

public struct SearchSnippet: Equatable, Sendable {
    /// Display text, whitespace-collapsed, with `…` where it was cut.
    public let text: String
    /// UTF-16 ranges inside `text` that match a search term.
    public let highlights: [NSRange]

    /// Builds a snippet around the first match of any term in `source`. Returns nil when no term occurs.
    public static func make(from source: String, terms: [String], radius: Int = 56) -> SearchSnippet? {
        let usable = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !usable.isEmpty, !source.isEmpty else { return nil }
        let collapsed = source
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var first: Range<String.Index>?
        for t in usable {
            if let r = collapsed.range(of: t, options: opts), first == nil || r.lowerBound < first!.lowerBound { first = r }
        }
        guard let hit = first else { return nil }
        let startIdx = collapsed.index(hit.lowerBound, offsetBy: -radius, limitedBy: collapsed.startIndex) ?? collapsed.startIndex
        let endIdx = collapsed.index(hit.upperBound, offsetBy: radius, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        var window = String(collapsed[startIdx..<endIdx])
        let prefix = startIdx > collapsed.startIndex ? "…" : ""
        let suffix = endIdx < collapsed.endIndex ? "…" : ""
        window = prefix + window + suffix

        var ranges: [NSRange] = []
        let ns = window as NSString
        for t in usable {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let r = ns.range(of: t, options: opts, range: search)
                if r.location == NSNotFound { break }
                ranges.append(r)
                let next = NSMaxRange(r)
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        ranges.sort { $0.location < $1.location }
        return SearchSnippet(text: window, highlights: ranges)
    }
}

// MARK: - Recent searches

public enum RecentSearches {
    public static let settingKey = "recent_searches_v1"
    public static let maxCount = 8

    public static func decode(_ raw: String) -> [String] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    public static func encode(_ list: [String]) -> String {
        guard let data = try? JSONEncoder().encode(list), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Most-recent-first, case-insensitively de-duplicated, capped. Blank and 1-character queries are ignored.
    public static func adding(_ query: String, to list: [String]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return list }
        var out = list.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        out.insert(q, at: 0)
        return Array(out.prefix(maxCount))
    }
}

// MARK: - Masking-aware snippet

extension SearchSnippet {
    /// Snippet for an entry's BODY (falling back to nothing). A hidden entry that is locked never
    /// yields body text — only the (already visible) title matches, which need no snippet.
    public static func forRecord(_ record: SearchQuery.Record, terms: [String], hiddenLocked: Bool, radius: Int = 56) -> SearchSnippet? {
        if record.isHidden && hiddenLocked { return nil }
        return make(from: record.body, terms: terms, radius: radius)
    }
}

// MARK: - Content masking

public enum ContentMasking {
    /// Body text, previews, thumbnails, tags and snippets may be shown only when this is true.
    public static func canShowContent(isHidden: Bool, hiddenLocked: Bool) -> Bool { !(isHidden && hiddenLocked) }
}

// MARK: - Drag payloads (sidebar drops)

public enum EntryDragPayload {
    public static let prefix = "omega-entries:"
    public static func encode(_ ids: [String]) -> String { prefix + ids.joined(separator: ",") }
    public static func decode(_ s: String) -> [String] {
        guard s.hasPrefix(prefix) else { return [] }
        return s.dropFirst(prefix.count).split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
}
