import Foundation

// MARK: - Smart folders (saved criteria with live counts)

public struct SmartFolder: Codable, Identifiable, Equatable, Sendable {
    public enum DateRange: String, Codable, CaseIterable, Sendable {
        case any, today, last7, last30, thisMonth, thisYear

        public var label: String {
            switch self {
            case .any: "Any time"; case .today: "Today"; case .last7: "Last 7 days"
            case .last30: "Last 30 days"; case .thisMonth: "This month"; case .thisYear: "This year"
            }
        }

        public func start(now: Date = Date(), calendar: Calendar = .current) -> Date? {
            let sod = calendar.startOfDay(for: now)
            switch self {
            case .any: return nil
            case .today: return sod
            case .last7: return calendar.date(byAdding: .day, value: -7, to: sod)
            case .last30: return calendar.date(byAdding: .day, value: -30, to: sod)
            case .thisMonth: return calendar.dateInterval(of: .month, for: now)?.start
            case .thisYear: return calendar.dateInterval(of: .year, for: now)?.start
            }
        }
    }

    public let id: String
    public var name: String
    /// Optional operator-capable search text (`tag:x has:image budget`).
    public var query: String
    /// Entry must carry ANY of these tags (or a descendant).
    public var tags: [String]
    /// Entry mood must be ANY of these raw values (1…5).
    public var moods: [Int]
    public var dateRange: DateRange
    public var hasAttachment: Bool
    public var minWords: Int

    public init(id: String = UUID().uuidString, name: String, query: String = "", tags: [String] = [], moods: [Int] = [],
                dateRange: DateRange = .any, hasAttachment: Bool = false, minWords: Int = 0) {
        self.id = id; self.name = name; self.query = query; self.tags = tags; self.moods = moods
        self.dateRange = dateRange; self.hasAttachment = hasAttachment; self.minWords = minWords
    }

    /// Promotes a saved search into a smart folder.
    public init(from saved: SavedSearch, moodValues: [String: Int] = [:]) {
        self.init(id: saved.id, name: saved.name, query: saved.query,
                  tags: saved.tag.map { [$0] } ?? [],
                  moods: saved.mood.flatMap { moodValues[$0] }.map { [$0] } ?? [])
    }

    public var hasCriteria: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || !tags.isEmpty || !moods.isEmpty
            || dateRange != .any || hasAttachment || minWords > 0
    }

    /// All criteria must hold (AND across kinds, OR within tags / moods).
    /// Privacy: while `hiddenLocked`, hidden entries never match any smart folder, so they can't be counted or listed.
    public func matches(_ r: SearchQuery.Record, hiddenLocked: Bool, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if r.isHidden && hiddenLocked { return false }
        if !tags.isEmpty, !tags.contains(where: { want in r.tags.contains { TagPath.isSameOrDescendant($0, of: want) } }) { return false }
        if !moods.isEmpty, !moods.contains(r.moodValue) { return false }
        if let start = dateRange.start(now: now, calendar: calendar), r.createdAt < start { return false }
        if hasAttachment, r.attachmentCount == 0 { return false }
        if minWords > 0, r.wordCount < minWords { return false }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !SearchQuery.parse(trimmed, calendar: calendar, now: now).matches(r, hiddenLocked: hiddenLocked) { return false }
        return true
    }

    public func count(in records: [SearchQuery.Record], hiddenLocked: Bool, now: Date = Date()) -> Int {
        records.reduce(0) { $0 + (matches($1, hiddenLocked: hiddenLocked, now: now) ? 1 : 0) }
    }
}

public enum SmartFolderStore {
    public static let settingKey = "smart_folders_v1"
    public static let maxCount = 40

    public static func decode(_ raw: String) -> [SmartFolder] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([SmartFolder].self, from: data) else { return [] }
        return list
    }

    public static func encode(_ list: [SmartFolder]) -> String {
        guard let data = try? JSONEncoder().encode(list), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Adds or replaces (same id, else same name case-insensitively). Folders with no name or no criteria are rejected.
    public static func upserting(_ folder: SmartFolder, into list: [SmartFolder]) -> [SmartFolder] {
        var f = folder
        f.name = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.name.isEmpty, f.hasCriteria else { return list }
        var out = list.filter { $0.id != f.id && $0.name.caseInsensitiveCompare(f.name) != .orderedSame }
        if let idx = list.firstIndex(where: { $0.id == f.id }), idx <= out.count { out.insert(f, at: idx) } else { out.append(f) }
        return Array(out.prefix(maxCount))
    }
}
