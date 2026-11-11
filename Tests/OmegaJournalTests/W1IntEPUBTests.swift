import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OmegaJournal
@testable import OmegaJournalCore

@Suite("W1Int EPUB")
struct W1IntEPUBTests {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    static let png1x1 = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==")!

    static func book(entries: [EPUBEntry]? = nil) -> EPUBBook {
        EPUBBook(title: "My <Journal> & Co", subtitle: "2025", author: "Me", language: "en",
                 identifier: "8F1C2C1A-6D7E-4C55-9B53-5D5B2E1D3A10",
                 modified: Date(timeIntervalSince1970: 1_765_800_000),
                 entries: entries ?? [
                    EPUBEntry(id: "b", title: "Second", date: Date(timeIntervalSince1970: 1_765_900_000), moodLabel: "Good",
                              tags: ["walks"], markdown: "Hello <script>alert(1)</script> & **bold** [x](javascript:alert(1))\n\n- [ ] task\n- item\n\n![](omega-attachment://pic.png)\n\n<!-- stamp: loc=Paris -->"),
                    EPUBEntry(id: "a", title: "", date: Date(timeIntervalSince1970: 1_765_800_000),
                              markdown: "# Heading\n\n> quote\n\n```\ncode <b>\n```\n\nA [link](https://example.com/?a=1&b=2).",
                              images: []),
                 ])
    }

    static func entries(of data: Data) throws -> (zip: AppleJournalZipReader, files: [String: AppleJournalZipReader.Entry]) {
        let zip = try AppleJournalZipReader(data: data)
        return (zip, Dictionary(zip.entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    @Test func mimetypeComesFirstStoredWithoutExtraField() throws {
        var book = Self.book()
        book.entries[0] = EPUBEntry(id: "b", title: "Second", date: book.entries[0].date, markdown: book.entries[0].markdown,
                                    images: [EPUBImage(originalName: "pic.png", data: Self.png1x1, mediaType: "image/png")])
        let data = try EPUBBuilder.build(book, calendar: Self.utc)
        // Local header #1 at offset 0: name "mimetype", method 0, extra length 0, then the bytes.
        #expect(data.u32(at: 0) == 0x0403_4B50)
        #expect(data.u16(at: 8) == 0)
        #expect(data.u16(at: 26) == 8)
        #expect(data.u16(at: 28) == 0)
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: data[38..<58], as: UTF8.self) == "application/epub+zip")
        let (zip, files) = try Self.entries(of: data)
        #expect(zip.entries.first?.name == "mimetype")
        for name in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/toc.ncx", "OEBPS/style.css",
                     "OEBPS/text/title.xhtml", "OEBPS/text/entry-0001.xhtml", "OEBPS/text/entry-0002.xhtml", "OEBPS/images/img-0001.png"] {
            #expect(files[name] != nil, "missing \(name)")
        }
    }

