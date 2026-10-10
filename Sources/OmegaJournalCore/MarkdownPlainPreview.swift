import Foundation

// MARK: - Plain-text preview of Markdown

/// Turns Markdown into short, readable plain text for cards (e.g. template
/// previews) so users see what they'll get — "Gratitude", "• One thing…" —
/// instead of raw syntax like "## Gratitude" or "- [ ] ".
public enum MarkdownPlainPreview {
    public static func lines(_ markdown: String, limit: Int = 6) -> [String] {
        var out: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { if !line.isEmpty { out.append(line) }; if out.count >= limit { break }; continue }
            if line.isEmpty { continue }
            // Bare markers left after trimming ("- ", "- [ ] ") carry no content.
            if ["-", "*", "+", "- [ ]", "* [ ]", "- []", "- [x]", "- [X]"].contains(line) { continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 { continue }

            // Headings
            if line.hasPrefix("#") {
                line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            }
            // Block quotes
            while line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // Task items, then bullets
            if let rest = strip(line, prefixes: ["- [ ] ", "* [ ] ", "- [] "]) {
                line = "☐ " + rest
            } else if let rest = strip(line, prefixes: ["- [x] ", "- [X] ", "* [x] ", "* [X] "]) {
                line = "☑ " + rest
            } else if let rest = strip(line, prefixes: ["- ", "* ", "+ "]) {
                line = "• " + rest
            }
            line = inline(line)
            if line.isEmpty || line == "•" || line == "☐" { continue }
            out.append(line)
            if out.count >= limit { break }
        }
        return out
    }

    public static func text(_ markdown: String, limit: Int = 6) -> String {
        lines(markdown, limit: limit).joined(separator: "\n")
    }

    private static func strip(_ s: String, prefixes: [String]) -> String? {
        for p in prefixes where s.hasPrefix(p) {
            return String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Removes inline emphasis/code markers and collapses links to their text.
    static func inline(_ s: String) -> String {
        var r = s
        // [text](url) -> text ; ![alt](url) -> alt ; [[Wiki]] -> Wiki
        r = r.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        r = r.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "~~", "`"] {
            r = r.replacingOccurrences(of: marker, with: "")
        }
        r = r.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*]+?)\*(?!\w)"#, with: "$1", options: .regularExpression)
        r = r.replacingOccurrences(of: #"(?<!\w)_(?!\s)([^_]+?)_(?!\w)"#, with: "$1", options: .regularExpression)
        return r.trimmingCharacters(in: .whitespaces)
    }
}
