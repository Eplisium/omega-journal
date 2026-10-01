import Foundation
import OmegaJournalCore

// MARK: - Importers (Day One JSON, Obsidian / markdown / plain-text folders)

extension JournalViewModel {
    struct FolderImportReport: Equatable {
        var added = 0
        var duplicates = 0
        var skipped: [String] = []
        var attachments = 0
    }

    /// Builds new (never hidden) entries from parsed import records, de-duplicating against
    /// the whole stored journal by title+timestamp. `attachmentRoot` resolves relative attachment paths.
    @discardableResult
    func importRecords(_ records: [ImportedEntry], attachmentRoot: URL?, extraTag: String) -> FolderImportReport {
        var report = FolderImportReport()
        guard let stored = allStoredEntries() else {
            showToast("Import aborted: couldn't read the existing journal safely", isError: true)
            return report
        }
        flushBeforeImmediateMutation()
        var keys = Set(stored.map { Self.dupKey(title: $0.title, createdAt: $0.createdAt) })
        var pending: [(id: String, files: [URL])] = []
        let committed = db.inTransaction {
            for r in records {
                guard keys.insert(Self.dupKey(title: r.title, createdAt: r.createdAt)).inserted else {
                    report.duplicates += 1; continue
                }
                var entry = JournalEntry.new()
                entry.title = r.title
                entry.body = r.body
                entry.tags = OmegaCore.normalizeTags(r.tags + [extraTag])
                entry.createdAt = r.createdAt
                entry.updatedAt = r.updatedAt
                entry.isFavorite = r.isFavorite
                entry.mood = r.mood.flatMap(Mood.init(rawValue:)) ?? .neutral
                db.saveEntry(entry)
                report.added += 1
                if let root = attachmentRoot {
                    let files = r.attachmentPaths.map { root.appendingPathComponent($0) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !files.isEmpty { pending.append((entry.id, files)) }
                }
            }
        }
        guard committed else {
            reload()
            showToast("Import failed and was rolled back — no entries were added", isError: true)
            return FolderImportReport()
        }
        for (id, files) in pending {
            for f in files {
                guard let data = try? Data(contentsOf: f) else { continue }
                if db.saveAttachment(entryId: id, data: data, filename: f.lastPathComponent,
                                     mimeType: Self.mimeType(forExtension: f.pathExtension)) != nil {
                    report.attachments += 1
                }
            }
        }
        reload()
        return report
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    private func toast(_ report: FolderImportReport, noun: String) {
        guard report.added > 0 || report.duplicates > 0 else {
            showToast("No \(noun) found to import", isError: true); return
        }
        var parts = [report.added == 0 ? "Nothing new to import" : "Imported \(report.added) \(report.added == 1 ? "entry" : "entries")"]
        if report.attachments > 0 { parts.append("\(report.attachments) attachment\(report.attachments == 1 ? "" : "s")") }
        if report.duplicates > 0 { parts.append("\(report.duplicates) already present") }
        if !report.skipped.isEmpty { parts.append("\(report.skipped.count) skipped") }
        showToast(parts.joined(separator: " · "), isError: !report.skipped.isEmpty)
    }

    /// Day One "Export → JSON" — either the `.json` file or the unzipped folder containing it
    /// (photos are read from the sibling `photos/` directory).
    @discardableResult
    func importDayOneJSON(from url: URL) -> FolderImportReport {
        var jsonURL = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let found = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                .first { $0.pathExtension.lowercased() == "json" }
            guard let found else {
                showToast("No Day One JSON file found in that folder", isError: true)
                return FolderImportReport()
            }
            jsonURL = found
        }
        do {
            let result = try ImportParsers.parseDayOneJSON(Data(contentsOf: jsonURL))
            var report = importRecords(result.entries, attachmentRoot: jsonURL.deletingLastPathComponent(), extraTag: "dayone")
            if result.skipped > 0 { report.skipped = Array(repeating: "entry", count: result.skipped) }
            toast(report, noun: "Day One entries")
            return report
        } catch {
            showToast("Day One import failed: \(error.localizedDescription)", isError: true)
            return FolderImportReport()
        }
    }

    /// Recursively imports `.md`/`.markdown`/`.txt` files (Obsidian vault or any notes folder).
    /// Hidden folders (`.obsidian`, `.trash`) are skipped. Front matter supplies title/date/tags/mood.
    @discardableResult
    func importNotesFolder(from root: URL) -> FolderImportReport {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            showToast("Couldn't read that folder", isError: true)
            return FolderImportReport()
        }
        var records: [ImportedEntry] = []
        var skipped: [String] = []
        let attachExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "pdf"]
        var siblingFiles: [String: URL] = [:]
        var notes: [URL] = []
        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            if ["md", "markdown", "txt"].contains(ext) { notes.append(url) }
            else if attachExts.contains(ext) { siblingFiles[url.lastPathComponent] = url }
        }
        for url in notes.sorted(by: { $0.path < $1.path }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { skipped.append(url.lastPathComponent); continue }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let date = values?.creationDate ?? values?.contentModificationDate ?? Date()
            let stem = url.deletingPathExtension().lastPathComponent
            var record = url.pathExtension.lowercased() == "txt"
                ? ImportParsers.parsePlainText(text: text, fallbackTitle: stem, fallbackDate: date)
                : ImportParsers.parseMarkdownNote(text: text, fallbackTitle: stem, fallbackDate: date)
            if record.updatedAt < record.createdAt { record.updatedAt = record.createdAt }
            // Obsidian embeds: ![[image.png]] — attach the referenced file when found in the vault.
            let embeds = Self.obsidianEmbeds(in: record.body)
            let relRoot = root.standardizedFileURL.path
            record.attachmentPaths = embeds.compactMap { name in
                guard let f = siblingFiles[name] else { return nil }
                let p = f.standardizedFileURL.path
                return p.hasPrefix(relRoot + "/") ? String(p.dropFirst(relRoot.count + 1)) : nil
            }
            record.body = record.body.replacingOccurrences(of: "!\\[\\[[^\\]]+\\]\\]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            records.append(record)
        }
        var report = importRecords(records, attachmentRoot: root, extraTag: "imported")
        report.skipped = skipped
        toast(report, noun: "notes")
        return report
    }

    static func obsidianEmbeds(in body: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "!\\[\\[([^\\]|]+)(?:\\|[^\\]]*)?\\]\\]") else { return [] }
        let ns = body as NSString
        return re.matches(in: body, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)) as NSString).lastPathComponent
        }
    }

    /// Opens a passphrase-protected `.ojenc` export (or plain JSON) and imports it.
    @discardableResult
    func importEncryptedExport(from url: URL, passphrase: String) -> Int {
        do {
            let raw = try Data(contentsOf: url)
            let plain = try PassphraseVault.open(raw, passphrase: passphrase)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ojimport-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try plain.write(to: tmp, options: .atomic)
            return importJSON(from: tmp)
        } catch {
            showToast(error.localizedDescription, isError: true)
            return 0
        }
    }
}
