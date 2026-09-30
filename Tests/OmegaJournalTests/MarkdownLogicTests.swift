import Testing
import Foundation
@testable import OmegaJournalCore

@Suite("Markdown logic: list continuation")
struct MarkdownListContinuationTests {
    @Test("bullet keeps its marker character")
    func bulletMarkerPreserved() {
        #expect(MarkdownLogic.listContext(forLine: "* item")?.nextPrefix == "* ")
        #expect(MarkdownLogic.listContext(forLine: "+ item")?.nextPrefix == "+ ")
        #expect(MarkdownLogic.listContext(forLine: "  - item")?.nextPrefix == "  - ")
    }

    @Test("ordered continues numbering and delimiter")
    func ordered() {
        #expect(MarkdownLogic.listContext(forLine: "3. three")?.nextPrefix == "4. ")
        #expect(MarkdownLogic.listContext(forLine: "  9) nine")?.nextPrefix == "  10) ")
    }

    @Test("task continues as unchecked")
    func task() {
        #expect(MarkdownLogic.listContext(forLine: "- [x] done")?.nextPrefix == "- [ ] ")
        #expect(MarkdownLogic.listContext(forLine: "  - [ ] sub")?.nextPrefix == "  - [ ] ")
    }

    @Test("empty item detected by UTF-16 marker length, even with emoji content elsewhere")
    func emptyItems() {
        #expect(MarkdownLogic.listContext(forLine: "- ")?.isEmptyItem == true)
        #expect(MarkdownLogic.listContext(forLine: "- [ ] ")?.isEmptyItem == true)
        #expect(MarkdownLogic.listContext(forLine: "12. ")?.isEmptyItem == true)
        #expect(MarkdownLogic.listContext(forLine: "- 👨‍👩‍👧")?.isEmptyItem == false)
        #expect(MarkdownLogic.listContext(forLine: "> - 😀")?.markerLength == 4)
    }

    @Test("empty indented item outdents instead of clearing")
    func emptyIndentedExit() {
        #expect(MarkdownLogic.listContext(forLine: "  - ")?.exitLine == "- ")
        #expect(MarkdownLogic.listContext(forLine: "- ")?.exitLine == "")
    }

    @Test("nested blockquotes continue and exit one level")
    func nestedQuote() {
        #expect(MarkdownLogic.listContext(forLine: "> > deep")?.nextPrefix == "> > ")
        #expect(MarkdownLogic.listContext(forLine: "> > ")?.isEmptyItem == true)
        #expect(MarkdownLogic.listContext(forLine: "> > ")?.exitLine == "> ")
        #expect(MarkdownLogic.listContext(forLine: "> quote")?.nextPrefix == "> ")
        #expect(MarkdownLogic.listContext(forLine: "> ")?.exitLine == "")
    }

    @Test("list inside a quote")
    func listInQuote() {
        #expect(MarkdownLogic.listContext(forLine: "> - a")?.nextPrefix == "> - ")
    }

    @Test("plain text is not a list")
    func plain() {
        #expect(MarkdownLogic.listContext(forLine: "hello") == nil)
        #expect(MarkdownLogic.listContext(forLine: "**bold**") == nil)
        #expect(MarkdownLogic.listContext(forLine: "-5 degrees") == nil)
    }

    @Test("renumbering after inserting an ordered item")
    func renumber() throws {
        let text = "1. a\n2. b\n2. c\n3. d\nplain"
        let edit = try #require(MarkdownLogic.renumberEdit(in: text, fromLine: 1))
        let ns = text as NSString
        #expect(ns.replacingCharacters(in: edit.range, with: edit.replacement) == "1. a\n2. b\n3. c\n4. d\nplain")
    }

    @Test("renumbering skips nested items and stops at other content")
    func renumberNested() throws {
        let text = "1. a\n1. x\n   - n\n1. y\n\n1. z"
        let edit = try #require(MarkdownLogic.renumberEdit(in: text, fromLine: 0))
        let out = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(out == "1. a\n2. x\n   - n\n3. y\n\n1. z")
    }