    @Test func everyDocumentIsWellFormedAndListedInTheManifest() throws {
        let data = try EPUBBuilder.build(Self.book(), calendar: Self.utc)
        let (zip, files) = try Self.entries(of: data)
        for (name, entry) in files where name.hasSuffix(".xhtml") || name.hasSuffix(".opf") || name.hasSuffix(".xml") || name.hasSuffix(".ncx") {
            let xml = String(decoding: try zip.contents(of: entry), as: UTF8.self)
            #expect(EPUBBuilder.isWellFormedXML(xml), "\(name) is not well-formed")
        }
        let opf = String(decoding: try zip.contents(of: #require(files["OEBPS/content.opf"])), as: UTF8.self)
        #expect(opf.contains(#"version="3.0""#))
        #expect(opf.contains("urn:uuid:8F1C2C1A-6D7E-4C55-9B53-5D5B2E1D3A10"))
        #expect(opf.contains("<dc:title>My &lt;Journal&gt; &amp; Co</dc:title>"))
        #expect(opf.contains(#"<meta property="dcterms:modified">2025-12-15T12:00:00Z</meta>"#))
        #expect(opf.contains(#"properties="nav""#))
        for name in files.keys where name.hasPrefix("OEBPS/text/") || name.hasPrefix("OEBPS/images/") {
            #expect(opf.contains(#"href="\#(name.dropFirst("OEBPS/".count))""#), "\(name) not in manifest")
        }
        let container = String(decoding: try zip.contents(of: #require(files["META-INF/container.xml"])), as: UTF8.self)
        #expect(container.contains(#"full-path="OEBPS/content.opf""#))
    }

    @Test func entriesAreOrderedAndContentIsSafe() throws {
        let data = try EPUBBuilder.build(Self.book(), calendar: Self.utc)
        let (zip, files) = try Self.entries(of: data)
        let first = String(decoding: try zip.contents(of: #require(files["OEBPS/text/entry-0001.xhtml"])), as: UTF8.self)
        let second = String(decoding: try zip.contents(of: #require(files["OEBPS/text/entry-0002.xhtml"])), as: UTF8.self)
        // Oldest first: the untitled entry ("a") is chapter 1.
        #expect(first.contains("<h1>Untitled</h1>"))
        #expect(first.contains("<h2>Heading</h2>"))
        #expect(first.contains("<blockquote><p>quote</p></blockquote>"))
        #expect(first.contains("<pre><code>code &lt;b&gt;</code></pre>"))
        #expect(first.contains(#"<a href="https://example.com/?a=1&amp;b=2">link</a>"#))
        #expect(second.contains("Hello &lt;script&gt;alert(1)&lt;/script&gt; &amp; <strong>bold</strong> x"))
        #expect(!second.contains("javascript:"))
        #expect(!second.contains("<script"))
        #expect(second.contains("☐ task"))
        #expect(second.contains("Paris"))          // place shown in the meta line
        #expect(!second.contains("stamp:"))        // the stamp comment itself is dropped
        #expect(second.contains("#walks"))
        let nav = String(decoding: try zip.contents(of: #require(files["OEBPS/nav.xhtml"])), as: UTF8.self)
        #expect(nav.contains(#"epub:type="toc""#))
        #expect(nav.contains("December 2025"))
        #expect(nav.range(of: "Untitled")!.lowerBound < nav.range(of: "Second")!.lowerBound)
    }

    @Test func inlineImagesBecomeFiguresAndOthersGoAtTheEnd() throws {
        let entry = EPUBEntry(id: "x", title: "Pics", date: Date(timeIntervalSince1970: 0),
                              markdown: "Look:\n\n![sunset](omega-attachment://a.png)\n\nEnd.",
                              images: [EPUBImage(originalName: "a.png", data: Self.png1x1, mediaType: "image/png"),
                                       EPUBImage(originalName: "b.png", data: Self.png1x1, mediaType: "image/png"),
                                       EPUBImage(originalName: "c.heic", data: Data([1]), mediaType: "image/heic")])
        let data = try EPUBBuilder.build(EPUBBook(title: "T", entries: [entry]), calendar: Self.utc)
        let (zip, files) = try Self.entries(of: data)
        let page = String(decoding: try zip.contents(of: #require(files["OEBPS/text/entry-0001.xhtml"])), as: UTF8.self)
        #expect(page.contains(#"<figure><img src="../images/img-0001.png" alt="sunset"/></figure>"#))
        #expect(page.contains(#"<img src="../images/img-0002.png" alt="b.png"/>"#))
        #expect(page.range(of: "End.")!.lowerBound < page.range(of: "img-0002")!.lowerBound)
        // Non-core media types are never put in the book.
        #expect(!files.keys.contains { $0.hasSuffix(".bin") || $0.contains("heic") })
    }

    @Test func systemUnzipAcceptsTheArchive() throws {
        let unzip = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzip) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w1int-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: url) }
        try EPUBBuilder.build(Self.book(), calendar: Self.utc).write(to: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: unzip)
        p.arguments = ["-tq", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "\(out)")
        #expect(out.contains("No errors detected"))
    }

    @Test func zipWriterRejectsUnsafeAndDuplicateNames() throws {
        var w = EPUBZipWriter()
        #expect(throws: EPUBZipError.unsafeName("../x")) { try w.add("../x", Data()) }
        #expect(throws: EPUBZipError.unsafeName("/x")) { try w.add("/x", Data()) }
        try w.add("a", Data())
        #expect(throws: EPUBZipError.duplicateName("a")) { try w.add("a", Data()) }
        #expect(EPUBCRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func badInlineMarkupFallsBackToEscapedText() {
        let (html, _) = EPUBBuilder.markdownToXHTML("**unclosed *mix** of* things\u{0001}")
        #expect(EPUBBuilder.isWellFormedXML("<x>\(html)</x>"))
    }
}

@Suite("W1Int EPUB export scope")
@MainActor
struct W1IntEPUBScopeTests {
    static func entry(_ id: String, year: Int, journal: String = "J1", hidden: Bool = false, trashed: Bool = false) -> JournalEntry {
        var e = JournalEntry.new()
        e = JournalEntry(id: id, title: id, body: "body \(id)", mood: .good, tags: [], createdAt:
                            W1IntEPUBTests.utc.date(from: DateComponents(year: year, month: 6, day: 1))!,
                         updatedAt: Date(), isPinned: false, isFavorite: false, isArchived: false,
                         deletedAt: trashed ? Date() : nil, isHidden: hidden, attachments: [])
        e.journalId = journal
        return e
    }

    static let all = [
        entry("a", year: 2024), entry("b", year: 2025), entry("c", year: 2025, journal: "J2"),
        entry("h", year: 2025, hidden: true), entry("t", year: 2025, trashed: true),
    ]

    @Test func trashIsNeverIncludedAndHiddenOnlyWhenUnlocked() {
        let locked = ExportManager.epubEntries(Self.all, scope: .all, includeHidden: false, calendar: W1IntEPUBTests.utc)
        #expect(locked.entries.map(\.id) == ["a", "b", "c"])
        #expect(locked.omittedHidden == 1)
        let unlocked = ExportManager.epubEntries(Self.all, scope: .all, includeHidden: true, calendar: W1IntEPUBTests.utc)
        #expect(Set(unlocked.entries.map(\.id)) == ["a", "b", "c", "h"])
        #expect(unlocked.omittedHidden == 0)
    }

    @Test func scopesSelectTheRightEntries() {
        let cal = W1IntEPUBTests.utc
        #expect(ExportManager.epubEntries(Self.all, scope: .year(2025), includeHidden: false, calendar: cal).entries.map(\.id) == ["b", "c"])
        #expect(ExportManager.epubEntries(Self.all, scope: .notebook(id: "J2", name: "Work"), includeHidden: false, calendar: cal)
            .entries.map(\.id) == ["c"])
        let sel = ExportManager.epubEntries(Self.all, scope: .selection(["a", "h", "t"]), includeHidden: false, calendar: cal)
        #expect(sel.entries.map(\.id) == ["a"])
        #expect(sel.omittedHidden == 1)
        #expect(ExportManager.EPUBScope.year(2025).bookTitle == "Omega Journal 2025")
        #expect(ExportManager.EPUBScope.notebook(id: "J2", name: "Work").bookTitle == "Work")
    }

    @Test func epubFromEntriesCarriesNoHiddenTextWhenLocked() throws {
        let kept = ExportManager.epubEntries(Self.all, scope: .all, includeHidden: false).entries
        let data = try ExportManager.epubData(kept, title: "T")
        let zip = try AppleJournalZipReader(data: data)
        let text = try zip.entries.map { String(decoding: try zip.contents(of: $0), as: UTF8.self) }.joined()
        #expect(text.contains("body a"))
        #expect(!text.contains("body h"))
        #expect(!text.contains("body t"))
    }

    @Test func imagesAreConvertedToReaderFormats() throws {
        #expect(ExportManager.epubImage(W1IntEPUBTests.png1x1, mimeType: "image/png")?.mimeType == "image/png")
        // A TIFF (not an EPUB core type) becomes a JPEG.
        let ctx = try #require(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let cg = try #require(ctx.makeImage())
        let tiff = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        let converted = try #require(ExportManager.epubImage(tiff as Data, mimeType: "image/tiff"))
        #expect(converted.mimeType == "image/jpeg")
        #expect(converted.data.starts(with: [0xFF, 0xD8]))
        #expect(ExportManager.epubImage(Data("nope".utf8), mimeType: "image/heic") == nil)
    }
}
