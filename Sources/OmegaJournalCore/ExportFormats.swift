import Foundation

// MARK: - Export formatting (pure)

public struct ExportableEntry: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let mood: Int
    public let moodLabel: String
    public let tags: [String]
    public let createdAt: Date
    public let updatedAt: Date
    public let isFavorite: Bool
    /// File names (inside the export's attachments folder) belonging to this entry.
    public let attachmentFiles: [String]
    public init(id: String, title: String, body: String, mood: Int, moodLabel: String, tags: [String],
                createdAt: Date, updatedAt: Date, isFavorite: Bool = false, attachmentFiles: [String] = []) {
        self.id = id; self.title = title; self.body = body; self.mood = mood; self.moodLabel = moodLabel
        self.tags = tags; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.isFavorite = isFavorite; self.attachmentFiles = attachmentFiles
    }
    public var displayTitle: String { title.isEmpty ? "Untitled" : title }
}

public enum ExportFormats {
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func yamlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// One markdown file with YAML front matter (round-trips through `ImportParsers.parseMarkdownNote`).
    public static func markdownWithFrontMatter(_ e: ExportableEntry, attachmentsFolder: String = "attachments") -> String {
        var s = "---\n"
        s += "id: \(e.id)\n"
        s += "title: \(yamlQuote(e.title))\n"
        s += "date: \(iso(e.createdAt))\n"
        s += "updated: \(iso(e.updatedAt))\n"
        s += "mood: \(e.mood)\n"
        if e.isFavorite { s += "favorite: true\n" }
        if e.tags.isEmpty { s += "tags: []\n" } else {
            s += "tags:\n"
            for t in e.tags { s += "  - \(t)\n" }
        }
        if !e.attachmentFiles.isEmpty {
            s += "attachments:\n"
            for f in e.attachmentFiles { s += "  - \(attachmentsFolder)/\(f)\n" }
        }
        s += "---\n\n"
        s += e.body
        if !e.body.hasSuffix("\n") { s += "\n" }
        return s
    }

    /// Filesystem-safe file stem like `2026-10-01 My title`.
    public static func fileStem(_ e: ExportableEntry, calendar: Calendar = .current) -> String {
        let day = DayKey.string(from: e.createdAt, calendar: calendar)
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = e.displayTitle.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(day) \(String(cleaned.prefix(60)))"
    }

    /// Makes names unique by appending " 2", " 3"… (case-insensitive).
    public static func uniqueNames(_ stems: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return stems.map { stem in
            let key = stem.lowercased()
            let n = (seen[key] ?? 0) + 1
            seen[key] = n
            return n == 1 ? stem : "\(stem) \(n)"
        }
    }

    // MARK: HTML

