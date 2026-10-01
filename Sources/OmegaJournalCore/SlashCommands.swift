import Foundation

// MARK: - Slash commands & wiki-link completion edits (pure; UTF-16 offsets)

public enum SlashCommandKind: String, CaseIterable, Sendable {
    case heading1, heading2, heading3
    case task, bullet, numbered, quote, code, divider, table
    case date, time, mood, wikiLink, template
}

public struct SlashCommand: Equatable, Sendable, Identifiable {
    public let kind: SlashCommandKind
    public let title: String
    public let subtitle: String
    public let icon: String          // SF Symbol name
    public let keywords: [String]
    public var id: String { kind.rawValue }
}

public struct SlashContext: Equatable, Sendable {
    /// Range covering the `/` and the query typed after it.
    public let range: NSRange
    public let query: String
}

/// Text to insert for a command and where the caret goes (UTF-16 offset inside `text`).
public struct SlashExpansion: Equatable, Sendable {
    public let text: String
    public let caretOffset: Int
    public let selectionLength: Int
    public init(text: String, caretOffset: Int, selectionLength: Int = 0) {
        self.text = text; self.caretOffset = caretOffset; self.selectionLength = selectionLength
    }
}

public enum SlashCommands {
    public static let maxQueryLength = 20

    public static let all: [SlashCommand] = [
        SlashCommand(kind: .heading1, title: "Heading 1", subtitle: "Big section title", icon: "textformat.size.larger", keywords: ["h1", "title", "#"]),
        SlashCommand(kind: .heading2, title: "Heading 2", subtitle: "Medium section title", icon: "textformat.size", keywords: ["h2", "subtitle"]),
        SlashCommand(kind: .heading3, title: "Heading 3", subtitle: "Small section title", icon: "textformat.size.smaller", keywords: ["h3"]),
        SlashCommand(kind: .task, title: "Task", subtitle: "Checkbox item", icon: "checklist", keywords: ["todo", "checkbox", "check"]),
        SlashCommand(kind: .bullet, title: "Bullet list", subtitle: "Simple list", icon: "list.bullet", keywords: ["ul", "list"]),
        SlashCommand(kind: .numbered, title: "Numbered list", subtitle: "Ordered list", icon: "list.number", keywords: ["ol", "list"]),
        SlashCommand(kind: .quote, title: "Quote", subtitle: "Block quote", icon: "text.quote", keywords: ["blockquote", "cite"]),
        SlashCommand(kind: .code, title: "Code block", subtitle: "Fenced code", icon: "curlybraces", keywords: ["fence", "snippet"]),
        SlashCommand(kind: .divider, title: "Divider", subtitle: "Horizontal rule", icon: "minus", keywords: ["hr", "rule", "line"]),
        SlashCommand(kind: .table, title: "Table", subtitle: "2 × 2 table", icon: "tablecells", keywords: ["grid", "columns"]),
        SlashCommand(kind: .date, title: "Today's date", subtitle: "Insert the current date", icon: "calendar", keywords: ["today", "now"]),
        SlashCommand(kind: .time, title: "Current time", subtitle: "Insert the current time", icon: "clock", keywords: ["now", "hour"]),
        SlashCommand(kind: .mood, title: "Mood", subtitle: "Insert this entry's mood", icon: "face.smiling", keywords: ["feeling", "emotion"]),
        SlashCommand(kind: .wikiLink, title: "Link to entry", subtitle: "[[Wiki link]]", icon: "link", keywords: ["wiki", "backlink", "reference"]),
        SlashCommand(kind: .template, title: "Template snippet", subtitle: "Insert a template's body", icon: "doc.text", keywords: ["snippet", "insert"]),
    ]

