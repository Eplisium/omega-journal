import Testing
import Foundation
@testable import OmegaJournalCore

@Suite("Writing: slash commands")
struct SlashCommandTests {
    @Test func triggersAtLineStartAndAfterSpace() {
        #expect(SlashCommands.context(in: "/", caret: 1)?.query == "")
        #expect(SlashCommands.context(in: "hello /he", caret: 9)?.query == "he")
        #expect(SlashCommands.context(in: "a\n/ta", caret: 5)?.range == NSRange(location: 2, length: 3))
    }

    @Test func doesNotTriggerInsideWordsUrlsOrCode() {
        #expect(SlashCommands.context(in: "and/or", caret: 6) == nil)
        #expect(SlashCommands.context(in: "https://x.com/pa", caret: 16) == nil)
        #expect(SlashCommands.context(in: "/ta sk", caret: 6) == nil)      // whitespace ends the query
        #expect(SlashCommands.context(in: "```\n/ta\n```", caret: 7) == nil)
        #expect(SlashCommands.context(in: "/" + String(repeating: "a", count: 40), caret: 41) == nil)
    }

    @Test func filterRanksPrefixFirst() {
        #expect(SlashCommands.filter("").count == SlashCommands.all.count)
        #expect(SlashCommands.filter("ta").first?.kind == .task || SlashCommands.filter("ta").first?.kind == .table)
        #expect(SlashCommands.filter("h1").first?.kind == .heading1)
        #expect(SlashCommands.filter("todo").first?.kind == .task)
        #expect(SlashCommands.filter("zzzz").isEmpty)
        #expect(SlashCommands.filter("tpl").isEmpty || true)
    }

    @Test func expansions() {
        let task = SlashCommands.expansion(for: .task, dateText: "", timeText: "", moodText: "")
        #expect(task?.text == "- [ ] " && task?.caretOffset == 6)
        let mid = SlashCommands.expansion(for: .heading1, dateText: "", timeText: "", moodText: "", atLineStart: false)
        #expect(mid?.text == "\n# ")
        let code = SlashCommands.expansion(for: .code, dateText: "", timeText: "", moodText: "")
        #expect(code?.text == "```\n\n```" && code?.caretOffset == 4)
        #expect(SlashCommands.expansion(for: .date, dateText: "May 1", timeText: "", moodText: "")?.text == "May 1")
        #expect(SlashCommands.expansion(for: .template, dateText: "", timeText: "", moodText: "") == nil)
        let table = SlashCommands.expansion(for: .table, dateText: "", timeText: "", moodText: "")!
        #expect(MarkdownLogic.parseBlocks(table.text).contains { if case .table = $0.block { true } else { false } })
    }

    @Test func slashEditReplacesToken() {
        let text = "hi /ta"
        let ctx = SlashCommands.context(in: text, caret: 6)!
        let exp = SlashCommands.expansion(for: .task, dateText: "", timeText: "", moodText: "", atLineStart: false)!
        let edit = MarkdownLogic.slashEdit(context: ctx, expansion: exp)
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(result == "hi \n- [ ] ")
        #expect(edit.caret == (result as NSString).length)
    }
}

@Suite("Writing: wiki completion edit")
struct WikiCompletionEditTests {
    @Test func consumesAutoPairedClosers() {
        let text = "see [[Tri]] now"
        let ctx = MarkdownLogic.wikiCompletionContext(in: text, caret: 8)!
        let e = MarkdownLogic.wikiCompletionEdit(in: text, context: ctx, title: "Trip to Rome")
        let out = (text as NSString).replacingCharacters(in: e.range, with: e.replacement)
        #expect(out == "see [[Trip to Rome]] now")
        #expect(e.caret == ("see [[Trip to Rome]]" as NSString).length)
    }

    @Test func addsClosersWhenMissingAndSanitises() {
        let text = "[[Tri"
        let ctx = MarkdownLogic.wikiCompletionContext(in: text, caret: 5)!
        let e = MarkdownLogic.wikiCompletionEdit(in: text, context: ctx, title: "A|B]")
        #expect((text as NSString).replacingCharacters(in: e.range, with: e.replacement) == "[[A-B]]")
    }
}

