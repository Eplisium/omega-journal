import Foundation

// MARK: - Weekly / monthly review scheduling (pure)

public struct ReviewSchedule: Equatable, Sendable {
    public var weeklyEnabled: Bool
    /// Calendar weekday, 1 = Sunday … 7 = Saturday.
    public var weeklyWeekday: Int
    public var monthlyEnabled: Bool
    /// Day of month (1…28 so every month has it).
    public var monthlyDay: Int
    public var hour: Int
    public var minute: Int

    public init(weeklyEnabled: Bool = false, weeklyWeekday: Int = 1, monthlyEnabled: Bool = false,
                monthlyDay: Int = 1, hour: Int = 18, minute: Int = 0) {
        self.weeklyEnabled = weeklyEnabled; self.weeklyWeekday = min(7, max(1, weeklyWeekday))
        self.monthlyEnabled = monthlyEnabled; self.monthlyDay = min(28, max(1, monthlyDay))
        self.hour = min(23, max(0, hour)); self.minute = min(59, max(0, minute))
    }

    /// Next `count` fire dates strictly after `now` for the period.
    public func upcoming(_ period: ReviewPeriod, after now: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        switch period {
        case .week:
            guard weeklyEnabled else { return [] }
            var comps = DateComponents(hour: hour, minute: minute, second: 0, weekday: weeklyWeekday)
            comps.nanosecond = 0
            var out: [Date] = []
            var cursor = now
            while out.count < count,
                  let next = calendar.nextDate(after: cursor, matching: comps, matchingPolicy: .nextTime) {
                out.append(next); cursor = next
            }
            return out
        case .month:
            guard monthlyEnabled else { return [] }
            let comps = DateComponents(day: monthlyDay, hour: hour, minute: minute, second: 0)
            var out: [Date] = []
            var cursor = now
            while out.count < count,
                  let next = calendar.nextDate(after: cursor, matching: comps, matchingPolicy: .nextTime) {
                out.append(next); cursor = next
            }
            return out
        }
    }
}
