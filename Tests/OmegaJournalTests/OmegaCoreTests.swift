import Testing
@testable import OmegaJournalCore

// Covers the pure logic behind search, import, the command palette, and the
// markdown formatting commands. No database, no AppKit, no app instance.

// MARK: - FTS sanitization

@Suite("FTS query sanitization")
struct FTSSanitizationTests {

    /// The original bug: these all threw `OperationalError` when passed raw to
    /// FTS5 MATCH. They must now produce a valid, quoted expression.
    @Test("punctuation and bare keywords survive", arguments: [
        "he-man", "quote\"inside", "AND", "OR", "NOT",
        "trailing-", "-leading", "col:on", "semi;colon", "NEAR(a b)", "^caret",
    ])
    func hostileInputIsTokenized(_ input: String) {
        let result = OmegaCore.sanitizeFTSQuery(input)
        #expect(result != nil, "\(input) should tokenize")
        // Quotes must be balanced or FTS5 will reject the expression.
        #expect(result!.filter { $0 == "\"" }.count % 2 == 0)
        // No bare syntax characters escape the tokenizer.
        #expect(!result!.contains("("))
        #expect(!result!.contains(":"))
        #expect(!result!.contains(";"))
    }

    @Test("untokenizable input returns nil so the caller falls back to LIKE",
          arguments: ["", "   ", "*", "()", "---", "!!!"])
    func emptyTokenSetReturnsNil(_ input: String) {
        #expect(OmegaCore.sanitizeFTSQuery(input) == nil)
    }

    @Test("each token becomes a quoted prefix term")
    func tokensBecomePrefixTerms() {
        #expect(OmegaCore.sanitizeFTSQuery("work") == "\"work\"*")
        #expect(OmegaCore.sanitizeFTSQuery("he-man") == "\"he\"* \"man\"*")
        #expect(OmegaCore.sanitizeFTSQuery("a AND b") == "\"a\"* \"AND\"* \"b\"*")
    }

    @Test("unicode is preserved rather than dropped")
    func unicodeSurvives() {
        // Alphanumerics is unicode-aware, so accented text must not be stripped.
        #expect(OmegaCore.sanitizeFTSQuery("café") == "\"café\"*")
    }
}

// MARK: - Markdown import

@Suite("Markdown import parsing")
struct MarkdownImportTests {

    @Test("a leading H1 becomes the title and is removed from the body")
    func h1BecomesTitle() {
        let r = OmegaCore.parseMarkdownImport(text: "# My Day\n\nIt was good.", fallbackTitle: "file")
        #expect(r.title == "My Day")
        #expect(r.body == "It was good.")
    }

    @Test("without an H1 the fallback title is used and the body is intact")
    func fallbackTitleUsed() {
        let r = OmegaCore.parseMarkdownImport(text: "Just text.", fallbackTitle: "2026-08-10")
        #expect(r.title == "2026-08-10")
        #expect(r.body == "Just text.")
    }

    @Test("a deeper heading is not treated as a title")
    func h2IsNotATitle() {
        let r = OmegaCore.parseMarkdownImport(text: "## Sub\nbody", fallbackTitle: "f")
        #expect(r.title == "f")
        #expect(r.body == "## Sub\nbody")
    }

    @Test("a hashtag without a space is not a heading")
    func hashtagIsNotAHeading() {
        let r = OmegaCore.parseMarkdownImport(text: "#work today", fallbackTitle: "f")
        #expect(r.title == "f")
        #expect(r.body == "#work today")
    }

    @Test("empty and whitespace-only files degrade gracefully")
    func emptyFile() {
        let r = OmegaCore.parseMarkdownImport(text: "", fallbackTitle: "empty")
        #expect(r.title == "empty")
        #expect(r.body == "")

        let w = OmegaCore.parseMarkdownImport(text: "# Title\n\n\n   \n", fallbackTitle: "f")
        #expect(w.title == "Title")
        #expect(w.body == "", "trailing whitespace should be trimmed")
    }

    @Test("an H1 with no body yields an empty body, not the title repeated")
    func titleOnly() {
        let r = OmegaCore.parseMarkdownImport(text: "# Only", fallbackTitle: "f")
        #expect(r.title == "Only")
        #expect(r.body == "")
    }
}

// MARK: - Command palette

@Suite("Command palette fuzzy matching")
struct FuzzyMatchTests {

    @Test("a subsequence matches; a non-subsequence does not")
    func subsequenceSemantics() {
        #expect(OmegaCore.fuzzyScore("nte", "New Template") != nil)
        #expect(OmegaCore.fuzzyScore("cal", "Go to Calendar") != nil)
        #expect(OmegaCore.fuzzyScore("zzz", "New Entry") == nil)
        // Order matters: the letters must appear in sequence.
        #expect(OmegaCore.fuzzyScore("yrtne", "New Entry") == nil)
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(OmegaCore.fuzzyScore("NEW", "new entry") != nil)
        #expect(OmegaCore.fuzzyScore("new", "NEW ENTRY") != nil)
    }

    @Test("an empty needle matches everything with a neutral score")
    func emptyNeedle() {
        #expect(OmegaCore.fuzzyScore("", "anything") == 0)
    }

