import Testing
import SwiftUI
import OmegaJournalCore
@testable import OmegaJournal

@Suite("Markdown renderer: wiki links, images, fonts")
@MainActor
struct MarkdownWikiRenderTests {
    private func plain(_ a: AttributedString) -> String { String(a.characters) }

    @Test("wiki links render as omega-entry links, brackets removed, alias shown")
    func links() {
        let out = MarkdownRenderer.render("Go to [[Trip to Rome]] or [[Rome|the city]].")
        #expect(plain(out) == "Go to Trip to Rome or the city.")
        let urls = out.runs.compactMap(\.link)
        #expect(urls.compactMap { MarkdownLogic.wikiLinkTitle(from: $0) } == ["Trip to Rome", "Rome"])
    }

    @Test("unresolved links are muted, resolved use link color")
    func unresolved() {
        var style = MarkdownRenderStyle(linkColor: .red, mutedColor: .gray)
        style.resolvedLinkTitles = ["known"]
        let out = MarkdownRenderer.render("[[Known]] [[Missing]]", style: style)
        let colors = out.runs.filter { $0.link != nil }.map { $0.foregroundColor }
        #expect(colors.count == 2)
        #expect(colors[0] == .red)
        #expect(colors[1] != .red)
    }

    @Test("code spans and fences keep literal [[ ]]")
    func code() {
        let out = MarkdownRenderer.render("`[[x]]` and\n```\n[[y]]\n```")
        #expect(plain(out).contains("[[x]]") && plain(out).contains("[[y]]"))
        #expect(out.runs.compactMap(\.link).isEmpty)
    }

    @Test("links work inside table cells")
    func table() {
        let segs = MarkdownRenderer.renderSegments("| a |\n|---|\n| [[Note]] |")
        guard case let .table(_, _, _, rows) = segs[0] else { Issue.record("no table"); return }
        #expect(plain(rows[0][0]) == "Note")
        #expect(rows[0][0].runs.compactMap(\.link).count == 1)
    }

    @Test("images show a muted placeholder and never a remote link")
    func images() {
        let out = MarkdownRenderer.render("![a cat](https://evil.example/cat.png) text ![](x.png)")
        #expect(plain(out) == "[image: a cat] text [image]")
        #expect(out.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
    }

    @Test("font design threads through the style")
    func fontDesign() {
        for (name, d) in [("serif", Font.Design.serif), ("default", .default), ("rounded", .rounded), ("mono", .monospaced)] {
            #expect(MarkdownRenderStyle.fontDesign(named: name) == d)
        }
        #expect(MarkdownRenderStyle.fontDesign(named: "bogus") == .serif)
        var style = MarkdownRenderStyle.default
        #expect(style.fontDesign == .serif)
        style.fontDesign = .monospaced
        let out = MarkdownRenderer.render("hello", style: style)
        #expect(out.runs.first?.font == Font.system(size: 16, weight: .regular, design: .monospaced))
    }
}
