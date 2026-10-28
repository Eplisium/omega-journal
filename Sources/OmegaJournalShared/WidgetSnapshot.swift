import Foundation
import OmegaJournalCore

// MARK: - Snapshot model

/// The ONLY journal data that leaves the app for the widget (and the
/// "Today's progress" intent): counts, a streak, a date and the day's writing
/// prompt. Never titles, bodies, tags, moods or anything from a hidden entry.
///
/// The app writes it into the App Group container (`WidgetSnapshotStore`); the
/// sandboxed widget extension only ever reads it. It carries one `Day` per
/// upcoming calendar day so the widget can roll over at midnight (words reset,
/// tomorrow's prompt, the streak as it will read then) without the app running.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Bump when the JSON shape changes incompatibly; readers ignore other versions.
    public static let currentVersion = 1

    public struct Day: Codable, Equatable, Sendable {
        /// Start of the calendar day this row describes.
        public var dayStart: Date
        /// Words written in visible entries created on this day.
        public var words: Int
        /// Visible entries created on this day.
        public var entries: Int
        /// Current streak as it reads on this day (see `StreakCalculator`).
        public var streak: Int
        /// True when this day already has a visible entry.
        public var writtenToday: Bool
        /// The day's writing prompt (`PromptGenerator`), not user content.
        public var prompt: String

        public init(dayStart: Date, words: Int, entries: Int, streak: Int, writtenToday: Bool, prompt: String) {
            self.dayStart = dayStart
            self.words = words
            self.entries = entries
            self.streak = streak
            self.writtenToday = writtenToday
            self.prompt = prompt
        }
    }

    public var version: Int
    public var generatedAt: Date
    /// Daily word goal (Settings › Goals), at least 1.
    public var dailyWordGoal: Int
    /// What the streak counts: "day" or "week" (`StreakSummary.unit`).
    public var streakUnit: String
    /// Most recent visible entry at or before `generatedAt`.
    public var lastWrittenAt: Date?
    /// Today first, then the following days in order.
    public var days: [Day]

    public init(version: Int = WidgetSnapshot.currentVersion, generatedAt: Date, dailyWordGoal: Int,
                streakUnit: String, lastWrittenAt: Date?, days: [Day]) {
        self.version = version
        self.generatedAt = generatedAt
        self.dailyWordGoal = dailyWordGoal
        self.streakUnit = streakUnit
        self.lastWrittenAt = lastWrittenAt
        self.days = days
    }
}

// MARK: - Builder input

/// What the builder may see of an entry. Deliberately no title, body or tags:
/// the snapshot cannot leak what it was never given.
public struct WidgetEntryFact: Equatable, Sendable {
    public var createdAt: Date
    public var wordCount: Int
    public var isHidden: Bool
    public var isTrashed: Bool
    public var isArchived: Bool

    public init(createdAt: Date, wordCount: Int, isHidden: Bool, isTrashed: Bool = false, isArchived: Bool = false) {
        self.createdAt = createdAt
        self.wordCount = wordCount
        self.isHidden = isHidden
        self.isTrashed = isTrashed
        self.isArchived = isArchived
    }

    /// Hidden entries are private: they contribute nothing to the widget, not
    /// even a writing day. Trashed and archived entries never count as writing.
    public var countsForWidget: Bool { !isHidden && !isTrashed && !isArchived }
}

// MARK: - Builder

public enum WidgetSnapshotBuilder {
    /// Days of lookahead after today (today + 7 = 8 rows).
    public static let defaultDaysAhead = 7

    public static func build(
        facts: [WidgetEntryFact],
        dailyWordGoal: Int,
        streakMode: StreakMode,
        weeklyStreakTarget: Int = 3,
        prompt: (Date) -> String,
        now: Date = Date(),
        daysAhead: Int = defaultDaysAhead,
        calendar: Calendar = .current
    ) -> WidgetSnapshot {
        let visible = facts.filter(\.countsForWidget)
        var wordsByDay: [Date: Int] = [:]
        var entriesByDay: [Date: Int] = [:]
        for fact in visible {
            let day = calendar.startOfDay(for: fact.createdAt)
            wordsByDay[day, default: 0] += max(0, fact.wordCount)
            entriesByDay[day, default: 0] += 1
        }
        let allDays = Set(entriesByDay.keys)
        let today = calendar.startOfDay(for: now)

        var days: [WidgetSnapshot.Day] = []
        var unit = "day"
        for offset in 0...max(0, daysAhead) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            // Future-dated entries are planned, not written: a day's streak only
            // sees writing days up to and including that day.
            let past = allDays.filter { $0 <= day }
            // Lookahead rows assume nothing new gets written before they arrive,
            // except entries already dated on or before that day.
            let summary = StreakCalculator.summary(writingDays: past, mode: streakMode,
                                                   weeklyTarget: weeklyStreakTarget, today: day, calendar: calendar)
            if offset == 0 { unit = summary.unit }
            days.append(WidgetSnapshot.Day(
                dayStart: day,
                words: wordsByDay[day] ?? 0,
                entries: entriesByDay[day] ?? 0,
                streak: summary.current,
                writtenToday: (entriesByDay[day] ?? 0) > 0,
                prompt: prompt(day)))
        }

