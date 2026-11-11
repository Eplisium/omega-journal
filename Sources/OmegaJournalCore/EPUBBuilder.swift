import Foundation

// MARK: - EPUB 3 book builder (pure)
//
// Layout (EPUB 3.3 OCF + Package):
//   mimetype                       first, STORED, no extra field
//   META-INF/container.xml         → OEBPS/content.opf
//   OEBPS/content.opf              package 3.0, dc:identifier/title/language, dcterms:modified
//   OEBPS/nav.xhtml                EPUB 3 navigation document (entries grouped by month)
//   OEBPS/toc.ncx                  EPUB 2 table of contents for older readers
//   OEBPS/style.css
//   OEBPS/text/title.xhtml, OEBPS/text/entry-0001.xhtml …
//   OEBPS/images/…                 JPEG / PNG / GIF / WebP / SVG only (core media types)
//
// Every XHTML document is checked with XMLParser before it is zipped; a block
// whose inline markup would not be well-formed falls back to escaped text, so
// a strict reader (Apple Books) never rejects a chapter.

public struct EPUBImage: Equatable, Sendable {
    /// Name the entry body refers to (`omega-attachment://<name>`).
    public let originalName: String
    public let data: Data
    public let mediaType: String
    public init(originalName: String, data: Data, mediaType: String) {
        self.originalName = originalName; self.data = data; self.mediaType = mediaType
    }
}

public struct EPUBEntry: Equatable, Sendable {
    public let id: String
    public let title: String
    public let date: Date
    public let moodLabel: String
    public let tags: [String]
    public let markdown: String
    public let images: [EPUBImage]
    public init(id: String, title: String, date: Date, moodLabel: String = "", tags: [String] = [],
                markdown: String, images: [EPUBImage] = []) {
        self.id = id; self.title = title; self.date = date; self.moodLabel = moodLabel
        self.tags = tags; self.markdown = markdown; self.images = images
    }
    public var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title }
}

public struct EPUBBook: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var author: String
    public var language: String
    /// UUID string; becomes `urn:uuid:…`.
    public var identifier: String
    public var modified: Date
    public var entries: [EPUBEntry]
    public init(title: String, subtitle: String = "", author: String = "", language: String = "en",
                identifier: String = UUID().uuidString, modified: Date = Date(), entries: [EPUBEntry]) {
        self.title = title; self.subtitle = subtitle; self.author = author; self.language = language
        self.identifier = identifier; self.modified = modified; self.entries = entries
    }
}

public enum EPUBBuilder {
    public static let mimetype = "application/epub+zip"
    public static let coreImageTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/svg+xml"]

