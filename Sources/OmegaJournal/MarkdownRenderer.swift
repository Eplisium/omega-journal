import Foundation
import SwiftUI
import OmegaJournalCore

// MARK: - Markdown Renderer
//
// Markdown → AttributedString for journal entries. Block structure comes from
// `MarkdownLogic.parseBlocks` (pure, unit-tested); inline styling uses Foundation's
// `AttributedString(markdown:)` so cost is linear — no per-character appends.
//
// Supports: headings, bold/italic (`*x*`, `_x_`), strikethrough, inline code, fenced
// code blocks, nested bullet/ordered (`1.` and `1)`) lists, task lists, nested
// blockquotes, simple tables, horizontal rules, links (validated) and bare-URL autolinks.

struct MarkdownRenderStyle {
    var linkColor: Color = .accentColor
    var codeColor: Color = .orange
    var mutedColor: Color = .secondary
    /// When true, ☐/☑ glyphs carry an `omega-task://toggle/<line>` link so the host can toggle them.
    var interactiveTasks = false

    static let `default` = MarkdownRenderStyle()
}

enum MarkdownRenderer {
    static func render(_ markdown: String, style: MarkdownRenderStyle = .default) -> AttributedString {
        var result = AttributedString()
        var first = true
        for item in MarkdownLogic.parseBlocks(markdown) {
            if !first { result.append(AttributedString("\n")) }
            first = false
            result.append(renderBlock(item, style: style))
        }
        return result
    }

    // MARK: Blocks

    private static func renderBlock(_ item: MarkdownBlockItem, style: MarkdownRenderStyle) -> AttributedString {
        switch item.block {
        case .blank:
            return AttributedString("")

        case let .heading(level, text):
            switch level {
            case 1: return inline(text, size: 24, weight: .bold, style: style)
            case 2: return inline(text, size: 20, weight: .bold, style: style)
            case 3: return inline(text, size: 16, weight: .semibold, style: style)
            default: return inline(text, size: 15, weight: .semibold, style: style)
            }

        case let .paragraph(text):
            return inline(text, size: 16, weight: .regular, style: style)

        case let .quote(depth, text):
            var bar = AttributedString(String(repeating: "\u{258E} ", count: depth))
            bar.foregroundColor = style.mutedColor.opacity(0.7)
            var body = inline(text, size: 15, weight: .regular, style: style, italic: true)
            body.foregroundColor = style.mutedColor
            return bar + body

        case let .bullet(level, text):
            let glyphs = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
            var marker = AttributedString(indent(level) + glyphs[level % glyphs.count] + "  ")
            marker.foregroundColor = style.mutedColor
            marker.font = .system(size: 16, design: .serif)
            return marker + inline(text, size: 16, weight: .regular, style: style)

        case let .ordered(level, number, delimiter, text):
            var marker = AttributedString(indent(level) + number + delimiter + " ")
            marker.foregroundColor = style.mutedColor
            marker.font = .system(size: 16, design: .serif)
            return marker + inline(text, size: 16, weight: .regular, style: style)

        case let .task(level, done, text):
            var box = AttributedString(indent(level) + (done ? "\u{2611}" : "\u{2610}"))
            box.font = .system(size: 16, design: .serif)
            box.foregroundColor = done ? style.mutedColor : style.linkColor
            if style.interactiveTasks, let url = MarkdownLogic.taskURL(line: item.line) {
                box.link = url
            }
            var body = inline(text, size: 16, weight: .regular, style: style)
            if done {
                body.strikethroughStyle = .single
                body.foregroundColor = style.mutedColor
            }
            return box + AttributedString("  ") + body

        case let .codeFence(_, lines):
            var out = AttributedString(lines.isEmpty ? " " : lines.map { $0.isEmpty ? " " : $0 }.joined(separator: "\n"))
            out.font = .system(size: 14, design: .monospaced)
            out.foregroundColor = style.codeColor
            out.backgroundColor = style.codeColor.opacity(0.08)
            return out

        case .rule:
            var attr = AttributedString(String(repeating: "\u{2500}", count: 24))
            attr.foregroundColor = style.mutedColor.opacity(0.4)
            return attr

        case let .table(header, alignments, rows):
            return renderTable(header: header, alignments: alignments, rows: rows, style: style)
        }
    }

