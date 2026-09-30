import Foundation

// MARK: - Wiki link syntax (pure)
//
// `[[Entry title]]` and `[[Entry title|alias]]`. Parsing, editor completion and the
// `omega-entry://` URL scheme used by the renderer. All ranges are UTF-16 offsets.

public struct MarkdownWikiLink: Equatable, Sendable {
    /// Range of the whole `[[...]]` token.
    public let range: NSRange
    public let title: String
    public let alias: String?
    public var displayText: String { alias ?? title }
}

public struct MarkdownWikiCompletion: Equatable, Sendable {
    /// Range of the partial title (between `[[` and the caret).
    public let range: NSRange
    public let query: String
}

extension MarkdownLogic {
    public static let entryURLScheme = "omega-entry"
    private static let entryURLPrefix = "omega-entry://open/"

    private static let wikiRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]+?)\]\]"#)
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)

    /// Sorted, non-overlapping ranges: is `range` touching any of them? O(log n).
    public static func intersectsAny(_ range: NSRange, sortedRanges: [NSRange]) -> Bool {
        guard !sortedRanges.isEmpty else { return false }
        var lo = 0, hi = sortedRanges.count
        // First range whose end is beyond range.location.
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(sortedRanges[mid]) <= range.location { lo = mid + 1 } else { hi = mid }
        }
        guard lo < sortedRanges.count else { return false }
        let r = sortedRanges[lo]
        let end = NSMaxRange(range)
        if range.length == 0 { return r.location <= range.location && range.location < NSMaxRange(r) }
        return r.location < end
    }

    /// Wiki links in `text` (optionally only those fully inside `within`), skipping fenced code,
    /// inline code spans, escaped `\[[`, empty titles and links spanning lines.
    /// `codeRanges` may be supplied to avoid rescanning fences; `skipInlineCode: false` is for
    /// callers whose text already had code spans removed/marked.
    public static func wikiLinks(in text: String, within: NSRange? = nil, codeRanges: [NSRange]? = nil,
                                 skipInlineCode: Bool = true) -> [MarkdownWikiLink] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var scan = within.map { NSIntersectionRange($0, full) } ?? full
        guard scan.length >= 4, text.contains("[[") else { return [] }
        if within != nil { scan = ns.lineRange(for: scan) }

        let fences = codeRanges ?? codeBlockRanges(in: text)
        var spans: [NSRange] = []
        if skipInlineCode {
            inlineCodeRegex.enumerateMatches(in: text, range: scan) { m, _, _ in
                if let m { spans.append(m.range) }
            }
        }
        var out: [MarkdownWikiLink] = []
        wikiRegex.enumerateMatches(in: text, range: scan) { m, _, _ in
            guard let m else { return }
            let r = m.range
            if let within, NSIntersectionRange(r, within).length != r.length { return }
            if r.location > 0, ns.character(at: r.location - 1) == 92 { return }   // backslash
            if intersectsAny(r, sortedRanges: fences) { return }
            if spans.contains(where: { NSIntersectionRange($0, r).length > 0 }) { return }
            let inner = ns.substring(with: m.range(at: 1))
            var title = inner
            var alias: String?
            if let bar = inner.firstIndex(of: "|") {
                title = String(inner[..<bar])
                let a = String(inner[inner.index(after: bar)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                alias = a.isEmpty ? nil : a
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            out.append(MarkdownWikiLink(range: r, title: title, alias: alias))
        }
        return out
    }

    // MARK: URLs

    public static func wikiLinkURL(title: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        guard let enc = title.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: entryURLPrefix + enc)
    }

    public static func wikiLinkTitle(from url: URL) -> String? {
        let s = url.absoluteString
        guard s.hasPrefix(entryURLPrefix) else { return nil }
        let t = String(s.dropFirst(entryURLPrefix.count)).removingPercentEncoding
        return (t?.isEmpty ?? true) ? nil : t
    }

    // MARK: Completion

    /// When the caret sits inside an unfinished `[[partial` on its line, the range/text of the partial.
    public static func wikiCompletionContext(in text: String, caret: Int) -> MarkdownWikiCompletion? {
        let ns = text as NSString
        guard caret >= 2, caret <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        var i = caret - 1
        while i >= lineStart + 1 {
            let c = ns.character(at: i)
            if c == 93 || c == 124 { return nil }                      // ] or |
            if c == 91 {                                               // [
                guard ns.character(at: i - 1) == 91 else { return nil }
                let start = i + 1
                return MarkdownWikiCompletion(range: NSRange(location: start, length: caret - start),
                                              query: ns.substring(with: NSRange(location: start, length: caret - start)))
            }
            i -= 1
        }
        return nil
    }

    /// Prefix matches first, then substring matches; case-insensitive, deduped, capped.
    public static func wikiTitleSuggestions(query: String, from titles: [String], limit: Int = 8) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        var prefix: [String] = [], contains: [String] = []
        for t in titles {
            let l = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !l.isEmpty, seen.insert(l).inserted else { continue }
            if q.isEmpty || l.hasPrefix(q) { prefix.append(t) } else if l.contains(q) { contains.append(t) }
        }
        return Array((prefix + contains).prefix(limit))
    }
}
