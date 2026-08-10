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
    }

    struct JSONExport: Codable {
        let exportDate: Date
        let appVersion: String
        let entryCount: Int
        let entries: [JSONEntry]
    }

    static func exportJSON(_ entries: [JournalEntry], to url: URL) throws {
        let jsonEntries = entries.map { e in
            JSONEntry(
                id: e.id, title: e.title, body: e.body,
                mood: e.mood.rawValue, moodLabel: e.mood.label,
                tags: e.tags, createdAt: e.createdAt, updatedAt: e.updatedAt,
                isPinned: e.isPinned, isFavorite: e.isFavorite,
                wordCount: e.wordCount
            )
        }
        let export = JSONExport(
            exportDate: Date(),
            appVersion: "1.0",
            entryCount: entries.count,
            entries: jsonEntries
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)
        try data.write(to: url)
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
        try pdfData.write(to: url)
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

    // MARK: - Show Export Panel

    static func showExportPanel(
        title: String,
        filename: String,
        contentType: UTType,
        export: @escaping (URL) throws -> Void
    ) -> String {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true

        var message = ""
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try export(url)
                message = "Exported to \(url.lastPathComponent)"
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
        }
        return message
    }
}
