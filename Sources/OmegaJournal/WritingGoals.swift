import Foundation

// MARK: - Writing Goals

struct WritingGoal: Identifiable {
    enum GoalType: String, CaseIterable {
        case dailyWords = "Daily Words"
        case dailyEntries = "Daily Entries"
        case weeklyEntries = "Weekly Entries"
        case weeklyWords = "Weekly Words"

        var icon: String {
            switch self {
            case .dailyWords: "text.word.spacing"
            case .dailyEntries: "doc.plaintext"
            case .weeklyEntries: "calendar"
            case .weeklyWords: "text.badge.star"
            }
        }

        var unit: String {
            switch self {
            case .dailyWords, .weeklyWords: "words"
            case .dailyEntries, .weeklyEntries: "entries"
            }
        }

        var defaultValue: Int {
            switch self {
            case .dailyWords: 250
            case .dailyEntries: 1
            case .weeklyEntries: 5
            case .weeklyWords: 1500
            }
        }

        /// Settings key where the target is saved. Must match the keys read in
        /// `GoalManager.loadGoals` — an older build wrote to "goal_\(rawValue)"
        /// (with spaces) here, which never matched the reads, so edits to goals
        /// silently didn't stick.
        var storageKey: String {
            switch self {
            case .dailyWords: "goal_dailyWords"
            case .dailyEntries: "goal_dailyEntries"
            case .weeklyEntries: "goal_weeklyEntries"
            case .weeklyWords: "goal_weeklyWords"
            }
        }
    }

    let id: String
    let type: GoalType
    var target: Int
    var current: Int

    var progress: Double {
        guard target > 0 else { return 0 }
        return min(1.0, Double(current) / Double(target))
    }

    var isComplete: Bool { current >= target }

    var displayProgress: String {
        "\(current)/\(target) \(type.unit)"
    }

    static func goal(for type: GoalType, target: Int, current: Int) -> WritingGoal {
        WritingGoal(id: type.rawValue, type: type, target: target, current: current)
    }
}

// MARK: - Goal Manager

@MainActor
final class GoalManager: ObservableObject {
    static let shared = GoalManager()

    @Published var goals: [WritingGoal] = []

    private let db = DatabaseManager.shared

    private init() {
        loadGoals()
    }

    func loadGoals() {
        migrateLegacyGoalKeys()
        let dailyWordsTarget = savedTarget(for: .dailyWords)
        let dailyEntriesTarget = savedTarget(for: .dailyEntries)
        let weeklyEntriesTarget = savedTarget(for: .weeklyEntries)
        let weeklyWordsTarget = savedTarget(for: .weeklyWords)

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today

        // SQL-side computation — avoids loading every entry into memory just to
        // count four numbers.
        let dailyWords = db.wordCountSum(since: today)
        let dailyEntryCount = db.entryCount(since: today)
        let weeklyWords = db.wordCountSum(since: weekStart)
        let weeklyEntryCount = db.entryCount(since: weekStart)

        goals = [
            .goal(for: .dailyWords, target: dailyWordsTarget, current: dailyWords),
            .goal(for: .dailyEntries, target: dailyEntriesTarget, current: dailyEntryCount),
            .goal(for: .weeklyEntries, target: weeklyEntriesTarget, current: weeklyEntryCount),
            .goal(for: .weeklyWords, target: weeklyWordsTarget, current: weeklyWords),
        ]
    }

    func updateGoal(type: WritingGoal.GoalType, target: Int) {
        let clamped = max(1, min(target, 10000))
        db.setSetting(type.storageKey, value: "\(clamped)")
        loadGoals()
    }

    /// Reads a goal's saved target, falling back to its default.
    private func savedTarget(for type: WritingGoal.GoalType) -> Int {
        Int(db.getSetting(type.storageKey, defaultValue: "\(type.defaultValue)")) ?? type.defaultValue
    }

    /// An older build wrote updates to "goal_<Display Name>" (with spaces)
    /// while `loadGoals` read the camelCase `storageKey`s, so edits never
    /// stuck. Carry any value written under the legacy key over to the real
    /// one (only when the real key was never set).
    private func migrateLegacyGoalKeys() {
        let missing = "\u{1}missing"
        for type in WritingGoal.GoalType.allCases {
            let legacy = db.getSetting("goal_\(type.rawValue)", defaultValue: missing)
            guard legacy != missing,
                  db.getSetting(type.storageKey, defaultValue: missing) == missing
            else { continue }
            db.setSetting(type.storageKey, value: legacy)
        }
    }
}
