import AppKit
import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// Fake on-device model: records every prompt, returns a canned reply or throws.
@MainActor
final class W1EditorFakeModel: AssistLanguageModel {
    var reply: String
    var error: Error?
    var prompts: [String] = []
    var instructions: [String] = []
    var onRespond: (() -> Void)?

    init(reply: String = "", error: Error? = nil) { self.reply = reply; self.error = error }

    func respond(instructions: String, prompt: String) async throws -> String {
        self.instructions.append(instructions)
        prompts.append(prompt)
        onRespond?()
        if let error { throw error }
        return reply
    }
}

/// Wave 1 editor-ai: "Suggest title & tags" and "Go deeper" — gating, parsing,
/// apply rules and the request models, all without Apple Intelligence.
@Suite("W1 editor: on-device writing help")
@MainActor
struct W1EditorAssistTests {
    struct Boom: Error {}

    // MARK: Gating

    @Test("entry points appear only when enabled AND available, never for hidden entries")
    func entryPointGate() {
        #expect(AssistEntryPoint.isOffered(enabled: true, available: true, isHidden: false))
        #expect(!AssistEntryPoint.isOffered(enabled: false, available: true, isHidden: false))
        #expect(!AssistEntryPoint.isOffered(enabled: true, available: false, isHidden: false))
        #expect(!AssistEntryPoint.isOffered(enabled: true, available: true, isHidden: true))
        #expect(!AssistEntryPoint.canRun(enabled: true, available: true, isHidden: false, body: " \n "))
        #expect(AssistEntryPoint.canRun(enabled: true, available: true, isHidden: false, body: "x"))
        let min = AssistEntryPoint.goDeeperMinimumWords
        #expect(!AssistEntryPoint.offersGoDeeper(enabled: true, available: true, isHidden: false, wordCount: min - 1))
        #expect(AssistEntryPoint.offersGoDeeper(enabled: true, available: true, isHidden: false, wordCount: min))
        #expect(!AssistEntryPoint.offersGoDeeper(enabled: true, available: true, isHidden: true, wordCount: 500))
        #expect(AssistEntryPoint.modelInput(body: "  abc  ", limit: 2) == "ab")
    }

