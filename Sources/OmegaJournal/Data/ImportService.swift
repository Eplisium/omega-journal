import AppKit
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

    /// One file to attach to an imported entry, read only after the entries commit.
    struct PendingImportAttachment {
        let name: String
        let load: () -> Data?
    }

    /// Builds new (never hidden) entries from parsed import records, de-duplicating against
    /// the whole stored journal by title+timestamp. `attachmentRoot` resolves relative attachment paths.
    @discardableResult
    func importRecords(_ records: [ImportedEntry], attachmentRoot: URL?, extraTag: String) -> FolderImportReport {
        importRecords(records, extraTag: extraTag) { paths in
            guard let root = attachmentRoot else { return [] }
            return Self.containedAttachmentFiles(paths, root: root).map { f in
                PendingImportAttachment(name: f.name, load: { try? Data(contentsOf: f.url) })
            }
        }
    }

    /// Core of every record importer. `attachments` turns a record's
    /// `attachmentPaths` into loaders; files are read one at a time after the
    /// transaction commits, so a large export is never held in memory at once.
    /// With `adoptSourceIds`, a record's `sourceId` becomes the new entry's id —
    /// a re-import then recognises the entry exactly (even if it was renamed
    /// or trashed since) instead of relying on title + time.
    @discardableResult
    func importRecords(_ records: [ImportedEntry], extraTag: String, adoptSourceIds: Bool = false,
                       attachments: ([String]) -> [PendingImportAttachment]) -> FolderImportReport {
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
        var pending: [(id: String, files: [PendingImportAttachment])] = []
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
                let fresh = JournalEntry.new()
                let id = adoptSourceIds ? (r.sourceId.flatMap(Self.adoptableId) ?? fresh.id) : fresh.id
                var entry = JournalEntry(id: id, title: title, body: ImportParsers.normalizeNewlines(r.body),
                                         mood: r.mood.flatMap(Mood.init(rawValue:)) ?? .neutral,
                                         tags: OmegaCore.normalizeTags(r.tags + [extraTag]),
                                         createdAt: r.createdAt, updatedAt: r.updatedAt,
                                         isPinned: false, isFavorite: r.isFavorite, isArchived: false,
                                         deletedAt: nil, isHidden: false, attachments: [])
                entry.journalId = fresh.journalId
                db.saveEntry(entry)
                report.added += 1
                let files = r.attachmentPaths.isEmpty ? [] : attachments(r.attachmentPaths)
                if !files.isEmpty { pending.append((entry.id, files)) }
            }
        }
        guard committed else {
            reload()
            showToast("Import failed and was rolled back — no entries were added", isError: true)
            return FolderImportReport()
        }
        for (id, files) in pending {
            for f in files {
                guard let data = f.load() else { continue }
                if db.saveAttachment(entryId: id, data: data, filename: f.name,
                                     mimeType: Self.mimeType(forExtension: (f.name as NSString).pathExtension)) != nil {
                    report.attachments += 1
                }
            }
        }
        reload()
        return report
    }

    /// Only canonical UUID strings become entry ids.
    nonisolated static func adoptableId(_ sourceId: String) -> String? {
        UUID(uuidString: sourceId)?.uuidString
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
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "heif": return "image/heif"
        case "tif", "tiff": return "image/tiff"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
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

    // MARK: Apple Journal

    /// What an Apple Journal import would do, shown before anything is written.
    struct AppleJournalImportPreview: Equatable {
        var total = 0
        var new = 0
        var duplicates = 0
        var attachments = 0
        var unreadable = 0

        /// "12 entries (3 already in your journal) with 20 photos and videos."
        var summary: String {
            var s = "\(total) \(total == 1 ? "entry" : "entries")"
            if duplicates > 0 { s += " (\(duplicates) already in your journal)" }
            if attachments > 0 { s += " with \(attachments) \(attachments == 1 ? "photo or recording" : "photos and recordings")" }
            if unreadable > 0 { s += "; \(unreadable) page\(unreadable == 1 ? "" : "s") couldn't be read" }
            return s + "."
        }
    }

    /// Opens an Apple Journal export: the `AppleJournalEntries` folder, the
    /// folder that contains it, its `Entries` folder, or the `.zip` Finder makes
    /// from it. nil = not an Apple Journal export.
    nonisolated static func openAppleJournalExport(at url: URL) -> (layout: AppleJournalLayout, read: (String) -> Data?)? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
                  let zip = try? AppleJournalZipReader(data: data) else { return nil }
            let files = zip.filesByName
            guard let layout = AppleJournalImport.layout(paths: Array(files.keys)) else { return nil }
            return (layout, { path in files[path].flatMap { try? zip.contents(of: $0) } })
        }
        // Picked the `Entries` folder itself: read from its parent.
        var root = url.standardizedFileURL
        if root.lastPathComponent.lowercased() == "entries" { root = root.deletingLastPathComponent() }
        let rootReal = root.resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var paths: [String] = []
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let p = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard p.hasPrefix(rootReal + "/") else { continue }
            paths.append(String(p.dropFirst(rootReal.count + 1)))
            if paths.count > 200_000 { break }
        }
        guard let layout = AppleJournalImport.layout(paths: paths) else { return nil }
        let known = Set(paths)
        return (layout, { path in
            // Only files the walk found under the chosen folder are ever read.
            guard known.contains(path) else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: rootReal).appendingPathComponent(path))
        })
    }

    /// Parses the export and counts what is new. Nothing is written.
    func previewAppleJournal(_ result: AppleJournalImportResult) -> AppleJournalImportPreview? {
        guard let stored = allStoredEntries() else { return nil }
        var ids = Set(stored.map(\.id))
        var keys = Set(stored.map { Self.dupKey(title: $0.title, createdAt: $0.createdAt) })
        var p = AppleJournalImportPreview(total: result.entries.count, unreadable: result.skipped)
        for r in result.entries {
            let id = r.sourceId.flatMap(Self.adoptableId)
            let key = Self.dupKey(title: ImportParsers.normalizeNewlines(r.title), createdAt: r.createdAt)
            if let id, ids.contains(id) { p.duplicates += 1; continue }
            guard keys.insert(key).inserted else { p.duplicates += 1; continue }
            if let id { ids.insert(id) }
            p.new += 1
            p.attachments += r.attachmentPaths.count
        }
        return p
    }

    /// Apple Journal (iPhone/iPad/Mac) export → new entries tagged #apple-journal.
    ///
    /// `confirm` sees the preview first; returning false cancels with nothing
    /// written. Entries are never hidden; places are kept in the entry's
    /// place stamp; photos, videos and audio become encrypted attachments.
    /// Everything is written in one transaction (rolled back on failure), and a
    /// re-import of the same export adds nothing.
    @discardableResult
    func importAppleJournal(from url: URL, calendar: Calendar = .current,
                            confirm: ((AppleJournalImportPreview) -> Bool)? = nil) -> FolderImportReport {
        guard let export = Self.openAppleJournalExport(at: url) else {
            showToast("That isn't an Apple Journal export. Choose the AppleJournalEntries folder or its .zip file.", isError: true)
            return FolderImportReport()
        }
        let result = AppleJournalImport.records(layout: export.layout, read: export.read, calendar: calendar,
                                                headerLocales: [Locale.current, Locale.autoupdatingCurrent])
        guard !result.entries.isEmpty else {
            showToast("No entries found in that Apple Journal export", isError: true)
            return FolderImportReport()
        }
        guard let preview = previewAppleJournal(result) else {
            showToast("Import aborted: couldn't read the existing journal safely", isError: true)
            return FolderImportReport()
        }
        if let confirm, !confirm(preview) { return FolderImportReport() }
        var report = importRecords(result.entries, extraTag: AppleJournalImport.tag, adoptSourceIds: true) { paths in
            paths.map { path in
                let name = DatabaseManager.sanitizedAttachmentFilename((path as NSString).lastPathComponent)
                return PendingImportAttachment(name: name, load: { export.read(path) })
            }
        }
        if result.skipped > 0 { report.skipped = Array(repeating: "page", count: result.skipped) }
        toast(report, noun: "Apple Journal entries")
        return report
    }

    /// Standard confirmation sheet for `importAppleJournal(confirm:)`.
    static func confirmAppleJournalImport(_ preview: AppleJournalImportPreview) -> Bool {
        let alert = NSAlert()
        if preview.new == 0 {
            alert.messageText = "Everything in this export is already in your journal"
            alert.informativeText = preview.summary
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        alert.messageText = "Import \(preview.new) \(preview.new == 1 ? "entry" : "entries") from Apple Journal?"
        alert.informativeText = "This export has " + preview.summary
            + " New entries are tagged #apple-journal so you can find them later."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Full flow for a Settings/menu button: pick the export (folder or .zip),
    /// show the preview, then import.
    func chooseAndImportAppleJournal() {
        let panel = NSOpenPanel()
        panel.title = "Import from Apple Journal"
        panel.message = "In Journal, choose File › Export (on iPhone: … › Export), then pick the AppleJournalEntries folder or its .zip file."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importAppleJournal(from: url, confirm: Self.confirmAppleJournalImport)
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
    /// The decrypted JSON is decoded in memory: it carries every entry body
    /// (hidden ones too), revisions and attachments, so it must never be
    /// written to a temp file a crash could leave behind.
    @discardableResult
    func importEncryptedExport(from url: URL, passphrase: String) -> Int {
        let plain: Data
        do {
            let raw = try Data(contentsOf: url)
            plain = try PassphraseVault.open(raw, passphrase: passphrase)
        } catch {
            showToast(error.localizedDescription, isError: true)
            return 0
        }
        return importJSON(data: plain)
    }

    /// Imports a JSON export already in memory (`importJSON(from:)` reads the
    /// file; `.ojenc` imports pass the decrypted bytes). Returns the number
    /// added. Existing ids (active, archived, hidden OR trashed) are never
    /// overwritten.
    @discardableResult
    func importJSON(data: Data) -> Int {
        do {
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
}