    public static func extensionFor(mediaType: String) -> String {
        switch mediaType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        default: return "bin"
        }
    }

    // MARK: Build

    public static func build(_ book: EPUBBook, calendar: Calendar = .current) throws -> Data {
        let entries = book.entries.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        var zip = EPUBZipWriter(modified: book.modified)
        try zip.add("mimetype", Data(mimetype.utf8), method: .stored)
        try zip.add("META-INF/container.xml", text: containerXML)
        try zip.add("OEBPS/style.css", text: stylesheet)
        try zip.add("OEBPS/text/title.xhtml", text: guarded(titlePage(book, entryCount: entries.count, calendar: calendar)))

        var manifest: [String] = [
            #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#,
            #"<item id="css" href="style.css" media-type="text/css"/>"#,
            #"<item id="title" href="text/title.xhtml" media-type="application/xhtml+xml"/>"#,
        ]
        var spine = [#"<itemref idref="title"/>"#, #"<itemref idref="nav"/>"#]
        var chapters: [(href: String, title: String, date: Date)] = []
        var imageIndex = 0
        for (i, entry) in entries.enumerated() {
            let n = String(format: "%04d", i + 1)
            // Images: unique book names, only the core media types.
            var names: [String: String] = [:]
            for img in entry.images where coreImageTypes.contains(img.mediaType) && names[img.originalName] == nil {
                imageIndex += 1
                let file = "img-\(String(format: "%04d", imageIndex)).\(extensionFor(mediaType: img.mediaType))"
                try zip.add("OEBPS/images/\(file)", img.data, method: .stored)
                manifest.append(#"<item id="img\#(imageIndex)" href="images/\#(file)" media-type="\#(img.mediaType)"/>"#)
                names[img.originalName] = "../images/\(file)"
            }
            let href = "text/entry-\(n).xhtml"
            try zip.add("OEBPS/\(href)", text: guarded(entryPage(entry, imageHrefs: names, language: book.language, calendar: calendar)))
            manifest.append(#"<item id="e\#(n)" href="\#(href)" media-type="application/xhtml+xml"/>"#)
            spine.append(#"<itemref idref="e\#(n)"/>"#)
            chapters.append((href, entry.displayTitle, entry.date))
        }
        try zip.add("OEBPS/nav.xhtml", text: guarded(navDocument(book, chapters: chapters, calendar: calendar)))
        try zip.add("OEBPS/toc.ncx", text: ncx(book, chapters: chapters, calendar: calendar))
        try zip.add("OEBPS/content.opf", text: opf(book, manifest: manifest, spine: spine))
        return try zip.finish()
    }

    static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    static let stylesheet = """
    body { font-family: Georgia, serif; line-height: 1.55; margin: 0 5%; }
    h1 { font-family: -apple-system, "Helvetica Neue", sans-serif; font-size: 1.6em; margin: 1.2em 0 0.2em; }
    h2, h3, h4, h5, h6 { font-family: -apple-system, "Helvetica Neue", sans-serif; }
    .meta { color: #6b6380; font-size: 0.85em; margin: 0 0 1.4em; font-family: -apple-system, sans-serif; }
    .tags { color: #6b4fbb; }
    blockquote { border-left: 3px solid #a78bfa; margin: 1em 0; padding-left: 1em; color: #4a4458; }
    pre { white-space: pre-wrap; font-size: 0.85em; background: #f4f1fa; padding: 0.6em; }
    figure { margin: 1em 0; text-align: center; }
    img { max-width: 100%; height: auto; }
    .title-page { text-align: center; margin-top: 30%; }
    .title-page h1 { font-size: 2.2em; }
    nav ol { list-style: none; padding-left: 1em; }
    li.task { list-style: none; }
    """

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    static func longDate(_ d: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? Locale(identifier: "en_US")
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func monthTitle(_ d: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return f.string(from: d)
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default:
                // XML 1.0 forbids most C0 controls.
                if ch.value < 0x20 && ch != "\n" && ch != "\t" && ch != "\r" { continue }
                if ch.value == 0xFFFE || ch.value == 0xFFFF { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func xhtml(title: String, language: String, cssHref: String, body: String, epubType: String? = nil) -> String {
        let lang = escape(language)
        let section = epubType.map { #"<section epub:type="\#($0)">"# } ?? "<section>"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
        <head>
        <meta charset="UTF-8"/>
        <title>\(escape(title))</title>
        <link rel="stylesheet" type="text/css" href="\(cssHref)"/>
        </head>
        <body>
        \(section)
        \(body)
        </section>
        </body>
        </html>
        """
    }

    static func titlePage(_ book: EPUBBook, entryCount: Int, calendar: Calendar) -> String {
        var b = #"<div class="title-page">"# + "\n<h1>\(escape(book.title))</h1>\n"
        if !book.subtitle.isEmpty { b += #"<p class="meta">"# + escape(book.subtitle) + "</p>\n" }
        if !book.author.isEmpty { b += "<p>\(escape(book.author))</p>\n" }
        b += "</div>"
        return xhtml(title: book.title, language: book.language, cssHref: "../style.css", body: b, epubType: "titlepage")
    }

    static func entryPage(_ e: EPUBEntry, imageHrefs: [String: String], language: String, calendar: Calendar) -> String {
        let (stamp, rest) = PlaceStampCodec.split(e.markdown)
        var meta = [longDate(e.date, calendar: calendar)]
        if !e.moodLabel.isEmpty { meta.append(e.moodLabel) }
        if let place = stamp?.location, !place.isEmpty { meta.append(place) }
        var b = "<h1>\(escape(e.displayTitle))</h1>\n"
        b += #"<p class="meta">"# + escape(meta.joined(separator: " · ")) + "</p>\n"
        if !e.tags.isEmpty {
            b += #"<p class="meta tags">"# + escape(e.tags.map { "#" + $0 }.joined(separator: " ")) + "</p>\n"
        }
        let (html, used) = markdownToXHTML(rest, imageHrefs: imageHrefs)
        b += html
        // Images not placed inline in the text go at the end of the entry.
        for img in e.images where !used.contains(img.originalName) {
            guard let href = imageHrefs[img.originalName] else { continue }
            b += #"<figure><img src="\#(escape(href))" alt="\#(escape(img.originalName))"/></figure>"# + "\n"
        }
        return xhtml(title: e.displayTitle, language: language, cssHref: "../style.css", body: b, epubType: "chapter")
    }

    static func navDocument(_ book: EPUBBook, chapters: [(href: String, title: String, date: Date)], calendar: Calendar) -> String {
        var b = #"<nav epub:type="toc" id="toc">"# + "\n<h1>Contents</h1>\n<ol>\n"
        var currentMonth: String?
        for c in chapters {
            let month = monthTitle(c.date, calendar: calendar)
            if month != currentMonth {
                if currentMonth != nil { b += "</ol></li>\n" }
                b += "<li><span>\(escape(month))</span><ol>\n"
                currentMonth = month
            }
            b += #"<li><a href="\#(escape(c.href))">"# + escape(c.title) + "</a></li>\n"
        }
        if currentMonth != nil { b += "</ol></li>\n" }
        if chapters.isEmpty { b += #"<li><a href="text/title.xhtml">"# + escape(book.title) + "</a></li>\n" }
        b += "</ol>\n</nav>"
        return xhtml(title: "Contents", language: book.language, cssHref: "style.css", body: b)
    }

    static func ncx(_ book: EPUBBook, chapters: [(href: String, title: String, date: Date)], calendar: Calendar) -> String {
        var points = #"<navPoint id="np-title" playOrder="1"><navLabel><text>"# + escape(book.title)
            + #"</text></navLabel><content src="text/title.xhtml"/></navPoint>"# + "\n"
        for (i, c) in chapters.enumerated() {
            points += #"<navPoint id="np-\#(i + 1)" playOrder="\#(i + 2)"><navLabel><text>"#
                + escape(c.title) + #"</text></navLabel><content src="\#(escape(c.href))"/></navPoint>"# + "\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head>
        <meta name="dtb:uid" content="urn:uuid:\(escape(book.identifier))"/>
        <meta name="dtb:depth" content="1"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
        </head>
        <docTitle><text>\(escape(book.title))</text></docTitle>
        <navMap>
        \(points)</navMap>
        </ncx>
        """
    }

    static func opf(_ book: EPUBBook, manifest: [String], spine: [String]) -> String {
        var meta = """
        <dc:identifier id="bookid">urn:uuid:\(escape(book.identifier))</dc:identifier>
        <dc:title>\(escape(book.title))</dc:title>
        <dc:language>\(escape(book.language))</dc:language>
        <meta property="dcterms:modified">\(iso(book.modified))</meta>
        """
        if !book.author.isEmpty { meta += "\n<dc:creator>\(escape(book.author))</dc:creator>" }
        if !book.subtitle.isEmpty { meta += "\n<dc:description>\(escape(book.subtitle))</dc:description>" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(escape(book.language))">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        \(meta)
        </metadata>
        <manifest>
        \(manifest.joined(separator: "\n"))
        </manifest>
        <spine toc="ncx">
        \(spine.joined(separator: "\n"))
        </spine>
        </package>
        """
    }

    // MARK: Well-formedness

    public static func isWellFormedXML(_ xml: String) -> Bool {
        // The XHTML5 doctype has no DTD reference, so XMLParser needs no network.
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }

    /// Last line of defence: a document that still isn't well-formed is
    /// replaced by a plain-text rendering of itself.
    static func guarded(_ xhtml: String) -> String {
        if isWellFormedXML(xhtml) { return xhtml }
        let text = xhtml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return EPUBBuilder.xhtml(title: "Entry", language: "en", cssHref: "../style.css", body: "<pre>\(escape(text))</pre>")
    }

    // MARK: Markdown → XHTML

    /// Converts Omega's Markdown to an XHTML fragment. Returns the fragment and
    /// the attachment names placed inline. Raw HTML in the text is escaped,
    /// never passed through; comments (stamps) are dropped.
    public static func markdownToXHTML(_ markdown: String, imageHrefs: [String: String] = [:]) -> (html: String, usedImages: Set<String>) {
        let md = ImportParsers.normalizeNewlines(markdown)
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        var out: [String] = []
        var used = Set<String>()
        var para: [String] = []
        var list: (tag: String, items: [String])?
        var quote: [String] = []
        var code: [String]?

        func emit(_ block: String, fallback: String) {
            out.append(isWellFormedXML("<x>\(block)</x>") ? block : fallback)
        }
        func flushPara() {
            guard !para.isEmpty else { return }
            let html = para.map { inline($0, imageHrefs: imageHrefs, used: &used) }.joined(separator: "<br/>")
            emit("<p>\(html)</p>", fallback: "<p>\(para.map(escape).joined(separator: "<br/>"))</p>")
            para = []
        }
        func flushList() {
            guard let l = list else { return }
            let items = l.items.map { raw -> String in
                if raw.hasPrefix("[ ] ") || raw.hasPrefix("[x] ") || raw.hasPrefix("[X] ") {
                    let mark = raw.hasPrefix("[ ]") ? "☐" : "☑"
                    return #"<li class="task">\#(mark) \#(inline(String(raw.dropFirst(4)), imageHrefs: imageHrefs, used: &used))</li>"#
                }
                return "<li>\(inline(raw, imageHrefs: imageHrefs, used: &used))</li>"
            }
            emit("<\(l.tag)>\(items.joined())</\(l.tag)>",
                 fallback: "<\(l.tag)>\(l.items.map { "<li>\(escape($0))</li>" }.joined())</\(l.tag)>")
            list = nil
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            let inner = markdownToXHTML(quote.joined(separator: "\n"), imageHrefs: imageHrefs)
            used.formUnion(inner.usedImages)
            emit("<blockquote>\(inner.html)</blockquote>", fallback: "<blockquote><p>\(escape(quote.joined(separator: " ")))</p></blockquote>")
            quote = []
        }
        func flushAll() { flushPara(); flushList(); flushQuote() }

        for line in md.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if trimmed.hasPrefix("```") {
                    out.append("<pre><code>\(escape(c.joined(separator: "\n")))</code></pre>")
                    code = nil
                } else { c.append(line); code = c }
                continue
            }
            if trimmed.hasPrefix("```") { flushAll(); code = []; continue }
            if trimmed.isEmpty { flushAll(); continue }
            if trimmed.hasPrefix(">") {
                flushPara(); flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushPara(); flushList()
                let level = min(6, trimmed[m].filter { $0 == "#" }.count + 1)  // entry title is <h1>
                let text = String(trimmed[m.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                emit("<h\(level)>\(inline(text, imageHrefs: imageHrefs, used: &used))</h\(level)>",
                     fallback: "<h\(level)>\(escape(text))</h\(level)>")
                continue
            }
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushAll(); out.append("<hr/>"); continue
            }
            if let m = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flushPara()
                if list?.tag != "ul" { flushList(); list = ("ul", []) }
                list?.items.append(String(trimmed[m.upperBound...]))
                continue
            }
            if let m = trimmed.range(of: #"^\d{1,4}[.)]\s+"#, options: .regularExpression) {
                flushPara()
                if list?.tag != "ol" { flushList(); list = ("ol", []) }
                list?.items.append(String(trimmed[m.upperBound...]))
                continue
            }
            // An image alone on its line becomes a figure.
            if let fig = figure(trimmed, imageHrefs: imageHrefs) {
                flushAll()
                used.insert(fig.name)
                out.append(fig.html)
                continue
            }
            flushList()
            para.append(trimmed)
        }
        if let c = code { out.append("<pre><code>\(escape(c.joined(separator: "\n")))</code></pre>") }
        flushAll()
        return (out.joined(separator: "\n"), used)
    }

    static let imageRegex = try! NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(omega-attachment://([^)\s#]+)(?:#[^)]*)?\)$"#)

    static func figure(_ line: String, imageHrefs: [String: String]) -> (name: String, html: String)? {
        let ns = line as NSString
        guard let m = imageRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let alt = ns.substring(with: m.range(at: 1))
        let raw = ns.substring(with: m.range(at: 2))
        let name = raw.removingPercentEncoding ?? raw
        guard let href = imageHrefs[name] else { return nil }
        return (name, #"<figure><img src="\#(escape(href))" alt="\#(escape(alt.isEmpty ? name : alt))"/></figure>"#)
    }

    /// Inline Markdown on one line: code, links (http/https/mailto), images,
    /// bold, italic, strikethrough, wiki links. Text is escaped first.
    static func inline(_ raw: String, imageHrefs: [String: String], used: inout Set<String>) -> String {
        var codes: [String] = []
        // Protect code spans from the other rules.
        var s = ""
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "`"), let close = rest[rest.index(after: open)...].firstIndex(of: "`") {
            s += escape(String(rest[..<open]))
            codes.append("<code>\(escape(String(rest[rest.index(after: open)..<close])))</code>")
            s += "\u{E000}\(codes.count - 1)\u{E001}"
            rest = rest[rest.index(after: close)...]
        }
        s += escape(String(rest))

        // Inline images (escaped text: `![alt](omega-attachment://x)` has no escapable chars except & in names).
        s = replace(s, #"!\[([^\]]*)\]\(omega-attachment://([^)\s#]+)(?:#[^)]*)?\)"#) { g in
            let name = (g[2].removingPercentEncoding ?? g[2]).replacingOccurrences(of: "&amp;", with: "&")
            guard let href = imageHrefs[name] else { return g[1] }
            used.insert(name)
            return #"<img src="\#(escape(href))" alt="\#(g[1].isEmpty ? escape(name) : g[1])"/>"#
        }
        // Links.
        s = replace(s, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { g in
            let url = g[2].replacingOccurrences(of: "&amp;", with: "&")
            guard AppleJournalHTML.isSafeLink(url) else { return g[1] }
            return #"<a href="\#(escape(url))">\#(g[1])</a>"#
        }
        // Wiki links → their title.
        s = replace(s, #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#) { g in g[2].isEmpty ? g[1] : g[2] }
        s = replace(s, #"\*\*([^*]+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        s = replace(s, #"__([^_]+?)__"#) { "<strong>\($0[1])</strong>" }
        s = replace(s, #"~~([^~]+?)~~"#) { "<del>\($0[1])</del>" }
        s = replace(s, #"(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])"#) { "<em>\($0[1])</em>" }
        s = replace(s, #"(?<![\w_])_([^_\s][^_]*?)_(?![\w_])"#) { "<em>\($0[1])</em>" }
        for (i, c) in codes.enumerated() { s = s.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: c) }
        return s
    }

    static func replace(_ s: String, _ pattern: String, _ make: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += make(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
