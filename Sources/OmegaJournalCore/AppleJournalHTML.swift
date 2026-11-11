import Foundation

// MARK: - Lenient HTML reading for Apple Journal exports (pure)
//
// Apple Journal writes each entry as a Cocoa-generated HTML page (the same
// writer NSAttributedString uses): `<p class="p2"><span class="s2">…</span></p>`
// paragraphs whose bold/italic often live in a `<style>` block as class rules
// rather than in `<b>`/`<i>` tags. This file is a small, forgiving parser — no
// WebKit, no AppKit, safe off the main thread — plus a converter from the
// parsed tree to the Markdown subset Omega Journal renders.

public struct AppleJournalHTMLNode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case element, text }
    public var kind: Kind
    /// Lower-cased tag name for elements; empty for text.
    public var name: String
    public var attributes: [String: String]
    public var children: [AppleJournalHTMLNode]
    /// Decoded text for text nodes.
    public var text: String

    public static func element(_ name: String, _ attributes: [String: String] = [:],
                               _ children: [AppleJournalHTMLNode] = []) -> AppleJournalHTMLNode {
        AppleJournalHTMLNode(kind: .element, name: name, attributes: attributes, children: children, text: "")
    }

    public static func textNode(_ s: String) -> AppleJournalHTMLNode {
        AppleJournalHTMLNode(kind: .text, name: "", attributes: [:], children: [], text: s)
    }

    public var classes: [String] {
        (attributes["class"] ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    public func hasClass(_ c: String) -> Bool { classes.contains(c) }

    /// Concatenated descendant text (no whitespace normalisation).
    public var textContent: String {
        kind == .text ? text : children.map(\.textContent).joined()
    }

    /// Depth-first, document order.
    public func descendants(where match: (AppleJournalHTMLNode) -> Bool) -> [AppleJournalHTMLNode] {
        var out: [AppleJournalHTMLNode] = []
        func walk(_ n: AppleJournalHTMLNode) {
            for c in n.children {
                if c.kind == .element && match(c) { out.append(c) }
                walk(c)
            }
        }
        walk(self)
        return out
    }

    public func first(where match: (AppleJournalHTMLNode) -> Bool) -> AppleJournalHTMLNode? {
        if kind == .element && match(self) { return self }
        for c in children { if let f = c.first(where: match) { return f } }
        return nil
    }
}

public enum AppleJournalHTML {
    static let voidElements: Set<String> = ["br", "img", "hr", "meta", "link", "input", "source", "col", "wbr", "area", "base", "embed", "track", "param"]
    static let rawTextElements: Set<String> = ["script", "style", "title", "textarea"]
    /// Opening one of these closes an open `<p>` (HTML's implied end tag).
    static let closesParagraph: Set<String> = ["p", "div", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6",
                                               "blockquote", "pre", "table", "hr", "section", "article"]

    // MARK: Parsing

    /// Parses HTML into a synthetic `#document` root. Never throws: unknown or
    /// broken markup degrades to text, unmatched end tags are ignored.
    public static func parse(_ html: String) -> AppleJournalHTMLNode {
        struct Frame { var name: String; var attributes: [String: String]; var children: [AppleJournalHTMLNode] }
        var stack: [Frame] = [Frame(name: "#document", attributes: [:], children: [])]
        let s = Array(html.unicodeScalars)
        var i = 0
        var textBuf = String.UnicodeScalarView()

        func flushText() {
            guard !textBuf.isEmpty else { return }
            stack[stack.count - 1].children.append(.textNode(decodeEntities(String(textBuf))))
            textBuf = String.UnicodeScalarView()
        }
        func closeTop() {
            let f = stack.removeLast()
            stack[stack.count - 1].children.append(.element(f.name, f.attributes, f.children))
        }
        func close(_ name: String) {
            guard let idx = stack.lastIndex(where: { $0.name == name }), idx > 0 else { return }
            while stack.count > idx { closeTop() }
        }
        func startsWith(_ lit: String, at pos: Int) -> Bool {
            let l = Array(lit.unicodeScalars)
            guard pos + l.count <= s.count else { return false }
            for k in 0..<l.count {
                let a = s[pos + k], b = l[k]
                if a != b && String(a).lowercased() != String(b) { return false }
            }
            return true
        }

        while i < s.count {
            let c = s[i]
            guard c == "<" else { textBuf.append(c); i += 1; continue }
            // Comment
            if startsWith("<!--", at: i) {
                flushText()
                var j = i + 4
                while j < s.count && !startsWith("-->", at: j) { j += 1 }
                i = min(s.count, j + 3)
                continue
            }
            // Doctype / CDATA / processing instruction
            if i + 1 < s.count && (s[i + 1] == "!" || s[i + 1] == "?") {
                flushText()
                var j = i + 1
                while j < s.count && s[j] != ">" { j += 1 }
                i = min(s.count, j + 1)
                continue
            }
            let isEnd = i + 1 < s.count && s[i + 1] == "/"
            var j = i + (isEnd ? 2 : 1)
            // Tag name must start with a letter; otherwise it's literal text ("a < b").
            guard j < s.count, s[j].properties.isAlphabetic else { textBuf.append(c); i += 1; continue }
            flushText()
            var name = ""
            while j < s.count, s[j].properties.isAlphabetic || ("0"..."9").contains(s[j]) || s[j] == "-" || s[j] == ":" {
                name.unicodeScalars.append(s[j]); j += 1
            }
            name = name.lowercased()
            // Attributes
            var attrs: [String: String] = [:]
            var selfClosing = false
            while j < s.count && s[j] != ">" {
                let ch = s[j]
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" { j += 1; continue }
                if ch == "/" { selfClosing = true; j += 1; continue }
                var key = ""
                while j < s.count, !" \t\n\r=>/".unicodeScalars.contains(s[j]) { key.unicodeScalars.append(s[j]); j += 1 }
                while j < s.count, " \t\n\r".unicodeScalars.contains(s[j]) { j += 1 }
                var value = ""
                if j < s.count && s[j] == "=" {
                    j += 1
                    while j < s.count, " \t\n\r".unicodeScalars.contains(s[j]) { j += 1 }
                    if j < s.count, s[j] == "\"" || s[j] == "'" {
                        let q = s[j]; j += 1
                        while j < s.count && s[j] != q { value.unicodeScalars.append(s[j]); j += 1 }
                        j += 1
                    } else {
                        while j < s.count, !" \t\n\r>".unicodeScalars.contains(s[j]) { value.unicodeScalars.append(s[j]); j += 1 }
                    }
                }
                if !key.isEmpty { attrs[key.lowercased()] = decodeEntities(value) }
                if key.isEmpty { j += 1 }
            }
            i = min(s.count, j + 1)
            if isEnd {
                if name == "p" || name == "li" || stack.contains(where: { $0.name == name }) { close(name) }
                continue
            }
            if closesParagraph.contains(name), stack.last?.name == "p" { closeTop() }
            if name == "li", let idx = stack.lastIndex(where: { $0.name == "li" }),
               !stack[idx...].contains(where: { $0.name == "ul" || $0.name == "ol" }) {
                while stack.count > idx { closeTop() }
            }
            if voidElements.contains(name) || selfClosing {
                stack[stack.count - 1].children.append(.element(name, attrs))
                continue
            }
            if rawTextElements.contains(name) {
                var k = i
                while k < s.count && !startsWith("</\(name)", at: k) { k += 1 }
                let raw = String(String.UnicodeScalarView(s[i..<k]))
                stack[stack.count - 1].children.append(.element(name, attrs, raw.isEmpty ? [] : [.textNode(raw)]))
                var e = k
                while e < s.count && s[e] != ">" { e += 1 }
                i = min(s.count, e + 1)
                continue
            }
            stack.append(Frame(name: name, attributes: attrs, children: []))
        }
        flushText()
        while stack.count > 1 { closeTop() }
        return .element("#document", [:], stack[0].children)
    }

    // MARK: Entities

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "middot": "·", "bull": "•", "times": "×",
        "euro": "€", "pound": "£", "yen": "¥", "laquo": "«", "raquo": "»", "shy": "",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            guard ch == "&", let semi = s[idx...].prefix(12).firstIndex(of: ";") else {
                out.append(ch); idx = s.index(after: idx); continue
            }
            let body = String(s[s.index(after: idx)..<semi])
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedEntities[body]
            }
            if let r = replacement {
                out += r
                idx = s.index(after: semi)
            } else {
                out.append(ch); idx = s.index(after: idx)
            }
        }
        return out
    }

    // MARK: CSS (class → inline traits)

    public struct InlineStyle: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let bold = InlineStyle(rawValue: 1)
        public static let italic = InlineStyle(rawValue: 2)
        public static let strike = InlineStyle(rawValue: 4)
    }

    /// Traits from one CSS declaration block (`font-weight: bold; …`).
    public static func traits(fromDeclarations decl: String) -> InlineStyle {
        var t: InlineStyle = []
        for part in decl.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard kv.count == 2 else { continue }
            let (k, v) = (kv[0], kv[1])
            switch k {
            case "font-weight":
                if v.contains("bold") || ["600", "700", "800", "900"].contains(where: { v.hasPrefix($0) }) { t.insert(.bold) }
            case "font-style":
                if v.contains("italic") || v.contains("oblique") { t.insert(.italic) }
            case "text-decoration", "text-decoration-line":
                if v.contains("line-through") { t.insert(.strike) }
            case "font", "font-family":
                // Cocoa writes PostScript names: 'Helvetica-Bold', '.SFUI-SemiboldItalic'.
                if v.contains("bold") || v.contains("semibold") || v.contains("heavy") || v.contains("black") { t.insert(.bold) }
                if v.contains("italic") || v.contains("oblique") { t.insert(.italic) }
            default: break
            }
        }
        return t
    }

    /// `span.s1 { … }` / `.s1 { … }` / `p.p2 span.s3 { … }` → class name → traits
    /// (the last simple selector's class wins; combined rules accumulate).
    public static func classTraits(fromCSS css: String) -> [String: InlineStyle] {
        var out: [String: InlineStyle] = [:]
        var rest = Substring(css.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression))
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let selectors = rest[..<open]
            let decl = String(rest[rest.index(after: open)..<close])
            let t = traits(fromDeclarations: decl)
            if !t.isEmpty {
                for sel in selectors.split(separator: ",") {
                    let last = sel.split(whereSeparator: { $0 == " " || $0 == ">" }).last.map(String.init) ?? ""
                    guard let dot = last.firstIndex(of: ".") else { continue }
                    let cls = String(last[last.index(after: dot)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cls.isEmpty { out[cls, default: []].formUnion(t) }
                }
            }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    // MARK: Markdown

    /// Converts a parsed subtree to Markdown: paragraphs, headings, emphasis,
    /// strikethrough, links (http/https/mailto only), lists (with Cocoa's
    /// literal `•`/`1.` markers stripped), block quotes and line breaks.
    public static func markdown(from root: AppleJournalHTMLNode, classStyles: [String: InlineStyle] = [:]) -> String {
        var r = MarkdownWriter(classStyles: classStyles)
        r.block(root, listDepth: 0)
        r.flushParagraph()
        return r.finish()
    }

    struct MarkdownWriter {
        let classStyles: [String: InlineStyle]
        var blocks: [String] = []
        var inline = ""
        var pendingBreak = false

        init(classStyles: [String: InlineStyle]) { self.classStyles = classStyles }

        static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
                                             "blockquote", "pre", "hr", "table", "tr", "section", "article", "body",
                                             "html", "#document", "main", "header", "footer"]
        static let skipTags: Set<String> = ["head", "style", "script", "title", "meta", "link", "img", "video",
                                            "audio", "source", "picture", "svg", "iframe", "object", "embed", "noscript"]

        mutating func flushParagraph() {
            let text = Self.tidy(inline)
            if !text.isEmpty { blocks.append(text) }
            inline = ""
            pendingBreak = false
        }

        /// Whitespace-collapses one paragraph and trims spaces around hard breaks.
        static func tidy(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{00A0}", with: " ")
                .components(separatedBy: "\n")
                .map { $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func block(_ node: AppleJournalHTMLNode, listDepth: Int) {
            for child in node.children { visit(child, listDepth: listDepth) }
        }

        mutating func visit(_ node: AppleJournalHTMLNode, listDepth: Int) {
            if node.kind == .text {
                inline += node.text.replacingOccurrences(of: "[\\t\\r\\n ]+", with: " ", options: .regularExpression)
                return
            }
            let name = node.name
            if Self.skipTags.contains(name) { return }
            switch name {
            case "br":
                inline += "\n"
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flushParagraph()
                let level = Int(name.dropFirst()) ?? 2
                let text = Self.tidy(inlineMarkdown(node)).replacingOccurrences(of: "\n", with: " ")
                if !text.isEmpty { blocks.append(String(repeating: "#", count: level) + " " + text) }
            case "ul", "ol":
                flushParagraph()
                var n = 0
                var lines: [String] = []
                for li in node.children where li.kind == .element {
                    if li.name == "li" {
                        n += 1
                        lines += listItem(li, ordered: name == "ol", number: n, depth: listDepth)
                    } else if li.name == "ul" || li.name == "ol" {
                        var nested = MarkdownWriter(classStyles: classStyles)
                        nested.visit(li, listDepth: listDepth + 1)
                        nested.flushParagraph()
                        lines += nested.blocks
                    }
                }
                if !lines.isEmpty { blocks.append(lines.joined(separator: "\n")) }
            case "blockquote":
                flushParagraph()
                var inner = MarkdownWriter(classStyles: classStyles)
                inner.block(node, listDepth: listDepth)
                inner.flushParagraph()
                let quoted = inner.blocks.joined(separator: "\n\n").components(separatedBy: "\n")
                    .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
                if !inner.blocks.isEmpty { blocks.append(quoted) }
            case "pre":
                flushParagraph()
                let code = node.textContent.trimmingCharacters(in: .newlines)
                if !code.isEmpty { blocks.append("```\n" + code + "\n```") }
            case "hr":
                flushParagraph()
                blocks.append("---")
            case _ where Self.blockTags.contains(name):
                flushParagraph()
                block(node, listDepth: listDepth)
                flushParagraph()
            default:
                inline += inlineMarkdown(node)
            }
        }

        func listItem(_ li: AppleJournalHTMLNode, ordered: Bool, number: Int, depth: Int) -> [String] {
            var own = AppleJournalHTMLNode.element("li", li.attributes, [])
            var nestedLists: [AppleJournalHTMLNode] = []
            for c in li.children {
                if c.kind == .element && (c.name == "ul" || c.name == "ol") { nestedLists.append(c) } else { own.children.append(c) }
            }
            var w = MarkdownWriter(classStyles: classStyles)
            w.block(own, listDepth: depth)
            w.flushParagraph()
            var text = w.blocks.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
            text = Self.stripListMarker(text)
            let indent = String(repeating: "  ", count: depth)
            var lines = [indent + (ordered ? "\(number). " : "- ") + text]
            for nl in nestedLists {
                var nested = MarkdownWriter(classStyles: classStyles)
                nested.visit(nl, listDepth: depth + 1)
                nested.flushParagraph()
                lines += nested.blocks
            }
            return lines
        }

        /// Cocoa writes the visible marker into the item: `\t•\tMilk`, `\t1.\tMilk`.
        static func stripListMarker(_ s: String) -> String {
            s.replacingOccurrences(of: #"^\s*(?:[•◦▪▫‣⁃●○■□–\-\*]|\(?[0-9]{1,3}[.)]|[a-zA-Z][.)])\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }

        func styleOf(_ node: AppleJournalHTMLNode) -> AppleJournalHTML.InlineStyle {
            var t: AppleJournalHTML.InlineStyle = []
            switch node.name {
            case "b", "strong": t.insert(.bold)
            case "i", "em", "cite": t.insert(.italic)
            case "s", "strike", "del": t.insert(.strike)
            default: break
            }
            for c in node.classes { if let ct = classStyles[c] { t.formUnion(ct) } }
            if let style = node.attributes["style"] { t.formUnion(AppleJournalHTML.traits(fromDeclarations: style)) }
            return t
        }

        func inlineMarkdown(_ node: AppleJournalHTMLNode, inherited: AppleJournalHTML.InlineStyle = []) -> String {
            if node.kind == .text {
                return node.text.replacingOccurrences(of: "[\\t\\r\\n ]+", with: " ", options: .regularExpression)
            }
            if Self.skipTags.contains(node.name) { return "" }
            if node.name == "br" { return "\n" }
            if node.name == "code" {
                let code = node.textContent.replacingOccurrences(of: "`", with: "'")
                return code.isEmpty ? "" : "`\(code)`"
            }
            let own = styleOf(node)
            let added = own.subtracting(inherited)
            let all = inherited.union(own)
            var inner = node.children.map { inlineMarkdown($0, inherited: all) }.joined()
            if node.name == "a", let href = node.attributes["href"]?.trimmingCharacters(in: .whitespaces),
               AppleJournalHTML.isSafeLink(href) {
                let label = inner.trimmingCharacters(in: .whitespaces)
                inner = "[\(label.isEmpty ? href : label)](\(href.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: ")", with: "%29")))"
            }
            return Self.wrap(inner, added)
        }

        /// Wraps with markers, keeping surrounding spaces outside them
        /// (`** bold **` would not render as bold).
        static func wrap(_ s: String, _ style: AppleJournalHTML.InlineStyle) -> String {
            guard !style.isEmpty else { return s }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains("\n") else { return s }
            let lead = s.prefix(while: { $0 == " " })
            let trail = String(s.reversed().prefix(while: { $0 == " " }))
            var open = "", close = ""
            if style.contains(.bold) { open += "**"; close = "**" + close }
            if style.contains(.italic) { open += "*"; close = "*" + close }
            if style.contains(.strike) { open += "~~"; close = "~~" + close }
            return lead + open + trimmed + close + trail
        }

        func finish() -> String {
            blocks.joined(separator: "\n\n")
        }
    }

    public static func isSafeLink(_ href: String) -> Bool {
        let lower = href.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
    }
}
