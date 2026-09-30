import Foundation

// MARK: - Markdown logic (pure, unit-testable)
//
// Parsing and list-editing rules used by the editor and renderer. No AppKit,
// no SwiftUI. All offsets are UTF-16 (NSString) offsets so they can be handed
// straight to NSTextView.

// MARK: Block model

public struct MarkdownBlockItem: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }

    public enum Block: Equatable, Sendable {
        case blank
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case quote(depth: Int, text: String)
        case bullet(level: Int, text: String)
        case ordered(level: Int, number: String, delimiter: String, text: String)
        case task(level: Int, done: Bool, text: String)
        case codeFence(language: String, lines: [String])
        case rule
        case table(header: [String], alignments: [Alignment], rows: [[String]])
    }

    /// Zero-based index of the first source line of this block.
    public let line: Int
    public let block: Block

    public init(line: Int, block: Block) {
        self.line = line
        self.block = block
    }
}

public struct MarkdownListContext: Equatable, Sendable {
    /// Text to insert after the newline when Return is pressed at end of item.
    public let nextPrefix: String
    /// UTF-16 length of the marker (quote prefix + indent + bullet/number/checkbox).
    public let markerLength: Int
    /// True when the item has no content after its marker.
    public let isEmptyItem: Bool
    /// What an empty item's line becomes when Return is pressed on it (outdent or clear).
    public let exitLine: String
    /// For ordered lists: the number of the current item.
    public let orderedNumber: Int?
}

public enum MarkdownLogic {

    // MARK: Regex helpers

