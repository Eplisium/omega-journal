import Foundation

// MARK: - Entry row meta text (pure)
//
// Rows used to print "Nov 10, 2026 at 9:00 PM · 33w" — long, and "33w" reads
// like weeks. Dates are now compact and relative, matching the list's section
// headers (Today / Yesterday / Previous 7 Days / month):
//   today          → "9:00 PM"
//   yesterday      → "Yesterday"           (with time: "Yesterday, 9:00 PM")
//   last 6 days    → "Monday"              (with time: "Monday, 9:00 PM")
//   this year      → "Nov 10"
//   other years    → "Nov 10, 2025"
// Word counts are spelled out: "1 word", "33 words", "1,204 words".

public enum UIRowMetaFormat {
    /// `includeTime` adds the time of day to recent (yesterday / this week)
    /// dates — the richer layout candidate. Today always shows its time.
    public static func dateText(for date: Date, now: Date = Date(), calendar: Calendar = .current,
                                locale: Locale = .current, includeTime: Bool = false) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(86_400)
        let time = date.formatted(style.hour().minute())

        if date >= startOfToday && date < startOfTomorrow { return time }
        if date < startOfToday {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 99
            if days == 1 { return includeTime ? "Yesterday, \(time)" : "Yesterday" }
            if days >= 2 && days <= 6 {
                let weekday = date.formatted(style.weekday(.wide))
                return includeTime ? "\(weekday), \(time)" : weekday
            }
        }
        style = style.month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }

    /// "1 word", "33 words", "1,204 words".
    public static func wordCountText(_ count: Int, locale: Locale = .current) -> String {
        let n = count.formatted(.number.locale(locale))
        return count == 1 ? "1 word" : "\(n) words"
    }
}
