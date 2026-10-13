import Foundation

// MARK: - Year in review (pure)

public struct YearReviewEntry: Equatable, Sendable {
    public let title: String
    public let wordCount: Int
    public let mood: Int
    public let tags: [String]
    public let createdAt: Date
    public let isFavorite: Bool
    public init(title: String, wordCount: Int, mood: Int, tags: [String], createdAt: Date, isFavorite: Bool = false) {
        self.title = title; self.wordCount = wordCount; self.mood = mood; self.tags = tags
        self.createdAt = createdAt; self.isFavorite = isFavorite
    }
}

public struct YearReview: Equatable, Sendable {
    public let year: Int
    public let entryCount: Int
    public let totalWords: Int
    public let writingDays: Int
    public let longestStreak: Int
    public let averageMood: Double?
    /// 12 months, index 0 = January; nil average when no entries.
    public let monthlyEntries: [Int]
    public let monthlyMood: [Double?]
    public let topTags: [(tag: String, count: Int)]
    public let bestMonth: Int?
    public let longestEntryTitle: String?
    public let longestEntryWords: Int
    public let favoriteTitles: [String]

    public static func == (a: YearReview, b: YearReview) -> Bool {
        a.year == b.year && a.entryCount == b.entryCount && a.totalWords == b.totalWords
            && a.writingDays == b.writingDays && a.longestStreak == b.longestStreak
            && a.monthlyEntries == b.monthlyEntries
    }
}

public enum YearReviewBuilder {
    public static func build(year: Int, entries: [YearReviewEntry], calendar: Calendar = .current) -> YearReview {
        let inYear = entries.filter { calendar.component(.year, from: $0.createdAt) == year }
        var monthCount = [Int](repeating: 0, count: 12)
        var monthMoodSum = [Double](repeating: 0, count: 12)
        var tagCounts: [String: Int] = [:]
        for e in inYear {
            let m = calendar.component(.month, from: e.createdAt) - 1
            guard (0..<12).contains(m) else { continue }
            monthCount[m] += 1
            monthMoodSum[m] += Double(e.mood)
            for t in Set(e.tags.map { $0.lowercased() }) { tagCounts[t, default: 0] += 1 }
        }
        let monthMood: [Double?] = (0..<12).map { monthCount[$0] > 0 ? monthMoodSum[$0] / Double(monthCount[$0]) : nil }
        let days = Set(inYear.map { calendar.startOfDay(for: $0.createdAt) })
        let longest = StreakHistory.runs(days: days, calendar: calendar).map(\.length).max() ?? 0
        let avg = inYear.isEmpty ? nil : Double(inYear.reduce(0) { $0 + $1.mood }) / Double(inYear.count)
        var best: Int?
        var bestVal = -1.0
        for m in 0..<12 { if let v = monthMood[m], v > bestVal { bestVal = v; best = m + 1 } }
        let longestEntry = inYear.max { $0.wordCount < $1.wordCount }
        return YearReview(
            year: year, entryCount: inYear.count, totalWords: inYear.reduce(0) { $0 + $1.wordCount },
            writingDays: days.count, longestStreak: longest, averageMood: avg,
            monthlyEntries: monthCount, monthlyMood: monthMood,
            topTags: tagCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(8).map { ($0.key, $0.value) },
            bestMonth: best,
            longestEntryTitle: longestEntry.map { $0.title.isEmpty ? "Untitled" : $0.title },
            longestEntryWords: longestEntry?.wordCount ?? 0,
            favoriteTitles: inYear.filter(\.isFavorite).sorted { $0.createdAt < $1.createdAt }
                .prefix(5).map { $0.title.isEmpty ? "Untitled" : $0.title }
        )
    }

    /// Years that have at least one entry, newest first.
    public static func availableYears(_ entries: [YearReviewEntry], calendar: Calendar = .current) -> [Int] {
        Array(Set(entries.map { calendar.component(.year, from: $0.createdAt) })).sorted(by: >)
    }
}

// MARK: - On This Day v2 (multi-year)

public struct OnThisDayYear<Item> {
    public let year: Int
    public let items: [Item]
}

public enum OnThisDayGrouping {
    /// Groups items written on `reference`'s month/day in earlier years by year, newest year first.
    /// `yearsAgo` filters (e.g. 1 for "a year ago").
    public static func group<Item>(_ items: [Item], date: (Item) -> Date, reference: Date = Date(),
                                   calendar: Calendar = .current) -> [OnThisDayYear<Item>] {
        let y = calendar.component(.year, from: reference)
        var byYear: [Int: [Item]] = [:]
        for item in items {
            let iy = calendar.component(.year, from: date(item))
            guard iy < y, isSameMonthDay(date(item), as: reference, calendar: calendar) else { continue }
            byYear[iy, default: []].append(item)
        }
        return byYear.keys.sorted(by: >).map { year in
            OnThisDayYear(year: year, items: (byYear[year] ?? []).sorted { date($0) < date($1) })
        }
    }

    /// Whether `date` falls on `reference`'s month/day. On Feb 28 of a year
    /// without Feb 29, leap-day (Feb 29) memories also match so they surface.
    public static func isSameMonthDay(_ date: Date, as reference: Date, calendar: Calendar = .current) -> Bool {
        let r = calendar.dateComponents([.month, .day], from: reference)
        let c = calendar.dateComponents([.month, .day], from: date)
        if c.month == r.month && c.day == r.day { return true }
        guard r.month == 2, r.day == 28, c.month == 2, c.day == 29 else { return false }
        let daysInFeb = calendar.range(of: .day, in: .month, for: reference)?.count ?? 28
        return daysInFeb < 29
    }

    /// "N years ago" by calendar year, independent of time of day (a
    /// `dateComponents([.year])` diff reads 0 when the old entry was written
    /// later in the day than now).
    public static func yearsAgo(_ date: Date, reference: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.component(.year, from: reference) - calendar.component(.year, from: date)
    }
}