    public static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Minimal, safe markdown→HTML (headings, bold/italic, code, lists, quotes, paragraphs). All input is
    /// escaped first, so entry text can never inject markup or script.
    public static func htmlBody(fromMarkdown md: String) -> String {
        var html = ""
        var inList = false
        var inCode = false
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { html += "<p>\(inline(para.joined(separator: "<br>")))</p>\n"; para = [] }
        }
        func closeList() { if inList { html += "</ul>\n"; inList = false } }
        for rawLine in md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if rawLine.hasPrefix("```") {
                flushPara(); closeList()
                html += inCode ? "</code></pre>\n" : "<pre><code>"
                inCode.toggle()
                continue
            }
            if inCode { html += escapeHTML(rawLine) + "\n"; continue }
            let line = escapeHTML(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushPara(); closeList(); continue }
            if let m = line.range(of: "^#{1,6} ", options: .regularExpression) {
                flushPara(); closeList()
                let level = line.distance(from: line.startIndex, to: m.upperBound) - 1
                html += "<h\(level)>\(inline(String(line[m.upperBound...])))</h\(level)>\n"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushPara()
                if !inList { html += "<ul>\n"; inList = true }
                html += "<li>\(inline(String(line.dropFirst(2))))</li>\n"
            } else if line.hasPrefix("&gt; ") {
                flushPara(); closeList()
                html += "<blockquote>\(inline(String(line.dropFirst(5))))</blockquote>\n"
            } else {
                closeList()
                para.append(line)
            }
        }
        if inCode { html += "</code></pre>\n" }
        flushPara(); closeList()
        return html
    }

    private static func inline(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
        r = r.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        r = r.replacingOccurrences(of: "(?<![*\\w])\\*([^*\\n]+)\\*(?!\\w)", with: "<em>$1</em>", options: .regularExpression)
        return r
    }

    public struct HTMLTheme: Sendable {
        public var background: String, card: String, text: String, secondary: String, accent: String
        public init(background: String = "#14101f", card: String = "#1e1830", text: String = "#ece8f7",
                    secondary: String = "#a89fc4", accent: String = "#a78bfa") {
            self.background = background; self.card = card; self.text = text; self.secondary = secondary; self.accent = accent
        }
    }

    static func css(_ t: HTMLTheme) -> String {
        """
        body{margin:0;background:\(t.background);color:\(t.text);font:16px/1.65 -apple-system,Georgia,serif}
        main{max-width:720px;margin:0 auto;padding:40px 20px}
        a{color:\(t.accent);text-decoration:none}a:hover{text-decoration:underline}
        .card{background:\(t.card);border-radius:12px;padding:16px 20px;margin:12px 0}
        .meta{color:\(t.secondary);font-size:13px}
        .tag{display:inline-block;background:\(t.accent)33;color:\(t.accent);border-radius:6px;padding:0 8px;margin-right:6px;font-size:12px}
        pre{background:#0004;padding:12px;border-radius:8px;overflow:auto}code{font-family:ui-monospace,Menlo,monospace}
        blockquote{border-left:3px solid \(t.accent);margin:0;padding-left:14px;color:\(t.secondary)}
        img{max-width:100%;border-radius:8px}
        """
    }

    public static func htmlPage(title: String, bodyHTML: String, theme: HTMLTheme = HTMLTheme()) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escapeHTML(title))</title><style>\(css(theme))</style></head>
        <body><main>
        \(bodyHTML)
        </main></body></html>
        """
    }

    /// Per-entry page; `rootPrefix` is "" for index-level pages or "../" for nested ones.
    public static func entryPage(_ e: ExportableEntry, theme: HTMLTheme = HTMLTheme(), indexHref: String = "index.html",
                                 attachmentsHref: String = "attachments", calendar: Calendar = .current) -> String {
        var b = "<p><a href=\"\(escapeHTML(indexHref))\">← All entries</a></p>\n"
        b += "<h1>\(escapeHTML(e.displayTitle))</h1>\n"
        b += "<p class=\"meta\">\(escapeHTML(DayKey.string(from: e.createdAt, calendar: calendar))) · \(escapeHTML(e.moodLabel))</p>\n"
        if !e.tags.isEmpty { b += "<p>" + e.tags.map { "<span class=\"tag\">#\(escapeHTML($0))</span>" }.joined() + "</p>\n" }
        b += htmlBody(fromMarkdown: e.body)
        for f in e.attachmentFiles {
            let href = "\(attachmentsHref)/\(percentEncode(f))"
            if isImageName(f) { b += "<p><img src=\"\(href)\" alt=\"\(escapeHTML(f))\"></p>\n" }
            else { b += "<p><a href=\"\(href)\">\(escapeHTML(f))</a></p>\n" }
        }
        return htmlPage(title: e.displayTitle, bodyHTML: b, theme: theme)
    }

    public static func indexPage(title: String, entries: [(entry: ExportableEntry, href: String)], theme: HTMLTheme = HTMLTheme(),
                                 calendar: Calendar = .current) -> String {
        var b = "<h1>\(escapeHTML(title))</h1>\n<p class=\"meta\">\(entries.count) entries</p>\n"
        for (e, href) in entries.sorted(by: { $0.entry.createdAt > $1.entry.createdAt }) {
            let preview = String(e.body.replacingOccurrences(of: "\n", with: " ").prefix(160))
            b += "<div class=\"card\"><a href=\"\(escapeHTML(href))\"><strong>\(escapeHTML(e.displayTitle))</strong></a>"
            b += "<div class=\"meta\">\(escapeHTML(DayKey.string(from: e.createdAt, calendar: calendar)))</div>"
            b += "<div>\(escapeHTML(preview))</div></div>\n"
        }
        return htmlPage(title: title, bodyHTML: b, theme: theme)
    }

    public static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    static func isImageName(_ f: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains((f as NSString).pathExtension.lowercased())
    }
}
