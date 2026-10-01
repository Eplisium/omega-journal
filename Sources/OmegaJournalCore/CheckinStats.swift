import Foundation

// MARK: - Check-in metrics (pure model + statistics)

/// How a metric is entered and displayed.
public enum CheckinMetricKind: String, Codable, CaseIterable, Sendable {
    /// 1…5 tap scale (energy, stress, …).
    case scale
    /// Free number with an optional unit (hours of sleep, glasses of water, …).
    case number
}

public struct CheckinMetric: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var kind: CheckinMetricKind
    public var unit: String
    public var sortOrder: Int
    public var isBuiltin: Bool
    public var icon: String

    public init(id: String, name: String, kind: CheckinMetricKind, unit: String = "",
                sortOrder: Int = 0, isBuiltin: Bool = false, icon: String = "circle") {
        self.id = id; self.name = name; self.kind = kind; self.unit = unit
        self.sortOrder = sortOrder; self.isBuiltin = isBuiltin; self.icon = icon
    }

    public static let sleepId = "builtin-sleep"
    public static let energyId = "builtin-energy"
    public static let stressId = "builtin-stress"
}

/// One metric value on one calendar day ("yyyy-MM-dd" local day key).
public struct CheckinValue: Equatable, Hashable, Sendable {
    public let day: String
    public let metricId: String
    public let value: Double
    public init(day: String, metricId: String, value: Double) {
        self.day = day; self.metricId = metricId; self.value = value
    }
}

