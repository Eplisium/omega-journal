import Foundation

// MARK: - Ask your journal: local retrieval, prompt and citations (pure)
//
// Questions are answered by Apple's on-device model from a few short excerpts
// of the writer's own entries. Which entries are eligible, how they are ranked,
// what text the model sees and how its citations map back to entries is all
// decided here, without the model or the database.
//
// Privacy: a hidden entry is never eligible while hidden entries are locked —
// not its body, not its title, not its tags.

public struct AskJournalSource: Equatable, Sendable, Identifiable {
    /// 1-based number the model cites as `[n]`.
    public let number: Int
    public let entryId: String
    public let title: String
    public let createdAt: Date
    public let excerpt: String
    public let score: Double
    public var id: String { entryId }
}

public enum AskJournalRetrieval {
    public static let defaultLimit = 4
    public static let excerptLength = 600
    /// Recency half-life in days: an entry this old earns half the freshness bonus.
    public static let recencyHalfLifeDays: Double = 45

    static let stopwords: Set<String> = [
        "a", "about", "after", "again", "all", "am", "an", "and", "any", "are", "as", "at", "be", "been",
        "before", "being", "but", "by", "can", "could", "did", "do", "does", "doing", "done", "for", "from",
        "had", "has", "have", "having", "how", "i", "i'm", "i've", "if", "in", "into", "is", "it", "its",
        "journal", "just", "lately", "like", "me", "most", "my", "myself", "of", "on", "or", "our", "over",
        "recently", "said", "say", "should", "so", "some", "tell", "than", "that", "the", "their", "them",
        "then", "there", "these", "they", "this", "those", "to", "up", "very", "was", "we", "were", "what",
        "when", "where", "which", "while", "who", "whom", "why", "will", "with", "would", "wrote", "write",
        "written", "you", "your", "entries", "entry", "time", "times", "ever", "much", "many", "get", "got",
    ]

    /// Whether an entry may be considered at all.
    public static func isEligible(_ record: SearchQuery.Record, hiddenLocked: Bool) -> Bool {
        !(record.isHidden && hiddenLocked)
    }

    /// Meaningful words of the question (lowercased, stopwords and very short
    /// words dropped; a quoted phrase stays one term). Search operators such as
    /// `tag:` or `after:` are not terms — they filter instead.
    public static func terms(for question: String) -> [String] {
        let parsed = SearchQuery.parse(question)
        var out: [String] = []
        for raw in parsed.terms {
            let isPhrase = raw.contains(" ")
            let t = raw.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            if isPhrase { if t.count >= 3 { out.append(t) }; continue }
            guard t.count >= 3, !stopwords.contains(t) else { continue }
            if !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// A light stem so "walks"/"walking" match "walk" without a dictionary.
    static func stem(_ term: String) -> String {
        guard !term.contains(" ") else { return term }
        for suffix in ["ing", "ed", "es", "s"] where term.count > suffix.count + 3 && term.hasSuffix(suffix) {
            return String(term.dropLast(suffix.count))
        }
        return term
    }

    static func occurrences(of needle: String, in haystack: String, cap: Int) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while count < cap, let r = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
            count += 1
            range = r.upperBound..<haystack.endIndex
        }
        return count
    }

    static func recencyWeight(_ date: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return pow(0.5, days / recencyHalfLifeDays)
    }

    /// Relevance of one entry: title hits weigh most, then tags, then body
    /// mentions (capped so one long entry can't drown the rest).
    static func termScore(_ record: SearchQuery.Record, terms: [String]) -> Double {
        var score = 0.0
        let body = plainBody(record.body)
        for term in terms {
            let key = stem(term)
            if SearchQuery.contains(record.title, key) { score += 4 }
            if record.tags.contains(where: { SearchQuery.contains($0, key) }) { score += 3 }
            score += Double(occurrences(of: key, in: body, cap: 5))
        }
        return score
    }

    /// The body as the model should read it: no trailing place/weather stamp.
    static func plainBody(_ body: String) -> String {
        EntryStampCodec.split(body).rest
    }