    private static let quotePrefixRegex = try! NSRegularExpression(pattern: #"^(?:[ \t]*>[ \t]?)+"#)
    private static let taskRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]) \[([ xX])\](?: (.*))?$"#)
    private static let bulletRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+(.*)$"#)
    private static let bulletMarkerOnlyRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]*$"#)
    private static let orderedRegex = try! NSRegularExpression(pattern: #"^([ \t]*)(\d{1,9})([.)])(?:[ \t]+(.*))?$"#)
    private static let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$"#)
    private static let tableSeparatorRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)

    private static func groups(_ regex: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    private static func utf16Length(_ s: String) -> Int { (s as NSString).length }

    /// Indent width in columns (tab = 4).
    public static func indentWidth(_ s: String) -> Int {
        var w = 0
        for c in s { if c == "\t" { w += 4 } else if c == " " { w += 1 } else { break } }
        return w
    }

    // MARK: List continuation

    public static func listContext(forLine line: String) -> MarkdownListContext? {
        var quote = ""
        var rest = line
        if let g = groups(quotePrefixRegex, line), let q = g[0] {
            quote = q
            rest = (line as NSString).substring(from: (q as NSString).length)
        }
        let quoteLen = utf16Length(quote)
        let quoteDepth = quote.filter { $0 == ">" }.count
        let quoteExit = quoteDepth > 1 ? String(repeating: "> ", count: quoteDepth - 1) : ""

        // Task list: `- [ ] text`
        if let g = groups(taskRegex, rest), let indent = g[1], let bullet = g[2] {
            let text = g[4] ?? ""
            let marker = "\(indent)\(bullet) [ ] "
            let markerLen = quoteLen + utf16Length(indent) + utf16Length("\(bullet) [\(g[3] ?? " ")] ")
            return MarkdownListContext(
                nextPrefix: quote + marker,
                markerLength: markerLen,
                isEmptyItem: text.trimmingCharacters(in: .whitespaces).isEmpty,
                exitLine: exitLine(quote: quote, quoteExit: quoteExit, indent: indent, marker: "\(bullet) [ ] "),
                orderedNumber: nil)
        }
        // Bullet: keeps the user's marker (-, * or +).
        if let g = groups(bulletRegex, rest), let indent = g[1], let bullet = g[2] {
            let text = g[3] ?? ""
            let markerLen = quoteLen + utf16Length(rest) - utf16Length(text)
            return MarkdownListContext(
                nextPrefix: quote + indent + bullet + " ",
                markerLength: markerLen,
                isEmptyItem: text.trimmingCharacters(in: .whitespaces).isEmpty,
                exitLine: exitLine(quote: quote, quoteExit: quoteExit, indent: indent, marker: bullet + " "),
                orderedNumber: nil)
        }
        if let g = groups(bulletMarkerOnlyRegex, rest), let indent = g[1], let bullet = g[2] {
            // "- " typed then trailing space trimmed away by the user.
            return MarkdownListContext(
                nextPrefix: quote + indent + bullet + " ",
                markerLength: quoteLen + utf16Length(rest),
                isEmptyItem: true,
                exitLine: exitLine(quote: quote, quoteExit: quoteExit, indent: indent, marker: bullet + " "),
                orderedNumber: nil)
        }
        // Ordered: `1.` or `1)`.
        if let g = groups(orderedRegex, rest), let indent = g[1], let digits = g[2], let delim = g[3] {
            let text = g[4] ?? ""
            let n = Int(digits) ?? 1
            let markerLen = quoteLen + utf16Length(rest) - utf16Length(text)
            return MarkdownListContext(
                nextPrefix: quote + indent + "\(n + 1)\(delim) ",
                markerLength: markerLen,
                isEmptyItem: text.trimmingCharacters(in: .whitespaces).isEmpty,
                exitLine: exitLine(quote: quote, quoteExit: quoteExit, indent: indent, marker: "\(digits)\(delim) "),
                orderedNumber: n)
        }
        // Bare (possibly nested) blockquote.
        if !quote.isEmpty {
            let normalized = quote.hasSuffix(" ") ? quote : quote + " "
            return MarkdownListContext(
                nextPrefix: normalized,
                markerLength: quoteLen,
                isEmptyItem: rest.trimmingCharacters(in: .whitespaces).isEmpty,
                exitLine: quoteExit,
                orderedNumber: nil)
        }
        return nil
    }

    private static func exitLine(quote: String, quoteExit: String, indent: String, marker: String) -> String {
        if !indent.isEmpty {
            return quote + outdent(indent) + marker
        }
        return quote.isEmpty ? "" : quoteExit
    }

    // MARK: Indent / outdent

    /// Adds one indent level (two spaces). Empty lines are left alone.
    public static func indentLine(_ line: String) -> String {
        line.isEmpty ? line : "  " + line
    }

    /// Removes one indent level: a tab, or up to two spaces.
    public static func outdent(_ s: String) -> String {
        if s.hasPrefix("\t") { return String(s.dropFirst()) }
        if s.hasPrefix("  ") { return String(s.dropFirst(2)) }
        if s.hasPrefix(" ") { return String(s.dropFirst()) }
        return s
    }

    /// Indents/outdents every line of a block (which may end with a newline).
    public static func shiftBlock(_ block: String, outdenting: Bool) -> String {
        let hadTrailing = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hadTrailing { lines.removeLast() }
        lines = lines.map { outdenting ? outdent($0) : indentLine($0) }
        return lines.joined(separator: "\n") + (hadTrailing ? "\n" : "")
    }

    public static func isListLine(_ line: String) -> Bool {
        guard let ctx = listContext(forLine: line) else { return false }
        // Pure blockquote lines aren't list items.
        return ctx.orderedNumber != nil || groups(bulletRegex, stripQuote(line)) != nil
            || groups(bulletMarkerOnlyRegex, stripQuote(line)) != nil
            || groups(taskRegex, stripQuote(line)) != nil
    }

    private static func stripQuote(_ line: String) -> String {
        if let g = groups(quotePrefixRegex, line), let q = g[0] {
            return (line as NSString).substring(from: (q as NSString).length)
        }
        return line
    }

    // MARK: Ordered renumbering

    /// After inserting/removing an ordered item at `lineIndex`, computes the edit
    /// that renumbers the following sibling items. Returns nil when nothing changes.
    public static func renumberEdit(in text: String, fromLine lineIndex: Int) -> (range: NSRange, replacement: String)? {
        let lines = text.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count,
              let g = groups(orderedRegex, lines[lineIndex]),
              let indent = g[1], let digits = g[2], let delim = g[3],
              var expected = Int(digits) else { return nil }
        expected += 1
        let baseWidth = indentWidth(indent)

        var newLines = lines
        var first: Int?
        var last = lineIndex
        var j = lineIndex + 1
        while j < lines.count {
            let l = lines[j]
            if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            let w = indentWidth(l)
            if w > baseWidth { j += 1; continue }           // nested content
            guard w == baseWidth, let og = groups(orderedRegex, l),
                  let ind = og[1], let d = og[3], d == delim else { break }
            let body = og[4]
            let rebuilt = "\(ind)\(expected)\(d)" + (body.map { " " + $0 } ?? "")
            if rebuilt != l {
                newLines[j] = rebuilt
                if first == nil { first = j }
                last = j
            }
            expected += 1
            j += 1
        }
        guard let f = first else { return nil }
        var offset = 0
        for i in 0..<f { offset += utf16Length(lines[i]) + 1 }
        let span = lines[f...last]
        let oldLen = span.reduce(0) { $0 + utf16Length($1) } + (last - f)
        let replacement = newLines[f...last].joined(separator: "\n")
        return (NSRange(location: offset, length: oldLen), replacement)
    }

    /// Zero-based line index containing a UTF-16 offset.
    public static func lineIndex(ofUTF16Offset offset: Int, in text: String) -> Int {
        var n = 0
        var i = 0
        for u in text.utf16 {
            if i >= offset { break }
            if u == 10 { n += 1 }
            i += 1
        }
        return n
    }

    // MARK: Task toggling

    /// Toggles `- [ ]` ↔ `- [x]` on a line. Returns nil when the line is not a task.
    public static func toggledTask(_ line: String) -> String? {
        guard let g = groups(taskRegex, line), let indent = g[1], let bullet = g[2], let mark = g[3] else { return nil }
        let done = mark == "x" || mark == "X"
        let text = g[4].map { " " + $0 } ?? ""
        return "\(indent)\(bullet) [\(done ? " " : "x")]\(text)"
    }

    /// Cycles a line for the editor's checkbox command:
    /// task → toggled, bullet → task, plain text → task.
    public static func cycledTaskLine(_ line: String) -> String {
        if let t = toggledTask(line) { return t }
        if let g = groups(bulletRegex, line), let indent = g[1], let bullet = g[2] {
            return "\(indent)\(bullet) [ ] \(g[3] ?? "")"
        }
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        return "\(indent)- [ ] " + String(line.dropFirst(indent.count))
    }

    /// Toggles the task on `lineIndex` of `body`; nil if that line isn't a task
    /// (or is inside a fenced code block).
    public static func togglingTask(inBody body: String, lineIndex: Int) -> String? {
        var lines = body.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count else { return nil }
        let blocks = parseBlocks(body)
        guard blocks.contains(where: { $0.line == lineIndex && { if case .task = $0.block { return true }; return false }($0) }),
              let toggled = toggledTask(lines[lineIndex]) else { return nil }
        lines[lineIndex] = toggled
        return lines.joined(separator: "\n")
    }

    public static let taskURLScheme = "omega-task"

    public static func taskURL(line: Int) -> URL? { URL(string: "\(taskURLScheme)://toggle/\(line)") }

    public static func taskLine(from url: URL) -> Int? {
        guard url.scheme == taskURLScheme, let n = Int(url.lastPathComponent) else { return nil }
        return n
    }

    // MARK: Counting

    /// Fast whitespace-delimited word count over UTF-16 units.
    public static func wordCount(_ s: String) -> Int {
        var count = 0
        var inWord = false
        for u in s.utf16 {
            let ws = u == 32 || (u >= 9 && u <= 13) || u == 0x85 || u == 0xA0
                || u == 0x1680 || (u >= 0x2000 && u <= 0x200A) || u == 0x2028 || u == 0x2029
                || u == 0x202F || u == 0x205F || u == 0x3000
            if ws { inWord = false } else if !inWord { inWord = true; count += 1 }
        }
        return count
    }

    // MARK: Code fences

    private static func fenceMarker(_ line: String) -> (char: Character, count: Int, info: String)? {
        let t = line.drop { $0 == " " }
        guard line.count - t.count <= 3, let c = t.first, c == "`" || c == "~" else { return nil }
        let run = t.prefix { $0 == c }
        guard run.count >= 3 else { return nil }
        let info = String(t.dropFirst(run.count)).trimmingCharacters(in: .whitespaces)
        if c == "`" && info.contains("`") { return nil }
        return (c, run.count, info)
    }

    /// UTF-16 ranges (whole lines, including the fences) of fenced code blocks.
    /// An unterminated fence runs to the end of the text.
    public static func codeBlockRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var offset = 0
        var open: (char: Character, count: Int, start: Int)?
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let len = utf16Length(line)
            let hasNewline = i < lines.count - 1
            let lineEnd = offset + len + (hasNewline ? 1 : 0)
            if let o = open {
                if let f = fenceMarker(line), f.char == o.char, f.count >= o.count, f.info.isEmpty {
                    ranges.append(NSRange(location: o.start, length: lineEnd - o.start))
                    open = nil
                }
            } else if let f = fenceMarker(line) {
                open = (f.char, f.count, offset)
            }
            offset = lineEnd
        }
        if let o = open { ranges.append(NSRange(location: o.start, length: offset - o.start)) }
        return ranges
    }

    // MARK: Block parser

    public static func parseBlocks(_ markdown: String) -> [MarkdownBlockItem] {
        let lines = markdown.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var out: [MarkdownBlockItem] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { out.append(.init(line: i, block: .blank)); i += 1; continue }

            if let f = fenceMarker(line) {
                var body: [String] = []
                var j = i + 1
                while j < lines.count {
                    if let c = fenceMarker(lines[j]), c.char == f.char, c.count >= f.count, c.info.isEmpty { break }
                    body.append(lines[j]); j += 1
                }
                out.append(.init(line: i, block: .codeFence(language: f.info, lines: body)))
                i = j + 1
                continue
            }

            // Table: header row with a pipe followed by a separator row.
            if line.contains("|"), i + 1 < lines.count,
               lines[i + 1].contains("-"),
               groups(tableSeparatorRegex, lines[i + 1]) != nil {
                let header = splitTableRow(line)
                let seps = splitTableRow(lines[i + 1])
                if !header.isEmpty, seps.count == header.count {
                    let aligns: [MarkdownBlockItem.Alignment] = seps.map {
                        let l = $0.hasPrefix(":"), r = $0.hasSuffix(":")
                        return l && r ? .center : (r ? .trailing : .leading)
                    }
                    var rows: [[String]] = []
                    var j = i + 2
                    while j < lines.count, lines[j].contains("|"),
                          !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                        var cells = splitTableRow(lines[j])
                        if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                        rows.append(Array(cells.prefix(header.count)))
                        j += 1
                    }
                    out.append(.init(line: i, block: .table(header: header, alignments: aligns, rows: rows)))
                    i = j
                    continue
                }
            }

            // Horizontal rule (checked before lists so `* * *` / `- - -` are rules).
            let compact = trimmed.filter { $0 != " " }
            if compact.count >= 3, let c = compact.first, "-*_".contains(c), compact.allSatisfy({ $0 == c }) {
                out.append(.init(line: i, block: .rule)); i += 1; continue
            }

            if let g = groups(headingRegex, line), let hashes = g[1] {
                out.append(.init(line: i, block: .heading(level: hashes.count, text: g[2] ?? ""))); i += 1; continue
            }

            if let g = groups(quotePrefixRegex, line), let q = g[0] {
                let depth = q.filter { $0 == ">" }.count
                let text = (line as NSString).substring(from: (q as NSString).length)
                out.append(.init(line: i, block: .quote(depth: depth, text: text))); i += 1; continue
            }

            if let g = groups(taskRegex, line), let indent = g[1] {
                out.append(.init(line: i, block: .task(level: indentWidth(indent) / 2,
                                                       done: g[3] != " ", text: g[4] ?? "")))
                i += 1; continue
            }
            if let g = groups(bulletRegex, line), let indent = g[1] {
                out.append(.init(line: i, block: .bullet(level: indentWidth(indent) / 2, text: g[3] ?? ""))); i += 1; continue
            }
            if let g = groups(orderedRegex, line), let indent = g[1], let n = g[2], let d = g[3] {
                out.append(.init(line: i, block: .ordered(level: indentWidth(indent) / 2, number: n, delimiter: d, text: g[4] ?? "")))
                i += 1; continue
            }

            out.append(.init(line: i, block: .paragraph(text: line))); i += 1
        }
        return out
    }

    public static func splitTableRow(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var cur = ""
        var escaped = false
        for ch in t {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Links

    /// Returns a URL only for web/mail links that look valid; nil otherwise.
    public static func safeLinkURL(_ string: String) -> URL? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        case "mailto":
            return url.path.contains("@") || !(url.absoluteString.dropFirst(7)).isEmpty ? url : nil
        default:
            return nil
        }
    }

    // MARK: Tag suggestions

    public static func tagSuggestions(prefix: String, from tags: [String], excluding: [String], limit: Int = 5) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "").lowercased()
        guard !p.isEmpty else { return [] }
        let taken = Set(excluding.map { $0.lowercased() })
        var seen = Set<String>()
        var result: [String] = []
        for t in tags {
            let l = t.lowercased()
            guard l.hasPrefix(p), !taken.contains(l), seen.insert(l).inserted else { continue }
            result.append(t)
            if result.count == limit { break }
        }
        return result
    }

    // MARK: Contrast

    /// True when dark text reads better on the given sRGB background (0…1 components).
    public static func prefersDarkText(onRed r: Double, green g: Double, blue b: Double) -> Bool {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let lum = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        // Contrast vs white = 1.05/(lum+0.05); vs black = (lum+0.05)/0.05
        return (lum + 0.05) / 0.05 > 1.05 / (lum + 0.05)
    }
}