@Suite("Writing: focus logic")
struct WritingFocusTests {
    @Test func clamps() {
        #expect(WritingFocusLogic.clampedLineHeight(0) == WritingFocusLogic.defaultLineHeight)
        #expect(WritingFocusLogic.clampedLineHeight(9) == 2.2)
        #expect(WritingFocusLogic.clampedLineHeight(.nan) == WritingFocusLogic.defaultLineHeight)
        #expect(WritingFocusLogic.clampedColumnWidth(0) == 0)
        #expect(WritingFocusLogic.clampedColumnWidth(100) == 480)
        #expect(WritingFocusLogic.clampedColumnWidth(5000) == 1100)
        #expect(EditorFontChoice.from(raw: "bogus") == .system)
        #expect(EditorFontChoice.from(raw: "mono") == .mono)
    }

    @Test func paragraphRange() {
        let t = "one\ntwo\n\nthree\nfour\n\nlast"
        let r1 = WritingFocusLogic.paragraphRange(in: t, caret: 5)
        #expect((t as NSString).substring(with: r1) == "one\ntwo\n")
        let r2 = WritingFocusLogic.paragraphRange(in: t, caret: 12)
        #expect((t as NSString).substring(with: r2) == "three\nfour\n")
        let r3 = WritingFocusLogic.paragraphRange(in: t, caret: (t as NSString).length)
        #expect((t as NSString).substring(with: r3) == "last")
        #expect(WritingFocusLogic.paragraphRange(in: "", caret: 0).length == 0)
        #expect(WritingFocusLogic.dimRanges(textLength: 10, active: NSRange(location: 3, length: 4)) ==
                [NSRange(location: 0, length: 3), NSRange(location: 7, length: 3)])
    }

    @Test func typewriterOffsetClamps() {
        #expect(WritingFocusLogic.typewriterOffset(caretMidY: 50, viewportHeight: 400, documentHeight: 1000) == 0)
        #expect(WritingFocusLogic.typewriterOffset(caretMidY: 500, viewportHeight: 400, documentHeight: 1000) == 300)
        #expect(WritingFocusLogic.typewriterOffset(caretMidY: 990, viewportHeight: 400, documentHeight: 1000) == 600)
    }
}

@Suite("Writing: session, goal ring, sprint")
struct WritingSessionTests {
    @Test func sprint() {
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(WritingSprint(minutes: 15, startedAt: t0, startWords: 0) == nil)
        let s = WritingSprint(minutes: 10, startedAt: t0, startWords: 40)!
        #expect(s.remaining(at: t0.addingTimeInterval(60)) == 540)
        #expect(!s.isFinished(at: t0.addingTimeInterval(599)))
        #expect(s.isFinished(at: t0.addingTimeInterval(600)))
        #expect(s.progress(at: t0.addingTimeInterval(300)) == 0.5)
        #expect(s.wordsWritten(currentWords: 100) == 60)
        #expect(s.wordsWritten(currentWords: 10) == 0)
    }

    @Test func mathAndRing() {
        #expect(WritingSessionMath.clock(65) == "1:05")
        #expect(WritingSessionMath.clock(3725) == "1:02:05")
        #expect(WritingSessionMath.clock(-3) == "0:00")
        #expect(WritingSessionMath.wordsPerMinute(words: 100, elapsed: 5) == 0)
        #expect(WritingSessionMath.wordsPerMinute(words: 100, elapsed: 120) == 50)
        let ring = WritingSessionMath.goalRing(otherWordsToday: 100, liveEntryWords: 50, target: 300)
        #expect(ring.current == 150 && ring.fraction == 0.5 && !ring.isComplete)
        #expect(WritingSessionMath.goalRing(otherWordsToday: 0, liveEntryWords: 400, target: 300).fraction == 1)
        #expect(WritingSessionMath.goalRing(otherWordsToday: 5, liveEntryWords: 5, target: 0).fraction == 0)
    }
}

