import Foundation

// MARK: - Session stats, goal ring and sprint (pure; callers pass `now`)

public struct WritingSprint: Equatable, Sendable {
    public static let allowedMinutes = [10, 20]
    public let minutes: Int
    public let startedAt: Date
    public let startWords: Int

    public init?(minutes: Int, startedAt: Date, startWords: Int) {
        guard Self.allowedMinutes.contains(minutes) else { return nil }
        self.minutes = minutes
        self.startedAt = startedAt
        self.startWords = startWords
    }

    public var duration: TimeInterval { TimeInterval(minutes * 60) }
    public func remaining(at now: Date) -> TimeInterval { max(0, duration - now.timeIntervalSince(startedAt)) }
    public func isFinished(at now: Date) -> Bool { remaining(at: now) <= 0 }
    public func progress(at now: Date) -> Double { min(1, max(0, now.timeIntervalSince(startedAt) / duration)) }
    public func wordsWritten(currentWords: Int) -> Int { max(0, currentWords - startWords) }
}

public struct GoalRingState: Equatable, Sendable {
    public let current: Int
    public let target: Int
    public var fraction: Double { target > 0 ? min(1, Double(current) / Double(target)) : 0 }
    public var isComplete: Bool { target > 0 && current >= target }
}

public enum WritingSessionMath {
    public static func wordsWritten(start: Int, current: Int) -> Int { max(0, current - start) }

    /// Words per minute, 0 until at least 10 s have elapsed (avoids absurd early spikes).
    public static func wordsPerMinute(words: Int, elapsed: TimeInterval) -> Int {
        guard elapsed >= 10, words > 0 else { return 0 }
        return Int((Double(words) / (elapsed / 60)).rounded())
    }

    /// `m:ss` below an hour, `h:mm:ss` above. Negative → 0:00.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Today's words = everything stored today except this entry's stored count, plus its live count.
    public static func goalRing(otherWordsToday: Int, liveEntryWords: Int, target: Int) -> GoalRingState {
        GoalRingState(current: max(0, otherWordsToday) + max(0, liveEntryWords), target: max(0, target))
    }
}
