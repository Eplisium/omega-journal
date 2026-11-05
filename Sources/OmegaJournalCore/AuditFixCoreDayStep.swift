import Foundation

// MARK: - DST-safe day and week stepping
//
// Where DST starts at local midnight (America/Santiago, America/Havana,
// Asia/Beirut, Africa/Cairo, America/Asuncion, Atlantic/Azores), that day's
// `startOfDay` is 01:00. `calendar.date(byAdding: .day, value: ±1, to:)`
// keeps the 01:00 wall-clock time on every later step, so a walk that
// compares its cursor with `startOfDay` keys never matches again. Walks step
// from a noon anchor instead (noon exists on every day) and re-normalise to
// the start of the target day or week.

public enum DayStep {
    /// Noon on `date`'s local day.
    public static func noon(of date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start)
            ?? start.addingTimeInterval(12 * 3600)
    }

    /// Start of the local day `days` days after `date`'s day (negative = earlier).
    public static func startOfDay(byAdding days: Int, to date: Date, calendar: Calendar) -> Date {
        let anchor = noon(of: date, calendar: calendar)
        let moved = calendar.date(byAdding: .day, value: days, to: anchor)
            ?? anchor.addingTimeInterval(Double(days) * 86_400)
        return calendar.startOfDay(for: moved)
    }

    /// Start of the week `weeks` weeks after the week containing `date`
    /// (the calendar's `firstWeekday` decides where weeks begin).
    public static func startOfWeek(byAdding weeks: Int, to date: Date, calendar: Calendar) -> Date? {
        let anchor = noon(of: date, calendar: calendar)
        guard let moved = calendar.date(byAdding: .weekOfYear, value: weeks, to: anchor) else { return nil }
        return calendar.dateInterval(of: .weekOfYear, for: moved)?.start
    }
}
