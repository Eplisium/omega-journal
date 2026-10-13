import Testing
import AppKit
import SwiftUI
import Foundation
import OmegaJournalCore
@testable import OmegaJournal

// Audit group C: editor / markdown / audio / links regressions.

// MARK: - 1. Voice memo recorder never discards a recording

@MainActor
private final class FakeMemoBackend: MemoRecordingBackend {
    var isRecording = true
    var currentTime: TimeInterval = 0
    var stopped = false
    func updateMeters() {}
    func averagePower() -> Float { -20 }
    func stop() { isRecording = false; stopped = true }
}

@Suite("Audit C: voice memo recorder", .serialized)
@MainActor
struct AuditFixesCRecorderTests {
    private func tempMemo(bytes: Int = 4096) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("auditc-\(UUID().uuidString).m4a")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test("auto-stop at the time cap delivers the recording instead of dropping it")
    func autoStopDelivers() throws {
        let rec = AudioMemoRecorder()
        let url = try tempMemo()
        let backend = FakeMemoBackend()
        rec.attachForTesting(backend: backend, fileURL: url)
        var delivered: Data?
        rec.onAutoStop = { delivered = $0 }

        backend.currentTime = 10
        rec.tick()
        #expect(delivered == nil)
        #expect(rec.state == .recording)

        backend.currentTime = AudioMemoRecorder.maxSeconds
        rec.tick()
        #expect(backend.stopped)
        #expect(rec.state == .idle)
        #expect(delivered?.count == 4096)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("auto-stop with no listener keeps the memo as a pending result")
    func autoStopPending() throws {
        let rec = AudioMemoRecorder()
        let url = try tempMemo()
        let backend = FakeMemoBackend()
        rec.attachForTesting(backend: backend, fileURL: url)
        backend.currentTime = AudioMemoRecorder.maxSeconds + 1
        rec.tick()
        #expect(rec.takePendingMemo()?.count == 4096)
        #expect(rec.takePendingMemo() == nil)
    }

    @Test("dismissing the popover mid-recording stops and returns the data (no silent cancel)")
    func dismissKeepsRecording() throws {
        let rec = AudioMemoRecorder()
        let url = try tempMemo()
        let backend = FakeMemoBackend()
        rec.attachForTesting(backend: backend, fileURL: url)
        let data = rec.finishForDismissal()
        #expect(data?.count == 4096)
        #expect(backend.stopped)
        #expect(rec.state == .idle)
        // Second call (e.g. Stop & attach already ran) returns nothing — no double attach.
        #expect(rec.finishForDismissal() == nil)
    }

    @Test("dismissing when idle returns nothing")
    func dismissIdle() {
        #expect(AudioMemoRecorder().finishForDismissal() == nil)
    }
}

// MARK: - 2/3. Link it

@Suite("Audit C: link mention")
struct AuditFixesCLinkMentionTests {
    @Test("skips existing wiki links and partial words")
    func skipsLinksAndWords() {
        let out = UnlinkedMentions.linkingFirstMention(of: "Art", in: "See [[Art History]] and art class.")
        #expect(out == "See [[Art History]] and [[Art|art]] class.")
        #expect(UnlinkedMentions.linkingFirstMention(of: "Art", in: "Smart party") == nil)
    }

    @Test("skips inline code and fenced code")
    func skipsCode() {
        let body = "`Rome` here\n```\nRome\n```\nVisited Rome."
        #expect(UnlinkedMentions.linkingFirstMention(of: "Rome", in: body) == "`Rome` here\n```\nRome\n```\nVisited [[Rome]].")
    }

    @Test("accented mention links with an alias so it resolves to the target")
    func accentAlias() throws {
        let out = try #require(UnlinkedMentions.linkingFirstMention(of: "Cafe", in: "Met at the café today."))
        #expect(out == "Met at the [[Cafe|café]] today.")
        let resolved = WikiLinks.resolveWikiLinks(in: out, entries: [LinkableEntry(id: "c", title: "Cafe", body: "")])
        #expect(resolved.map(\.entryId) == ["c"])
        #expect(MarkdownLogic.wikiLinks(in: out).first?.displayText == "café")
    }

    @Test("UTF-16 safe after emoji")
    func emoji() {
        #expect(UnlinkedMentions.linkingFirstMention(of: "Rome", in: "🙂🙂 rome!") == "🙂🙂 [[Rome|rome]]!")
    }