    @Test("renumber returns nil when already consistent")
    func renumberNoop() {
        #expect(MarkdownLogic.renumberEdit(in: "1. a\n2. b\n3. c", fromLine: 0) == nil)
    }
}

@Suite("Markdown logic: indent, tasks, counting")
struct MarkdownIndentTaskTests {
    @Test("indent and outdent")
    func indent() {
        #expect(MarkdownLogic.indentLine("- a") == "  - a")
        #expect(MarkdownLogic.indentLine("") == "")
        #expect(MarkdownLogic.outdent("  - a") == "- a")
        #expect(MarkdownLogic.outdent("\t- a") == "- a")
        #expect(MarkdownLogic.outdent(" - a") == "- a")
        #expect(MarkdownLogic.outdent("- a") == "- a")
        #expect(MarkdownLogic.shiftBlock("- a\n- b\n", outdenting: false) == "  - a\n  - b\n")
        #expect(MarkdownLogic.shiftBlock("  - a\n- b", outdenting: true) == "- a\n- b")
    }

    @Test("toggle task")
    func toggle() {
        #expect(MarkdownLogic.toggledTask("- [ ] a") == "- [x] a")
        #expect(MarkdownLogic.toggledTask("  * [X] a") == "  * [ ] a")
        #expect(MarkdownLogic.toggledTask("- a") == nil)
    }

    @Test("checklist command cycles lines")
    func cycle() {
        #expect(MarkdownLogic.cycledTaskLine("- [ ] a") == "- [x] a")
        #expect(MarkdownLogic.cycledTaskLine("- a") == "- [ ] a")
        #expect(MarkdownLogic.cycledTaskLine("plain") == "- [ ] plain")
    }

    @Test("toggling a task in a body skips code fences")
    func bodyToggle() {
        let body = "```\n- [ ] not a task\n```\n- [ ] real"
        #expect(MarkdownLogic.togglingTask(inBody: body, lineIndex: 1) == nil)
        #expect(MarkdownLogic.togglingTask(inBody: body, lineIndex: 3) == "```\n- [ ] not a task\n```\n- [x] real")
    }

    @Test("task URL round trip")
    func taskURL() throws {
        let url = try #require(MarkdownLogic.taskURL(line: 7))
        #expect(MarkdownLogic.taskLine(from: url) == 7)
        #expect(MarkdownLogic.taskLine(from: URL(string: "https://x.com/7")!) == nil)
    }

    @Test("word count handles whitespace, newlines and unicode")
    func words() {
        #expect(MarkdownLogic.wordCount("") == 0)
        #expect(MarkdownLogic.wordCount("  a  b\n\nc\t d ") == 4)
        #expect(MarkdownLogic.wordCount("héllo wörld 😀") == 3)
    }

    @Test("line index by utf16 offset")
    func lineIndex() {
        #expect(MarkdownLogic.lineIndex(ofUTF16Offset: 0, in: "a\nb\nc") == 0)
        #expect(MarkdownLogic.lineIndex(ofUTF16Offset: 2, in: "a\nb\nc") == 1)
        #expect(MarkdownLogic.lineIndex(ofUTF16Offset: 5, in: "a\nb\nc") == 2)
    }

    @Test("contrast picks readable text color")
    func contrast() {
        #expect(MarkdownLogic.prefersDarkText(onRed: 1, green: 1, blue: 0) == true)
        #expect(MarkdownLogic.prefersDarkText(onRed: 0.3, green: 0.2, blue: 0.7) == false)
    }

    @Test("tag suggestions are prefix matched, exclude existing, capped")
    func tags() {
        let all = ["work", "Workout", "life", "wonder", "war", "web", "wax", "wow"]
        #expect(MarkdownLogic.tagSuggestions(prefix: "#wo", from: all, excluding: ["work"]) == ["Workout", "wonder", "wow"])
        #expect(MarkdownLogic.tagSuggestions(prefix: "", from: all, excluding: []).isEmpty)
        #expect(MarkdownLogic.tagSuggestions(prefix: "w", from: all, excluding: [], limit: 2).count == 2)
    }
}

