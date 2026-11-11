import Foundation

// MARK: - Insights labels (pure)
//
// The Insights header had five equally weighted tiles, one of them a bare
// "1.0 · Entries per writing day · Your cadence", a "Best writing day" whose
// value was a unit-less "34", and a "Mood check-ins" tile that actually showed
// the average. Charts showed bare numbers without units, and correlations
// showed "r = +0.42". These helpers hold the tightened copy so it is tested.

public enum UIInsightsCopy {
    /// "1 word" / "34 words" / "1,204 words".
    public static func words(_ n: Int, locale: Locale = .current) -> String {
        UIRowMetaFormat.wordCountText(n, locale: locale)
    }

    /// "1 entry" / "9 entries".
    public static func entries(_ n: Int, locale: Locale = .current) -> String {
        "\(n.formatted(.number.locale(locale))) \(n == 1 ? "entry" : "entries")"
    }

    /// Detail under "Words written": "Across 9 entries · about 16 each".
    public static func wordsDetail(entryCount: Int, averagePerEntry: Int?, locale: Locale = .current) -> String {
        guard entryCount > 0 else { return "Nothing written yet" }
        let across = "Across \(entries(entryCount, locale: locale))"
        guard entryCount > 1, let avg = averagePerEntry else { return across }
        return "\(across) · about \(avg.formatted(.number.locale(locale))) each"
    }

    /// Detail under "Average mood": "From 9 check-ins".
    public static func moodDetail(checkIns: Int) -> String {
        switch checkIns {
        case 0: return "No check-ins yet"
        case 1: return "From 1 check-in"
        default: return "From \(checkIns) check-ins"
        }
    }

    /// Detail under "Writing days": "9 of 30 days" for bounded periods.
    public static func writingDaysDetail(writingDays: Int, periodDays: Int?) -> String {
        guard let periodDays, periodDays > 0 else { return "All time" }
        return "\(min(writingDays, periodDays)) of \(periodDays) days"
    }

    /// Plain-language chip for a check-in/mood correlation (replaces "r = +0.42").
    public static func correlationChip(strength: String) -> String {
        switch strength {
        case "strong": return "Strong link"
        case "moderate": return "Moderate link"
        case "weak": return "Weak link"
        default: return "No clear link"
        }
    }

    /// "Current streak" pattern value.
    public static func streak(_ days: Int) -> String {
        switch days {
        case ..<1: return "Start when ready"
        case 1: return "1 day"
        default: return "\(days) days in a row"
        }
    }
}
