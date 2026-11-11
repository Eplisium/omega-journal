import Foundation

// MARK: - Automatic context (pure rules)
//
// What "Add context" may fetch, and how fetched context is written into an
// entry. The app-side `ContextService` does the fetching (CoreLocation +
// MapKit, EventKit, PhotoKit); everything here is deterministic and tested.

public struct ContextSources: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let place = ContextSources(rawValue: 1)
    public static let calendar = ContextSources(rawValue: 2)
    public static let photos = ContextSources(rawValue: 4)
    public static let all: ContextSources = [.place, .calendar, .photos]
}

public enum ContextTrigger: Sendable {
    /// The user pressed "Add context".
    case explicit
    /// A new entry was just created.
    case newEntry
}

public enum ContextPolicy {
    /// Sources to fetch. Every source is opt-in (`enabled` defaults to none).
    /// New entries only fetch place and calendar, and only when the user also
    /// turned on "add context to new entries"; photos always wait for an
    /// explicit pick.
    public static func sources(for trigger: ContextTrigger, enabled: ContextSources, autoOnNewEntry: Bool) -> ContextSources {
        switch trigger {
        case .explicit: return enabled
        case .newEntry: return autoOnNewEntry ? enabled.intersection([.place, .calendar]) : []
        }
    }
}

/// A calendar event, reduced to what a journal needs: a title and a time.
public struct ContextEvent: Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public init(title: String, start: Date, end: Date, isAllDay: Bool) {
        self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
    }
}

public enum ContextFormatting {
    public static let eventsHeading = "**Today's calendar**"
    public static let maxEvents = 12

    /// "Blue Bottle Coffee, Oakland" — the most specific name plus a locality,
    /// without repeating parts. nil when there is nothing usable.
    public static func placeLabel(name: String?, locality: String?, area: String?, country: String?) -> String? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let parts = [clean(name), clean(locality), clean(area), clean(country)].compactMap { $0 }
        guard let first = parts.first else { return nil }
        // A second part that the first already contains adds nothing ("Oakland, CA" + "Oakland").
        if let second = parts.dropFirst().first(where: { !first.localizedCaseInsensitiveContains($0) }) {
            return "\(first), \(second)"
        }
        return first
    }

    /// Markdown list of the day's events: all-day first, then by start time.
    /// Titles are single-line and Markdown-neutral; at most `maxEvents`.
    public static func eventsMarkdown(_ events: [ContextEvent], timeZone: TimeZone = .current,
                                      locale: Locale = .current) -> String? {
        guard !events.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        let sorted = events.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            return (a.start, a.title) < (b.start, b.title)
        }
        var lines = [eventsHeading]
        for e in sorted.prefix(maxEvents) {
            let when = e.isAllDay ? "All day" : (e.end > e.start ? "\(f.string(from: e.start)) – \(f.string(from: e.end))" : f.string(from: e.start))
            lines.append("- \(when) · \(safeTitle(e.title))")
        }
        if sorted.count > maxEvents { lines.append("- and \(sorted.count - maxEvents) more") }
        return lines.joined(separator: "\n")
    }

    static func safeTitle(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "Untitled event" }
        // Keep the line a plain list item: no HTML comments (stamps) or leading Markdown markers.
        t = t.replacingOccurrences(of: "<!--", with: "‹!--").replacingOccurrences(of: "-->", with: "--›")
        if let first = t.first, "#>-*+".contains(first) { t = "\\" + t }
        return t
    }

    /// Adds the events block to `body` (before a trailing place stamp). A body
    /// that already has the exact block is returned unchanged.
    public static func insertingEvents(_ block: String, into body: String) -> String {
        let (stamp, rest) = PlaceStampCodec.split(body)
        guard !rest.contains(block) else { return body }
        let trimmed = rest.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let joined = trimmed.isEmpty ? block : trimmed + "\n\n" + block
        return PlaceStampCodec.join(stamp: stamp, rest: joined)
    }

    /// Start (inclusive) and end (exclusive) of `day` in `calendar`.
    public static func dayInterval(_ day: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: day)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    /// Photo file name for an attached library photo: "Photo 2025-12-15 at 09.41.heic".
    public static func photoFilename(created: Date?, uniformTypeExtension ext: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safeExt = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        return "Photo \(created.map(f.string(from:)) ?? "from library").\(safeExt.isEmpty ? "jpg" : safeExt)"
    }
}