    @Test("word-start matches outrank mid-word matches")
    func wordStartsWinFirst() {
        let atStart = OmegaCore.fuzzyScore("ne", "New Entry")!
        let midWord = OmegaCore.fuzzyScore("ne", "Alone Time")!
        #expect(atStart > midWord)
    }

    @Test("shorter targets win ties")
    func shorterTargetsWin() {
        let short = OmegaCore.fuzzyScore("cal", "Calendar")!
        let long = OmegaCore.fuzzyScore("cal", "Calendar View Settings Panel")!
        #expect(short > long)
    }

    @Test("consecutive runs outrank equally-positioned scattered hits")
    func consecutiveRunsWin() {
        // Compared against a target of the same length where the hits are not
        // adjacent. (A run loses to "c a t", by design: every letter there sits
        // at a word start, and the word-start bonus intentionally dominates.)
        let run = OmegaCore.fuzzyScore("cat", "cats")!
        let scattered = OmegaCore.fuzzyScore("cat", "chat")!
        #expect(run > scattered)
    }

    @Test("word-start bonus intentionally outweighs adjacency")
    func wordStartBeatsAdjacency() {
        #expect(OmegaCore.fuzzyScore("cat", "c a t")! > OmegaCore.fuzzyScore("cat", "cat")!)
    }
}

// MARK: - Markdown formatting commands

@Suite("Inline wrap toggling")
struct WrapTests {

    @Test("wrapping and unwrapping round-trips")
    func roundTrip() {
        let wrapped = OmegaCore.toggleWrap("hello", open: "**", close: "**")
        #expect(wrapped == "**hello**")
        #expect(OmegaCore.toggleWrap(wrapped, open: "**", close: "**") == "hello")
    }

    @Test("an empty selection produces bare markers")
    func emptySelection() {
        #expect(OmegaCore.toggleWrap("", open: "**", close: "**") == "****")
    }

    @Test("unwrapping requires both sides, not just one")
    func partialMarkersAreNotUnwrapped() {
        // "**x" ends in "x", so it is not wrapped: it gets wrapped, not mangled.
        #expect(OmegaCore.toggleWrap("**x", open: "**", close: "**") == "****x**")
        #expect(OmegaCore.toggleWrap("x**", open: "**", close: "**") == "**x****")
    }

    @Test("all four inline styles behave consistently", arguments: [
        ("**", "**"), ("*", "*"), ("`", "`"), ("~~", "~~"),
    ])
    func allStyles(_ pair: (String, String)) {
        let w = OmegaCore.toggleWrap("x", open: pair.0, close: pair.1)
        #expect(w == pair.0 + "x" + pair.1)
        #expect(OmegaCore.toggleWrap(w, open: pair.0, close: pair.1) == "x")
    }
}

@Suite("Line prefix commands")
struct LinePrefixTests {

    @Test("a prefix is applied to every line in the block")
    func appliesToAllLines() {
        #expect(OmegaCore.applyLinePrefix("- ", to: "a\nb") == "- a\n- b")
    }

    @Test("a fully prefixed block toggles off")
    func togglesOff() {
        #expect(OmegaCore.applyLinePrefix("- ", to: "- a\n- b") == "a\nb")
    }

    @Test("a partially prefixed block applies rather than toggles")
    func partialBlockApplies() {
        #expect(OmegaCore.applyLinePrefix("- ", to: "- a\nb") == "- a\n- b")
    }

    @Test("a competing block marker is replaced, not stacked")
    func competingMarkersAreReplaced() {
        // The bug this guards: "# " + "- x" would otherwise give "# - x".
        #expect(OmegaCore.applyLinePrefix("# ", to: "- x") == "# x")
        #expect(OmegaCore.applyLinePrefix("- ", to: "# x") == "- x")
        #expect(OmegaCore.applyLinePrefix("> ", to: "1. x") == "> x")
        #expect(OmegaCore.applyLinePrefix("- ", to: "- [ ] x") == "- x")
    }

    @Test("a trailing newline is preserved so the block boundary is stable")
    func trailingNewlinePreserved() {
        #expect(OmegaCore.applyLinePrefix("- ", to: "a\n") == "- a\n")
        #expect(OmegaCore.applyLinePrefix("- ", to: "- a\n") == "a\n")
    }

    @Test("round-tripping any prefix returns the original text", arguments: [
        "# ", "## ", "### ", "- ", "1. ", "- [ ] ", "> ",
    ])
    func roundTripsCleanly(_ prefix: String) {
        let original = "alpha\nbeta"
        let applied = OmegaCore.applyLinePrefix(prefix, to: original)
        #expect(OmegaCore.applyLinePrefix(prefix, to: applied) == original)
    }

    @Test("marker stripping leaves ordinary text alone")
    func stripLeavesPlainText() {
        #expect(OmegaCore.stripBlockMarker("plain text") == "plain text")
        #expect(OmegaCore.stripBlockMarker("2026 was a year") == "2026 was a year")
        // No space after the hash: a tag, not a heading.
        #expect(OmegaCore.stripBlockMarker("#tag") == "#tag")
    }
}