    /// A `/query` token ending at `caret`. The slash must start a line or follow whitespace
    /// (so URLs, `and/or`, `1/2` never trigger), the query has no whitespace and is short,
    /// and the caret must not be inside a fenced code block.
    public static func context(in text: String, caret: Int, codeRanges: [NSRange]? = nil) -> SlashContext? {
        let ns = text as NSString
        guard caret >= 1, caret <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: caret - 1, length: 0)).location
        var i = caret - 1
        while i >= lineStart {
            let c = ns.character(at: i)
            if c == 47 { // "/"
                if i > lineStart {
                    let prev = ns.character(at: i - 1)
                    guard let scalar = UnicodeScalar(prev), CharacterSet.whitespaces.contains(scalar) else { return nil }
                }
                let len = caret - i
                guard len - 1 <= maxQueryLength else { return nil }
                let range = NSRange(location: i, length: len)
                let fences = codeRanges ?? MarkdownLogic.codeBlockRanges(in: text)
                if MarkdownLogic.intersectsAny(NSRange(location: i, length: 0), sortedRanges: fences) { return nil }
                return SlashContext(range: range, query: ns.substring(with: NSRange(location: i + 1, length: len - 1)))
            }
            if let scalar = UnicodeScalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            i -= 1
        }
        return nil
    }

    /// Commands matching `query`: title prefix, keyword prefix, title substring, then fuzzy.
    public static func filter(_ query: String, in commands: [SlashCommand] = all) -> [SlashCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return commands }
        var ranked: [(tier: Int, score: Int, index: Int, cmd: SlashCommand)] = []
        for (i, cmd) in commands.enumerated() {
            let title = cmd.title.lowercased()
            let words = title.split(separator: " ").map(String.init)
            if title.hasPrefix(q) || words.contains(where: { $0.hasPrefix(q) }) {
                ranked.append((0, 0, i, cmd))
            } else if cmd.keywords.contains(where: { $0.lowercased().hasPrefix(q) }) {
                ranked.append((1, 0, i, cmd))
            } else if title.contains(q) {
                ranked.append((2, 0, i, cmd))
            } else if q.count >= 2, let s = OmegaCore.fuzzyScore(q, title) {
                ranked.append((3, -s, i, cmd))
            }
        }
        return ranked.sorted { ($0.tier, $0.score, $0.index) < ($1.tier, $1.score, $1.index) }.map(\.cmd)
    }

    /// What to insert for `kind`. Nil for `.template` (the UI picks one first).
    /// `blockStart` = the slash was at the start of its line, so block syntax needs no leading newline.
    public static func expansion(for kind: SlashCommandKind, dateText: String, timeText: String,
                                 moodText: String, atLineStart: Bool = true) -> SlashExpansion? {
        func simple(_ s: String) -> SlashExpansion { SlashExpansion(text: s, caretOffset: (s as NSString).length, selectionLength: 0) }
        let lead = atLineStart ? "" : "\n"
        func block(_ s: String) -> SlashExpansion { simple(lead + s) }
        switch kind {
        case .heading1: return block("# ")
        case .heading2: return block("## ")
        case .heading3: return block("### ")
        case .task: return block("- [ ] ")
        case .bullet: return block("- ")
        case .numbered: return block("1. ")
        case .quote: return block("> ")
        case .divider: return block("---\n")
        case .code:
            let t = lead + "```\n\n```"
            return SlashExpansion(text: t, caretOffset: (lead as NSString).length + 4, selectionLength: 0)
        case .table:
            let header = "| Column 1 | Column 2 |\n| --- | --- |\n| | |\n"
            let t = lead + header
            return SlashExpansion(text: t, caretOffset: (lead as NSString).length + 2, selectionLength: 8)
        case .date: return simple(dateText)
        case .time: return simple(timeText)
        case .mood: return simple(moodText)
        case .wikiLink: return SlashExpansion(text: "[[]]", caretOffset: 2, selectionLength: 0)
        case .template: return nil
        }
    }
}

// MARK: - Wiki completion acceptance

public struct CompletionEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    /// Caret position (UTF-16, absolute) after applying the edit.
    public let caret: Int
}

extension MarkdownLogic {
    /// Edit that completes `[[partial` to `[[Title]]`. Auto-pairing usually leaves `]]` after the
    /// caret; that is consumed so the result is never `[[Title]]]]`.
    public static func wikiCompletionEdit(in text: String, context: MarkdownWikiCompletion, title: String) -> CompletionEdit {
        let ns = text as NSString
        let safeTitle = title.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "|", with: "-").replacingOccurrences(of: "\n", with: " ")
        var end = NSMaxRange(context.range)
        // Anything the user typed after the caret up to a closing `]]` on the same line is part of the partial.
        var close = end
        while close < ns.length, ns.character(at: close) != 10, ns.character(at: close) != 93 { close += 1 }
        if close < ns.length, ns.character(at: close) == 93 {
            end = close + 1
            if end < ns.length, ns.character(at: end) == 93 { end += 1 }
        }
        let range = NSRange(location: context.range.location, length: end - context.range.location)
        let replacement = safeTitle + "]]"
        return CompletionEdit(range: range, replacement: replacement,
                              caret: context.range.location + (replacement as NSString).length)
    }

    /// Edit that replaces a slash token with an expansion.
    public static func slashEdit(context: SlashContext, expansion: SlashExpansion) -> CompletionEdit {
        CompletionEdit(range: context.range, replacement: expansion.text,
                       caret: context.range.location + expansion.caretOffset)
    }
}