    @Test("unlinked-mention detection agrees with Link it (word boundaries)")
    func findAgrees() {
        let entries = [LinkableEntry(id: "1", title: "x", body: "Smart party"),
                       LinkableEntry(id: "2", title: "y", body: "an art class")]
        #expect(UnlinkedMentions.find(forTitle: "Art", in: entries).map(\.id) == ["2"])
    }
}

// MARK: - 4. Wiki completion

@Suite("Audit C: wiki completion")
struct AuditFixesCWikiCompletionTests {
    @Test("does not swallow a following markdown link")
    func keepsFollowingLink() throws {
        let text = "[[ProjMeeting with [Bob](mailto:b@x.com)"
        let ctx = try #require(MarkdownLogic.wikiCompletionContext(in: text, caret: 6))
        let e = MarkdownLogic.wikiCompletionEdit(in: text, context: ctx, title: "Project")
        let out = (text as NSString).replacingCharacters(in: e.range, with: e.replacement)
        #expect(out == "[[Project]] with [Bob](mailto:b@x.com)")
    }

    @Test("consumes adjacent auto-paired closers only")
    func adjacentClosers() throws {
        let text = "[[Pr]] then ]"
        let ctx = try #require(MarkdownLogic.wikiCompletionContext(in: text, caret: 4))
        let e = MarkdownLogic.wikiCompletionEdit(in: text, context: ctx, title: "Project")
        #expect((text as NSString).replacingCharacters(in: e.range, with: e.replacement) == "[[Project]] then ]")
        let t2 = "[[Pr later]]"
        let c2 = try #require(MarkdownLogic.wikiCompletionContext(in: t2, caret: 4))
        let e2 = MarkdownLogic.wikiCompletionEdit(in: t2, context: c2, title: "Project")
        #expect((t2 as NSString).replacingCharacters(in: e2.range, with: e2.replacement) == "[[Project]] later]]")
    }
}

// MARK: - 5. CRLF fences

@Suite("Audit C: CRLF")
struct AuditFixesCCRLFTests {
    @Test("closing fence followed by CR closes the block")
    func codeBlockCRLF() {
        let text = "```\r\ncode\r\n```\r\nafter text\r\n"
        let r = MarkdownLogic.codeBlockRanges(in: text)
        #expect(r == [NSRange(location: 0, length: ("```\r\ncode\r\n```\r\n" as NSString).length)])
    }

    @Test("wiki links inside CRLF fences are ignored")
    func linkTitlesCRLF() {
        #expect(WikiLinks.linkTitles(in: "intro\r\n```\r\n[[InCode]]\r\n```\r\n[[Real]]") == ["Real"])
        #expect(MarkdownLogic.wikiLinks(in: "intro\r\n```\r\n[[InCode]]\r\n```\r\n[[Real]]").map(\.title) == ["Real"])
    }

    @Test("parseBlocks closes CRLF fences")
    func parseCRLF() {
        let blocks = MarkdownLogic.parseBlocks("```swift\r\nlet x = 1\r\n```\r\n# After")
        #expect(blocks.first?.block == .codeFence(language: "swift", lines: ["let x = 1"]))
        #expect(blocks.contains { $0.block == .heading(level: 1, text: "After") })
    }
}

// MARK: - 7/8. Tables and line endings

@Suite("Audit C: table and task line endings")
struct AuditFixesCLineTests {
    @Test("only \\| is an escape in table cells")
    func tableBackslash() {
        #expect(MarkdownLogic.splitTableRow(#"| C:\path\to | a\|b |"#) == [#"C:\path\to"#, "a|b"])
    }

    @Test("toggling a task keeps CR line endings")
    func toggleCR() {
        #expect(MarkdownLogic.toggledTask("- [ ] buy milk\r") == "- [x] buy milk\r")
        #expect(MarkdownLogic.togglingTask(inBody: "- [ ] a\r\n- [ ] b\r\n", lineIndex: 0) == "- [x] a\r\n- [ ] b\r\n")
    }

