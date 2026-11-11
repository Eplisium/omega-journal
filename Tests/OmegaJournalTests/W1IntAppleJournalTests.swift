import Foundation
import Testing
@testable import OmegaJournalCore

// Synthetic fixtures only: the markup mirrors the documented shape of Apple
// Journal's HTML export (Cocoa-written `<p class="p1"><span class="s1">`
// paragraphs inside `.bodyText`, `.pageHeader`, `.title`, `.assetGrid`).

enum W1IntJournalFixture {
    static let style = """
    <style type="text/css">
    p.p1 {margin: 0.0px 0.0px 0.0px 0.0px; font: 17.0px '.AppleSystemUIFont'}
    span.s1 {font-family: '.SFUI-Semibold'; font-weight: bold; font-style: normal; font-size: 17.00px}
    span.s2 {font-family: '.SFUI-Regular'; font-weight: normal; font-style: italic}
    span.s3 {text-decoration: line-through}
    li.li1 {margin: 0.0px}
    </style>
    """

    static func page(header: String = "Monday, 15 December 2025", title: String = "Evening walk",
                     body: String, assets: String = "") -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(title)</title>\(style)</head>
        <body>
        <div class='pageHeader'>\(header)</div>
        <div class='title'>\(title)</div>
        <div class='bodyText'>\(body)</div>
        \(assets)
        </body></html>
        """
    }
}

@Suite("W1Int Apple Journal HTML")
struct W1IntAppleJournalHTMLTests {
    @Test func parsesForgivingMarkup() {
        let doc = AppleJournalHTML.parse("<div class=a><p>One<p>Two &amp; <b>three</div><!-- c --><script>if (a < b) {}</script>tail &lt;x&gt; &#x1F600;")
        let ps = doc.descendants { $0.name == "p" }
        #expect(ps.count == 2)
        #expect(ps[0].textContent == "One")
        #expect(ps[1].textContent == "Two & three")
        #expect(doc.textContent.contains("tail <x> 😀"))
        #expect(!doc.textContent.contains(" c "))
        #expect(doc.first { $0.name == "script" }?.textContent == "if (a < b) {}")
    }

    @Test func literalLessThanIsText() {
        let doc = AppleJournalHTML.parse("<p>3 < 4 and 5 > 2</p>")
        #expect(doc.textContent == "3 < 4 and 5 > 2")
    }

    @Test func classTraitsFromCocoaCSS() {
        let t = AppleJournalHTML.classTraits(fromCSS: W1IntJournalFixture.style)
        #expect(t["s1"] == .bold)
        #expect(t["s2"] == .italic)
        #expect(t["s3"] == .strike)
        #expect(t["p1"] == nil)
    }

    @Test func markdownKeepsParagraphsEmphasisListsAndLinks() {
        let html = """
        <p class="p1"><span class="s1">Big</span> day, <i>really</i>.</p>
        <p class="p1">Second line<br>wrapped</p>
        <ul class="ul1"><li class="li1">\t•\tMilk</li><li class="li1"><b>Eggs</b></li></ul>
        <ol><li>\t1.\tFirst</li><li>Second</li></ol>
        <p>See <a href="https://example.com/a b">this</a> and <a href="javascript:alert(1)">that</a>.</p>
        <p><span class="s3">gone</span></p>
        <blockquote><p>Quoted</p></blockquote>
        """
        let doc = AppleJournalHTML.parse(html)
        let md = AppleJournalHTML.markdown(from: doc, classStyles: AppleJournalHTML.classTraits(fromCSS: W1IntJournalFixture.style))
        #expect(md == """
        **Big** day, *really*.

        Second line
        wrapped

        - Milk
        - **Eggs**

        1. First
        2. Second

