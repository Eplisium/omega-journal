import Foundation
import OmegaJournalCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Opt-in on-device AI assist
//
// Uses Apple's on-device Foundation Models only. Off by default, never touches the network,
// hidden entries are refused. When the framework / model is unavailable everything reports
// `.unavailable` and the UI hides the controls (no dead UI).
//
// Features built on it: "Suggest title & tags" and "Go deeper" in the editor, and
// "Ask your journal" (Views/Ask). The parsing / ranking / apply rules are pure and live in
// OmegaJournalCore (`Assist*`, `AskJournal*`); this file only talks to the model.

enum SmartAssistAvailability: Equatable {
    case available
    case unavailable(String)
    var isAvailable: Bool { self == .available }
}

/// Kept for existing callers; the type itself lives in Core.
typealias SmartSuggestion = AssistTitleTagSuggestion

enum SmartAssistError: Error, LocalizedError, Equatable {
    case disabled, hiddenEntry, emptyEntry, unavailable(String), failed(String), cancelled
    var errorDescription: String? {
        switch self {
        case .disabled: return "Turn on On-Device Writing Help in Settings first."
        case .hiddenEntry: return "Hidden entries are never sent to writing help."
        case .emptyEntry: return "There's nothing to read yet. Write a few sentences first."
        case .unavailable(let why): return why
        case .failed(let why): return why
        case .cancelled: return "Stopped."
        }
    }
}

extension Notification.Name {
    /// Posted when On-Device Writing Help is switched on or off, so open editors
    /// show or hide their entry points without a relaunch.
    static let smartAssistSettingChanged = Notification.Name("OmegaJournal.smartAssistSettingChanged")
}

/// The on-device language model, behind a seam so the flows are testable
/// without Apple Intelligence (tests inject a fake).
protocol AssistLanguageModel: AnyObject {
    func respond(instructions: String, prompt: String) async throws -> String
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
final class FoundationAssistModel: AssistLanguageModel {
    func respond(instructions: String, prompt: String) async throws -> String {
        // A fresh session per request: nothing from one entry carries into the next.
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
    }
}
#endif

enum SmartAssist {
    static let enabledKey = "smartAssistEnabled"

    static func isEnabled(_ db: DatabaseManager = .shared) -> Bool {
        db.bool(enabledKey)
    }

    static func setEnabled(_ on: Bool, db: DatabaseManager = .shared) {
        db.setBool(enabledKey, on)
        NotificationCenter.default.post(name: .smartAssistSettingChanged, object: nil)
    }

