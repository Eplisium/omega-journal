import Foundation

// MARK: - Template picker preview (pure)
//
// What the template picker shows before an entry is created: the entry title
// the template will produce, a one-line purpose, the sections it prompts for,
// and the filled-in body (today's date/prompt/mood) for a rendered preview.

public struct TemplatePickerSummary: Equatable, Sendable {
    /// Name with variables filled in, for list rows ("{{weekday}} check-in" → "Tuesday check-in").
    public var displayName: String
    /// Title of the entry this template creates ("" = untitled, e.g. Blank).
    public var entryTitle: String
    public var purpose: String
    /// Headings / labelled prompts the body walks through, in order.
    public var sections: [String]
    /// Body with variables filled in — render this as Markdown.
    public var filledBody: String
    public var tags: [String]

    public var isBlank: Bool { filledBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum TemplatePickerPreview {
    /// One-line purposes for the built-in templates (only used while the
    /// template still has its built-in body — an edited template describes itself).
    public static let builtInPurposes: [String: String] = [
        "Daily Reflection": "Close out the day: highlights, challenges, gratitude, and a plan for tomorrow.",
        "Gratitude": "List three good things from today and why they mattered.",
        "Weekly Review": "Look back on the week: what went well, what didn't, lessons, and next week's focus.",
        "Dream Log": "Capture a dream while it's fresh: the setting, what happened, how it felt, what it might mean.",
        "Decision Log": "Record a decision, the options, why you chose, and how you'll know it worked.",
        "Blank": "An empty page — no prompts and no tags.",
    ]

    public static func summary(name: String, body: String, tags: [String],
                               knownPurpose: String? = nil,
                               context: TemplateContext) -> TemplatePickerSummary {
        let filled = TemplateExpander.instantiate(name: name, body: body, tags: tags, context: context)
        let sections = sections(in: filled.body)
        let displayName = TemplateExpander.expand(name, context: context)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TemplatePickerSummary(
            displayName: displayName.isEmpty ? "Untitled template" : displayName,
            entryTitle: filled.title.trimmingCharacters(in: .whitespacesAndNewlines),
            purpose: knownPurpose ?? derivedPurpose(filledBody: filled.body, sections: sections),
            sections: sections,
            filledBody: filled.body,
            tags: filled.tags)
    }

    /// Describes a custom template from its own content.
    public static func derivedPurpose(filledBody: String, sections: [String]) -> String {
        if !sections.isEmpty {
            let shown = sections.prefix(3).joined(separator: ", ")
            let more = sections.count > 3 ? ", and \(sections.count - 3) more" : ""
            return "Prompts for \(shown)\(more)."
        }
        guard let first = MarkdownPlainPreview.lines(filledBody, limit: 1).first else {
            return "An empty page — no prompts and no tags."
        }
        return first.count > 90 ? String(first.prefix(89)) + "…" : first
    }

    /// Section prompts: `##`+ headings (falling back to `#` headings when there
    /// are no sub-headings), bold labels (`**Setting:**`) and short lines that
    /// end in a colon ("Why they mattered:"). Code fences are skipped.
    public static func sections(in markdown: String, limit: Int = 8) -> [String] {
        var sub: [String] = [], top: [String] = [], labels: [String] = []
        var order: [(kind: Int, text: String)] = []
        var inFence = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty { continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = clean(String(line.dropFirst(level)))
                guard !text.isEmpty, level <= 6 else { continue }
                if level == 1 { top.append(text); order.append((1, text)) } else { sub.append(text); order.append((2, text)) }
                continue
            }
            if line.hasPrefix("**"), let label = boldLabel(line) {
                labels.append(label); order.append((3, label)); continue
            }
            if line.hasSuffix(":"), line.count <= 40, !line.hasPrefix("-"), !line.hasPrefix("*") {
                let text = clean(String(line.dropLast()))
                if !text.isEmpty { labels.append(text); order.append((3, text)) }
            }
        }
        // `# Title` lines are usually the page heading; only list them when
        // the template has no finer structure.
        let useTop = sub.isEmpty && labels.isEmpty
        var out: [String] = []
        for item in order where item.kind != 1 || useTop {
            if !out.contains(item.text) { out.append(item.text) }
            if out.count >= limit { break }
        }
        return out
    }

    /// Keeps the picker's selection valid after templates are added, deleted
    /// or reordered: the current id if it still exists, else the first one.
    public static func resolveSelection(current: String?, available: [String]) -> String? {
        if let current, available.contains(current) { return current }
        return available.first
    }

    private static func boldLabel(_ line: String) -> String? {
        let inner = line.dropFirst(2)
        guard let end = inner.range(of: "**") else { return nil }
        var text = String(inner[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(":") { text.removeLast() }
        text = clean(text)
        return text.isEmpty ? nil : text
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespaces)
    }
}
