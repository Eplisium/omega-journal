import Testing
import AppKit
import SwiftUI
@testable import OmegaJournal

@Suite("Markdown renderer")
@MainActor
struct MarkdownRendererTests {
    private func text(_ md: String, style: MarkdownRenderStyle = .default) -> String {
        String(MarkdownRenderer.render(md, style: style).characters)
    }

    @Test("task list renders checkbox glyphs with strikethrough when done")
    func tasks() {
        let out = MarkdownRenderer.render("- [ ] open\n- [x] done")
        let s = String(out.characters)
        #expect(s.contains("\u{2610}") && s.contains("\u{2611}"))
        let struck = out.runs.filter { $0.strikethroughStyle != nil }.map { String(out.characters[$0.range]) }
        #expect(struck == ["done"])
    }

    @Test("interactive tasks carry a toggle link with the source line")
    func interactive() {
        let out = MarkdownRenderer.render("intro\n- [ ] a", style: MarkdownRenderStyle(interactiveTasks: true))
        let links = out.runs.compactMap(\.link)
        #expect(links.count == 1)
        #expect(MarkdownLogic_taskLine(links[0]) == 1)
    }

    @Test("fenced code is not inline-parsed")
    func fence() {
        #expect(text("```\n**not bold** # nope\n```") == "**not bold** # nope")
    }

    @Test("strikethrough, underscore italics and bold")
    func inline() {
        let out = MarkdownRenderer.render("~~gone~~ _it_ **b**")
        #expect(String(out.characters) == "gone it b")
        #expect(out.runs.contains { $0.strikethroughStyle != nil })
    }

    @Test("invalid link destinations are not linked; valid ones are")
    func links() {
        #expect(MarkdownRenderer.render("[x](url)").runs.allSatisfy { $0.link == nil })
        #expect(MarkdownRenderer.render("[x](javascript:alert(1))").runs.allSatisfy { $0.link == nil })
        #expect(MarkdownRenderer.render("[x](https://example.com)").runs.contains { $0.link != nil })
    }

    @Test("bare URLs autolink")
    func autolink() {
        let out = MarkdownRenderer.render("see https://example.com/a now")
        let linked = out.runs.filter { $0.link != nil }.map { String(out.characters[$0.range]) }
        #expect(linked == ["https://example.com/a"])
    }

    @Test("nested and 1) lists keep their text")
    func lists() {
        let s = text("- a\n  - b\n1) c")
        #expect(s.contains("a") && s.contains("b") && s.contains("1) c"))
        #expect(s.components(separatedBy: "\n").count == 3)
    }

    @Test("table renders aligned rows")
    func table() {
        let lines = text("| a | bb |\n|---|---|\n| 1 | 2 |").components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(Set(lines.map(\.count)).count == 1)
    }

    @Test("horizontal rule is bounded and long documents render quickly")
    func rulesAndPerf() {
        #expect(text("---").count <= 40)
        let big = String(repeating: "Lorem **ipsum** dolor `sit` amet, https://example.com consectetur.\n", count: 3000)
        let start = Date()
        _ = MarkdownRenderer.render(big)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test("blank lines are preserved")
    func blanks() {
        #expect(text("a\n\nb") == "a\n\nb")
    }
}

private func MarkdownLogic_taskLine(_ url: URL) -> Int? {
    url.scheme == "omega-task" ? Int(url.lastPathComponent) : nil
}

@Suite("Markdown editor commands")
@MainActor
struct MarkdownEditorCommandTests {
    private func makeView(_ text: String, selection: NSRange) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        tv.string = text
        tv.setSelectedRange(selection)
        return tv
    }

    @Test("toggleTask converts a bullet, then toggles done")
    func toggleTask() {
        let tv = makeView("- item", selection: NSRange(location: 0, length: 0))
        tv.applyMarkdownCommand(.toggleTask)
        #expect(tv.string == "- [ ] item")
        tv.applyMarkdownCommand(.toggleTask)
        #expect(tv.string == "- [x] item")
        tv.applyMarkdownCommand(.toggleTask)
        #expect(tv.string == "- [ ] item")
    }

    @Test("toggleTask works across multiple selected lines and skips blanks")
    func toggleMulti() {
        let tv = makeView("a\n\nb", selection: NSRange(location: 0, length: 4))
        tv.applyMarkdownCommand(.toggleTask)
        #expect(tv.string == "- [ ] a\n\n- [ ] b")
    }
}
