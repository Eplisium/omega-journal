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
        let dailyWordsTarget = Int(db.getSetting("goal_dailyWords", defaultValue: "\(WritingGoal.GoalType.dailyWords.defaultValue)")) ?? WritingGoal.GoalType.dailyWords.defaultValue
        let dailyEntriesTarget = Int(db.getSetting("goal_dailyEntries", defaultValue: "\(WritingGoal.GoalType.dailyEntries.defaultValue)")) ?? WritingGoal.GoalType.dailyEntries.defaultValue
        let weeklyEntriesTarget = Int(db.getSetting("goal_weeklyEntries", defaultValue: "\(WritingGoal.GoalType.weeklyEntries.defaultValue)")) ?? WritingGoal.GoalType.weeklyEntries.defaultValue
        let weeklyWordsTarget = Int(db.getSetting("goal_weeklyWords", defaultValue: "\(WritingGoal.GoalType.weeklyWords.defaultValue)")) ?? WritingGoal.GoalType.weeklyWords.defaultValue

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: today)!
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today

        let entries = db.fetchAllEntries()

        // Daily stats
        let todayEntries = entries.filter { $0.createdAt >= today && $0.createdAt < todayEnd }
        let dailyWords = todayEntries.reduce(0) { $0 + $1.wordCount }
        let dailyEntryCount = todayEntries.count

        // Weekly stats
        let weekEntries = entries.filter { $0.createdAt >= weekStart }
        let weeklyWords = weekEntries.reduce(0) { $0 + $1.wordCount }
        let weeklyEntryCount = weekEntries.count

        goals = [
            .goal(for: .dailyWords, target: dailyWordsTarget, current: dailyWords),
            .goal(for: .dailyEntries, target: dailyEntriesTarget, current: dailyEntryCount),
            .goal(for: .weeklyEntries, target: weeklyEntriesTarget, current: weeklyEntryCount),
            .goal(for: .weeklyWords, target: weeklyWordsTarget, current: weeklyWords),
        ]
    }

    func updateGoal(type: WritingGoal.GoalType, target: Int) {
        db.setSetting("goal_\(type.rawValue)", value: "\(target)")
        loadGoals()
    }
}
