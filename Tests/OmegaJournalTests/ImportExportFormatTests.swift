import Foundation
import Testing
@testable import OmegaJournalCore

@Suite("Import parsers")
struct ImportParserTests {
    @Test("front matter parsing: scalars, block lists, inline lists, body")
    func frontMatter() {
        let text = "---\ntitle: \"Hello: world\"\ndate: 2026-10-01T09:30:00Z\ntags:\n  - a\n  - b\nmood: 4\n---\n\nBody text\n"
        let (f, l, body) = ImportParsers.splitFrontMatter(text)
        #expect(f["title"] == "Hello: world")
        #expect(l["tags"] == ["a", "b"])
        #expect(f["mood"] == "4")
        #expect(body == "Body text\n")
        let inline = ImportParsers.splitFrontMatter("---\ntags: [x, \"y z\"]\n---\nhi")
        #expect(inline.lists["tags"] == ["x", "y z"])
        #expect(ImportParsers.splitFrontMatter("no front matter").body == "no front matter")
    }

    @Test("markdown note: front matter wins, falls back to heading/filename")
    func note() {
        let fallback = Date(timeIntervalSince1970: 1_000_000)
        let a = ImportParsers.parseMarkdownNote(text: "---\ntitle: T\ndate: 2026-01-02\ntags: [#one, two]\nmood: 9\nfavorite: true\n---\nbody", fallbackTitle: "file", fallbackDate: fallback)
        #expect(a.title == "T" && a.body == "body" && a.tags == ["one", "two"] && a.mood == 5 && a.isFavorite)
        #expect(a.createdAt != fallback)
        let b = ImportParsers.parseMarkdownNote(text: "# Heading\n\ntext", fallbackTitle: "file", fallbackDate: fallback)
        #expect(b.title == "Heading" && b.createdAt == fallback)
        let c = ImportParsers.parseMarkdownNote(text: "just text", fallbackTitle: "file", fallbackDate: fallback)
        #expect(c.title == "file")
    }

    @Test("plain text title heuristic")
    func plain() {
        let d = Date()
        let a = ImportParsers.parsePlainText(text: "Morning walk\nIt was cold.", fallbackTitle: "f", fallbackDate: d)
        #expect(a.title == "Morning walk" && a.body == "It was cold.")
        let b = ImportParsers.parsePlainText(text: "A single long sentence that ends with a period.", fallbackTitle: "f", fallbackDate: d)
        #expect(b.title == "f")
    }

    @Test("Day One JSON")
    func dayOne() throws {
        let json = """
        {"metadata":{"version":"1.0"},"entries":[
         {"uuid":"U1","creationDate":"2024-05-06T07:08:09Z","modifiedDate":"2024-05-07T07:08:09Z","starred":true,
          "tags":["trip plan"],"text":"# Beach day\\n\\nWe went\\\\. It was fun\\\\!\\n\\n![](dayone-moment://ABC)",
          "photos":[{"identifier":"ABC","md5":"deadbeef","type":"jpeg"}]},
         {"uuid":"U2","text":"no date"}
        ]}
        """
        let r = try ImportParsers.parseDayOneJSON(Data(json.utf8))
        #expect(r.entries.count == 1 && r.skipped == 1)
        let e = r.entries[0]
        #expect(e.title == "Beach day")
        #expect(e.body.contains("We went. It was fun!"))
        #expect(!e.body.contains("dayone-moment"))
        #expect(e.isFavorite && e.tags == ["trip-plan"] && e.sourceId == "U1")
        #expect(e.attachmentPaths == ["photos/deadbeef.jpeg"])
        #expect(throws: ImportParsers.ImportParseError.self) { try ImportParsers.parseDayOneJSON(Data("{}".utf8)) }
    }
}

@Suite("Export formats")
struct ExportFormatTests {
    static let entry = ExportableEntry(id: "abc", title: "Day: \"one\"", body: "# Head\n\nSome **bold** and *it* and `code`\n- a\n- b\n\n<script>alert(1)</script>",
                                       mood: 4, moodLabel: "Good", tags: ["x", "y"],
                                       createdAt: CheckinStatsTests.date(2026, 10, 1), updatedAt: CheckinStatsTests.date(2026, 10, 2),
                                       isFavorite: true, attachmentFiles: ["abc-pic.png"])

    @Test("markdown front matter round-trips through the importer")
    func roundTrip() {
        let md = ExportFormats.markdownWithFrontMatter(Self.entry)
        #expect(md.hasPrefix("---\n"))
        let parsed = ImportParsers.parseMarkdownNote(text: md, fallbackTitle: "f", fallbackDate: Date(timeIntervalSince1970: 0))
        #expect(parsed.title == "Day: \"one\"")
        #expect(parsed.tags == ["x", "y"])
        #expect(parsed.mood == 4 && parsed.isFavorite)
        #expect(parsed.body.contains("Some **bold**"))
        #expect(parsed.sourceId == "abc")
        #expect(md.contains("attachments/abc-pic.png"))
    }

    @Test("html is escaped and structured")
    func html() {
        let page = ExportFormats.entryPage(Self.entry, calendar: CheckinStatsTests.cal)
        #expect(!page.contains("<script>"))
        #expect(page.contains("&lt;script&gt;"))
        #expect(page.contains("<h1>Day: &quot;one&quot;</h1>"))
        #expect(page.contains("<strong>bold</strong>") && page.contains("<em>it</em>") && page.contains("<code>code</code>"))
        #expect(page.contains("<li>a</li>"))
        #expect(page.contains("<img src=\"attachments/abc-pic.png\""))
        #expect(!page.contains("http://") && !page.contains("https://"))
    }

    @Test("file stems are safe and unique")
    func stems() {
        let e = ExportableEntry(id: "1", title: "a/b:c?", body: "", mood: 3, moodLabel: "", tags: [], createdAt: CheckinStatsTests.date(2026, 1, 2), updatedAt: Date())
        let stem = ExportFormats.fileStem(e, calendar: CheckinStatsTests.cal)
        #expect(stem == "2026-01-02 a-b-c-")
        #expect(ExportFormats.uniqueNames(["A", "a", "B", "A"]) == ["A", "a 2", "B", "A 3"])
    }
}