public enum DayKey {
    public static func string(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

// MARK: - Statistics

public struct CorrelationResult: Equatable, Sendable {
    /// Pearson r in -1…1.
    public let r: Double
    /// Number of paired days.
    public let n: Int

    public enum Strength: String, Sendable { case none, weak, moderate, strong }

    public var strength: Strength {
        let a = abs(r)
        if n < CheckinStats.minimumPairs { return .none }
        if a >= 0.6 { return .strong }
        if a >= 0.35 { return .moderate }
        if a >= 0.15 { return .weak }
        return .none
    }

    /// Plain-language sentence for the Insights UI.
    public func sentence(metric: String) -> String {
        guard n >= CheckinStats.minimumPairs else {
            return "Need at least \(CheckinStats.minimumPairs) days of \(metric) and entries to compare."
        }
        let direction = r >= 0 ? "higher" : "lower"
        switch strength {
        case .none: return "No clear link between \(metric) and mood so far (\(n) days)."
        case .weak: return "Slight tendency: more \(metric) goes with \(direction) mood (\(n) days)."
        case .moderate: return "More \(metric) tends to go with \(direction) mood (\(n) days)."
        case .strong: return "Strong pattern: more \(metric) goes with \(direction) mood (\(n) days)."
        }
    }
}

public struct WeekdayMood: Equatable, Sendable {
    /// Calendar weekday, 1 = Sunday … 7 = Saturday.
    public let weekday: Int
    public let averageMood: Double?
    public let entryCount: Int
}

public struct TagMood: Equatable, Sendable {
    public let tag: String
    public let averageMood: Double
    public let count: Int
    /// Difference from the overall average mood.
    public let delta: Double
}

public struct MoodSplit: Equatable, Sendable {
    public let threshold: Double
    public let lowAverage: Double?
    public let highAverage: Double?
    public let lowDays: Int
    public let highDays: Int
}

public enum CheckinStats {
    /// Below this many paired days a correlation is not reported.
    public static let minimumPairs = 5

    /// Pearson correlation. Nil for fewer than 3 pairs or zero variance.
    public static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        let n = min(xs.count, ys.count)
        guard n >= 3 else { return nil }
        let x = Array(xs.prefix(n)), y = Array(ys.prefix(n))
        let mx = x.reduce(0, +) / Double(n), my = y.reduce(0, +) / Double(n)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<n {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 1e-12, syy > 1e-12 else { return nil }
        return max(-1, min(1, sxy / (sxx * syy).squareRoot()))
    }

    /// Mean mood per day-key from (date, mood 1…5) entry samples.
    public static func dailyMood(_ samples: [(date: Date, mood: Int)], calendar: Calendar = .current) -> [String: Double] {
        var sums: [String: (Double, Int)] = [:]
        for s in samples {
            let k = DayKey.string(from: s.date, calendar: calendar)
            let cur = sums[k] ?? (0, 0)
            sums[k] = (cur.0 + Double(s.mood), cur.1 + 1)
        }
        return sums.mapValues { $0.0 / Double($0.1) }
    }

    /// Correlates a metric's daily values with daily mood on days having both.
    public static func correlation(metricValues: [String: Double], dailyMood: [String: Double]) -> CorrelationResult? {
        let days = metricValues.keys.filter { dailyMood[$0] != nil }.sorted()
        guard let r = pearson(days.map { metricValues[$0]! }, days.map { dailyMood[$0]! }) else { return nil }
        return CorrelationResult(r: r, n: days.count)
    }

    /// Average mood on days at/above vs below `threshold` (e.g. sleep ≥ 7h).
    public static func moodSplit(metricValues: [String: Double], dailyMood: [String: Double], threshold: Double) -> MoodSplit {
        var low: [Double] = [], high: [Double] = []
        for (day, v) in metricValues {
            guard let m = dailyMood[day] else { continue }
            if v >= threshold { high.append(m) } else { low.append(m) }
        }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        return MoodSplit(threshold: threshold, lowAverage: avg(low), highAverage: avg(high),
                         lowDays: low.count, highDays: high.count)
    }

    /// Average mood for each weekday (1 = Sunday … 7), ordered from the calendar's first weekday.
    public static func moodByWeekday(_ samples: [(date: Date, mood: Int)], calendar: Calendar = .current) -> [WeekdayMood] {
        var sums = [Int: (Double, Int)]()
        for s in samples {
            let w = calendar.component(.weekday, from: s.date)
            let cur = sums[w] ?? (0, 0)
            sums[w] = (cur.0 + Double(s.mood), cur.1 + 1)
        }
        return (0..<7).map { offset in
            let w = (calendar.firstWeekday - 1 + offset) % 7 + 1
            if let s = sums[w] { return WeekdayMood(weekday: w, averageMood: s.0 / Double(s.1), entryCount: s.1) }
            return WeekdayMood(weekday: w, averageMood: nil, entryCount: 0)
        }
    }

    /// Tags whose entries run happier/sadder than average. Tags with fewer than
    /// `minCount` entries are ignored. Sorted by |delta| desc.
    public static func moodByTag(_ samples: [(mood: Int, tags: [String])], minCount: Int = 3) -> [TagMood] {
        guard !samples.isEmpty else { return [] }
        let overall = Double(samples.reduce(0) { $0 + $1.mood }) / Double(samples.count)
        var sums: [String: (Double, Int)] = [:]
        for s in samples {
            for t in Set(s.tags.map { $0.lowercased() }) {
                let cur = sums[t] ?? (0, 0)
                sums[t] = (cur.0 + Double(s.mood), cur.1 + 1)
            }
        }
        return sums.compactMap { tag, v -> TagMood? in
            guard v.1 >= minCount else { return nil }
            let a = v.0 / Double(v.1)
            return TagMood(tag: tag, averageMood: a, count: v.1, delta: a - overall)
        }
        .sorted { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.tag < $1.tag }
    }
}

// MARK: - Streak history

public struct StreakRun: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let length: Int
}

public enum StreakHistory {
    /// Every run of consecutive writing days, longest first (ties: most recent first).
    public static func runs(days: Set<Date>, calendar: Calendar = .current) -> [StreakRun] {
        let sorted = Set(days.map { calendar.startOfDay(for: $0) }).sorted()
        var out: [StreakRun] = []
        var start: Date?, prev: Date?, len = 0
        for d in sorted {
            if let p = prev, calendar.date(byAdding: .day, value: 1, to: p) == d {
                len += 1
            } else {
                if let s = start, let p = prev { out.append(StreakRun(start: s, end: p, length: len)) }
                start = d; len = 1
            }
            prev = d
        }
        if let s = start, let p = prev { out.append(StreakRun(start: s, end: p, length: len)) }
        return out.sorted { $0.length != $1.length ? $0.length > $1.length : $0.end > $1.end }
    }
}
