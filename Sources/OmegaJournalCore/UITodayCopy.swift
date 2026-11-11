import Foundation

// MARK: - Today page copy (pure)
//
// Today used to show its numbers three times (sidebar footer, a streak-ring
// stat line, a progress card) and again in Insights. It now carries only what
// is about *today*: the date with the current streak beside it, and today's
// goal progress inside the writing hero. Totals live in the sidebar footer and
// Insights.

public enum UITodayCopy {
    /// "Wednesday, November 11 · 4-day streak". The streak is left out below
    /// two (a one-day "streak" is just today).
    public static func dateLine(dateText: String, streak: Int, unit: String) -> String {
        guard streak >= 2 else { return dateText }
        return "\(dateText) · \(streak)-\(unit) streak"
    }

    /// Accessibility form of the date line.
    public static func dateLineAccessibility(dateText: String, streak: Int, unit: String) -> String {
        guard streak >= 2 else { return dateText }
        return "\(dateText). Writing streak: \(streak) \(unit)s."
    }

    /// Hero heading when nothing is written yet today.
    public static let promptHeading = "Today's prompt"
    /// Hero heading when today has an entry.
    public static let entryHeading = "Today's entry"
}
