import Testing
import Foundation
@testable import OmegaJournalCore

@Suite("Wiki link syntax")
struct WikiLinkLogicTests {
    @Test("finds simple and aliased links with UTF-16 ranges")
    func basic() {
        let text = "See [[Trip to Rome]] and [[Rome|the city]] ok"
        let links = MarkdownLogic.wikiLinks(in: text)
        #expect(links.map(\.title) == ["Trip to Rome", "Rome"])
        #expect(links.map(\.alias) == [nil, "the city"])
        #expect(links.map(\.displayText) == ["Trip to Rome", "the city"])
        #expect((text as NSString).substring(with: links[0].range) == "[[Trip to Rome]]")
    }

    @Test("ranges stay correct after emoji (UTF-16)")
    func utf16() {
        let text = "🙂🙂 [[Day]]"
        let l = MarkdownLogic.wikiLinks(in: text)
        #expect(l.count == 1)
        #expect((text as NSString).substring(with: l[0].range) == "[[Day]]")
    }

    @Test("ignores fenced code, inline code, escaped, empty and multi-line links")
    func exclusions() {
        let text = """
        ```
        [[InFence]]
        ```
        `[[Inline]]` [[Real]] \\[[Escaped]] [[ ]] [[a
        b]] [[|alias]]
        """
        #expect(MarkdownLogic.wikiLinks(in: text).map(\.title) == ["Real"])
    }

    @Test("within: only returns links inside the given range")
    func within() {
        let text = "[[A]]\n[[B]]\n[[C]]"
        let ns = text as NSString
        let r = ns.lineRange(for: NSRange(location: 6, length: 0))
        #expect(MarkdownLogic.wikiLinks(in: text, within: r).map(\.title) == ["B"])
    }

    @Test("URL round trip preserves slashes, unicode and percent signs")
    func urls() throws {
        for title in ["Trip", "A/B", "Café ☕ 100%", "a b&c?d#e"] {
            let url = try #require(MarkdownLogic.wikiLinkURL(title: title))
            #expect(url.scheme == "omega-entry")
            #expect(MarkdownLogic.wikiLinkTitle(from: url) == title)
        }
        #expect(MarkdownLogic.wikiLinkTitle(from: URL(string: "https://x.com/a")!) == nil)
        #expect(MarkdownLogic.wikiLinkTitle(from: URL(string: "omega-task://toggle/3")!) == nil)
    }

    @Test("completion context after [[ up to caret")
    func completion() {
        let t = "hi [[Tri]]"
        let ctx = MarkdownLogic.wikiCompletionContext(in: t, caret: 8)
        #expect(ctx?.query == "Tri")
        #expect(ctx?.range == NSRange(location: 5, length: 3))
        #expect(MarkdownLogic.wikiCompletionContext(in: "hi [[Tri]] x", caret: 12) == nil)
        #expect(MarkdownLogic.wikiCompletionContext(in: "[[a|b", caret: 5) == nil)
        #expect(MarkdownLogic.wikiCompletionContext(in: "[[a\nb", caret: 5) == nil)
        #expect(MarkdownLogic.wikiCompletionContext(in: "[[", caret: 2)?.query == "")
    }

    @Test("title suggestions: prefix first, then contains, deduped, capped")
    func suggestions() {
        let titles = ["Rome trip", "Roman notes", "Trip to Rome", "", "rome trip", "Other"]
        #expect(MarkdownLogic.wikiTitleSuggestions(query: "rom", from: titles) == ["Rome trip", "Roman notes", "Trip to Rome"])
        #expect(MarkdownLogic.wikiTitleSuggestions(query: "", from: titles, limit: 2) == ["Rome trip", "Roman notes"])
        #expect(MarkdownLogic.wikiTitleSuggestions(query: "zzz", from: titles).isEmpty)
    }
}
