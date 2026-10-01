import Foundation

// MARK: - Whole-app lock policy (pure)

public enum AppLockTimeout: Int, CaseIterable, Sendable, Identifiable {
    case immediately = 0, oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900, oneHour = 3600, never = -1
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .immediately: "Immediately"
        case .oneMinute: "After 1 minute"
        case .fiveMinutes: "After 5 minutes"
        case .fifteenMinutes: "After 15 minutes"
        case .oneHour: "After 1 hour"
        case .never: "Only at launch"
        }
    }
}

public enum AppLockPolicy {
    /// Whether the app must be locked given the lock state and idle/background time.
    /// - `enabled`: user turned the app lock on.
    /// - `lastActive`: when the app last left the foreground (nil = fresh launch → locked).
    public static func shouldLock(enabled: Bool, timeout: AppLockTimeout, lastActive: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastActive else { return true }
        switch timeout {
        case .never: return false
        case .immediately: return true
        default: return now.timeIntervalSince(lastActive) >= TimeInterval(timeout.rawValue)
        }
    }
}