    /// Top entries for `question`. With meaningful terms only entries that
    /// mention at least one are returned (none → empty, so the app can say so
    /// instead of guessing). A question with no meaningful terms ("How have I
    /// been?") gets the most recent entries. Operators in the question filter.
    public static func rank(question: String, records: [SearchQuery.Record], hiddenLocked: Bool,
                            now: Date = Date(), limit: Int = defaultLimit) -> [AskJournalSource] {
        let terms = terms(for: question)
        var operators = SearchQuery.parse(question)
        operators.text = ""
        operators.excluded = []
        let pool = records.filter {
            isEligible($0, hiddenLocked: hiddenLocked)
                && (!operators.hasOperators || operators.matches($0, hiddenLocked: hiddenLocked))
        }
        var scored: [(record: SearchQuery.Record, score: Double)] = []
        for record in pool {
            let recency = recencyWeight(record.createdAt, now: now)
            if terms.isEmpty {
                scored.append((record, recency))
            } else {
                let relevance = termScore(record, terms: terms)
                guard relevance > 0 else { continue }
                scored.append((record, relevance + 1.5 * recency))
            }
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.record.createdAt != $1.record.createdAt { return $0.record.createdAt > $1.record.createdAt }
            return $0.record.id < $1.record.id
        }
        return scored.prefix(max(0, limit)).enumerated().map { index, item in
            AskJournalSource(number: index + 1, entryId: item.record.id,
                             title: item.record.title.isEmpty ? "Untitled" : item.record.title,
                             createdAt: item.record.createdAt,
                             excerpt: excerpt(plainBody(item.record.body), terms: terms),
                             score: item.score)
        }
    }

    /// About `length` characters of `body` around the first mention of a term
    /// (or the opening when nothing matches), cut at word boundaries.
    public static func excerpt(_ body: String, terms: [String], length: Int = excerptLength) -> String {
        let text = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard text.count > length else { return text }
        var anchor = text.startIndex
        for term in terms {
            if let r = text.range(of: stem(term), options: [.caseInsensitive, .diacriticInsensitive]) {
                anchor = r.lowerBound; break
            }
        }
        let lead = min(length / 3, text.distance(from: text.startIndex, to: anchor))
        var start = text.index(anchor, offsetBy: -lead)
        let end = text.index(start, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        if end == text.endIndex { start = text.index(text.endIndex, offsetBy: -length) }
        var slice = String(text[start..<end])
        if start > text.startIndex, let space = slice.firstIndex(of: " ") { slice = String(slice[slice.index(after: space)...]) }
        if end < text.endIndex, let space = slice.lastIndex(of: " ") { slice = String(slice[..<space]) }
        return (start > text.startIndex ? "…" : "") + slice + (end < text.endIndex ? "…" : "")
    }
}

public enum AskJournalPrompt {
    public static let instructions = """
        You answer questions about the user's own private journal, speaking to them as "you". \
        Use only the numbered journal excerpts you are given. After each fact, cite the excerpt it came from \
        with its number in square brackets, like [1] or [2]. If the excerpts don't answer the question, \
        say that you couldn't find it in the journal. Keep it brief, warm and plain: at most four sentences. \
        Never invent events, people or dates.
        """

    public static func prompt(question: String, sources: [AskJournalSource],
                              dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }) -> String {
        var out = "Journal excerpts:\n"
        for s in sources {
            out += "\n[\(s.number)] \(s.title) — \(dateText(s.createdAt))\n\(s.excerpt)\n"
        }
        out += "\nQuestion: \(AssistResponseParser.oneLine(question))"
        return out
    }
}

public enum AskJournalCitations {
    /// Sources the answer cites (`[1]`, `[2, 3]`, `[Source 4]`), in order of first
    /// citation. Numbers that don't match a source are ignored.
    public static func cited(in answer: String, sources: [AskJournalSource]) -> [AskJournalSource] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(?:sources?\s*)?(\d+(?:\s*[,;]\s*\d+)*)\]"#,
                                                   options: [.caseInsensitive]) else { return [] }
        let ns = answer as NSString
        let byNumber = Dictionary(sources.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<Int>()
        var out: [AskJournalSource] = []
        for match in regex.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            let list = ns.substring(with: match.range(at: 1))
            for piece in list.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                guard let n = Int(piece.trimmingCharacters(in: .whitespaces)), let source = byNumber[n],
                      seen.insert(n).inserted else { continue }
                out.append(source)
            }
        }
        return out
    }

    /// What the answer panel lists under "Sources": the cited entries, or every
    /// excerpt the model was shown when it cited none.
    public static func sourcesToShow(answer: String, sources: [AskJournalSource]) -> [AskJournalSource] {
        let cited = cited(in: answer, sources: sources)
        return cited.isEmpty ? sources : cited
    }
}
