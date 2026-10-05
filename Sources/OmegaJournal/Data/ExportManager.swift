import Foundation
import SwiftUI
import UniformTypeIdentifiers
import OmegaJournalCore

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
        // Added in v6: optional version history (see `JSONRevision`). Absent in older files / when not requested.
        var revisions: [JSONRevision]? = nil
        // Added with notebooks: optional so older files import into the default journal.
        var journalId: String? = nil
        var journalName: String? = nil
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
    static let formatVersion = 6

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
                           attachmentData: ((Attachment) -> Data?)? = nil,
                           revisionData: ((JournalEntry) -> [JSONRevision])? = nil) throws {
        try jsonData(entries, attachmentData: attachmentData, revisionData: revisionData).write(to: url, options: .atomic)
    }

    static func jsonData(_ entries: [JournalEntry], attachmentData: ((Attachment) -> Data?)? = nil,
                         revisionData: ((JournalEntry) -> [JSONRevision])? = nil,
                         db: DatabaseManager = .shared) throws -> Data {
        let journalNames = Dictionary(db.fetchJournals().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
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
                },
                revisions: revisionData.flatMap { read in
                    let list = read(e)
                    return list.isEmpty ? nil : list
                },
                journalId: e.journalId,
                journalName: journalNames[e.journalId]
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
        return try encoder.encode(export)
    }

    // MARK: Passphrase-encrypted export (CryptoKit)

    static let encryptedExtension = "ojenc"

    /// Full JSON export (attachments included) sealed with a passphrase — readable on any Mac.
    static func exportEncrypted(_ entries: [JournalEntry], to url: URL, passphrase: String,
                                attachmentData: ((Attachment) -> Data?)? = nil,
                                iterations: UInt32 = PassphraseVault.defaultIterations) throws {
        let plain = try jsonData(entries, attachmentData: attachmentData)
        try PassphraseVault.seal(plain, passphrase: passphrase, iterations: iterations).write(to: url, options: .atomic)
    }

    // MARK: Entry model bridge

    static func exportable(_ e: JournalEntry, attachmentFiles: [String] = []) -> ExportableEntry {
        ExportableEntry(id: e.id, title: e.title, body: e.body, mood: e.mood.rawValue, moodLabel: e.mood.label,
                        tags: e.tags, createdAt: e.createdAt, updatedAt: e.updatedAt,
                        isFavorite: e.isFavorite, attachmentFiles: attachmentFiles)
    }

    /// Writes `<dir>/<date title>.md` per entry with YAML front matter, plus `<dir>/attachments/`.
    /// Returns the number of entry files written.
    @discardableResult
    static func exportMarkdownFolder(_ entries: [JournalEntry], to dir: URL,
                                     attachmentData: ((Attachment) -> Data?)? = nil) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stems = ExportFormats.uniqueNames(entries.map { ExportFormats.fileStem(exportable($0)) })
        for (e, stem) in zip(entries, stems) {
            let files = try writeAttachments(for: e, into: dir.appendingPathComponent("attachments", isDirectory: true),
                                             attachmentData: attachmentData)
            let md = ExportFormats.markdownWithFrontMatter(exportable(e, attachmentFiles: files))
            try md.write(to: dir.appendingPathComponent("\(stem).md"), atomically: true, encoding: .utf8)
        }
        return entries.count
    }

    /// Writes an entry's attachments with collision-free names; returns the file names written.
    private static func writeAttachments(for e: JournalEntry, into dir: URL,
                                         attachmentData: ((Attachment) -> Data?)?) throws -> [String] {
        guard let read = attachmentData, !e.attachments.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        for a in e.attachments {
            guard let data = read(a) else { continue }
            let safe = a.filename.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
            let name = "\(e.id.prefix(8))-\(safe)"
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            names.append(name)
        }
        return names
    }

    /// Static website: `index.html`, `entries/<n>.html`, `attachments/…`. Self-contained, no scripts, no network.
    @discardableResult
    static func exportHTMLSite(_ entries: [JournalEntry], to dir: URL, title: String = "Omega Journal",
                               theme: ExportFormats.HTMLTheme = .init(),
                               attachmentData: ((Attachment) -> Data?)? = nil) throws -> Int {
        let fm = FileManager.default
        let entriesDir = dir.appendingPathComponent("entries", isDirectory: true)
        try fm.createDirectory(at: entriesDir, withIntermediateDirectories: true)
        let stems = ExportFormats.uniqueNames(entries.map { ExportFormats.fileStem(exportable($0)) })
        var index: [(ExportableEntry, String)] = []
        for (e, stem) in zip(entries, stems) {
            let files = try writeAttachments(for: e, into: dir.appendingPathComponent("attachments", isDirectory: true),
                                             attachmentData: attachmentData)
            let ex = exportable(e, attachmentFiles: files)
            let fileName = "\(stem).html"
            let page = ExportFormats.entryPage(ex, theme: theme, indexHref: "../index.html", attachmentsHref: "../attachments")
            try page.write(to: entriesDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
            index.append((ex, "entries/" + ExportFormats.percentEncode(fileName)))
        }
        try ExportFormats.indexPage(title: title, entries: index, theme: theme)
            .write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return entries.count
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

    /// The themed, print-quality body shared by PDF export and printing.
    static func entryPrintContent(_ entry: JournalEntry, accent: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.paragraphSpacing = 6
        let ink = NSColor(red: 0.13, green: 0.10, blue: 0.22, alpha: 1)
        let soft = NSColor(red: 0.42, green: 0.38, blue: 0.52, alpha: 1)
        text.append(NSAttributedString(string: entry.displayTitle + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: accent]))
        var meta = "\(entry.createdAt.formatted(date: .long, time: .shortened)) · \(entry.mood.emoji) \(entry.mood.label) · \(entry.wordCount) words"
        if !entry.tags.isEmpty { meta += "\n" + entry.tags.map { "#\($0)" }.joined(separator: "  ") }
        text.append(NSAttributedString(string: meta + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: soft]))
        text.append(NSAttributedString(string: entry.body.isEmpty ? "No content" : entry.body, attributes: [
            .font: NSFont(name: "Georgia", size: 13) ?? NSFont.systemFont(ofSize: 13), .foregroundColor: ink, .paragraphStyle: para]))
        return text
    }

    /// Opens the system print panel for one entry (paginated, 0.75in margins, black on white).
    /// Callers must have unlocked a hidden entry first.
    @MainActor
    static func printEntry(_ entry: JournalEntry, accent: NSColor = NSColor(red: 0.49, green: 0.30, blue: 0.93, alpha: 1)) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.leftMargin = 54; info.rightMargin = 54; info.topMargin = 54; info.bottomMargin = 54
        info.isHorizontallyCentered = false
        info.verticalPagination = .automatic
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.textStorage?.setAttributedString(entryPrintContent(entry, accent: accent))
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.sizeToFit()
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.jobTitle = entry.displayTitle
        op.showsPrintPanel = true
        op.run()
    }

    /// Themed single-entry PDF (accent-coloured heading, serif body). Hidden entries must be
    /// unlocked by the caller before exporting.
    @MainActor
    static func exportEntryPDF(_ entry: JournalEntry, to url: URL, accent: NSColor = NSColor(red: 0.49, green: 0.30, blue: 0.93, alpha: 1)) throws {
        let pageWidth: CGFloat = 612, pageHeight: CGFloat = 792, margin: CGFloat = 54
        let text = entryPrintContent(entry, accent: accent)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: pageWidth - margin * 2, height: pageHeight))
        tv.textStorage?.setAttributedString(text)
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.sizeToFit()
        let height = max(tv.bounds.height + margin * 2, pageHeight)
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: height))
        tv.frame.origin = NSPoint(x: margin, y: height - margin - tv.bounds.height)
        canvas.addSubview(tv)
        try canvas.dataWithPDF(inside: canvas.bounds).write(to: url, options: .atomic)
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
