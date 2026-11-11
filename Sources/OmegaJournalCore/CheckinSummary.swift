import Foundation

// MARK: - Today check-in summary (pure)

/// The one line the collapsed check-in on Today shows, so the page stays quiet
/// until you open it.
public enum CheckinSummary {
    /// "2 of 3 logged · 1 of 2 habits done". Counts only metrics and habits that
    /// still exist, so values of a removed metric never inflate it.
    public static func line(metricsLogged: Int, metricCount: Int, habitsDone: Int, habitCount: Int) -> String {
        if metricCount == 0 && habitCount == 0 { return "Add something to track" }
        var parts: [String] = []
        if metricCount > 0 {
            parts.append(metricsLogged == 0 ? "Nothing logged yet" : "\(min(metricsLogged, metricCount)) of \(metricCount) logged")
        }
        if habitCount > 0 {
            parts.append("\(min(habitsDone, habitCount)) of \(habitCount) \(habitCount == 1 ? "habit" : "habits") done")
        }
        return parts.joined(separator: " · ")
    }

    /// Everything tracked has a value / is checked off today (and there is something to track).
    public static func isComplete(metricsLogged: Int, metricCount: Int, habitsDone: Int, habitCount: Int) -> Bool {
        (metricCount > 0 || habitCount > 0) && metricsLogged >= metricCount && habitsDone >= habitCount
    }
}
