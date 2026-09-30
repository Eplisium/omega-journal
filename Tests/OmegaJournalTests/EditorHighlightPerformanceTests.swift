import Testing
import AppKit
import SwiftUI
import OmegaJournalCore
@testable import OmegaJournal

@Suite("Editor highlighting performance", .serialized)
@MainActor
struct EditorHighlightPerformanceTests {
    /// ~200KB markdown with headings, lists, code fences, links and wiki links.
    static func bigDocument() -> String {
        var s = ""
        var i = 0
        while s.utf8.count < 200_000 {
            s += "# Section \(i)\n\nSome *emphasis* and **bold** text with [[Note \(i)]] and #tag\(i) and `code`.\n\n"
            s += "- [ ] task \(i)\n- item with [link](https://example.com/\(i))\n\n```swift\nlet x = \(i) // [[not a link]]\n```\n\n"
            i += 1
        }
        return s
    }

    private func makeCoordinator(_ text: String) -> MarkdownTextEditor.Coordinator {
        let editor = MarkdownTextEditor(text: .constant(text), font: .systemFont(ofSize: 14),
                                        controller: MarkdownEditorController())
        return MarkdownTextEditor.Coordinator(editor)
    }

    @Test("typing in the middle restyles only the edited paragraph")
    func incremental() {
        let doc = Self.bigDocument()
        let storage = NSTextStorage(string: doc)
        let c = makeCoordinator(doc)
        c.highlightNow(storage)
        #expect(c.lastHighlightRange == NSRange(location: 0, length: storage.length))

        // Insert a character in the middle of a plain paragraph.
        let ns = storage.string as NSString
        let mid = ns.range(of: "Some *emphasis*", options: [], range: NSRange(location: storage.length / 2, length: storage.length / 2 - 1))
        #expect(mid.location != NSNotFound)
        c.noteEdit(range: NSRange(location: mid.location + 4, length: 0), replacementLength: 1)
        storage.replaceCharacters(in: NSRange(location: mid.location + 4, length: 0), with: "x")

        let start = Date()
        c.highlightNow(storage)
        let elapsed = Date().timeIntervalSince(start)
        let r = try! #require(c.lastHighlightRange)
        #expect(r.length < 400, "restyled \(r.length) chars")
        #expect(r.length > 0)
        #expect(elapsed < 0.25, "incremental pass took \(elapsed)s")
    }

    @Test("adding a code fence forces a full pass; plain edits do not")
    func fenceForcesFull() {
        let doc = "intro\n\n```\ncode\n```\n\nafter"
        let storage = NSTextStorage(string: doc)
        let c = makeCoordinator(doc)
        c.highlightNow(storage)
        // Break the closing fence.
        let loc = (doc as NSString).range(of: "```\n\nafter").location
        c.noteEdit(range: NSRange(location: loc, length: 3), replacementLength: 0)
        storage.replaceCharacters(in: NSRange(location: loc, length: 3), with: "")
        c.highlightNow(storage)
        #expect(c.lastHighlightRange == NSRange(location: 0, length: storage.length))
    }

    @Test("code-range scan and wiki-link scan on 200KB are fast and linear")
    func pureScans() {
        let doc = Self.bigDocument()
        let t0 = Date()
        let ranges = MarkdownLogic.codeBlockRanges(in: doc)
        let t1 = Date()
        let links = MarkdownLogic.wikiLinks(in: doc)
        let t2 = Date()
        #expect(!ranges.isEmpty)
        #expect(!links.isEmpty)
        #expect(links.allSatisfy { $0.title.hasPrefix("Note ") })   // none from fences
        #expect(t1.timeIntervalSince(t0) < 0.5, "codeBlockRanges \(t1.timeIntervalSince(t0))s")
        #expect(t2.timeIntervalSince(t1) < 1.0, "wikiLinks \(t2.timeIntervalSince(t1))s")
    }

    @Test("range containment helper is binary-search correct")
    func intersects() {
        let r = [NSRange(location: 10, length: 5), NSRange(location: 30, length: 10), NSRange(location: 100, length: 1)]
        #expect(MarkdownLogic.intersectsAny(NSRange(location: 12, length: 1), sortedRanges: r))
        #expect(MarkdownLogic.intersectsAny(NSRange(location: 0, length: 11), sortedRanges: r))
        #expect(MarkdownLogic.intersectsAny(NSRange(location: 39, length: 5), sortedRanges: r))
        #expect(!MarkdownLogic.intersectsAny(NSRange(location: 15, length: 15), sortedRanges: r))
        #expect(!MarkdownLogic.intersectsAny(NSRange(location: 101, length: 5), sortedRanges: r))
        #expect(!MarkdownLogic.intersectsAny(NSRange(location: 0, length: 5), sortedRanges: []))
    }
}
