import Foundation

/// Shared, cached formatters. `DateFormatter` is expensive to create, so views and
/// the data layer reuse these instead of building one per call.
enum DateFormatters {
    private static func make(_ format: String, posix: Bool = false) -> DateFormatter {
        let f = DateFormatter()
        if posix { f.locale = Locale(identifier: "en_US_POSIX") }
        f.dateFormat = format
        return f
    }

    /// Local-calendar day stamp, e.g. `2026-10-05` (locale-independent).
    static let dayStamp = make("yyyy-MM-dd", posix: true)
    /// Backup file stamp, e.g. `2026-10-05_13-45-10-123`.
    static let fileStamp = make("yyyy-MM-dd_HH-mm-ss-SSS", posix: true)
    /// `Mon, Oct 5`.
    static let weekdayMonthDay = make("EEE, MMM d")
    /// `Oct`.
    static let monthAbbrev = make("MMM")
    /// Localized full date, e.g. `Monday, October 5, 2026`.
    static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()
}
