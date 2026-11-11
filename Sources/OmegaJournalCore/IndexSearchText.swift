import Foundation

// MARK: - Search text index (pure)
//
// `SearchQuery.contains` is `range(of:options: [.caseInsensitive, .diacriticInsensitive])`.
// Foundation's comparison is correct for every script but costs a full Unicode pass per call,
// and the list ran it over every decrypted body on every keystroke (≈1.7 s at 10k entries).
//
// For the overwhelmingly common case — a printable-ASCII search term and a text made of ASCII
// plus a fixed set of "inert" symbols (curly quotes, dashes, bullets, emoji…) — the same answer
// is a plain ASCII-case-insensitive byte search: such texts have no diacritics, no multi-letter
// case folds (ß → ss) and nothing Foundation ignores. Anything else falls back to the exact
// Foundation call, so results are identical by construction. `IndexSearchTextTests` pins the
// equivalence (inert set, ASCII pairs, a deterministic fuzz) on the running OS.

/// A search term prepared once per query.
public struct SearchNeedle: Equatable, Sendable {
    public let text: String
    /// Lower-cased bytes when the term is non-empty printable ASCII (fast path).
    let asciiLower: [UInt8]?

    public init(_ text: String) {
        self.text = text
        let bytes = Array(text.utf8)
        if !bytes.isEmpty, bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
            asciiLower = bytes.map(SearchHaystack.lowerASCII)
        } else {
            asciiLower = nil
        }
    }
}

/// A text that is searched repeatedly, with its fast-path eligibility worked out once.
public struct SearchHaystack: Sendable {
    public let text: String
    /// True when every scalar is ASCII or inert, so ASCII terms can use the byte search.
    public let isASCIIFoldable: Bool

    public init(_ text: String) {
        self.text = text
        self.isASCIIFoldable = Self.isASCIIFoldable(text)
    }

    /// For a text whose eligibility is already known (cached per body).
    public init(_ text: String, isASCIIFoldable: Bool) {
        self.text = text
        self.isASCIIFoldable = isASCIIFoldable
    }

    /// Same answer as `SearchQuery.contains(text, needle.text)`.
    public func contains(_ needle: SearchNeedle) -> Bool {
        if isASCIIFoldable, let lowered = needle.asciiLower {
            return Self.asciiCaseInsensitiveContains(text, lowered)
        }
        return SearchQuery.contains(text, needle.text)
    }

    // MARK: Eligibility

    public static func isASCIIFoldable(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.value >= 0x80 {
            if !isInert(scalar) { return false }
        }
        return true
    }

    /// Non-ASCII scalars that never match, fold to, or hide an ASCII character under
    /// `[.caseInsensitive, .diacriticInsensitive]`: they have no case, carry no diacritic,
    /// are not ignorable (unlike U+FE0F) and are not combining marks. Emoji skin-tone
    /// modifiers, variation selectors and joiners are deliberately absent.
    public static func isInert(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        for range in inertRanges where range.contains(v) { return true }
        return false
    }

    public static let inertRanges: [ClosedRange<UInt32>] = [
        0x00A0...0x00A0,   // no-break space
        0x00A9...0x00A9,   // ©
        0x00AB...0x00AB,   // «
        0x00B0...0x00B0,   // °
        0x00B7...0x00B7,   // ·
        0x00BB...0x00BB,   // »
        0x00D7...0x00D7,   // ×
        0x00F7...0x00F7,   // ÷
        0x2010...0x2015,   // hyphens and dashes
        0x2018...0x201F,   // curly quotes
        0x2020...0x2022,   // † ‡ •
        0x2026...0x2026,   // …
        0x2030...0x2030,   // ‰
        0x2032...0x2033,   // ′ ″
        0x2039...0x203A,   // ‹ ›
        0x20AC...0x20AC,   // €
        0x2190...0x21FF,   // arrows
        0x2600...0x26FF,   // miscellaneous symbols
        0x2700...0x27BF,   // dingbats
        0x1F300...0x1F3FA, // pictographs (skin-tone modifiers 1F3FB–1F3FF excluded)
        0x1F400...0x1F5FF,
        0x1F600...0x1F64F, // emoticons
        0x1F680...0x1F6FF, // transport and map
        0x1F900...0x1F9FF, // supplemental symbols and pictographs
        0x1FA70...0x1FAFF,
    ]

    // MARK: Byte search

    @inline(__always)
    static func lowerASCII(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
    }

    /// ASCII-case-insensitive substring test over UTF-8. Non-ASCII bytes (≥ 0x80) never
    /// equal a printable-ASCII needle byte, so inert symbols simply never match.
    static func asciiCaseInsensitiveContains(_ text: String, _ needle: [UInt8]) -> Bool {
        guard let first = needle.first else { return false }
        var text = text
        return text.withUTF8 { hay -> Bool in
            let n = needle.count
            guard hay.count >= n else { return false }
            let firstUpper = (first >= 0x61 && first <= 0x7A) ? first & ~0x20 : first
            var i = 0
            let last = hay.count - n
            while i <= last {
                let c = hay[i]
                if c == first || c == firstUpper {
                    var j = 1
                    while j < n, lowerASCII(hay[i + j]) == needle[j] { j += 1 }
                    if j == n { return true }
                }
                i += 1
            }
            return false
        }
    }
}

// MARK: - Indexed records

/// A `SearchQuery.Record` whose title, body and tags are ready for repeated matching.
public struct IndexedSearchRecord: Sendable {
    public let record: SearchQuery.Record
    let title: SearchHaystack
    let body: SearchHaystack
    let tags: [SearchHaystack]

    /// `bodyIsASCIIFoldable` lets callers reuse a per-body cached eligibility.
    public init(_ record: SearchQuery.Record, bodyIsASCIIFoldable: Bool? = nil) {
        self.record = record
        title = SearchHaystack(record.title)
        body = bodyIsASCIIFoldable.map { SearchHaystack(record.body, isASCIIFoldable: $0) }
            ?? SearchHaystack(record.body)
        tags = record.tags.map(SearchHaystack.init)
    }
}

/// A parsed query with its terms prepared once, for matching many records.
public struct PreparedSearchQuery: Sendable {
    public let query: SearchQuery
    let terms: [SearchNeedle]
    let excluded: [SearchNeedle]

    public init(_ query: SearchQuery) {
        self.query = query
        terms = query.terms.map(SearchNeedle.init)
        excluded = query.excluded.map(SearchNeedle.init)
    }

    public var isEmpty: Bool { query.isEmpty }

    /// Same answer as `query.matches(indexed.record, hiddenLocked:)`.
    public func matches(_ indexed: IndexedSearchRecord, hiddenLocked: Bool) -> Bool {
        query.evaluate(indexed.record, hiddenLocked: hiddenLocked, terms: terms, excluded: excluded) { field, needle in
            switch field {
            case .title: return indexed.title.contains(needle)
            case .body: return indexed.body.contains(needle)
            case .tag(let i): return indexed.tags[i].contains(needle)
            }
        }
    }
}