    static var availability: SmartAssistAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable("This Mac doesn't support Apple Intelligence.")
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Turn on Apple Intelligence in System Settings to use on-device help.")
                case .modelNotReady: return .unavailable("Apple Intelligence is still getting ready. Try again later.")
                @unknown default: return .unavailable("Apple Intelligence isn't available right now.")
                }
            }
        }
        #endif
        return .unavailable("Requires macOS 26 with Apple Intelligence.")
    }

    /// The real on-device model, or nil when it can't run here.
    static func systemModel() -> AssistLanguageModel? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability.isAvailable { return FoundationAssistModel() }
        #endif
        return nil
    }

    /// Whether the editor should show writing help for this entry at all.
    static func isOffered(for entry: JournalEntry, db: DatabaseManager = .shared) -> Bool {
        AssistEntryPoint.isOffered(enabled: isEnabled(db), available: availability.isAvailable, isHidden: entry.isHidden)
    }

    /// Pure gate used before any text reaches the model — tested directly.
    static func gate(entry: JournalEntry, enabled: Bool) throws {
        try gate(body: entry.body, isHidden: entry.isHidden, enabled: enabled)
    }

    static func gate(body: String, isHidden: Bool, enabled: Bool) throws {
        guard enabled else { throw SmartAssistError.disabled }
        guard !isHidden else { throw SmartAssistError.hiddenEntry }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SmartAssistError.emptyEntry }
    }

    /// Splits "TITLE: …\nTAGS: a, b\nSUMMARY: …" style output.
    static func parse(_ raw: String) -> SmartSuggestion {
        AssistResponseParser.parseTitleTags(raw)
    }

    static let titleTagsInstructions = """
        You help a person organise their private journal. Reply with exactly three lines and nothing else:
        TITLE: a short title (max 8 words)
        TAGS: up to 4 lowercase single-word tags, comma separated
        SUMMARY: one gentle sentence summarising the entry, speaking to the writer as "you"
        """

    static let followUpInstructions = """
        You help a person reflect in their private journal. Read their entry and reply with up to three short, \
        open, kind follow-up questions that would help them explore what they wrote more deeply. \
        Speak to them as "you". One question per line, nothing else: no numbering, no preamble.
        """

    // MARK: Requests

    /// Title, tags and a one-line summary for the draft body (never the title or stamp).
    static func suggestTitleTags(body: String, isHidden: Bool, enabled: Bool,
                                 availability: SmartAssistAvailability = SmartAssist.availability,
                                 model: AssistLanguageModel? = nil) async throws -> AssistTitleTagSuggestion {
        try gate(body: body, isHidden: isHidden, enabled: enabled)
        let model = try resolve(model, availability: availability)
        let raw = try await run(model, instructions: titleTagsInstructions, prompt: AssistEntryPoint.modelInput(body: body))
        let parsed = AssistResponseParser.parseTitleTags(raw)
        if parsed.isEmpty { throw SmartAssistError.failed("Writing help didn't come up with anything this time. Try again.") }
        return parsed
    }

    /// 1–3 follow-up questions about the draft body.
    static func followUpQuestions(body: String, isHidden: Bool, enabled: Bool,
                                  availability: SmartAssistAvailability = SmartAssist.availability,
                                  model: AssistLanguageModel? = nil) async throws -> [String] {
        try gate(body: body, isHidden: isHidden, enabled: enabled)
        let model = try resolve(model, availability: availability)
        let raw = try await run(model, instructions: followUpInstructions, prompt: AssistEntryPoint.modelInput(body: body))
        let questions = AssistFollowUps.parse(raw)
        if questions.isEmpty { throw SmartAssistError.failed("No questions came up this time. Try again.") }
        return questions
    }

    /// Answers a question from the given excerpts only (Ask your journal).
    static func answer(question: String, sources: [AskJournalSource], enabled: Bool,
                       availability: SmartAssistAvailability = SmartAssist.availability,
                       model: AssistLanguageModel? = nil) async throws -> String {
        guard enabled else { throw SmartAssistError.disabled }
        let model = try resolve(model, availability: availability)
        let raw = try await run(model, instructions: AskJournalPrompt.instructions,
                                prompt: AskJournalPrompt.prompt(question: question, sources: sources))
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw SmartAssistError.failed("No answer came back. Try asking another way.") }
        return text
    }

    /// Legacy entry point: suggestion for a stored entry.
    static func suggest(for entry: JournalEntry, db: DatabaseManager = .shared) async throws -> SmartSuggestion {
        try await suggestTitleTags(body: EntryStampCodec.split(entry.body).rest, isHidden: entry.isHidden,
                                   enabled: isEnabled(db))
    }

    // MARK: Plumbing

    private static func resolve(_ model: AssistLanguageModel?, availability: SmartAssistAvailability) throws -> AssistLanguageModel {
        if case .unavailable(let why) = availability { throw SmartAssistError.unavailable(why) }
        if let model { return model }
        if let system = systemModel() { return system }
        throw SmartAssistError.unavailable("Requires macOS 26 with Apple Intelligence.")
    }

    private static func run(_ model: AssistLanguageModel, instructions: String, prompt: String) async throws -> String {
        do {
            try Task.checkCancellation()
            let raw = try await model.respond(instructions: instructions, prompt: prompt)
            try Task.checkCancellation()
            return raw
        } catch is CancellationError {
            throw SmartAssistError.cancelled
        } catch let e as SmartAssistError {
            throw e
        } catch {
            throw SmartAssistError.failed(friendlyMessage(for: error))
        }
    }

    /// Plain-English wording for model errors (never raw framework text).
    static func friendlyMessage(for error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let e = error as? LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = e { return "This entry is too long for on-device help. Try a shorter entry." }
            if case .guardrailViolation = e { return "Apple's on-device model can't help with this entry." }
            if case .unsupportedLanguageOrLocale = e { return "On-device help doesn't support this language yet." }
            if case .assetsUnavailable = e { return "Apple Intelligence is still getting ready. Try again later." }
        }
        #endif
        return "Writing help couldn't finish. Try again."
    }
}
