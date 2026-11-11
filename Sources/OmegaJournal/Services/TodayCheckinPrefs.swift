import Foundation

/// UserDefaults keys for the check-in on Today.
enum TodayCheckinPrefs {
    /// Settings › Writing › Daily Check-in: show the check-in on Today (default on).
    static let showKey = "today.showCheckin"
    /// Whether the check-in is open on Today (default collapsed to one line).
    static let expandedKey = "today.checkinExpanded"
}