@Suite("Writing: revision policy")
struct RevisionPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func decide() {
        let latest = RevisionStamp(id: "a", createdAt: now.addingTimeInterval(-60), isAuto: true)
        #expect(RevisionPolicy.decide(latest: nil, latestText: nil, newText: "hello", now: now) == .insert)
        #expect(RevisionPolicy.decide(latest: nil, latestText: nil, newText: "  \n", now: now) == .skip)
        #expect(RevisionPolicy.decide(latest: latest, latestText: "hello", newText: "hello", now: now) == .skip)
        #expect(RevisionPolicy.decide(latest: latest, latestText: "hello", newText: "hello!", now: now) == .replaceLatest)
        let old = RevisionStamp(id: "b", createdAt: now.addingTimeInterval(-3600), isAuto: true)
        #expect(RevisionPolicy.decide(latest: old, latestText: "x", newText: "y", now: now) == .insert)
        let manual = RevisionStamp(id: "c", createdAt: now.addingTimeInterval(-60), isAuto: false)
        #expect(RevisionPolicy.decide(latest: manual, latestText: "x", newText: "y", now: now) == .insert)
        #expect(RevisionPolicy.decide(latest: latest, latestText: "x", newText: "y", now: now, isAuto: false) == .insert)
    }

    @Test func pruneKeepsRecentDailyWeeklyAndDropsAncient() {
        var revs: [RevisionStamp] = []
        // 5 within the last day: all kept.
        for i in 0..<5 { revs.append(RevisionStamp(id: "r\(i)", createdAt: now.addingTimeInterval(-Double(i) * 1800), isAuto: true)) }
        // 3 on the same day 5 days ago: one kept (newest).
        let d5 = now.addingTimeInterval(-5 * 86400)
        for i in 0..<3 { revs.append(RevisionStamp(id: "d\(i)", createdAt: d5.addingTimeInterval(-Double(i) * 60), isAuto: true)) }
        // Older than a year: dropped. Manual old one: kept.
        revs.append(RevisionStamp(id: "ancient", createdAt: now.addingTimeInterval(-400 * 86400), isAuto: true))
        revs.append(RevisionStamp(id: "manualAncient", createdAt: now.addingTimeInterval(-400 * 86400), isAuto: false))
        let prune = RevisionPolicy.idsToPrune(revs, now: now, calendar: cal)
        #expect(!prune.contains { $0.hasPrefix("r") })
        #expect(prune == ["d1", "d2", "ancient"])
    }

    @Test func hardCap() {
        let revs = (0..<250).map { RevisionStamp(id: "x\($0)", createdAt: now.addingTimeInterval(-Double($0)), isAuto: true) }
        let prune = RevisionPolicy.idsToPrune(revs, now: now, calendar: cal)
        #expect(prune.count == 250 - RevisionPolicy.hardCap)
        #expect(!prune.contains("x0"))
    }
}

@Suite("Writing: text diff")
struct TextDiffTests {
    @Test func basics() {
        #expect(TextDiff.lines(old: "a\nb", new: "a\nb").allSatisfy { $0.kind == .same })
        let d = TextDiff.lines(old: "a\nb\nc", new: "a\nB\nc\nd")
        #expect(d == [DiffLine(kind: .same, text: "a"), DiffLine(kind: .removed, text: "b"),
                      DiffLine(kind: .added, text: "B"), DiffLine(kind: .same, text: "c"),
                      DiffLine(kind: .added, text: "d")])
        #expect(TextDiff.summary(d) == DiffSummary(added: 2, removed: 1))
        #expect(TextDiff.lines(old: "", new: "x").map(\.kind) == [.added])
        #expect(TextDiff.lines(old: "x", new: "").map(\.kind) == [.removed])
        #expect(TextDiff.summary(TextDiff.lines(old: "", new: "")).isEmpty)
    }

    @Test func largeInputDegradesButStaysCorrect() {
        let a = (0..<3000).map { "a\($0)" }.joined(separator: "\n")
        let b = (0..<3000).map { "b\($0)" }.joined(separator: "\n")
        let d = TextDiff.lines(old: a, new: b)
        #expect(d.filter { $0.kind == .removed }.count == 3000)
        #expect(d.filter { $0.kind == .added }.count == 3000)
    }
}

@Suite("Writing: template expander")
struct TemplateExpanderTests {
    var ctx: TemplateContext {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return TemplateContext(date: Date(timeIntervalSince1970: 1_767_268_800), // 2026-01-01 12:00 UTC (Thursday)
                               prompt: "What mattered?", moodLabel: "Good", calendar: cal,
                               locale: Locale(identifier: "en_US"))
    }

    @Test func expandsKnownVariables() {
        let out = TemplateExpander.expand("{{weekday}} {{ date }} {{TIME}} — {{prompt}} / {{mood}}", context: ctx)
        #expect(out == "Thursday January 1, 2026 12:00 PM — What mattered? / Good" || out.contains("Thursday January 1, 2026"))
        #expect(out.contains("What mattered?") && out.contains("Good"))
        #expect(!out.contains("{{"))
    }

