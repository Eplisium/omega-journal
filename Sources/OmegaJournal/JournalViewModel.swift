import Foundation
import SwiftUI

// MARK: - Journal View Model

@MainActor
final class JournalViewModel: ObservableObject {
    @Published var entries: [JournalEntry] = []
    @Published var selectedEntryId: String?
    @Published var searchText: String = ""
    @Published var sortOrder: SortOrder = .dateDesc
    @Published var editingEntryId: String?
    @Published var isSearching = false

    let db = DatabaseManager.shared
    private var debounceTask: Task<Void, Never>?

    init() { reload() }

    func reload() {
        entries = db.fetchAllEntries(search: searchText, sort: sortOrder)
    }

    /// Targeted update — refresh a single entry without full reload
    private func updateEntry(_ entry: JournalEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        }
        // Re-sort if needed
        switch sortOrder {
        case .dateDesc:
            entries.sort { ($0.isPinned && !$1.isPinned) || ($0.isPinned == $1.isPinned && $0.createdAt > $1.createdAt) }
        case .dateAsc:
            entries.sort { ($0.isPinned && !$1.isPinned) || ($0.isPinned == $1.isPinned && $0.createdAt < $1.createdAt) }
        case .titleAsc:
            entries.sort { ($0.isPinned && !$1.isPinned) || ($0.isPinned == $1.isPinned && $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending) }
        case .titleDesc:
            entries.sort { ($0.isPinned && !$1.isPinned) || ($0.isPinned == $1.isPinned && $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending) }
        }
    }

    var selectedEntry: JournalEntry? { entries.first { $0.id == selectedEntryId } }
    var editingEntry: JournalEntry? { entries.first { $0.id == editingEntryId } }
    var isEditing: Bool { editingEntryId != nil }
    var entryCount: Int { db.entryCount() }

    func createEntry() {
        let entry = JournalEntry.new()
        db.saveEntry(entry)
        reload()
        selectedEntryId = entry.id
        editingEntryId = entry.id
    }

    func toggleSelection(_ entry: JournalEntry) {
        if selectedEntryId == entry.id {
            selectedEntryId = nil
        } else {
            selectedEntryId = entry.id
        }
    }

    func startEditing(_ entry: JournalEntry) { editingEntryId = entry.id }

    func autoSave(_ entry: JournalEntry) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            var u = entry; u.updatedAt = Date()
            db.saveEntry(u)
            // Targeted update instead of full reload
            if let idx = entries.firstIndex(where: { $0.id == u.id }) {
                entries[idx] = u
            }
            GoalManager.shared.loadGoals()
        }
    }

    func stopEditing() {
        if let e = editingEntry, e.title.isEmpty && e.body.isEmpty {
            db.deleteEntry(id: e.id)
            if selectedEntryId == e.id { selectedEntryId = nil }
        }
        editingEntryId = nil
        reload()
    }

    func deleteEntry(_ entry: JournalEntry) {
        db.deleteEntry(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        GoalManager.shared.loadGoals()
    }

    func togglePin(_ entry: JournalEntry) {
        var u = entry; u.isPinned.toggle(); u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
    }

    func toggleFavorite(_ entry: JournalEntry) {
        var u = entry; u.isFavorite.toggle(); u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
    }

    // MARK: - Full-text search

    func performSearch() {
        if searchText.isEmpty {
            reload()
        } else {
            entries = db.fullTextSearch(searchText)
            if entries.isEmpty {
                // Fallback to LIKE search
                entries = db.fetchAllEntries(search: searchText, sort: sortOrder)
            }
        }
    }

    // MARK: - Stats

    var moodThisWeek: [Mood: Int] {
        let w = Date().addingTimeInterval(-7 * 24 * 3600)
        var c: [Mood: Int] = [:]
        for e in entries where e.createdAt >= w { c[e.mood, default: 0] += 1 }
        return c
    }
    var totalWordCount: Int { entries.reduce(0) { $0 + $1.wordCount } }
    var averageMood: Double { entries.isEmpty ? 0 : Double(entries.reduce(0) { $0 + $1.mood.rawValue }) / Double(entries.count) }
    var entriesThisWeek: Int { entries.filter { $0.createdAt >= Date().addingTimeInterval(-7 * 24 * 3600) }.count }
    var writingStreak: Int {
        let cal = Calendar.current
        var streak = 0; var date = cal.startOfDay(for: Date())
        while true {
            let end = cal.date(byAdding: .day, value: 1, to: date)!
            if entries.contains(where: { $0.createdAt >= date && $0.createdAt < end }) {
                streak += 1; date = cal.date(byAdding: .day, value: -1, to: date)!
            } else { break }
        }
        return streak
    }

    // MARK: - Insights

    func moodTrend(days: Int = 30) -> [MoodPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var points: [MoodPoint] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -i, to: today),
                  let end = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            let dayEntries = entries.filter { $0.createdAt >= day && $0.createdAt < end }
            guard !dayEntries.isEmpty else { continue }
            let avg = Double(dayEntries.reduce(0) { $0 + $1.mood.rawValue }) / Double(dayEntries.count)
            points.append(MoodPoint(date: day, avg: avg))
        }
        return points
    }

    func dailyCounts(daysBack: Int = 210) -> [Date: Int] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today) else { return [:] }
        var map: [Date: Int] = [:]
        for e in entries where e.createdAt >= start {
            map[cal.startOfDay(for: e.createdAt), default: 0] += 1
        }
        return map
    }

    struct DayInfo {
        let date: Date
        let count: Int
        let moods: [Mood]
        let titles: [String]
    }

    func dailyInfo(daysBack: Int = 210) -> [Date: DayInfo] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today) else { return [:] }
        var map: [Date: [JournalEntry]] = [:]
        for e in entries where e.createdAt >= start {
            map[cal.startOfDay(for: e.createdAt), default: []].append(e)
        }
        var result: [Date: DayInfo] = [:]
        for (date, dayEntries) in map {
            result[date] = DayInfo(
                date: date,
                count: dayEntries.count,
                moods: dayEntries.map(\.mood),
                titles: dayEntries.prefix(3).map { $0.title.isEmpty ? "Untitled" : $0.title }
            )
        }
        return result
    }

    var moodDistribution: [MoodCount] {
        Mood.allCases
            .map { m in MoodCount(mood: m, count: entries.filter { $0.mood == m }.count) }
            .sorted { $0.mood.rawValue < $1.mood.rawValue }
    }

    var entriesThisMonth: Int {
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .month, for: Date())?.start else { return 0 }
        return entries.filter { $0.createdAt >= start }.count
    }

    var longestStreak: Int {
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.createdAt) })
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var best = 1, cur = 1
        for i in 1..<sorted.count {
            if let next = cal.date(byAdding: .day, value: 1, to: sorted[i - 1]), next == sorted[i] {
                cur += 1; best = max(best, cur)
            } else { cur = 1 }
        }
        return best
    }

    var totalReadingTime: String {
        let total = entries.reduce(0) { $0 + max(1, Int(ceil(Double($1.wordCount) / 220.0))) }
        if total < 60 { return "\(total) min" }
        return "\(total / 60)h \(total % 60)m"
    }

    // MARK: - On This Day

    /// Entries written on this month/day in any previous year.
    var onThisDay: [JournalEntry] {
        let cal = Calendar.current
        let today = Date()
        let month = cal.component(.month, from: today)
        let day = cal.component(.day, from: today)
        let thisYear = cal.component(.year, from: today)
        return entries.filter { e in
            let eYear = cal.component(.year, from: e.createdAt)
            return eYear != thisYear &&
                cal.component(.month, from: e.createdAt) == month &&
                cal.component(.day, from: e.createdAt) == day
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func createEntryFromPrompt() {
        let entry = JournalEntry(
            id: UUID().uuidString,
            title: "Today: " + PromptGenerator.today(),
            body: "", mood: .neutral, tags: ["prompt"],
            createdAt: Date(), updatedAt: Date(), isPinned: false, isFavorite: false,
            attachments: []
        )
        db.saveEntry(entry)
        reload()
        selectedEntryId = entry.id
        editingEntryId = entry.id
    }

    // MARK: - Attachment helpers

    func addAttachment(to entry: JournalEntry, data: Data, filename: String, mimeType: String) {
        guard let attachment = db.saveAttachment(entryId: entry.id, data: data, filename: filename, mimeType: mimeType) else { return }
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].attachments.append(attachment)
        }
    }

    func deleteAttachment(_ attachment: Attachment) {
        db.deleteAttachment(id: attachment.id)
        for (i, entry) in entries.enumerated() {
            entries[i].attachments = entry.attachments.filter { $0.id != attachment.id }
        }
    }
}
