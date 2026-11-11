import Foundation

// MARK: - "Go deeper" follow-up questions (pure)

public enum AssistFollowUps {
    public static let maxQuestions = 3
    public static let maxQuestionLength = 180

    /// How an accepted question is written into the entry.
    public enum InsertStyle: String, CaseIterable, Sendable {
        case quote, heading
        public var label: String { self == .quote ? "Insert as quote" : "Insert as heading" }
    }

    /// Reads 1–3 questions from a model reply: one per line, numbering/bullets
    /// and quotes stripped, each ending in "?", duplicates and over-long lines
    /// dropped. Lines that aren't questions (preambles like "Here are…") are skipped.
    public static func parse(_ raw: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for line in raw.components(separatedBy: .newlines) {
            var t = line.trimmingCharacters(in: .whitespaces)
            t = stripListMarker(t)
            t = t.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’*_`"))
            if let colon = t.firstIndex(of: ":"), t[..<colon].lowercased().hasPrefix("question") {
                t = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard t.hasSuffix("?"), t.count >= 8, t.count <= maxQuestionLength else { continue }
            let key = t.lowercased()
            if seen.insert(key).inserted { out.append(t) }
            if out.count == maxQuestions { break }
        }
        return out
    }

    /// Text to insert at the caret. Block syntax always starts on its own line
    /// and leaves an empty line to write the answer on.
    public static func insertion(_ question: String, style: InsertStyle, atLineStart: Bool) -> String {
        let q = AssistResponseParser.oneLine(question)
        let lead = atLineStart ? "" : "\n\n"
        switch style {
        case .quote: return lead + "> " + q + "\n\n"
        case .heading: return lead + "### " + q + "\n\n"
        }
    }

    static func stripListMarker(_ s: String) -> String {
        var t = Substring(s)
        while let first = t.first, "-*•>".contains(first) { t = t.dropFirst().drop(while: { $0 == " " }) }
        // "1." / "2)" / "(3)"
        if let end = t.firstIndex(where: { !$0.isNumber && $0 != "(" }), end != t.startIndex,
           t[t.startIndex..<end].contains(where: \.isNumber),
           t[end] == "." || t[end] == ")" {
            t = t[t.index(after: end)...].drop(while: { $0 == " " })
        }
        return String(t)
    }
}
