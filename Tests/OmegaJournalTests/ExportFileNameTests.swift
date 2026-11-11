import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// core-7: export file-name de-duplication must never reuse a name.
@Suite("Unique export file names")
@MainActor
struct ExportFileNameTests {
    @Test("core-7 a generated suffix never collides with a real stem")
    func suffixSkipsTakenNames() {
        let names = ExportFormats.uniqueNames(["2026-03-01 Note", "2026-03-01 Note 2", "2026-03-01 Note"])
        #expect(names == ["2026-03-01 Note", "2026-03-01 Note 2", "2026-03-01 Note 3"])
        let later = ExportFormats.uniqueNames(["A", "A", "A 2", "A 3", "A"])
        #expect(Set(later.map { $0.lowercased() }).count == later.count, "\(later)")
        #expect(later == ["A", "A 2", "A 2 2", "A 3", "A 4"])
    }

    @Test("core-7 names are unique ignoring case and Unicode normalisation (APFS)")
    func caseAndNormalisation() {
        let names = ExportFormats.uniqueNames(["Note", "NOTE", "note 2", "Caf\u{E9}", "Cafe\u{301}"])
        let keys = names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        #expect(Set(keys).count == names.count, "\(names)")
        #expect(names[0] == "Note" && names[1] == "NOTE 2" && names[2] == "note 2 2")
        #expect(names[3] == "Caf\u{E9}" && names[4] == "Cafe\u{301} 2")
    }

    @Test("core-7 existing de-duplication is unchanged")
    func unchangedBehaviour() {
        #expect(ExportFormats.uniqueNames(["a", "a", "a"]) == ["a", "a 2", "a 3"])
        #expect(ExportFormats.uniqueNames(["x", "y"]) == ["x", "y"])
        #expect(ExportFormats.uniqueNames([]).isEmpty)
    }

    private func entries(_ titles: [String]) -> [JournalEntry] {
        let day = Date(timeIntervalSince1970: 1_772_366_400) // 2026-03-01 12:00 UTC
        return titles.map { t in
            var e = JournalEntry.new(); e.title = t; e.body = "body of \(t) \(UUID().uuidString)"; e.createdAt = day
            return e
        }
    }

    @Test("core-7 markdown folder export writes one file per entry; every body survives")
    func markdownFolderKeepsEveryEntry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-fixcore-md-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = entries(["Note", "Note 2", "Note"])
        let n = try ExportManager.exportMarkdownFolder(list, to: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") }
        #expect(n == 3)
        #expect(files.count == 3, "only \(files.count) files written: \(files)")
        let text = try files.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }.joined()
        for e in list { #expect(text.contains(e.body)) }
    }

    @Test("core-7 HTML site export writes one page per entry")
    func htmlSiteKeepsEveryEntry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-fixcore-html-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = entries(["Note", "Note 2", "Note"])
        _ = try ExportManager.exportHTMLSite(list, to: dir)
        let pages = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("entries").path)
            .filter { $0.hasSuffix(".html") }
        #expect(pages.count == 3, "\(pages)")
    }
}
