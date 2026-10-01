import Foundation

// MARK: - Template variables (pure)
//
// `{{date}}` `{{time}}` `{{weekday}}` `{{prompt}}` `{{mood}}`. Unknown variables are left
// untouched so literal braces in a user's template survive. Case-insensitive, spaces allowed
// inside the braces (`{{ date }}`).

public struct TemplateContext: Sendable {
    public var date: Date
    public var prompt: String
    public var moodLabel: String
    public var calendar: Calendar
    public var locale: Locale

    public init(date: Date = Date(), prompt: String = "", moodLabel: String = "",
                calendar: Calendar = .current, locale: Locale = .current) {
        self.date = date; self.prompt = prompt; self.moodLabel = moodLabel
        self.calendar = calendar; self.locale = locale
    }
}

public enum TemplateExpander {
    public static let variableNames = ["date", "time", "weekday", "prompt", "mood"]

    private static let regex = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z]+)\s*\}\}"#)

    public static func value(for name: String, context: TemplateContext) -> String? {
        switch name.lowercased() {
        case "date":
            let f = DateFormatter()
            f.calendar = context.calendar; f.locale = context.locale; f.timeZone = context.calendar.timeZone
            f.dateStyle = .long; f.timeStyle = .none
            return f.string(from: context.date)
        case "time":
            let f = DateFormatter()
            f.calendar = context.calendar; f.locale = context.locale; f.timeZone = context.calendar.timeZone
            f.dateStyle = .none; f.timeStyle = .short
            return f.string(from: context.date)
        case "weekday":
            let f = DateFormatter()
            f.calendar = context.calendar; f.locale = context.locale; f.timeZone = context.calendar.timeZone
            f.setLocalizedDateFormatFromTemplate("EEEE")
            return f.string(from: context.date)
        case "prompt": return context.prompt
        case "mood": return context.moodLabel
        default: return nil
        }
    }

    /// Replaces every known variable in `text`.
    public static func expand(_ text: String, context: TemplateContext) -> String {
        guard text.contains("{{") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let name = ns.substring(with: m.range(at: 1))
            guard let value = value(for: name, context: context) else { return }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += value
            last = NSMaxRange(m.range)
        }
        out += ns.substring(from: last)
        return out
    }

    /// Variables referenced by `text` (known ones only, unique, in first-seen order).
    public static func variables(in text: String) -> [String] {
        let ns = text as NSString
        var seen: [String] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            if variableNames.contains(name), !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    /// Splits a comma-separated tag field into normalised tags (no `#`, no commas, no dupes).
    public static func parseTagField(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for part in raw.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
            let key = t.lowercased()
            if !t.isEmpty, seen.insert(key).inserted { out.append(t) }
        }
        return out
    }

    /// Final title/body/tags for a new entry started from a template.
    /// A template named "Blank" gets no title; otherwise the (expanded) name is the title.
    public static func instantiate(name: String, body: String, tags: [String],
                                   context: TemplateContext) -> (title: String, body: String, tags: [String]) {
        let title = name == "Blank" ? "" : expand(name, context: context)
        return (title, expand(body, context: context), tags.map { expand($0, context: context) }.filter { !$0.isEmpty })
    }
}
