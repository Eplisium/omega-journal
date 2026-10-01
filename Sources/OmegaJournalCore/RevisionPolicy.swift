import Foundation

// MARK: - Version history policy (pure)
//
// Revisions are snapshots of an entry's title+body taken when an edit session ends.
// Snapshots inside `coalesceWindow` of the previous automatic one replace it (so a burst of
// short edit sessions is one revision), unchanged text is never stored, and old revisions are
// thinned: everything for a day, then one per day for a month, then one per week for a year.

public struct RevisionStamp: Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    /// Automatic (edit-session) snapshots may be coalesced/pruned; manual ones ("restore", "manual") are kept.
    public let isAuto: Bool
    public init(id: String, createdAt: Date, isAuto: Bool) {
        self.id = id; self.createdAt = createdAt; self.isAuto = isAuto
    }
}

public enum RevisionDecision: Equatable, Sendable {
    case skip
    case insert
    /// Overwrite the most recent automatic snapshot with the new text.
    case replaceLatest
}

public enum RevisionPolicy {
    public static let coalesceWindow: TimeInterval = 10 * 60
    public static let keepAllWithin: TimeInterval = 24 * 3600
    public static let dailyWindow: TimeInterval = 30 * 24 * 3600
    public static let weeklyWindow: TimeInterval = 365 * 24 * 3600
    public static let hardCap = 200

    /// What to do with a candidate snapshot given the newest stored one.
    public static func decide(latest: RevisionStamp?, latestText: String?, newText: String,
                              now: Date, isAuto: Bool = true) -> RevisionDecision {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .skip }
        guard let latest else { return .insert }
        if let latestText, latestText == newText { return .skip }
        if isAuto, latest.isAuto, now.timeIntervalSince(latest.createdAt) < coalesceWindow { return .replaceLatest }
        return .insert
    }

    /// Ids to delete so the remaining set follows the retention schedule. Newest wins each bucket;
    /// manual revisions are exempt from thinning (only the hard cap can remove them, oldest first).
    public static func idsToPrune(_ revisions: [RevisionStamp], now: Date,
                                  calendar: Calendar = .current) -> Set<String> {
        let sorted = revisions.sorted { $0.createdAt > $1.createdAt }
        var keep = Set<String>()
        var seenBuckets = Set<String>()
        for r in sorted {
            if !r.isAuto { keep.insert(r.id); continue }
            let age = now.timeIntervalSince(r.createdAt)
            let bucket: String?
            if age < keepAllWithin { bucket = nil }
            else if age < dailyWindow {
                let c = calendar.dateComponents([.year, .month, .day], from: r.createdAt)
                bucket = "d\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
            } else if age < weeklyWindow {
                let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: r.createdAt)
                bucket = "w\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
            } else { continue }                       // older than a year: pruned
            if let bucket { if seenBuckets.insert(bucket).inserted { keep.insert(r.id) } }
            else { keep.insert(r.id) }
        }
        // Hard cap: drop the oldest kept ones beyond the limit.
        let keptSorted = sorted.filter { keep.contains($0.id) }
        if keptSorted.count > hardCap {
            for r in keptSorted.dropFirst(hardCap) { keep.remove(r.id) }
        }
        return Set(revisions.map(\.id)).subtracting(keep)
    }
}

// MARK: - Line diff

public enum DiffKind: Equatable, Sendable { case same, added, removed }

public struct DiffLine: Equatable, Sendable {
    public let kind: DiffKind
    public let text: String
}

public struct DiffSummary: Equatable, Sendable {
    public let added: Int
    public let removed: Int
    public var isEmpty: Bool { added == 0 && removed == 0 }
}

public enum TextDiff {
    /// Above this many LCS cells the middle section degrades to "all removed, all added".
    public static let maxCells = 4_000_000

    /// Line diff of `old` → `new` (common prefix/suffix trimmed, LCS on the middle).
    public static func lines(old: String, new: String) -> [DiffLine] {
        let a = split(old), b = split(new)
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let am = Array(a[pre..<(a.count - suf)]), bm = Array(b[pre..<(b.count - suf)])

        var out = a[..<pre].map { DiffLine(kind: .same, text: $0) }
        if am.isEmpty { out += bm.map { DiffLine(kind: .added, text: $0) } }
        else if bm.isEmpty { out += am.map { DiffLine(kind: .removed, text: $0) } }
        else if am.count * bm.count > maxCells {
            out += am.map { DiffLine(kind: .removed, text: $0) } + bm.map { DiffLine(kind: .added, text: $0) }
        } else {
            out += lcsDiff(am, bm)
        }
        out += a[(a.count - suf)...].map { DiffLine(kind: .same, text: $0) }
        return out
    }

    public static func summary(_ lines: [DiffLine]) -> DiffSummary {
        DiffSummary(added: lines.filter { $0.kind == .added }.count, removed: lines.filter { $0.kind == .removed }.count)
    }

    private static func split(_ s: String) -> [String] {
        s.isEmpty ? [] : s.components(separatedBy: "\n")
    }

    private static func lcsDiff(_ a: [String], _ b: [String]) -> [DiffLine] {
        let n = a.count, m = b.count
        var table = [[UInt32]](repeating: [UInt32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { out.append(DiffLine(kind: .same, text: a[i])); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { out.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
            else { out.append(DiffLine(kind: .added, text: b[j])); j += 1 }
        }
        while i < n { out.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
        while j < m { out.append(DiffLine(kind: .added, text: b[j])); j += 1 }
        return out
    }
}
