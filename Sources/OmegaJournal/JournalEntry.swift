import Foundation
import SwiftUI

// MARK: - Attachment

struct Attachment: Identifiable, Hashable {
    let id: String
    let entryId: String
    let filename: String
    let mimeType: String
    let createdAt: Date

    var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("OmegaJournal", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(filename)
    }

    var isImage: Bool {
        mimeType.hasPrefix("image/")
    }
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
    var isArchived: Bool
    /// Non-nil when the entry is in the trash.
    var deletedAt: Date?
    /// Whether the entry is hidden (requires biometric/password to view).
    var isHidden: Bool
    var attachments: [Attachment]

    static func new() -> JournalEntry {
        JournalEntry(id: UUID().uuidString, title: "", body: "", mood: .neutral,
                     tags: [], createdAt: Date(), updatedAt: Date(),
                     isPinned: false, isFavorite: false, isArchived: false,
                     deletedAt: nil, isHidden: false, attachments: [])
    }

    var isTrashed: Bool { deletedAt != nil }

    var wordCount: Int { body.isEmpty ? 0 : body.split(whereSeparator: { $0.isWhitespace }).count }
    var characterCount: Int { body.count }

    var readingMinutes: Int { max(1, Int(ceil(Double(wordCount) / 220.0))) }
    var readingTime: String {
        let minutes = readingMinutes
        return minutes == 1 ? "1 min read" : "\(minutes) min read"
    }

    var displayTitle: String { title.isEmpty ? "Untitled" : title }

    var preview: String {
        let stripped = body
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? "No content" : stripped
    }

    var bodyAsAttributed: AttributedString {
        MarkdownRenderer.render(body)
    }

    /// Days elapsed since the entry was moved to the trash.
    var daysInTrash: Int {
        guard let deletedAt else { return 0 }
        return Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
    }
}

// MARK: - Entry Filter

/// Declarative description of everything the entry list is currently filtering on.
struct EntryFilter: Equatable {
    enum DateRange: String, CaseIterable, Identifiable {
        case any = "Any time"
        case today = "Today"
        case last7 = "Last 7 days"
        case last30 = "Last 30 days"
        case thisMonth = "This month"
        case thisYear = "This year"
        var id: String { rawValue }

        /// Inclusive lower bound, or nil for "any time".
        var startDate: Date? {
            let cal = Calendar.current
            let now = Date()
            switch self {
            case .any: return nil
            case .today: return cal.startOfDay(for: now)
            case .last7: return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))
            case .last30: return cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: now))
            case .thisMonth: return cal.dateInterval(of: .month, for: now)?.start
            case .thisYear: return cal.dateInterval(of: .year, for: now)?.start
            }
        }
    }

    var moods: Set<Mood> = []
    var tags: Set<String> = []
    var dateRange: DateRange = .any
    var favoritesOnly = false
    var pinnedOnly = false
    var withAttachmentsOnly = false
    var minWords: Int = 0

    static let empty = EntryFilter()

    var isActive: Bool { self != EntryFilter.empty }

    var activeCount: Int {
        var n = 0
        if !moods.isEmpty { n += 1 }
        if !tags.isEmpty { n += 1 }
        if dateRange != .any { n += 1 }
        if favoritesOnly { n += 1 }
        if pinnedOnly { n += 1 }
        if withAttachmentsOnly { n += 1 }
        if minWords > 0 { n += 1 }
        return n
    }

    func matches(_ entry: JournalEntry) -> Bool {
        if !moods.isEmpty && !moods.contains(entry.mood) { return false }
        if !tags.isEmpty && tags.isDisjoint(with: Set(entry.tags)) { return false }
        if let start = dateRange.startDate, entry.createdAt < start { return false }
        if favoritesOnly && !entry.isFavorite { return false }
        if pinnedOnly && !entry.isPinned { return false }
        if withAttachmentsOnly && entry.attachments.isEmpty { return false }
        if minWords > 0 && entry.wordCount < minWords { return false }
        return true
    }
}
