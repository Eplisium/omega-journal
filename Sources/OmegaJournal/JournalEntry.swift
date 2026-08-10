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
    var attachments: [Attachment]

    static func new() -> JournalEntry {
        JournalEntry(id: UUID().uuidString, title: "", body: "", mood: .neutral,
                     tags: [], createdAt: Date(), updatedAt: Date(),
                     isPinned: false, isFavorite: false, attachments: [])
    }

    var wordCount: Int { body.isEmpty ? 0 : body.split(whereSeparator: { $0.isWhitespace }).count }
    var readingTime: String {
        let minutes = max(1, Int(ceil(Double(wordCount) / 220.0)))
        return minutes == 1 ? "1 min read" : "\(minutes) min read"
    }
    var preview: String {
        let s = body.replacingOccurrences(of: "\\n+", with: " ", options: .regularExpression)
        return s.isEmpty ? "No content" : s
    }

    var bodyAsAttributed: AttributedString {
        MarkdownRenderer.render(body)
    }
}