    private static func indent(_ level: Int) -> String {
        String(repeating: "    ", count: max(0, level)) + "  "
    }

    // MARK: Tables

    private static func plainText(_ s: String) -> String {
        // Strip inline markers so column widths reflect what is displayed.
        String(inline(s, size: 14, weight: .regular, style: .default).characters)
    }

    private static func renderTable(header: [String], alignments: [MarkdownBlockItem.Alignment],
                                    rows: [[String]], style: MarkdownRenderStyle) -> AttributedString {
        let headerText = header.map(plainText)
        let rowText = rows.map { $0.map(plainText) }
        var widths = headerText.map { $0.count }
        for r in rowText { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], c.count) } }

        func pad(_ s: String, _ i: Int) -> String {
            let gap = max(0, widths[i] - s.count)
            switch alignments[i] {
            case .leading: return s + String(repeating: " ", count: gap)
            case .trailing: return String(repeating: " ", count: gap) + s
            case .center:
                let l = gap / 2
                return String(repeating: " ", count: l) + s + String(repeating: " ", count: gap - l)
            }
        }
        func line(_ cells: [String]) -> String {
            "\u{2502} " + cells.enumerated().map { pad($0.element, $0.offset) }.joined(separator: " \u{2502} ") + " \u{2502}"
        }
        let rule = "\u{251C}" + widths.map { String(repeating: "\u{2500}", count: $0 + 2) }.joined(separator: "\u{253C}") + "\u{2524}"

        var out = AttributedString(line(headerText) + "\n" + rule)
        out.font = .system(size: 13, weight: .semibold, design: .monospaced)
        var body = AttributedString(rowText.map { "\n" + line($0) }.joined())
        body.font = .system(size: 13, design: .monospaced)
        out.append(body)
        return out
    }

    // MARK: Inline

    /// Linear-time inline rendering: one markdown parse, then a single pass over runs.
    static func inline(_ text: String, size: CGFloat, weight: Font.Weight, style: MarkdownRenderStyle,
                       italic: Bool = false) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var attr = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)

        // Snapshot runs first; mutating while iterating invalidates indices.
        var edits: [(Range<AttributedString.Index>, InlinePresentationIntent?, URL?)] = []
        for run in attr.runs { edits.append((run.range, run.inlinePresentationIntent, run.link)) }

        for (range, intent, link) in edits {
            let i = intent ?? []
            if i.contains(.code) {
                attr[range].font = .system(size: max(12, size - 2), design: .monospaced)
                attr[range].foregroundColor = style.codeColor
                attr[range].backgroundColor = style.codeColor.opacity(0.1)
            } else {
                var f = Font.system(size: size, weight: i.contains(.stronglyEmphasized) ? .bold : weight, design: .serif)
                if italic || i.contains(.emphasized) { f = f.italic() }
                attr[range].font = f
            }
            if i.contains(.strikethrough) { attr[range].strikethroughStyle = .single }
            if let link {
                if MarkdownLogic.safeLinkURL(link.absoluteString) != nil {
                    attr[range].foregroundColor = style.linkColor
                    attr[range].underlineStyle = .single
                } else {
                    attr[range].link = nil   // invalid/unsafe destination: show plain text
                }
            }
        }
        autolink(&attr, style: style)
        return attr
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Turns bare http(s) URLs into links (skipping text that is already a link or code).
    private static func autolink(_ attr: inout AttributedString, style: MarkdownRenderStyle) {
        let s = String(attr.characters)
        guard s.contains("://") || s.contains("www."), let detector else { return }
        let ns = s as NSString
        for m in detector.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, MarkdownLogic.safeLinkURL(url.absoluteString) != nil,
                  url.scheme?.hasPrefix("http") == true,
                  let sr = Range(m.range, in: s) else { continue }
            let lo = s.distance(from: s.startIndex, to: sr.lowerBound)
            let hi = s.distance(from: s.startIndex, to: sr.upperBound)
            let start = attr.index(attr.startIndex, offsetByCharacters: lo)
            let end = attr.index(attr.startIndex, offsetByCharacters: hi)
            let range = start..<end
            let already = attr[range].runs.contains { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }
            if already { continue }
            attr[range].link = url
            attr[range].foregroundColor = style.linkColor
            attr[range].underlineStyle = .single
        }
    }
}
