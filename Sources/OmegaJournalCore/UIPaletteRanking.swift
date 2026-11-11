import Foundation

// MARK: - Command palette ranking + highlighting (pure)
//
// The palette used a loose subsequence match on titles *and* subtitles, then
// appended entry-content hits after every command. Typing "dream" could leave
// "Go to Trash" or "Sort by Mood" (letters scattered through the words, or a
// subtitle like "Navigate") above the entry that actually says "dream".
//
// Now every candidate — command, entry title, entry content hit — gets one
// relevance score from the same tiers, and the list is sorted by it:
//   exact title  >  title prefix  >  word prefix  >  substring  >  all words
//   >  entry content hit  >  tight fuzzy (initials / near-contiguous)
// Subtitles only count for whole-word or substring matches, at a discount.
// Scattered subsequences no longer match at all. Matched ranges are returned
// so the row can highlight them.

public enum UIPaletteRanking {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Matched character offsets in the text (`Character` indices).
        public let ranges: [Range<Int>]
        public init(score: Int, ranges: [Range<Int>]) { self.score = score; self.ranges = ranges }
    }

    public enum Tier: Int, Sendable {
        case fuzzy = 300
        case contentHit = 450
        case allWords = 500
        case substring = 600
        case wordPrefix = 700
        case prefix = 800
        case exact = 900
    }

    /// Relevance of `text` for `query`, or nil when it does not match.
    /// Within a tier, shorter texts and earlier matches rank higher.
    public static func match(_ query: String, in text: String, allowFuzzy: Bool = true) -> Match? {
        let q = Array(query.lowercased().trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return nil }
        let h = Array(text.lowercased())
        guard !h.isEmpty else { return nil }
        let lengthPenalty = min(99, h.count / 2)

        if h == q { return Match(score: Tier.exact.rawValue, ranges: [0..<h.count]) }
        if let at = find(q, in: h) {
            let tier: Tier = at == 0 ? .prefix : (isWordStart(at, h) ? .wordPrefix : .substring)
            return Match(score: tier.rawValue - lengthPenalty - min(50, at), ranges: [at..<(at + q.count)])
        }
        // Several words, each found somewhere ("export pdf" → "Export as PDF").
        let words = String(q).split(separator: " ").map(Array.init)
        if words.count > 1 {
            var ranges: [Range<Int>] = []
            for w in words {
                guard let at = find(w, in: h) else { ranges = []; break }
                ranges.append(at..<(at + w.count))
            }
            if !ranges.isEmpty {
                return Match(score: Tier.allWords.rawValue - lengthPenalty, ranges: merge(ranges))
            }
        }
        guard allowFuzzy, let fuzzy = tightFuzzy(q.filter { $0 != " " }, in: h) else { return nil }
        return Match(score: Tier.fuzzy.rawValue + fuzzy.bonus - lengthPenalty, ranges: merge(fuzzy.ranges))
    }

    /// Best score for a palette row: its title, or (discounted, no fuzzy) its subtitle.
    public static func score(_ query: String, title: String, subtitle: String) -> Match? {
        let t = match(query, in: title)
        let s = match(query, in: subtitle, allowFuzzy: false).map {
            Match(score: $0.score / 2, ranges: [])   // subtitle ranges are not highlighted
        }
        switch (t, s) {
        case let (t?, s?): return t.score >= s.score ? t : s
        case let (t?, nil): return t
        case let (nil, s?): return s
        default: return nil
        }
    }

    /// Sorts scored items best-first; ties keep their original order.
    public static func ranked<T>(_ items: [(T, Int)]) -> [T] {
        items.enumerated()
            .sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
            .map(\.element.0)
    }

    // MARK: Helpers

    private static func find(_ needle: [Character], in hay: [Character]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var best: Int?
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<(i + needle.count)]) == needle {
                // Prefer a match at a word start over an earlier mid-word one.
                if isWordStart(i, hay) { return i }
                if best == nil { best = i }
            }
        }
        return best
    }

    private static func isWordStart(_ i: Int, _ h: [Character]) -> Bool {
        i == 0 || !(h[i - 1].isLetter || h[i - 1].isNumber)
    }

    /// Subsequence match that must start each run at a word start (initials
    /// like "nft" → "New from Template") or stay near-contiguous. Scattered
    /// letters are rejected.
    private static func tightFuzzy(_ q: [Character], in h: [Character]) -> (bonus: Int, ranges: [Range<Int>])? {
        guard q.count >= 2 else { return nil }
        var qi = 0, ranges: [Range<Int>] = [], runStart = -1, last = -2, gaps = 0, runs = 0
        for (hi, ch) in h.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            if hi == last + 1 {
                // continues the run
            } else {
                // A new run must begin at a word start.
                guard isWordStart(hi, h) else { continue }
                if runStart >= 0 { ranges.append(runStart..<(last + 1)) }
                if last >= 0 { gaps += hi - last - 1 }
                runStart = hi; runs += 1
            }
            last = hi; qi += 1
        }
        guard qi == q.count else { return nil }
        ranges.append(runStart..<(last + 1))
        // Up to two runs ("newtem" → "New from Template"), or pure initials
        // ("nft"); anything choppier is scattered letters, not intent.
        guard runs <= 2 || ranges.allSatisfy({ $0.count == 1 }) else { return nil }
        let bonus = max(0, 90 - runs * 15 - min(60, gaps))
        return (bonus, ranges)
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<Int>] = []
        for r in sorted {
            if let lastRange = out.last, r.lowerBound <= lastRange.upperBound {
                out[out.count - 1] = lastRange.lowerBound..<max(lastRange.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
