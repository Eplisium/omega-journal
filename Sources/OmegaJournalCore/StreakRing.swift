import Foundation

/// Progress model for the Today streak ring. Pure so it can be unit-tested.
public enum StreakRing {
    /// Next milestone strictly above `current` (3, 7, 14, 30, 60, 100, 200, 365, then +365 each).
    public static func nextMilestone(after current: Int) -> Int {
        let steps = [3, 7, 14, 30, 60, 100, 200, 365]
        if let s = steps.first(where: { $0 > max(0, current) }) { return s }
        return (max(0, current) / 365 + 1) * 365
    }

    /// 0...1 fill: how far `current` is from the previous milestone toward the next.
    public static func progress(current: Int) -> Double {
        let c = max(0, current)
        let next = nextMilestone(after: c)
        let steps = [0, 3, 7, 14, 30, 60, 100, 200, 365]
        let prev = steps.last(where: { $0 <= c }) ?? ((c / 365) * 365)
        let base = c >= 365 ? (c / 365) * 365 : prev
        let span = max(1, next - base)
        return min(1, max(0, Double(c - base) / Double(span)))
    }

    /// Spoken/visible caption, e.g. "4 more days to 7".
    public static func caption(current: Int, unit: String) -> String {
        let next = nextMilestone(after: current)
        let left = next - max(0, current)
        let u = left == 1 ? unit : unit + "s"
        return "\(left) more \(u) to \(next)"
    }
}