@Suite("Markdown logic: block parsing")
struct MarkdownBlockParsingTests {
    @Test("fenced code blocks, including unterminated and tilde fences")
    func fences() {
        let blocks = MarkdownLogic.parseBlocks("a\n```swift\nlet x = 1\n# not heading\n```\nb")
        #expect(blocks.map(\.block) == [
            .paragraph(text: "a"),
            .codeFence(language: "swift", lines: ["let x = 1", "# not heading"]),
            .paragraph(text: "b"),
        ])
        let open = MarkdownLogic.parseBlocks("~~~\ncode\nmore")
        #expect(open.map(\.block) == [.codeFence(language: "", lines: ["code", "more"])])
    }

    @Test("code block ranges are UTF-16 and cover fences")
    func ranges() {
        let text = "😀\n```\nx\n```\nend"
        let r = MarkdownLogic.codeBlockRanges(in: text)
        #expect(r.count == 1)
        #expect((text as NSString).substring(with: r[0]) == "```\nx\n```\n")
    }

    @Test("lists: nested, ordered with paren, tasks")
    func lists() {
        let blocks = MarkdownLogic.parseBlocks("- a\n  - b\n1) one\n- [x] done\n    * [ ] deep").map(\.block)
        #expect(blocks == [
            .bullet(level: 0, text: "a"),
            .bullet(level: 1, text: "b"),
            .ordered(level: 0, number: "1", delimiter: ")", text: "one"),
            .task(level: 0, done: true, text: "done"),
            .task(level: 2, done: false, text: "deep"),
        ])
    }

    @Test("horizontal rules incl. spaced and not confused with bullets")
    func rules() {
        #expect(MarkdownLogic.parseBlocks("---").map(\.block) == [.rule])
        #expect(MarkdownLogic.parseBlocks("* * *").map(\.block) == [.rule])
        #expect(MarkdownLogic.parseBlocks("- a").map(\.block) == [.bullet(level: 0, text: "a")])
    }

    @Test("headings, nested quotes")
    func headingsQuotes() {
        #expect(MarkdownLogic.parseBlocks("## Hi ##").map(\.block) == [.heading(level: 2, text: "Hi")])
        #expect(MarkdownLogic.parseBlocks("####### x").map(\.block) == [.paragraph(text: "####### x")])
        #expect(MarkdownLogic.parseBlocks("> > deep").map(\.block) == [.quote(depth: 2, text: "deep")])
    }

    @Test("simple tables with alignment and short rows")
    func tables() {
        let blocks = MarkdownLogic.parseBlocks("| a | b |\n|:--|--:|\n| 1 | 2 |\n| 3 |\nafter").map(\.block)
        #expect(blocks == [
            .table(header: ["a", "b"], alignments: [.leading, .trailing], rows: [["1", "2"], ["3", ""]]),
            .paragraph(text: "after"),
        ])
        #expect(MarkdownLogic.parseBlocks("a | b\nnot table").map(\.block) == [.paragraph(text: "a | b"), .paragraph(text: "not table")])
    }

    @Test("link validation")
    func links() {
        #expect(MarkdownLogic.safeLinkURL("https://example.com/a") != nil)
        #expect(MarkdownLogic.safeLinkURL("mailto:a@b.co") != nil)
        #expect(MarkdownLogic.safeLinkURL("url") == nil)
        #expect(MarkdownLogic.safeLinkURL("") == nil)
        #expect(MarkdownLogic.safeLinkURL("javascript:alert(1)") == nil)
        #expect(MarkdownLogic.safeLinkURL("file:///etc/passwd") == nil)
        #expect(MarkdownLogic.safeLinkURL("https://") == nil)
    }
}
