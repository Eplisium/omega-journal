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
        // A source id equal to an existing entry id (e.g. the `id:` front matter of our own
        // markdown export) means the entry is already here — even if it is trashed.
        var knownIds = Set(stored.map(\.id))
        var pending: [(id: String, files: [(url: URL, name: String)])] = []
        let committed = db.inTransaction {
            for r in records {
                let title = ImportParsers.normalizeNewlines(r.title)
                if let sid = r.sourceId, !sid.isEmpty, knownIds.contains(sid) {
                    report.duplicates += 1; continue
                }
                guard keys.insert(Self.dupKey(title: title, createdAt: r.createdAt)).inserted else {
                    report.duplicates += 1; continue
                }
                if let sid = r.sourceId, !sid.isEmpty { knownIds.insert(sid) }
                var entry = JournalEntry.new()
                entry.title = title
                entry.body = ImportParsers.normalizeNewlines(r.body)
                entry.tags = OmegaCore.normalizeTags(r.tags + [extraTag])
                entry.createdAt = r.createdAt
                entry.updatedAt = r.updatedAt
                entry.isFavorite = r.isFavorite
                entry.mood = r.mood.flatMap(Mood.init(rawValue:)) ?? .neutral
                db.saveEntry(entry)
                report.added += 1
                if let root = attachmentRoot {
                    let files = Self.containedAttachmentFiles(r.attachmentPaths, root: root)
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
                guard let data = try? Data(contentsOf: f.url) else { continue }
                if db.saveAttachment(entryId: id, data: data, filename: f.name,
                                     mimeType: Self.mimeType(forExtension: (f.name as NSString).pathExtension)) != nil {
                    report.attachments += 1
                }
            }
        }
        reload()
        return report
    }

    /// Resolves import-file attachment paths (relative to `root`) to regular files that really
    /// live under `root` after standardizing and resolving symlinks. Anything that escapes
    /// (`../x`, absolute paths, symlinks pointing outside) is dropped. Returns the resolved file
    /// to read plus the name to store it under.
    static func containedAttachmentFiles(_ paths: [String], root: URL) -> [(url: URL, name: String)] {
        let fm = FileManager.default
        let rootReal = root.standardizedFileURL.resolvingSymlinksInPath().path
        var seen = Set<String>()
        var out: [(url: URL, name: String)] = []
        for p in paths where !p.isEmpty && !p.hasPrefix("/") {
            let candidate = root.appendingPathComponent(p).standardizedFileURL
            let real = candidate.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard real.path.hasPrefix(rootReal + "/"),
                  fm.fileExists(atPath: real.path, isDirectory: &isDir), !isDir.boolValue,
                  seen.insert(real.path).inserted else { continue }
            out.append((real, DatabaseManager.sanitizedAttachmentFilename(candidate.lastPathComponent)))
        }
        return out
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

    private func toast(_ report: FolderImportReport, noun: String, note: String? = nil) {
        guard report.added > 0 || report.duplicates > 0 else {
            showToast("No \(noun) found to import", isError: true); return
        }
        var parts = [report.added == 0 ? "Nothing new to import" : "Imported \(report.added) \(report.added == 1 ? "entry" : "entries")"]
        if report.attachments > 0 { parts.append("\(report.attachments) attachment\(report.attachments == 1 ? "" : "s")") }
        if report.duplicates > 0 { parts.append("\(report.duplicates) already present") }
        if !report.skipped.isEmpty { parts.append("\(report.skipped.count) skipped") }
        if let note { parts.append(note) }
        showToast(parts.joined(separator: " · "), isError: !report.skipped.isEmpty || note != nil)
    }

    /// Day One "Export → JSON" — either the `.json` file or the unzipped folder containing it
    /// (photos are read from the sibling `photos/` directory).
    ///
    /// In the App Sandbox picking only the `.json` grants that one file, so when entries list
    /// photos the importer calls `askForPhotoFolder` (with the folder to start in) to get the
    /// export folder; returning nil imports the text only and says so.
    @discardableResult
    func importDayOneJSON(from url: URL,
                          isSandboxed: Bool = AppEnvironment.isSandboxed,
                          canReadPhotosFolder: (URL) -> Bool = MASSandboxDayOneImport.folderIsReadable,
                          askForPhotoFolder: ((URL) -> URL?)? = nil) -> FolderImportReport {
        let fm = FileManager.default
        var jsonURL = url
        var isDir: ObjCBool = false
        let pickedFolder = fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        if pickedFolder {
            let found = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first
            guard let found else {
                showToast("No Day One JSON file found in that folder", isError: true)
                return FolderImportReport()
            }
            jsonURL = found
        }
        let result: ImportParsers.DayOneResult
        do {
            result = try ImportParsers.parseDayOneJSON(Data(contentsOf: jsonURL))
        } catch is ImportParsers.ImportParseError {
            showToast("Day One import failed: that file isn't a Day One JSON export", isError: true)
            return FolderImportReport()
        } catch {
            showToast("Day One import failed: the file couldn't be read as a Day One export", isError: true)
            return FolderImportReport()
        }

        // Shape check on every photo name from the JSON before anything touches the disk.
        var records = result.entries.map { r -> ImportedEntry in
            var r = r
            r.attachmentPaths = MASSandboxDayOneImport.sanitizedPhotoPaths(r.attachmentPaths)
            return r
        }
        let referencesPhotos = records.contains { !$0.attachmentPaths.isEmpty }
        var root: URL?
        var photosSkipped = false
        switch MASSandboxDayOneImport.photoAccess(selection: pickedFolder ? url : jsonURL,
                                                  selectionIsDirectory: pickedFolder,
                                                  referencesPhotos: referencesPhotos,
                                                  isSandboxed: isSandboxed,
                                                  canReadPhotosFolder: canReadPhotosFolder) {
        case .useRoot(let r): root = r
        case .noPhotosNeeded: root = nil
        case .askForFolder(let suggested):
            if let picked = askForPhotoFolder?(suggested) {
                let photos = picked.appendingPathComponent(MASSandboxDayOneImport.photosFolderName, isDirectory: true)
                var sub: ObjCBool = false
                let hasPhotos = fm.fileExists(atPath: photos.path, isDirectory: &sub) && sub.boolValue
                root = MASSandboxDayOneImport.exportRoot(forPickedFolder: picked, hasPhotosSubfolder: hasPhotos)
            }
            photosSkipped = root == nil
        }
        // Containment: each photo must really live inside `<root>/photos`.
        if let root {
            for i in records.indices {
                records[i].attachmentPaths = records[i].attachmentPaths.filter {
                    MASSandboxDayOneImport.containedPhotoFile($0, root: root) != nil
                }
            }
        } else {
            for i in records.indices { records[i].attachmentPaths = [] }
        }

        var report = importRecords(records, attachmentRoot: root, extraTag: "dayone")
        if result.skipped > 0 { report.skipped = Array(repeating: "entry", count: result.skipped) }
        toast(report, noun: "Day One entries",
              note: photosSkipped && report.added > 0 ? "photos not imported (choose the export folder to include them)" : nil)
        return report
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
            let relRoot = root.standardizedFileURL.path
            // Front-matter `attachments:` (Omega's markdown-folder export) are relative to the
            // note. Re-root them, and point the body's relative links back at the stored files.
            var paths: [String] = []
            var linkNames: [String: String] = [:]
            let notePath = url.standardizedFileURL.path
            if notePath.hasPrefix(relRoot + "/") {
                let noteDir = (String(notePath.dropFirst(relRoot.count + 1)) as NSString).deletingLastPathComponent
                for p in record.attachmentPaths {
                    let rel = noteDir.isEmpty ? p : (noteDir as NSString).appendingPathComponent(p)
                    guard let file = Self.containedAttachmentFiles([rel], root: root).first else { continue }
                    paths.append(rel)
                    linkNames[p] = file.name
                }
            }
            record.body = ExportFormats.restoreAttachmentLinks(record.body, names: linkNames)
            // Obsidian embeds: ![[image.png]] — attach the referenced file when found in the vault.
            let embeds = Self.obsidianEmbeds(in: record.body)
            paths += embeds.compactMap { name in
                guard let f = siblingFiles[name] else { return nil }
                let p = f.standardizedFileURL.path
                return p.hasPrefix(relRoot + "/") ? String(p.dropFirst(relRoot.count + 1)) : nil
            }
            record.attachmentPaths = paths
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