    @Test("the setting key and API stay the same, and toggling it notifies open editors")
    func settingNotifies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oj-w1editor-ai-\(UUID().uuidString)")
        TestSharedEnvironment.pin()
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("a").path)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SmartAssist.enabledKey == "smartAssistEnabled")
        #expect(!SmartAssist.isEnabled(db))
        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: .smartAssistSettingChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { notified += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        SmartAssist.setEnabled(true, db: db)
        #expect(SmartAssist.isEnabled(db) && notified >= 1)
        var hidden = JournalEntry.new(); hidden.isHidden = true
        // Even when on, a hidden entry is never offered.
        #expect(!SmartAssist.isOffered(for: hidden, db: db))
    }

    // MARK: Parsing

    @Test("title/tags/summary replies are parsed robustly")
    func parseReplies() {
        let a = AssistResponseParser.parseTitleTags("**Title:** \"A slow Sunday.\"\n- Tags: #Rest, family; Walk, rest\nSummary:  You took the day   gently.\nExtra: ignore")
        #expect(a.title == "A slow Sunday")
        #expect(a.tags == ["rest", "family", "walk"])
        #expect(a.summary == "You took the day gently.")
        let b = AssistResponseParser.parseTitleTags("TITLE: one two three four five six seven eight nine ten eleven twelve\nTAGS: none")
        #expect(b.title?.split(separator: " ").count == AssistResponseParser.maxTitleWords)
        #expect(b.tags.isEmpty && b.summary == nil)
        #expect(AssistResponseParser.parseTitleTags("I can't help with that.").isEmpty)
        #expect(AssistResponseParser.cleanTags("a b c d e f g").count == AssistResponseParser.maxTags)
        // The on-device model often replies in lowercase; titles come back sentence case.
        #expect(AssistResponseParser.cleanTitle("phone habits and quiet nights") == "Phone habits and quiet nights")
        #expect(AssistResponseParser.cleanTitle("iPhone-free evenings") == "iPhone-free evenings")
        #expect(AssistResponseParser.cleanTitle("Évening walk") == "Évening walk")
        // Legacy entry point still parses the same way.
        let legacy = SmartAssist.parse("TITLE: \"A good walk\"\nTAGS: Walk, #nature health\nSUMMARY: You walked.")
        #expect(legacy.title == "A good walk" && legacy.tags == ["walk", "nature", "health"] && legacy.summary == "You walked.")
    }

    @Test("follow-up questions: list markers, preambles and duplicates are dropped; at most three")
    func parseFollowUps() {
        let raw = """
        Here are some questions to consider:
        1. What made the walk feel different today?
        2) **Who** were you hoping to see?
        - What made the walk feel different today?
        Question: What would you tell yourself a year ago?
        What else?
        * How did your body feel afterwards?
        """
        let q = AssistFollowUps.parse(raw)
        #expect(q == ["What made the walk feel different today?", "Who were you hoping to see?",
                      "What would you tell yourself a year ago?"])
        #expect(AssistFollowUps.parse("No questions here.").isEmpty)
    }

    @Test("follow-up insertion starts its own block as a quote or heading")
    func followUpInsertion() {
        #expect(AssistFollowUps.insertion("Why?  now", style: .quote, atLineStart: true) == "> Why? now\n\n")
        #expect(AssistFollowUps.insertion("Why now?", style: .heading, atLineStart: false) == "\n\n### Why now?\n\n")
    }

    // MARK: Choice + apply

    @Test("defaults: title only for an untitled entry; existing tags aren't re-suggested; summary off")
    func choiceDefaults() {
        let s = AssistTitleTagSuggestion(title: "Rainy walk", tags: ["walk", "rain"], summary: "You walked.")
        let untitled = AssistSuggestionChoice.defaults(for: s, currentTitle: "  ", currentTags: ["Walk"])
        #expect(untitled.useTitle && untitled.acceptedTags == ["rain"] && !untitled.insertSummary)
        let titled = AssistSuggestionChoice.defaults(for: s, currentTitle: "Mine", currentTags: [])
        #expect(!titled.useTitle && titled.acceptedTags == ["walk", "rain"])
        #expect(AssistSuggestionChoice().changesNothing)
    }

    @Test("apply updates only what was kept: title, appended tags (no duplicates), summary quote")
    func applyRules() {
        let s = AssistTitleTagSuggestion(title: "Rainy walk", tags: ["walk", "rain", "family"], summary: "You walked\nin the rain.")
        let draft = AssistDraft(title: "Old", body: "Body text", tags: ["Walk", "work"])
        let none = AssistApply.apply(s, choice: AssistSuggestionChoice(), to: draft)
        #expect(none == draft)
        let some = AssistApply.apply(s, choice: AssistSuggestionChoice(useTitle: true, acceptedTags: ["walk", "family"], insertSummary: true), to: draft)
        #expect(some.title == "Rainy walk")
        #expect(some.tags == ["Walk", "work", "family"])
        #expect(some.body == "> You walked in the rain.\n\nBody text")
        let empty = AssistApply.apply(s, choice: AssistSuggestionChoice(insertSummary: true), to: AssistDraft(title: "", body: "", tags: []))
        #expect(empty.body == "> You walked in the rain.\n")
    }

    // MARK: Requests (fake model)

    @Test("requests send only the body, refuse hidden/disabled/empty without calling the model")
    func requestGates() async throws {
        let fake = W1EditorFakeModel(reply: "TITLE: Walk\nTAGS: walk\nSUMMARY: You walked.")
        let s = try await SmartAssist.suggestTitleTags(body: "I walked to the river.", isHidden: false, enabled: true,
                                                       availability: .available, model: fake)
        #expect(s.title == "Walk" && s.tags == ["walk"])
        #expect(fake.prompts == ["I walked to the river."])

        await #expect(throws: SmartAssistError.hiddenEntry) {
            _ = try await SmartAssist.suggestTitleTags(body: "secret", isHidden: true, enabled: true, availability: .available, model: fake)
        }
        await #expect(throws: SmartAssistError.disabled) {
            _ = try await SmartAssist.followUpQuestions(body: "text", isHidden: false, enabled: false, availability: .available, model: fake)
        }
        await #expect(throws: SmartAssistError.emptyEntry) {
            _ = try await SmartAssist.followUpQuestions(body: "  ", isHidden: false, enabled: true, availability: .available, model: fake)
        }
        await #expect(throws: SmartAssistError.unavailable("nope")) {
            _ = try await SmartAssist.suggestTitleTags(body: "x", isHidden: false, enabled: true, availability: .unavailable("nope"), model: fake)
        }
        #expect(fake.prompts.count == 1)   // none of the refusals reached the model

        // Framework errors become plain wording, never raw error text.
        let failing = W1EditorFakeModel(error: Boom())
        await #expect(throws: SmartAssistError.failed("Writing help couldn't finish. Try again.")) {
            _ = try await SmartAssist.suggestTitleTags(body: "x", isHidden: false, enabled: true, availability: .available, model: failing)
        }
        let junk = W1EditorFakeModel(reply: "Sorry.")
        await #expect(throws: SmartAssistError.self) {
            _ = try await SmartAssist.suggestTitleTags(body: "x", isHidden: false, enabled: true, availability: .available, model: junk)
        }
    }

    @Test("writing-help model: loading → ready with defaults; apply; cancel; failure message")
    func writingHelpModel() async {
        let fake = W1EditorFakeModel(reply: "TITLE: Calm morning\nTAGS: calm, coffee\nSUMMARY: You slowed down.")
        let model = WritingHelpModel(model: fake, availability: .available)
        model.start(body: "Coffee on the porch.", isHidden: false, enabled: true, currentTitle: "", currentTags: ["coffee"])
        #expect(model.phase == .loading)
        await model.waitForCompletion()
        guard case .ready(let s) = model.phase else { Issue.record("not ready: \(model.phase)"); return }
        #expect(s.title == "Calm morning")
        #expect(model.choice.useTitle && model.choice.acceptedTags == ["calm"])
        model.toggleTag("calm")
        model.choice.useTitle = false
        #expect(model.applied(to: AssistDraft(title: "", body: "b", tags: [])) == nil)   // nothing kept
        model.toggleTag("calm")
        #expect(model.applied(to: AssistDraft(title: "", body: "b", tags: ["coffee"]))?.tags == ["coffee", "calm"])

        let hidden = WritingHelpModel(model: fake, availability: .available)
        hidden.start(body: "secret", isHidden: true, enabled: true, currentTitle: "", currentTags: [])
        await hidden.waitForCompletion()
        #expect(hidden.phase == .failed(SmartAssistError.hiddenEntry.errorDescription ?? ""))

        let cancelled = WritingHelpModel(model: fake, availability: .available)
        cancelled.start(body: "x", isHidden: false, enabled: true, currentTitle: "", currentTags: [])
        cancelled.cancel()
        #expect(cancelled.phase == .idle)
    }

    @Test("go-deeper model returns up to three questions")
    func goDeeperModel() async {
        let fake = W1EditorFakeModel(reply: "What surprised you?\nWho else was there?\nWhat would you change?\nWhy now?")
        let model = GoDeeperModel(model: fake, availability: .available)
        model.start(body: "A long day at work.", isHidden: false, enabled: true)
        await model.waitForCompletion()
        #expect(model.phase == .ready(["What surprised you?", "Who else was there?", "What would you change?"]))
        #expect(fake.instructions.first == SmartAssist.followUpInstructions)
        model.cancel()
        #expect(model.phase == .idle)
    }

    // MARK: Slash commands

    @Test("writing-help slash commands show only when offered and insert nothing themselves")
    func slashCommands() {
        let hidden = SlashCommands.visible(assistOffered: false)
        #expect(!hidden.contains { $0.kind.isAssist })
        #expect(SlashCommands.visible(assistOffered: true).count == SlashCommands.all.count)
        #expect(SlashCommands.filter("suggest", in: SlashCommands.visible(assistOffered: true)).first?.kind == .suggestTitleTags)
        #expect(SlashCommands.filter("deeper", in: SlashCommands.visible(assistOffered: true)).first?.kind == .goDeeper)
        #expect(SlashCommands.filter("suggest", in: hidden).allSatisfy { !$0.kind.isAssist })
        for kind in [SlashCommandKind.suggestTitleTags, .goDeeper] {
            #expect(SlashCommands.expansion(for: kind, dateText: "", timeText: "", moodText: "") == nil)
        }
        // Existing ranking is unchanged.
        #expect(SlashCommands.filter("ta").first?.kind == .task || SlashCommands.filter("ta").first?.kind == .table)
    }

    // MARK: Toolbar density

    @Test("the narrowest top bar folds Focus and Attach into More, so it never clips")
    func topBarVariants() {
        let v = EditorView.topBarVariants
        #expect(v.count == 4 && Set(v).count == 4)
        #expect(v.first == EditorView.TopBarVariant(compactMood: false, iconModes: false, compactTools: false))
        #expect(v.last == EditorView.TopBarVariant(compactMood: true, iconModes: true, compactTools: true))
        // Each step only ever gets more compact.
        func weight(_ x: EditorView.TopBarVariant) -> Int { [x.compactMood, x.iconModes, x.compactTools].filter { $0 }.count }
        #expect(zip(v, v.dropFirst()).allSatisfy { weight($0) < weight($1) })
    }
}
