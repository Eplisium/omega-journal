import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export Manager

enum ExportManager {
    // MARK: Markdown Export

    static func exportMarkdown(_ entries: [JournalEntry], to url: URL) throws {
        var md = "# Omega Journal Export\n\n"
        md += "_Generated \(Date().formatted(date: .long, time: .shortened)) — \(entries.count) entries_\n\n"
        for e in entries {
            md += "## \(e.title.isEmpty ? "Untitled" : e.title)\n\n"
            md += "- **Date:** \(e.createdAt.formatted(date: .long, time: .shortened))\n"
            md += "- **Mood:** \(e.mood.label) \(e.mood.emoji)\n"
            if !e.tags.isEmpty {
                md += "- **Tags:** \(e.tags.map { "#\($0)" }.joined(separator: " "))\n"
            }
            md += "\n\(e.body.isEmpty ? "_No content_" : e.body)\n\n---\n\n"
        }
        try md.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: JSON Export

    struct JSONEntry: Codable {
        let id: String
        let title: String
        let body: String
        let mood: Int
        let moodLabel: String
        let tags: [String]
        let createdAt: Date
        let updatedAt: Date
        let isPinned: Bool
        let isFavorite: Bool
        let wordCount: Int
        // Added in v2 of the export format. Older files omit these, so they decode
        // as nil/false and the importer treats them as active (the old behaviour).
        let isArchived: Bool?
        let deletedAt: Date?
        // Added in v3 of the export format: a hidden entry must survive an
        // export/import round-trip as hidden — importing a backup must never
        // silently publish private entries into the visible library.
        let isHidden: Bool?
        // Added in v5: attachment payloads (base64). Absent in older files.
        var attachments: [JSONAttachment]? = nil
    }

    struct JSONAttachment: Codable {
        let filename: String
        let mimeType: String
        /// Base64 of the decrypted file bytes.
        let dataBase64: String
    }

    /// Decoded attachment payload ready to hand to `DatabaseManager.saveAttachment`.
    struct DecodedAttachment: Equatable {
        let filename: String
        let mimeType: String
        let data: Data
    }

    /// Attachments carried by a JSON entry; entries from older files, or with
    /// undecodable payloads, yield fewer/no attachments rather than failing.
    static func decodeAttachments(_ entry: JSONEntry) -> [DecodedAttachment] {
        (entry.attachments ?? []).compactMap { a in
            guard let data = Data(base64Encoded: a.dataBase64) else { return nil }
            return DecodedAttachment(filename: a.filename, mimeType: a.mimeType, data: data)
        }
    }

    /// Bump when the JSON layout changes. v3 = adds isHidden; v4 = adds formatVersion;
    /// v5 = optional per-entry attachments (older files stay importable).
    static let formatVersion = 5

    /// Real app version from the bundle (falls back for `swift run`/tests).
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _): return s
        case let (_, b?): return b
        default: return "dev"
        }
    }

    struct JSONExport: Codable {
        /// Absent in files written before v4.
        var formatVersion: Int? = nil
        let exportDate: Date
        let appVersion: String
        let entryCount: Int
        let entries: [JSONEntry]
    }

    /// `attachmentData` supplies the decrypted bytes of an attachment; when nil,
    /// attachments are not embedded.
    static func exportJSON(_ entries: [JournalEntry], to url: URL,
                           attachmentData: ((Attachment) -> Data?)? = nil) throws {
        let jsonEntries = entries.map { e in
            JSONEntry(
                id: e.id, title: e.title, body: e.body,
                mood: e.mood.rawValue, moodLabel: e.mood.label,
                tags: e.tags, createdAt: e.createdAt, updatedAt: e.updatedAt,
                isPinned: e.isPinned, isFavorite: e.isFavorite,
                wordCount: e.wordCount,
                isArchived: e.isArchived,
                deletedAt: e.deletedAt,
                isHidden: e.isHidden,
                attachments: attachmentData.flatMap { read in
                    let list = e.attachments.compactMap { a in
                        read(a).map { JSONAttachment(filename: a.filename, mimeType: a.mimeType, dataBase64: $0.base64EncodedString()) }
                    }
                    return list.isEmpty ? nil : list
                }
            )
        }
        let export = JSONExport(
            formatVersion: formatVersion,
            exportDate: Date(),
            appVersion: appVersion,
            entryCount: entries.count,
            entries: jsonEntries
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)
        try data.write(to: url, options: .atomic)
    }

    // MARK: PDF Export

    @MainActor
    static func exportPDF(_ entries: [JournalEntry], to url: URL) throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textView.textStorage?.setAttributedString(buildPDFContent(entries))
        textView.isVerticallyResizable = true
        textView.sizeToFit()

        let totalHeight = textView.bounds.height
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792

        let fullRect = NSRect(x: 0, y: 0, width: pageWidth, height: max(totalHeight, pageHeight))
        textView.frame = fullRect

        let pdfData = textView.dataWithPDF(inside: fullRect)
        try pdfData.write(to: url, options: .atomic)
    }

    private static func buildPDFContent(_ entries: [JournalEntry]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titleFont = NSFont.systemFont(ofSize: 28, weight: .bold)
        let headingFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let bodyFont = NSFont(name: "Georgia", size: 13) ?? NSFont.systemFont(ofSize: 13)
        let metaFont = NSFont.systemFont(ofSize: 10)
        let titleColor = NSColor.labelColor
        let metaColor = NSColor.secondaryLabelColor

        // Title page
        result.append(NSAttributedString(string: "Omega Journal\n", attributes: [.font: titleFont, .foregroundColor: titleColor]))
        result.append(NSAttributedString(string: "Exported \(Date().formatted(date: .long, time: .shortened))\n", attributes: [.font: metaFont, .foregroundColor: metaColor]))
        result.append(NSAttributedString(string: "\(entries.count) entries\n\n", attributes: [.font: metaFont, .foregroundColor: metaColor]))

        for (i, entry) in entries.enumerated() {
            if i > 0 {
                result.append(NSAttributedString(string: "\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", attributes: [.font: metaFont, .foregroundColor: metaColor]))
            }

            // Entry heading
            result.append(NSAttributedString(string: entry.title.isEmpty ? "Untitled" : entry.title, attributes: [.font: headingFont, .foregroundColor: titleColor]))
            result.append(NSAttributedString(string: "\n"))

            // Metadata
            let meta = "\(entry.createdAt.formatted(date: .long, time: .shortened)) · \(entry.mood.emoji) \(entry.mood.label) · \(entry.wordCount) words"
            result.append(NSAttributedString(string: meta, attributes: [.font: metaFont, .foregroundColor: metaColor]))
            result.append(NSAttributedString(string: "\n"))

            if !entry.tags.isEmpty {
                result.append(NSAttributedString(string: entry.tags.map { "#\($0)" }.joined(separator: " "), attributes: [.font: metaFont, .foregroundColor: NSColor.systemBlue]))
                result.append(NSAttributedString(string: "\n"))
            }

            // Body
            result.append(NSAttributedString(string: "\n"))
            result.append(NSAttributedString(string: entry.body.isEmpty ? "No content" : entry.body, attributes: [.font: bodyFont, .foregroundColor: titleColor]))
        }

        return result
    }

}
