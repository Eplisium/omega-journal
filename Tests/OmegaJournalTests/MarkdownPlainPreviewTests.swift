import Testing
import OmegaJournalCore

@Suite("Markdown plain preview")
struct MarkdownPlainPreviewTests {
    @Test("headings, bullets, tasks and quotes lose their syntax")
    func blocks() {
        let md = """
        ## Gratitude
        - One thing that went well
        - [ ] Call mom
        - [x] Walk
        > A quote worth keeping
        ---
        1. Numbered stays numbered
        """
        #expect(MarkdownPlainPreview.lines(md, limit: 10) == [
            "Gratitude",
            "• One thing that went well",
            "☐ Call mom",
            "☑ Walk",
            "A quote worth keeping",
            "1. Numbered stays numbered",
        ])
    }

    @Test("inline emphasis, code and links collapse to their text")
    func inline() {
        #expect(MarkdownPlainPreview.text("**Bold** and *it* with `code`, [link](https://x.y) and [[Wiki Page]]")
                == "Bold and it with code, link and Wiki Page")
        // Snake_case words and lone asterisks are left alone.
        #expect(MarkdownPlainPreview.text("my_var_name costs 2 * 3") == "my_var_name costs 2 * 3")
    }

    @Test("empty bullets and blank lines are skipped and the limit is honoured")
    func limitAndEmpties() {
        let md = "# A\n\n- \n- [ ] \nB\nC\nD"
        #expect(MarkdownPlainPreview.lines(md, limit: 3) == ["A", "B", "C"])
        #expect(MarkdownPlainPreview.lines("", limit: 3).isEmpty)
    }
}
