import Foundation
import SwiftUI

// MARK: - Mood

enum Mood: Int, CaseIterable, Identifiable {
    case awful = 1, bad = 2, neutral = 3, good = 4, great = 5
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .awful: "Awful"; case .bad: "Bad"; case .neutral: "Neutral"
        case .good: "Good"; case .great: "Great"
        }
    }
    var emoji: String {
        switch self {
        case .awful: "😞"; case .bad: "😕"; case .neutral: "😐"
        case .good: "🙂"; case .great: "😄"
        }
    }
    var color: Color {
        switch self {
        case .awful: Color(red: 0.85, green: 0.35, blue: 0.35)
        case .bad: Color(red: 0.90, green: 0.60, blue: 0.30)
        case .neutral: Color(red: 0.55, green: 0.55, blue: 0.60)
        case .good: Color(red: 0.30, green: 0.75, blue: 0.55)
        case .great: Color(red: 0.20, green: 0.60, blue: 0.90)
        }
    }
}

// MARK: - Sort Order

enum SortOrder: String, CaseIterable, Identifiable {
    case dateDesc = "Newest First"
    case dateAsc = "Oldest First"
    case titleAsc = "Title A→Z"
    case titleDesc = "Title Z→A"
    var id: String { rawValue }
}

// MARK: - Journal Entry

struct JournalEntry: Identifiable, Hashable {
    let id: String
    var title: String
    var body: String
    var mood: Mood
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var isFavorite: Bool

    static func new() -> JournalEntry {
        JournalEntry(id: UUID().uuidString, title: "", body: "", mood: .neutral,
                     tags: [], createdAt: Date(), updatedAt: Date(),
                     isPinned: false, isFavorite: false)
    }

    var wordCount: Int { body.isEmpty ? 0 : body.split(whereSeparator: { $0.isWhitespace }).count }
    var preview: String {
        let s = body.replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
        return s.isEmpty ? "No content" : s
    }
}

// MARK: - View Model

@MainActor
final class JournalViewModel: ObservableObject {
    @Published var entries: [JournalEntry] = []
    @Published var selectedEntryId: String?
    @Published var searchText: String = ""
    @Published var sortOrder: SortOrder = .dateDesc
    @Published var editingEntryId: String?

    private let db = DatabaseManager.shared
    private var debounceTask: Task<Void, Never>?

    init() { reload() }
    func reload() { entries = db.fetchAllEntries(search: searchText, sort: sortOrder) }
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

    func startEditing(_ entry: JournalEntry) { editingEntryId = entry.id }

    func autoSave(_ entry: JournalEntry) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            var u = entry; u.updatedAt = Date()
            db.saveEntry(u); reload()
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
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        reload()
    }

    func togglePin(_ entry: JournalEntry) {
        var u = entry; u.isPinned.toggle(); u.updatedAt = Date()
        db.saveEntry(u); reload()
    }

    func toggleFavorite(_ entry: JournalEntry) {
        var u = entry; u.isFavorite.toggle(); u.updatedAt = Date()
        db.saveEntry(u); reload()
    }

    // Stats
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
}
