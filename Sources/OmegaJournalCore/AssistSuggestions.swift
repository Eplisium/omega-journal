import Foundation

// MARK: - On-device writing help: pure parsing, gating and apply rules
//
// The app asks Apple's on-device model for a title, tags and a one-line summary
// (and for "Go deeper" follow-up questions). Everything that decides what the
// model may see, how its reply is read, and how an accepted suggestion changes
// the draft lives here so it is testable without the model.

/// When the editor may offer writing help at all. No dead UI: every entry point
/// is hidden unless the feature is switched on AND the on-device model is ready.
/// Hidden entries are never offered (their text never reaches the model, even
/// while unlocked), and there must be something written to read.
public enum AssistEntryPoint {
    /// Fewest words before "Go deeper" appears (a question about one line is noise).
    public static let goDeeperMinimumWords = 25

    public static func isOffered(enabled: Bool, available: Bool, isHidden: Bool) -> Bool {
        enabled && available && !isHidden
    }

    public static func canRun(enabled: Bool, available: Bool, isHidden: Bool, body: String) -> Bool {
        isOffered(enabled: enabled, available: available, isHidden: isHidden)
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func offersGoDeeper(enabled: Bool, available: Bool, isHidden: Bool, wordCount: Int) -> Bool {
        isOffered(enabled: enabled, available: available, isHidden: isHidden) && wordCount >= goDeeperMinimumWords
    }

    /// The text that may be sent to the model: the body only (title, tags and
    /// the place/weather stamp stay out), trimmed and capped.
    public static func modelInput(body: String, limit: Int = 6_000) -> String {
        String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

/// A parsed "title, tags, summary" reply.
public struct AssistTitleTagSuggestion: Equatable, Sendable {
    public var title: String?
    public var tags: [String]
    public var summary: String?

    public init(title: String? = nil, tags: [String] = [], summary: String? = nil) {
        self.title = title; self.tags = tags; self.summary = summary
    }

    public var isEmpty: Bool { title == nil && tags.isEmpty && summary == nil }
}

public enum AssistResponseParser {
    public static let maxTitleWords = 10
    public static let maxTags = 5

    /// Reads `TITLE: … / TAGS: a, b / SUMMARY: …` (any case, optional bullets,
    /// bold markers or quotes). Unknown lines are ignored; empty fields stay nil.
    public static func parseTitleTags(_ raw: String) -> AssistTitleTagSuggestion {
        var out = AssistTitleTagSuggestion()
        for line in raw.components(separatedBy: .newlines) {
            let t = stripDecoration(line)
            guard let (key, value) = keyValue(t) else { continue }
            switch key {
            case "title":
                let cleaned = cleanTitle(value)
                if !cleaned.isEmpty { out.title = cleaned }
            case "tags", "tag":
                out.tags = cleanTags(value)
            case "summary":
                let s = oneLine(value)
                if !s.isEmpty { out.summary = s }
            default: continue
            }
        }
        return out
    }

    /// A title: unquoted, single line, no trailing period, capped in words.
    public static func cleanTitle(_ raw: String) -> String {
        var t = oneLine(raw).trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’*_#`"))
        while t.hasSuffix(".") { t.removeLast() }
        let words = t.split(whereSeparator: { $0.isWhitespace })
        if words.count > maxTitleWords { t = words.prefix(maxTitleWords).joined(separator: " ") }
        t = t.trimmingCharacters(in: .whitespaces)
        // The on-device model often answers in all lowercase; titles read as
        // sentence case everywhere else in the app. Leave words like "iPhone" alone.
        if let first = t.first, first.isLowercase,
           let firstWord = t.split(separator: " ").first,
           !firstWord.contains(where: { $0.isUppercase }) {
            t = first.uppercased() + t.dropFirst()
        }
        return t
    }

    /// Tags: single words (the model is asked for single-word tags), split on
    /// commas, semicolons or spaces, lowercased, `#` and quotes removed,
    /// de-duplicated and capped.
    public static func cleanTags(_ raw: String) -> [String] {
        let pieces = oneLine(raw).split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        var seen = Set<String>()
        var out: [String] = []
        for piece in pieces {
            var t = piece.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”*_`.()[]")).lowercased()
            while t.hasPrefix("#") { t.removeFirst() }
            guard !t.isEmpty, t.count <= 32, t != "none", t != "n/a" else { continue }
            if seen.insert(t).inserted { out.append(t) }
            if out.count == maxTags { break }
        }
        return out
    }

    /// Collapses whitespace/newlines into single spaces.
    public static func oneLine(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func stripDecoration(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        while let first = t.first, "-*•>".contains(first) { t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces) }
        return t.replacingOccurrences(of: "**", with: "")
    }

    static func keyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, key.count <= 12 else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }
}

/// What the writer picked in the suggestion popover.
public struct AssistSuggestionChoice: Equatable, Sendable {
    public var useTitle: Bool
    public var acceptedTags: Set<String>
    public var insertSummary: Bool

    public init(useTitle: Bool = false, acceptedTags: Set<String> = [], insertSummary: Bool = false) {
        self.useTitle = useTitle; self.acceptedTags = acceptedTags; self.insertSummary = insertSummary
    }

    /// Sensible starting point: take the title only when the entry has none;
    /// every tag starts accepted unless the entry already has it; the summary
    /// is never inserted unless asked for.
    public static func defaults(for suggestion: AssistTitleTagSuggestion, currentTitle: String,
                                currentTags: [String]) -> AssistSuggestionChoice {
        let existing = Set(currentTags.map { $0.lowercased() })
        let titleEmpty = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return AssistSuggestionChoice(
            useTitle: suggestion.title != nil && titleEmpty,
            acceptedTags: Set(suggestion.tags.filter { !existing.contains($0.lowercased()) }),
            insertSummary: false)
    }

    public var changesNothing: Bool { !useTitle && acceptedTags.isEmpty && !insertSummary }
}

/// The editor fields an accepted suggestion may change.
public struct AssistDraft: Equatable, Sendable {
    public var title: String
    public var body: String
    public var tags: [String]

    public init(title: String, body: String, tags: [String]) {
        self.title = title; self.body = body; self.tags = tags
    }
}

public enum AssistApply {
    /// Applies the accepted parts of `suggestion`. Tags keep their existing order,
    /// new ones are appended in suggestion order (never duplicated, case-insensitive);
    /// a summary goes in as a quote line at the top of the body.
    public static func apply(_ suggestion: AssistTitleTagSuggestion, choice: AssistSuggestionChoice,
                             to draft: AssistDraft) -> AssistDraft {
        var out = draft
        if choice.useTitle, let title = suggestion.title, !title.isEmpty { out.title = title }
        var seen = Set(out.tags.map { $0.lowercased() })
        for tag in suggestion.tags where choice.acceptedTags.contains(tag) {
            guard let normalized = TagPath.normalize(tag), seen.insert(normalized.lowercased()).inserted else { continue }
            out.tags.append(normalized)
        }
        if choice.insertSummary, let summary = suggestion.summary, !summary.isEmpty {
            let quote = "> " + AssistResponseParser.oneLine(summary)
            out.body = out.body.isEmpty ? quote + "\n" : quote + "\n\n" + out.body
        }
        return out
    }
}