// MARK: - Typing helpers (auto-pairing, URL paste)

public struct MarkdownTypingEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange
}

extension MarkdownLogic {
    private static let pairs: [Character: Character] = [
        "`": "`", "*": "*", "_": "_", "~": "~", "(": ")", "[": "]", "\"": "\"",
    ]
    private static let closers: Set<Character> = [")", "]", "`", "\""]

    /// Pasting an http(s)/mailto URL over a single-line selection makes `[selection](url)`.
    public static func pasteLink(selected: String, pasted: String) -> String? {
        let url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, !selected.contains("\n"), !url.contains(where: { $0.isWhitespace }),
              safeLinkURL(url) != nil, safeLinkURL(selected) == nil else { return nil }
        return "[\(selected)](\(url))"
    }

    /// Edit to perform when `typed` is entered at `selection`, or nil to let it type normally.
    /// - Selection + opener wraps the selection and keeps it selected.
    /// - Empty selection: `` ` ``, `(`, `[` insert a pair when the next character is blank/closer
    ///   (never after a backtick, so ``` fences still work); typing a closer skips over it.
    public static func autoPairEdit(typed: Character, in text: String, selection: NSRange) -> MarkdownTypingEdit? {
        let ns = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return nil }

        if selection.length > 0 {
            guard let close = pairs[typed] else { return nil }
            let inner = ns.substring(with: selection)
            if inner.contains("\n") && typed != "`" && typed != "*" && typed != "_" && typed != "~" { return nil }
            return MarkdownTypingEdit(range: selection, replacement: "\(typed)\(inner)\(close)",
                                      selection: NSRange(location: selection.location + 1, length: selection.length))
        }

        let loc = selection.location
        let next: Character? = loc < ns.length ? Character(UnicodeScalar(ns.character(at: loc)) ?? " ") : nil
        let prev: Character? = loc > 0 ? Character(UnicodeScalar(ns.character(at: loc - 1)) ?? " ") : nil

        if closers.contains(typed), next == typed {
            return MarkdownTypingEdit(range: NSRange(location: loc, length: 0), replacement: "",
                                      selection: NSRange(location: loc + 1, length: 0))
        }
        guard typed == "`" || typed == "(" || typed == "[", let close = pairs[typed] else { return nil }
        if typed == "`" && prev == "`" { return nil }
        if let n = next, !(n.isWhitespace || closers.contains(n)) { return nil }
        return MarkdownTypingEdit(range: NSRange(location: loc, length: 0), replacement: "\(typed)\(close)",
                                  selection: NSRange(location: loc + 1, length: 0))
    }
}