        let lastWritten = visible.map(\.createdAt).filter { $0 <= now }.max()
        return WidgetSnapshot(generatedAt: now, dailyWordGoal: max(1, dailyWordGoal), streakUnit: unit,
                              lastWrittenAt: lastWritten, days: days)
    }
}

// MARK: - What the widget shows at a given moment

/// Everything a widget/intent renders for one point in time, derived from a
/// snapshot. Pure, so the widget, the intent and the tests agree.
public struct WidgetDisplayState: Equatable, Sendable {
    public var date: Date
    public var words: Int
    public var goal: Int
    public var streak: Int
    public var streakUnit: String
    public var writtenToday: Bool
    public var prompt: String
    public var lastWrittenText: String
    /// False when there is no usable snapshot (never opened, or it expired).
    public var hasData: Bool

    public var progress: Double { goal > 0 ? min(1, Double(words) / Double(goal)) : 0 }
    public var goalMet: Bool { words >= goal }

    public var streakText: String {
        streak == 1 ? "1 \(streakUnit)" : "\(streak) \(streakUnit)s"
    }

    public init(date: Date, words: Int, goal: Int, streak: Int, streakUnit: String, writtenToday: Bool,
                prompt: String, lastWrittenText: String, hasData: Bool) {
        self.date = date
        self.words = words
        self.goal = goal
        self.streak = streak
        self.streakUnit = streakUnit
        self.writtenToday = writtenToday
        self.prompt = prompt
        self.lastWrittenText = lastWrittenText
        self.hasData = hasData
    }

    /// Shown before the app has written a snapshot (or after it expired).
    public static func empty(at date: Date) -> WidgetDisplayState {
        WidgetDisplayState(date: date, words: 0, goal: 250, streak: 0, streakUnit: "day", writtenToday: false,
                           prompt: "Open Omega Journal to start today's page.",
                           lastWrittenText: "Open the app to sync", hasData: false)
    }

    /// Sample used for the widget gallery placeholder (no real data).
    public static func sample(at date: Date) -> WidgetDisplayState {
        WidgetDisplayState(date: date, words: 180, goal: 250, streak: 6, streakUnit: "day", writtenToday: true,
                           prompt: "What made today different from yesterday?",
                           lastWrittenText: "Today", hasData: true)
    }
}

public enum WidgetDisplay {
    /// The display state at `date`, or `.empty` when the snapshot has no row for
    /// that day (missing, wrong version, or older than its lookahead).
    public static func state(for snapshot: WidgetSnapshot?, at date: Date,
                             calendar: Calendar = .current) -> WidgetDisplayState {
        guard let snapshot, snapshot.version == WidgetSnapshot.currentVersion else { return .empty(at: date) }
        let dayStart = calendar.startOfDay(for: date)
        guard let day = snapshot.days.first(where: { calendar.isDate($0.dayStart, inSameDayAs: dayStart) }) else {
            return .empty(at: date)
        }
        return WidgetDisplayState(
            date: date, words: day.words, goal: snapshot.dailyWordGoal, streak: day.streak,
            streakUnit: snapshot.streakUnit, writtenToday: day.writtenToday, prompt: day.prompt,
            lastWrittenText: lastWrittenText(snapshot.lastWrittenAt, relativeTo: date, calendar: calendar),
            hasData: true)
    }

    /// "Today", "Yesterday", "3 days ago", "2 weeks ago", or "No entries yet".
    public static func lastWrittenText(_ last: Date?, relativeTo now: Date, calendar: Calendar = .current) -> String {
        guard let last else { return "No entries yet" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        default:
            let months = max(2, days / 30)
            return months >= 24 ? "\(months / 12) years ago" : "\(months) months ago"
        }
    }

    /// Timeline dates: now, then each following midnight the snapshot covers.
    public static func timelineDates(for snapshot: WidgetSnapshot?, now: Date,
                                     calendar: Calendar = .current) -> [Date] {
        var dates = [now]
        guard let snapshot else { return dates }
        let today = calendar.startOfDay(for: now)
        for day in snapshot.days.map(\.dayStart).sorted() where day > today {
            dates.append(day)
        }
        return dates
    }

    /// The one-line answer for the "Today's progress" intent. Counts only.
    public static func progressSentence(_ state: WidgetDisplayState) -> String {
        guard state.hasData else {
            return "Open Omega Journal once and your progress will show up here."
        }
        let words = state.words == 1 ? "1 word" : "\(state.words) words"
        let goal = state.goalMet ? "Daily goal of \(state.goal) reached." : "\(max(0, state.goal - state.words)) to go for your \(state.goal)-word goal."
        let streak = state.streak > 0 ? "Streak: \(state.streakText)." : "No streak yet. Today is a good day to start one."
        return "\(words) today. \(goal) \(streak)"
    }
}