        See [this](https://example.com/a%20b) and that.

        ~~gone~~

        > Quoted
        """)
    }

    @Test func emphasisMarkersHugTheWords() {
        let md = AppleJournalHTML.markdown(from: AppleJournalHTML.parse("<p>a<b> bold </b>b</p>"))
        #expect(md == "a **bold** b")
    }

    @Test func nestedListsIndent() {
        let md = AppleJournalHTML.markdown(from: AppleJournalHTML.parse("<ul><li>A<ul><li>A1</li></ul></li><li>B</li></ul>"))
        #expect(md == "- A\n  - A1\n- B")
    }
}

@Suite("W1Int Apple Journal pages")
struct W1IntAppleJournalPageTests {
    @Test func parsesHeaderTitleBodyAndAssets() {
        let html = W1IntJournalFixture.page(body: #"<p class="p1"><span class="s1">Hello</span> world</p>"#, assets: """
        <div class="assetGrid">
          <div class="gridItem assetType_photo" id="AAA-111"><img src="../Resources/AAA-111.heic" class="asset_image"></div>
          <div id="BBB-222" class="gridItem assetType_video "><video src="../Resources/BBB-222.mov"></video></div>
          <div id="MAP-1" class="gridItem assetType_genericMap "><img src="../Resources/MAP-1.heic" class="asset_image"/>
            <div class="gridItemOverlayHeader">Hyde Park</div></div>
          <div id="SOM-1" class="gridItem assetType_stateOfMind "><div class="gridItemOverlayHeader">Pleasant</div>
            <div class="gridItemOverlayFooter">Calm, Grateful</div></div>
          <div id="LNK-1" class="gridItem assetType_link "><a href='https://example.com/recipe'>Recipe</a></div>
        </div>
        """)
        let page = AppleJournalImport.parsePage(html: html, fileName: "2025-12-15_Evening_walk.html")
        #expect(page.headerDate == "Monday, 15 December 2025")
        #expect(page.title == "Evening walk")
        #expect(page.markdownBody == "**Hello** world")
        #expect(page.assets.map(\.kind) == [.photo, .video, .map, .stateOfMind, .link])
        #expect(page.assets[0].source == "../Resources/AAA-111.heic")
        #expect(page.assets[2].caption == "Hyde Park")
        #expect(page.assets[3].header == "Pleasant")
        #expect(page.assets[4].href == "https://example.com/recipe")
    }

    @Test func gridWithoutItemsIsItsOwnAsset() {
        let html = #"<div class="assetGrid assetType_photo" id="FFF-666"><img src="../Resources/My%20Photo%20%C3%A9.heic"></div>"#
        let page = AppleJournalImport.parsePage(html: html, fileName: "2025-01-01.html")
        #expect(page.assets.count == 1)
        #expect(page.assets[0].source == "../Resources/My Photo é.heic")
        #expect(page.assets[0].kind == .photo)
    }

    @Test func missingBodyTextFallsBackToPageBody() {
        let html = "<html><body><div class='pageHeader'>Friday, December 5, 2025</div><p>Just text</p></body></html>"
        let page = AppleJournalImport.parsePage(html: html, fileName: "2025-12-05.html")
        #expect(page.markdownBody == "Just text")
        #expect(page.title == "")
    }

    @Test func headerDatesInCommonFormats() {
        let en = [Locale(identifier: "en_US_POSIX")]
        #expect(AppleJournalImport.parseHeaderDate("Monday, 15 December 2025", locales: en) == DateComponents(year: 2025, month: 12, day: 15))
        #expect(AppleJournalImport.parseHeaderDate("Friday, December 5, 2025", locales: en) == DateComponents(year: 2025, month: 12, day: 5))
        #expect(AppleJournalImport.parseHeaderDate("  Wednesday,\u{00A0}28 August 2024 ", locales: en) == DateComponents(year: 2024, month: 8, day: 28))
        #expect(AppleJournalImport.parseHeaderDate("Montag, 15. Dezember 2025", locales: [Locale(identifier: "de_DE")])
                == DateComponents(year: 2025, month: 12, day: 15))
        #expect(AppleJournalImport.parseHeaderDate("Yesterday", locales: en) == nil)
        #expect(AppleJournalImport.parseHeaderDate("", locales: en) == nil)
    }

    @Test func fileNamesGiveTitleAndDayIndex() {
        #expect(AppleJournalImport.titleFromFileName("2024-08-28_Evening_walk.html") == "Evening walk")
        #expect(AppleJournalImport.titleFromFileName("2024-08-28_(2).html") == "")
        #expect(AppleJournalImport.titleFromFileName("2024-08-28_Walk_(3).html") == "Walk")
        #expect(AppleJournalImport.titleFromFileName("2024-08-28.html") == "")
        #expect(AppleJournalImport.fileNameDate("2024-08-28_(2).html")?.index == 2)
        #expect(AppleJournalImport.fileNameDate("2024-08-28_Walk.html")?.day == DateComponents(year: 2024, month: 8, day: 28))
        #expect(AppleJournalImport.fileNameDate("notes.html") == nil)
    }

    @Test func sidecarReadsReferenceDateAndPlace() throws {
        let json = #"{"date": 787489200, "placeName": " Hyde Park ", "location": {"latitude": 51.5073, "longitude": -0.1657}}"#
        let s = try #require(AppleJournalImport.parseSidecar(Data(json.utf8)))
        #expect(s.date == Date(timeIntervalSinceReferenceDate: 787_489_200))
        #expect(s.placeName == "Hyde Park")
        #expect(s.coordinate == PlaceCoordinate(latitude: 51.5073, longitude: -0.1657))
        #expect(AppleJournalImport.parseSidecar(Data("not json".utf8)) == nil)
        #expect(AppleJournalImport.parseSidecar(Data(#"{"date": true}"#.utf8))?.date == nil)
    }

    @Test func stateOfMindMapsToMood() {
        #expect(AppleJournalImport.mood(fromStateOfMind: "Very Pleasant") == 5)
        #expect(AppleJournalImport.mood(fromStateOfMind: "Slightly Unpleasant") == 2)
        #expect(AppleJournalImport.mood(fromStateOfMind: "Neutral") == 3)
        #expect(AppleJournalImport.mood(fromStateOfMind: "Anxious, Stressed") == 2)
        #expect(AppleJournalImport.mood(fromStateOfMind: "Overwhelmed") == 1)
        #expect(AppleJournalImport.mood(fromStateOfMind: "Calm") == 4)
        #expect(AppleJournalImport.mood(fromStateOfMind: "Joyful") == 5)
        #expect(AppleJournalImport.mood(fromStateOfMind: "Purple") == nil)
    }
}

@Suite("W1Int Apple Journal records")
struct W1IntAppleJournalRecordTests {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func files(extra: [String: Data] = [:]) -> [String: Data] {
        var f: [String: Data] = [
            "AppleJournalEntries/Entries/2025-12-15_Evening_walk.html": Data(W1IntJournalFixture.page(
                body: "<p>Cold but <i>lovely</i>.</p>",
                assets: """
                <div class="assetGrid">
                <div class="gridItem assetType_photo" id="PH-1"><img src="../Resources/PH-1.heic"></div>
                <div class="gridItem assetType_photo" id="PH-2"><img src="../../../etc/passwd"></div>
                <div id="MAP-1" class="gridItem assetType_genericMap "><img src="../Resources/MAP-1.heic"/>
                  <div class="gridItemOverlayHeader">Hyde Park</div></div>
                <div id="SOM-1" class="gridItem assetType_stateOfMind "><div class="gridItemOverlayHeader">Very Pleasant</div></div>
                </div>
                """).utf8),
            "AppleJournalEntries/Entries/2025-12-16_(2).html": Data(W1IntJournalFixture.page(
                header: "Tuesday, 16 December 2025", title: "", body: "<p>Second</p>").utf8),
            "AppleJournalEntries/Entries/broken.html": Data("<p>no date anywhere</p>".utf8),
            "AppleJournalEntries/Resources/PH-1.heic": Data([1, 2, 3]),
            "AppleJournalEntries/Resources/PH-1.json": Data(#"{"date": 787518000}"#.utf8),
            "AppleJournalEntries/Resources/MAP-1.heic": Data([9]),
            "AppleJournalEntries/Resources/MAP-1.json": Data(#"{"placeName": "Hyde Park", "latitude": 51.5073, "longitude": -0.1657}"#.utf8),
            "__MACOSX/AppleJournalEntries/Entries/._2025-12-15_Evening_walk.html": Data(),
        ]
        for (k, v) in extra { f[k] = v }
        return f
    }

    @Test func layoutFindsTheExportRoot() throws {
        let layout = try #require(AppleJournalImport.layout(paths: Array(Self.files().keys)))
        #expect(layout.root == "AppleJournalEntries/")
        #expect(layout.entryPaths.count == 3)
        #expect(layout.resourcePaths.contains("AppleJournalEntries/Resources/PH-1.heic"))
        #expect(AppleJournalImport.layout(paths: ["notes/a.md", "b.html"]) == nil)
        // Unwrapped export (Entries/ at the top level).
        #expect(AppleJournalImport.layout(paths: ["Entries/2025-01-01.html"])?.root == "")
    }

    @Test func buildsRecordsWithDatesPlacesMoodsAndSafeAttachments() throws {
        let files = Self.files()
        let layout = try #require(AppleJournalImport.layout(paths: Array(files.keys)))
        let result = AppleJournalImport.records(layout: layout, read: { files[$0] }, calendar: Self.utc,
                                                headerLocales: [Locale(identifier: "en_US_POSIX")])
        #expect(result.skipped == 1)
        #expect(result.entries.count == 2)
        let walk = result.entries[0]
        #expect(walk.title == "Evening walk")
        // Photo sidecar time (787518000 = 2025-12-15 19:00 UTC) on the header's day.
        #expect(walk.createdAt == Date(timeIntervalSinceReferenceDate: 787_518_000))
        #expect(walk.mood == 5)
        #expect(walk.attachmentPaths == ["AppleJournalEntries/Resources/PH-1.heic"])
        let (stamp, rest) = PlaceStampCodec.split(walk.body)
        #expect(rest == "Cold but *lovely*.\n\nState of mind: Very Pleasant")
        #expect(stamp?.location == "Hyde Park")
        #expect(stamp?.coordinate == PlaceCoordinate(latitude: 51.5073, longitude: -0.1657))
        // The editor's stamp reader still sees the place name.
        #expect(EntryStampCodec.split(walk.body).stamp?.location == "Hyde Park")

        let second = result.entries[1]
        #expect(second.title == "")
        // No sidecar: noon + same-day index minutes, in the given calendar.
        let noon = Self.utc.date(from: DateComponents(year: 2025, month: 12, day: 16, hour: 12, minute: 2))
        #expect(second.createdAt == noon)
        #expect(second.mood == nil)
    }

    @Test func sourceIdsAreStableAndContentSensitive() throws {
        let files = Self.files()
        let layout = try #require(AppleJournalImport.layout(paths: Array(files.keys)))
        let a = AppleJournalImport.records(layout: layout, read: { files[$0] }, calendar: Self.utc)
        let b = AppleJournalImport.records(layout: layout, read: { files[$0] }, calendar: Self.utc)
        #expect(a.entries.map(\.sourceId) == b.entries.map(\.sourceId))
        let ids = a.entries.compactMap(\.sourceId)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
        let other = AppleJournalImport.sourceId(day: DateComponents(year: 2025, month: 12, day: 15), title: "Evening walk",
                                                body: "Different", assets: [])
        #expect(!ids.contains(other))
    }

    @Test func resourcePathsNeverLeaveResources() throws {
        let layout = AppleJournalLayout(root: "X/", entryPaths: ["X/Entries/a.html"],
                                        resourcePaths: ["X/Resources/ok.jpg", "X/Resources/ID-9.mov", "X/Resources/ID-9.json"])
        func asset(_ src: String?, id: String = "") -> AppleJournalAsset {
            AppleJournalAsset(id: id, kind: .photo, source: src, caption: "", header: "", href: nil)
        }
        #expect(AppleJournalImport.resourcePath(for: asset("../Resources/ok.jpg"), pagePath: "X/Entries/a.html", layout: layout) == "X/Resources/ok.jpg")
        #expect(AppleJournalImport.resourcePath(for: asset("../../secret.jpg"), pagePath: "X/Entries/a.html", layout: layout) == nil)
        #expect(AppleJournalImport.resourcePath(for: asset("/etc/passwd"), pagePath: "X/Entries/a.html", layout: layout) == nil)
        #expect(AppleJournalImport.resourcePath(for: asset("file:///etc/passwd"), pagePath: "X/Entries/a.html", layout: layout) == nil)
        // Fallback by asset id, never picking the JSON sidecar.
        #expect(AppleJournalImport.resourcePath(for: asset(nil, id: "ID-9"), pagePath: "X/Entries/a.html", layout: layout) == "X/Resources/ID-9.mov")
    }
}

@Suite("W1Int Apple Journal zip")
struct W1IntAppleJournalZipTests {
    @Test func readsBackOurOwnZip() throws {
        var w = EPUBZipWriter()
        let big = Data(String(repeating: "journal ", count: 2_000).utf8)
        try w.add("AppleJournalEntries/Entries/2025-01-01.html", big)
        try w.add("AppleJournalEntries/Resources/a.jpg", Data([0xFF, 0xD8, 0xFF]), method: .stored)
        let zip = try AppleJournalZipReader(data: try w.finish())
        let files = zip.filesByName
        #expect(files.count == 2)
        let page = try #require(files["AppleJournalEntries/Entries/2025-01-01.html"])
        #expect(page.method == 8)
        #expect(try zip.contents(of: page) == big)
        #expect(try zip.contents(of: #require(files["AppleJournalEntries/Resources/a.jpg"])) == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test func detectsCorruptionAndNonZips() throws {
        #expect(throws: AppleJournalZipError.notAZip) { try AppleJournalZipReader(data: Data("hello".utf8)) }
        var w = EPUBZipWriter()
        try w.add("a.txt", Data("abc".utf8), method: .stored)
        var data = try w.finish()
        // Flip a payload byte: header says "abc", CRC must catch it.
        let payloadOffset = 30 + "a.txt".utf8.count
        data[payloadOffset] = UInt8(ascii: "x")
        let zip = try AppleJournalZipReader(data: data)
        #expect(throws: AppleJournalZipError.self) { try zip.contents(of: zip.entries[0]) }
    }

    @Test func normalizesHostileNames() {
        #expect(AppleJournalZipReader.normalize("a/./b//c") == "a/b/c")
        #expect(AppleJournalZipReader.normalize("../../etc/passwd") == "")
        #expect(AppleJournalZipReader.normalize("/abs/x") == "abs/x")
        #expect(AppleJournalZipReader.normalize("a\\..\\b") == "b")
        #expect(AppleJournalZipReader.isFinderJunk("__MACOSX/x"))
        #expect(AppleJournalZipReader.isFinderJunk("A/._x.html"))
    }

    /// Finder's "Compress" uses the same engine as `ditto -c -k`.
    @Test func readsAFinderStyleArchive() throws {
        let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
        guard FileManager.default.isExecutableFile(atPath: ditto.path) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("w1int-zip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let export = tmp.appendingPathComponent("AppleJournalEntries", isDirectory: true)
        try FileManager.default.createDirectory(at: export.appendingPathComponent("Entries"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: export.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let html = W1IntJournalFixture.page(body: String(repeating: "<p>Words words words.</p>", count: 50))
        try Data(html.utf8).write(to: export.appendingPathComponent("Entries/2025-12-15_Evening_walk.html"))
        try Data([1, 2, 3, 4]).write(to: export.appendingPathComponent("Resources/PH-1.heic"))
        let zipURL = tmp.appendingPathComponent("AppleJournalEntries.zip")
        let p = Process()
        p.executableURL = ditto
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", export.path, zipURL.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let zip = try AppleJournalZipReader(data: Data(contentsOf: zipURL))
        let layout = try #require(AppleJournalImport.layout(paths: Array(zip.filesByName.keys)))
        #expect(layout.entryPaths == ["AppleJournalEntries/Entries/2025-12-15_Evening_walk.html"])
        let page = try #require(zip.filesByName[layout.entryPaths[0]])
        #expect(String(decoding: try zip.contents(of: page), as: UTF8.self) == html)
    }
}
