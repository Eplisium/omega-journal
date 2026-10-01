import Foundation
import OmegaJournalCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Opt-in on-device AI assist
//
// Uses Apple's on-device Foundation Models only. Off by default, never touches the network,
// hidden entries are refused. When the framework / model is unavailable everything reports
// `.unavailable` and the UI hides the controls.

enum SmartAssistAvailability: Equatable {
    case available
    case unavailable(String)
    var isAvailable: Bool { self == .available }
}

struct SmartSuggestion: Equatable {
    var summary: String?
    var title: String?
    var tags: [String] = []
}

enum SmartAssistError: Error, LocalizedError, Equatable {
    case disabled, hiddenEntry, emptyEntry, unavailable(String), failed(String)
    var errorDescription: String? {
        switch self {
        case .disabled: return "Turn on on-device AI assist in Settings first."
        case .hiddenEntry: return "Hidden entries are never sent to AI assist."
        case .emptyEntry: return "There's nothing to summarize yet."
        case .unavailable(let why): return why
        case .failed(let why): return "AI assist couldn't finish: \(why)"
        }
    }
}

enum SmartAssist {
    static let enabledKey = "smartAssistEnabled"

    static func isEnabled(_ db: DatabaseManager = .shared) -> Bool {
        db.getSetting(enabledKey, defaultValue: "false") == "true"
    }

    static func setEnabled(_ on: Bool, db: DatabaseManager = .shared) {
        db.setSetting(enabledKey, value: on ? "true" : "false")
    }

    static var availability: SmartAssistAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason): return .unavailable("On-device model unavailable (\(reason)).")
            }
        }
        #endif
        return .unavailable("Requires macOS 26 with Apple Intelligence.")
    }

    /// Pure gate used before any text reaches the model — tested directly.
    static func gate(entry: JournalEntry, enabled: Bool) throws {
        guard enabled else { throw SmartAssistError.disabled }
        guard !entry.isHidden else { throw SmartAssistError.hiddenEntry }
        guard !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SmartAssistError.emptyEntry }
    }

    /// Splits "TITLE: …\nTAGS: a, b\nSUMMARY: …" style output.
    static func parse(_ raw: String) -> SmartSuggestion {
        var out = SmartSuggestion()
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            let lower = t.lowercased()
            if lower.hasPrefix("title:") { out.title = String(t.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " \"*")) }
            else if lower.hasPrefix("tags:") {
                out.tags = OmegaCore.normalizeTags(String(t.dropFirst(5)).split(whereSeparator: { $0 == "," || $0 == " " })
                    .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "#*\"")) }.filter { !$0.isEmpty }.map { $0.lowercased() })
            } else if lower.hasPrefix("summary:") { out.summary = String(t.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    static func suggest(for entry: JournalEntry, db: DatabaseManager = .shared) async throws -> SmartSuggestion {
        try gate(entry: entry, enabled: isEnabled(db))
        guard case .available = availability else {
            if case .unavailable(let why) = availability { throw SmartAssistError.unavailable(why) }
            throw SmartAssistError.unavailable("Unavailable")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                You help a person organise their private journal. Reply with exactly three lines and nothing else:
                TITLE: a short title (max 8 words)
                TAGS: up to 4 lowercase single-word tags, comma separated
                SUMMARY: one or two gentle sentences summarising the entry
                """)
            do {
                let response = try await session.respond(to: String(entry.body.prefix(6_000)))
                let parsed = parse(response.content)
                if parsed.title == nil && parsed.summary == nil && parsed.tags.isEmpty {
                    throw SmartAssistError.failed("unexpected response")
                }
                return parsed
            } catch let e as SmartAssistError { throw e }
            catch { throw SmartAssistError.failed(error.localizedDescription) }
        }
        #endif
        throw SmartAssistError.unavailable("Requires macOS 26 with Apple Intelligence.")
    }
}
