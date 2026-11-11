import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// Wave 1 editor-ai: "Ask your journal" — local ranking, hidden-entry privacy,
/// prompt contents, citations and the panel model (fake on-device model).
@Suite("W1 editor: ask your journal")
@MainActor
struct W1EditorAskJournalTests {
    // Fixed instants: no dependency on the clock or time zone.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    static func record(_ id: String, _ title: String, _ body: String, days: Double, tags: [String] = [],
                       hidden: Bool = false) -> SearchQuery.Record {
        SearchQuery.Record(id: id, title: title, body: body, tags: tags, moodName: "", moodValue: 0,
                           createdAt: daysAgo(days), isHidden: hidden)
    }

    static let records: [SearchQuery.Record] = [
        record("a", "Morning run", "Ran by the river before work. My knee felt fine.", days: 2, tags: ["running"]),
        record("b", "Old run", "A long run in the hills, the knee hurt a lot.", days: 300, tags: ["running"]),
        record("c", "Dinner", "Pasta with Sam. We talked about moving.", days: 1),
        record("h", "Private", "Secret about my knee and running.", days: 0.5, tags: ["running"], hidden: true),
    ]

    // MARK: Retrieval

    @Test("terms drop stopwords and keep quoted phrases")
    func terms() {
        #expect(AskJournalRetrieval.terms(for: "When did my knee hurt?") == ["knee", "hurt"])
        #expect(AskJournalRetrieval.terms(for: "What about \"long run\" lately") == ["long run"])
        #expect(AskJournalRetrieval.terms(for: "How have I been?").isEmpty)
    }

    @Test("ranking prefers matching, recent entries and numbers sources from 1")
    func ranking() {
        let top = AskJournalRetrieval.rank(question: "How is my knee after running?", records: Self.records,
                                           hiddenLocked: true, now: Self.now)
        #expect(top.map(\.entryId) == ["a", "b"])
        #expect(top.map(\.number) == [1, 2])
        #expect(AskJournalRetrieval.rank(question: "zebra migration", records: Self.records, hiddenLocked: true, now: Self.now).isEmpty)
        // No meaningful words: most recent eligible entries.
        let recent = AskJournalRetrieval.rank(question: "How have I been?", records: Self.records, hiddenLocked: true,
                                              now: Self.now, limit: 2)
        #expect(recent.map(\.entryId) == ["c", "a"])
        // Operators filter.
        #expect(AskJournalRetrieval.rank(question: "knee tag:running", records: Self.records, hiddenLocked: true,
                                         now: Self.now).allSatisfy { $0.entryId != "c" })
    }

    @Test("locked hidden entries are never ranked — not by body, title or tag; unlocked they are")
    func hiddenPrivacy() {
        for question in ["secret", "Private", "tag:running knee", "How have I been?"] {
            let locked = AskJournalRetrieval.rank(question: question, records: Self.records, hiddenLocked: true, now: Self.now)
            #expect(!locked.contains { $0.entryId == "h" }, "\(question)")
            #expect(!AskJournalPrompt.prompt(question: question, sources: locked).contains("Secret"))
        }
        let unlocked = AskJournalRetrieval.rank(question: "secret", records: Self.records, hiddenLocked: false, now: Self.now)
        #expect(unlocked.map(\.entryId) == ["h"])
    }

    @Test("excerpts are short, centred on the match, and drop the place/weather stamp")
    func excerpts() {
        let long = String(repeating: "filler words here ", count: 80) + "the knee finally healed " + String(repeating: "more text ", count: 80)
        let ex = AskJournalRetrieval.excerpt(long, terms: ["knee"], length: 120)
        #expect(ex.contains("knee") && ex.hasPrefix("…") && ex.hasSuffix("…") && ex.count <= 125)
        let stamped = EntryStampCodec.join(stamp: EntryStamp(location: "Secret Street 4", weather: "Sun"), rest: "Knee is fine.")
        let s = AskJournalRetrieval.rank(question: "knee", records: [Self.record("s", "T", stamped, days: 1)],
                                         hiddenLocked: true, now: Self.now)
        #expect(s.first?.excerpt == "Knee is fine.")
    }

    @Test("prompt lists numbered excerpts with titles and the question on one line")
    func prompt() {
        let sources = AskJournalRetrieval.rank(question: "knee", records: Self.records, hiddenLocked: true, now: Self.now)
        let p = AskJournalPrompt.prompt(question: "How's\nmy knee?", sources: sources, dateText: { _ in "DATE" })
        #expect(p.contains("[1] Morning run — DATE\nRan by the river"))
        #expect(p.contains("[2] Old run — DATE"))
        #expect(p.hasSuffix("Question: How's my knee?"))
    }

    @Test("citations map [n], [1, 2] and [Source 3] to sources; unknown numbers ignored")
    func citations() {
        let sources = AskJournalRetrieval.rank(question: "How have I been?", records: Self.records, hiddenLocked: true,
                                               now: Self.now, limit: 3)
        let cited = AskJournalCitations.cited(in: "You ran [2]. You ate [1, 2]. Also [Source 3] and [9].", sources: sources)
        #expect(cited.map(\.number) == [2, 1, 3])
        #expect(AskJournalCitations.sourcesToShow(answer: "No citations.", sources: sources) == sources)
    }

    // MARK: Panel model

    @Test("asking sends only the top excerpts and shows the cited sources")
    func askFlow() async {
        let fake = W1EditorFakeModel(reply: "Your knee felt fine on your last run [1].")
        let model = AskJournalModel(model: fake, availability: .available, isHiddenLocked: { true })
        model.question = "How is my knee?"
        model.ask(records: Self.records, enabled: true, now: Self.now)
        #expect(model.phase == .answering)
        await model.waitForCompletion()
        guard case .answered(let answer, let sources) = model.phase else { Issue.record("\(model.phase)"); return }
        #expect(answer.contains("[1]"))
        #expect(sources.map(\.entryId) == ["a"])
        let prompt = fake.prompts.joined()
        #expect(prompt.contains("Ran by the river") && !prompt.contains("Secret") && !prompt.contains("Pasta"))
        #expect(fake.instructions == [AskJournalPrompt.instructions])
    }

    @Test("no match, disabled and unavailable never call the model")
    func askGates() async {
        let fake = W1EditorFakeModel(reply: "x")
        let model = AskJournalModel(model: fake, availability: .available, isHiddenLocked: { true })
        model.question = "zebra migration"
        model.ask(records: Self.records, enabled: true, now: Self.now)
        #expect(model.phase == .noMatches)
        model.question = "knee"
        model.ask(records: Self.records, enabled: false, now: Self.now)
        await model.waitForCompletion()
        #expect(model.phase == .failed(SmartAssistError.disabled.errorDescription ?? ""))
        let off = AskJournalModel(model: fake, availability: .unavailable("Needs Apple Intelligence."), isHiddenLocked: { true })
        off.question = "knee"
        off.ask(records: Self.records, enabled: true, now: Self.now)
        await off.waitForCompletion()
        #expect(off.phase == .failed("Needs Apple Intelligence."))
        #expect(fake.prompts.isEmpty)
        model.question = "   "
        #expect(!model.canAsk)
    }

    @Test("an answer drawn from a hidden entry disappears when hidden entries lock")
    func clearsOnLock() async {
        var locked = false
        let fake = W1EditorFakeModel(reply: "It was a secret [1].")
        let model = AskJournalModel(model: fake, availability: .available, isHiddenLocked: { locked })
        model.question = "secret"
        model.ask(records: Self.records, enabled: true, now: Self.now)
        await model.waitForCompletion()
        guard case .answered = model.phase else { Issue.record("\(model.phase)"); return }
        #expect(model.hiddenSourceIds == ["h"])
        locked = true
        model.hiddenEntriesLocked()
        #expect(model.phase == .idle && model.hiddenSourceIds.isEmpty)

        // Locking while the model is still answering drops the answer too.
        locked = false
        fake.onRespond = { locked = true }
        model.ask(records: Self.records, enabled: true, now: Self.now)
        await model.waitForCompletion()
        #expect(model.phase == .idle)

        // Answers from visible entries survive a lock.
        locked = false
        fake.onRespond = nil
        model.question = "knee"
        model.ask(records: Self.records.filter { !$0.isHidden }, enabled: true, now: Self.now)
        await model.waitForCompletion()
        model.hiddenEntriesLocked()
        if case .answered = model.phase {} else { Issue.record("visible answer was cleared") }
    }

    @Test("a cited entry opens in the Journal, or in the Archive when archived")
    func citationDestination() {
        var e = JournalEntry.new()
        #expect(AskJournalPresenter.destination(for: e) == .all)
        e.isArchived = true
        #expect(AskJournalPresenter.destination(for: e) == .archive)
    }
}