    @Test("renumbering keeps CR line endings and does not touch correct lines")
    func renumberCR() {
        #expect(MarkdownLogic.renumberEdit(in: "1. a\r\n2. b\r\n3. c\r\n", fromLine: 0) == nil)
        let e = MarkdownLogic.renumberEdit(in: "1. a\r\n1. b\r\n", fromLine: 0)
        let text = "1. a\r\n1. b\r\n" as NSString
        #expect(e.map { text.replacingCharacters(in: $0.range, with: $0.replacement) } == "1. a\r\n2. b\r\n")
    }
}

// MARK: - 9. Entry stamp

@Suite("Audit C: entry stamp")
struct AuditFixesCStampTests {
    @Test("split(join) round-trips trailing blank lines")
    func roundTrip() {
        let stamp = EntryStamp(location: "Rome", weather: "Sunny")
        for rest in ["Hello\n\n", "Hello\n", "Hello", "", "a\r\n"] {
            #expect(EntryStampCodec.split(EntryStampCodec.join(stamp: stamp, rest: rest)).rest == rest)
        }
    }
}

// MARK: - 6/10. Editor highlighting

@Suite("Audit C: editor highlighting", .serialized)
@MainActor
struct AuditFixesCEditorTests {
    private func makeCoordinator(_ text: String) -> MarkdownTextEditor.Coordinator {
        let editor = MarkdownTextEditor(text: .constant(text), font: .systemFont(ofSize: 14),
                                        controller: MarkdownEditorController())
        return MarkdownTextEditor.Coordinator(editor)
    }

    @Test("typing at the end of an unterminated fence stays incremental")
    func unterminatedFenceIncremental() {
        let doc = EditorHighlightPerformanceTests.bigDocument() + "```\ncode"
        let storage = NSTextStorage(string: doc)
        let c = makeCoordinator(doc)
        c.highlightNow(storage)
        for ch in ["x", "y"] {
            let end = storage.length
            c.noteEdit(range: NSRange(location: end, length: 0), replacementLength: 1)
            storage.replaceCharacters(in: NSRange(location: end, length: 0), with: ch)
            c.highlightNow(storage)
            let r = c.lastHighlightRange ?? NSRange(location: 0, length: storage.length)
            #expect(r.length < 400, "restyled \(r.length) chars")
        }
        // Deleting at the end is incremental too.
        let end = storage.length
        c.noteEdit(range: NSRange(location: end - 1, length: 1), replacementLength: 0)
        storage.replaceCharacters(in: NSRange(location: end - 1, length: 1), with: "")
        c.highlightNow(storage)
        #expect((c.lastHighlightRange?.length ?? .max) < 400)
    }

    @Test("a closed fence at the very end still predicts correctly when typing after it")
    func closedFenceAtEnd() {
        let doc = EditorHighlightPerformanceTests.bigDocument() + "```\ncode\n```\n"
        let storage = NSTextStorage(string: doc)
        let c = makeCoordinator(doc)
        c.highlightNow(storage)
        let end = storage.length
        c.noteEdit(range: NSRange(location: end, length: 0), replacementLength: 1)
        storage.replaceCharacters(in: NSRange(location: end, length: 0), with: "x")
        c.highlightNow(storage)
        #expect((c.lastHighlightRange?.length ?? .max) < 400)
    }

    @Test("a lone # does not style the next line as a heading")
    func loneHash() {
        let doc = "#\nNext line\n"
        let storage = NSTextStorage(string: doc)
        let c = makeCoordinator(doc)
        c.highlightNow(storage)
        let font = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 14)
        // A real heading still gets the heading size.
        let s2 = NSTextStorage(string: "# Title\nbody")
        let c2 = makeCoordinator(s2.string)
        c2.highlightNow(s2)
        #expect((s2.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.pointSize == 24)
    }

    @Test("link styling includes balanced parentheses in the URL")
    func linkParens() {
        let doc = "x [w](https://en.wikipedia.org/wiki/Foo_(bar)) y"
        let storage = NSTextStorage(string: doc)
        let c = makeCoordinator(doc)
        c.highlightNow(storage)
        let ns = doc as NSString
        let first = storage.attribute(.foregroundColor, at: ns.range(of: "[w]").location, effectiveRange: nil) as? NSColor
        let lastParen = ns.range(of: "))").location + 1
        let last = storage.attribute(.foregroundColor, at: lastParen, effectiveRange: nil) as? NSColor
        #expect(first != nil)
        #expect(first == last)
    }
}
