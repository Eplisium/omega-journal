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
}
