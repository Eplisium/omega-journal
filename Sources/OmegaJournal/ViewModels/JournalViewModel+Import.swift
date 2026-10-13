import Combine
import Foundation
import SwiftUI
import AppKit
import OmegaJournalCore

extension JournalViewModel {
    // MARK: - Import

    struct ImportReport: Equatable {
        var added = 0
        var duplicates = 0
        var skipped: [String] = []
    }

    /// Every stored entry, trashed included. Returns nil when the read looks
    /// failed (row count disagrees with COUNT(*)) so callers never treat an
    /// unreadable database as an empty one and re-insert over real data.
    func allStoredEntries() -> [JournalEntry]? {
        let stored = db.fetchAllEntriesForExport()
        let expected = db.entryCount(scope: .all) + db.entryCount(scope: .trashed)
        return stored.count == expected ? stored : nil
    }

    /// Title + creation time at WHOLE-second precision: text formats (markdown front
    /// matter, older exports) may round-trip timestamps without sub-second digits.
    static func dupKey(title: String, createdAt: Date) -> String {
        "\(title)\u{1}\(Int(createdAt.timeIntervalSince1970.rounded(.down)))"
    }

    /// Imports entries from a previously exported JSON file. Returns the number added.
    /// Existing ids (active, archived, hidden OR trashed) are never overwritten.
    @discardableResult
    func importJSON(from url: URL) -> Int {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let export = try decoder.decode(ExportManager.JSONExport.self, from: data)
            guard let stored = allStoredEntries() else {
                showToast("Import aborted: couldn't read the existing journal safely", isError: true)
                return 0
            }
            flushBeforeImmediateMutation()
            var knownIDs = Set(stored.map(\.id))
            var added = 0
            var skipped = 0
            var pendingAttachments: [(id: String, items: [ExportManager.DecodedAttachment])] = []
            // One transaction for the whole file: a failure leaves the journal
            // untouched instead of half-imported, and there is one commit/FTS
            // pass instead of one per entry.
            let committed = db.inTransaction {
              for je in export.entries {
                guard knownIDs.insert(je.id).inserted else { skipped += 1; continue }
                var entry = JournalEntry(
                    id: je.id, title: ImportParsers.normalizeNewlines(je.title), body: ImportParsers.normalizeNewlines(je.body),
                    mood: Mood(rawValue: je.mood) ?? .neutral,
                    tags: OmegaCore.normalizeTags(je.tags),
                    createdAt: je.createdAt, updatedAt: je.updatedAt,
                    isPinned: je.isPinned, isFavorite: je.isFavorite,
                    isArchived: je.isArchived ?? false,
                    deletedAt: je.deletedAt,
                    isHidden: je.isHidden ?? false,
                    attachments: []
                )
                entry.journalId = db.ensureJournal(id: je.journalId, name: je.journalName)
                db.saveEntry(entry)
                added += 1
                let atts = ExportManager.decodeAttachments(je)
                if !atts.isEmpty { pendingAttachments.append((je.id, atts)) }
                for r in je.revisions ?? [] {
                    // A revision that can't be stored fails the whole import (rolled back)
                    // rather than silently dropping history the file carried.
                    if !db.importRevision(entryId: je.id, title: r.title, body: ImportParsers.normalizeNewlines(r.body),
                                          createdAt: r.createdAt, isAuto: r.isAuto ?? true) {
                        db.flagTransactionFailure()
                    }
                }
              }
            }
            guard committed else {
                reload()
                showToast("Import failed and was rolled back — no entries were added", isError: true)
                return 0
            }
            // Attachment files are written only after the entries committed.
            for (id, items) in pendingAttachments {
                for a in items { _ = db.saveAttachment(entryId: id, data: a.data, filename: a.filename, mimeType: a.mimeType) }
            }
            reload()
            if added == 0 {
                showToast("Nothing new to import (\(skipped) already in your journal)")
            } else {
                showToast("Imported \(added) \(added == 1 ? "entry" : "entries")" + (skipped > 0 ? ", skipped \(skipped) already present" : ""))
            }
            return added
        } catch {
            showToast("Import failed: \(error.localizedDescription)", isError: true)
            return 0
        }
    }

    /// Splits raw markdown into a title and body: a leading `# Heading` wins,
    /// otherwise the filename is the title. Pure, so it can be tested directly.
    static func parseMarkdownImport(text: String, fallbackTitle: String) -> (title: String, body: String) {
        OmegaCore.parseMarkdownImport(text: text, fallbackTitle: fallbackTitle)
    }

    /// Imports markdown files, one entry per file. Returns the number added;
    /// use `importMarkdownReport` for the skipped/duplicate breakdown.
    @discardableResult
    func importMarkdown(from urls: [URL]) -> Int {
        importMarkdownReport(from: urls).added
    }

    @discardableResult
    func importMarkdownReport(from urls: [URL]) -> ImportReport {
        var report = ImportReport()
        guard let stored = allStoredEntries() else {
            showToast("Import aborted: couldn't read the existing journal safely", isError: true)
            report.skipped = urls.map(\.lastPathComponent)
            return report
        }
        flushBeforeImmediateMutation()
        var keys = Set(stored.map { Self.dupKey(title: $0.title, createdAt: $0.createdAt) })
        let knownIds = Set(stored.map(\.id))
        for url in urls {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                report.skipped.append(url.lastPathComponent)
                continue
            }
            let text = ImportParsers.normalizeNewlines(raw)
            let fallbackTitle = url.deletingPathExtension().lastPathComponent
            let fileDate = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            var entry = JournalEntry.new()
            let fm = ImportParsers.splitFrontMatter(text)
            if !fm.fields.isEmpty || !fm.lists.isEmpty {
                // Front matter (our own markdown export, Obsidian…): honor title/date/mood/tags.
                let note = ImportParsers.parseMarkdownNote(text: text, fallbackTitle: fallbackTitle, fallbackDate: fileDate)
                if let sid = note.sourceId, knownIds.contains(sid) { report.duplicates += 1; continue }
                entry.title = note.title
                entry.body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
                entry.tags = OmegaCore.normalizeTags(note.tags + ["imported"])
                entry.createdAt = note.createdAt
                entry.updatedAt = max(note.updatedAt, note.createdAt)
                entry.isFavorite = note.isFavorite
                entry.mood = note.mood.flatMap(Mood.init(rawValue:)) ?? .neutral
            } else {
                let parsed = Self.parseMarkdownImport(text: text, fallbackTitle: fallbackTitle)
                entry.title = parsed.title
                entry.body = parsed.body
                entry.tags = OmegaCore.normalizeTags(["imported"])
                entry.createdAt = fileDate
                entry.updatedAt = fileDate
            }
            guard keys.insert(Self.dupKey(title: entry.title, createdAt: entry.createdAt)).inserted else {
                report.duplicates += 1
                continue
            }
            db.saveEntry(entry)
            report.added += 1
        }
        reload()
        var parts: [String] = []
        parts.append(report.added == 0 ? "No markdown files imported" : "Imported \(report.added) markdown \(report.added == 1 ? "file" : "files")")
        if report.duplicates > 0 { parts.append("\(report.duplicates) already imported") }
        if !report.skipped.isEmpty {
            let names = report.skipped.prefix(3).joined(separator: ", ")
            parts.append("\(report.skipped.count) unreadable (\(names)\(report.skipped.count > 3 ? "…" : ""))")
        }
        showToast(parts.joined(separator: " · "), isError: !report.skipped.isEmpty)
        return report
    }
}