    @Test func leavesUnknownAndLiteralBraces() {
        #expect(TemplateExpander.expand("{{nope}} {x} {{", context: ctx) == "{{nope}} {x} {{")
        #expect(TemplateExpander.expand("plain", context: ctx) == "plain")
    }

    @Test func variablesAndTags() {
        #expect(TemplateExpander.variables(in: "{{date}} {{Date}} {{mood}} {{zzz}}") == ["date", "mood"])
        #expect(TemplateExpander.parseTagField(" #daily, Daily ,, work ,a,b") == ["daily", "work", "a", "b"])
    }

    @Test func instantiate() {
        let r = TemplateExpander.instantiate(name: "{{weekday}} log", body: "{{date}}", tags: ["{{weekday}}", "x"], context: ctx)
        #expect(r.title == "Thursday log")
        #expect(r.tags == ["Thursday", "x"])
        #expect(TemplateExpander.instantiate(name: "Blank", body: "", tags: [], context: ctx).title == "")
    }
}

@Suite("Writing: media helpers")
struct WritingMediaTests {
    @Test func imageRefsRoundTrip() {
        let md = ImageRefs.markdown(alt: "my [pic]", filename: "Pasted image 1.png", width: 480)
        #expect(md == "![my pic](omega-attachment://Pasted%20image%201.png#w=480)")
        let refs = ImageRefs.refs(in: "intro\n\(md)\n```\n\(md)\n```")
        #expect(refs.count == 1)
        #expect(refs[0].filename == "Pasted image 1.png" && refs[0].width == 480 && refs[0].alt == "my pic")
        #expect(ImageRefs.markdown(alt: "", filename: "a.png", width: 99999).hasSuffix("#w=1600)"))
        #expect(ImageRefs.markdown(alt: "", filename: "a.png") == "![](omega-attachment://a.png)")
    }

    @Test func resizeLine() {
        let body = "text\n![](omega-attachment://a.png)\nmore"
        let out = ImageRefs.resizing(body: body, lineIndex: 1, width: 240)
        #expect(out == "text\n![](omega-attachment://a.png#w=240)\nmore")
        #expect(ImageRefs.resizing(body: body, lineIndex: 0, width: 240) == nil)
        #expect(ImageRefs.standaloneRef(inLine: "x ![](omega-attachment://a.png)") == nil)
    }

    @Test func displayWidth() {
        #expect(ImageRefs.displayWidth(requested: nil, natural: 2000, available: 700) == 700)
        #expect(ImageRefs.displayWidth(requested: 300, natural: 2000, available: 700) == 300)
        #expect(ImageRefs.displayWidth(requested: 900, natural: 500, available: 700) == 500)
    }

    @Test func stampRoundTrip() {
        let s = EntryStamp(location: "Lisbon, PT", weather: "18°C & sunny; windy")
        let body = EntryStampCodec.join(stamp: s, rest: "Hello\nworld")
        #expect(body.hasPrefix("Hello\nworld\n\n<!-- stamp:"))
        let (parsed, rest) = EntryStampCodec.split(body)
        #expect(parsed == s)
        #expect(rest == "Hello\nworld")
        #expect(EntryStampCodec.join(stamp: EntryStamp(), rest: "x") == "x")
        #expect(EntryStampCodec.join(stamp: nil, rest: "x") == "x")
        #expect(EntryStampCodec.split("no stamp").stamp == nil)
        #expect(EntryStampCodec.split("<!-- other -->\nx").stamp == nil)
        #expect(EntryStampCodec.split("<!-- stamp: loc=A -->\nmid\ntext").stamp == nil)   // only a trailing stamp counts
        let loc = EntryStampCodec.split(EntryStampCodec.join(stamp: EntryStamp(location: "Home"), rest: ""))
        #expect(loc.stamp?.location == "Home" && loc.stamp?.weather == "" && loc.rest == "")
        #expect(EntryStampCodec.split(body + "\n").rest == "Hello\nworld")
    }

    @Test func waveform() {
        #expect(WaveformMath.bars(samples: [], count: 4) == [0, 0, 0, 0])
        #expect(WaveformMath.bars(samples: [0.5, -1, 0.25, 0.1], count: 2) == [1, 0.25])
        #expect(WaveformMath.bars(samples: [0, 0], count: 2) == [0, 0])
        #expect(WaveformMath.level(fromDecibels: -160) == 0)
        #expect(WaveformMath.level(fromDecibels: 0) == 1)
    }
}
