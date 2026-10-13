import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    // MARK: - Attachments

    /// Reduces an untrusted attachment name (imports, drag & drop) to a single
    /// safe path component: no directories, no `/` or `:`, never `.`/`..`/empty.
    static func sanitizedAttachmentFilename(_ raw: String) -> String {
        let last = (raw as NSString).lastPathComponent
        let cleaned = last.unicodeScalars
            .filter { $0 != "/" && $0 != ":" && $0 != "\0" && !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "attachment" }
        return cleaned
    }

    /// On-disk location of an attachment, or nil when the stored id/filename would
    /// resolve outside `attachmentsDir/<id>/` (malicious or corrupted rows).
    func attachmentFileURL(id: String, filename: String) -> URL? {
        let base = URL(fileURLWithPath: attachmentsDir, isDirectory: true).standardizedFileURL
        let dir = base.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        let file = dir.appendingPathComponent(filename).standardizedFileURL
        guard !id.isEmpty, !filename.isEmpty,
              dir.path.hasPrefix(base.path + "/"), !dir.path.dropFirst(base.path.count + 1).contains("/"),
              file.path.hasPrefix(dir.path + "/"), !file.path.dropFirst(dir.path.count + 1).contains("/")
        else { return nil }
        return file
    }

    /// Decrypts an attachment file for display or external opening. Returns
    /// nil if the file is missing or fails authentication (corrupted/wrong key).
    func readAttachmentData(_ attachment: Attachment) -> Data? {
        guard let url = attachmentFileURL(id: attachment.id, filename: attachment.filename) else { return nil }
        return try? JournalCrypto.readEncrypted(from: url)
    }

    /// Writes a decrypted copy to a caller-managed temp file for NSWorkspace
    /// opening. The caller should remove it after use; the plaintext lives
    /// only transiently in the system temp directory.
    func openAttachmentExternally(_ attachment: Attachment) -> URL? {
        guard let url = attachmentFileURL(id: attachment.id, filename: attachment.filename) else { return nil }
        return try? JournalCrypto.decryptedTemporaryFile(
            from: url,
            preferredName: Self.sanitizedAttachmentFilename(attachment.filename))
    }

    func saveAttachment(entryId: String, data: Data, filename rawFilename: String, mimeType: String = "") -> Attachment? {
        let id = UUID().uuidString
        // The name may come from an untrusted import file: never let it pick
        // the directory (`../../omega_journal.sqlite3` would overwrite the DB).
        let filename = Self.sanitizedAttachmentFilename(rawFilename)
        let dir = (attachmentsDir as NSString).appendingPathComponent(id)
        guard let fileURL = attachmentFileURL(id: id, filename: filename) else {
            reportError("Refused to save attachment with an unsafe name")
            return nil
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Stored encrypted (S1): the plaintext bytes never touch disk. The
        // filename is used as the on-disk name but the content is sealed.
        do {
            try JournalCrypto.writeEncrypted(data, to: fileURL)
        } catch {
            reportError("Failed to save attachment: \(error.localizedDescription)")
            return nil
        }

        let sql = "INSERT INTO attachments (id, entry_id, filename, mime_type, created_at) VALUES (?, ?, ?, ?, ?);"
        guard let stmt = try? prepare(sql) else {
            try? FileManager.default.removeItem(atPath: dir)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        bindText(stmt, index: 2, value: entryId)
        bindText(stmt, index: 3, value: filename)
        bindText(stmt, index: 4, value: mimeType)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            print("Attachment insert failed: \(String(cString: sqlite3_errmsg(db)))")
            // Don't leave an orphaned file behind for a row that doesn't exist.
            try? FileManager.default.removeItem(atPath: dir)
            return nil
        }

        return Attachment(id: id, entryId: entryId, filename: filename, mimeType: mimeType, createdAt: Date())
    }

    func fetchAttachments(entryId: String) -> [Attachment] {
        let sql = "SELECT id, entry_id, filename, mime_type, created_at FROM attachments WHERE entry_id = ? ORDER BY created_at;"
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: entryId)
        var attachments: [Attachment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            attachments.append(Attachment(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                entryId: String(cString: sqlite3_column_text(stmt, 1)),
                filename: String(cString: sqlite3_column_text(stmt, 2)),
                mimeType: String(cString: sqlite3_column_text(stmt, 3)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            ))
        }
        return attachments
    }

    func deleteAttachment(id: String) {
        let dir = (attachmentsDir as NSString).appendingPathComponent(id)
        // Row first; the file only goes once the row deletion is durable. Inside
        // a transaction the removal waits for the outermost COMMIT.
        guard execChecked("DELETE FROM attachments WHERE id = ?;", context: "Attachment row delete failed", bind: {
            self.bindText($0, index: 1, value: id)
        }) else { return }
        if transactionDepth > 0 {
            pendingFileRemovals.append(dir)
        } else {
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    /// One query for every attachment, grouped by entry — avoids N+1 when listing entries.
    func allAttachmentsByEntry() -> [String: [Attachment]] {
        let sql = "SELECT id, entry_id, filename, mime_type, created_at FROM attachments ORDER BY created_at;"
        guard let stmt = try? prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var map: [String: [Attachment]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let a = Attachment(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                entryId: String(cString: sqlite3_column_text(stmt, 1)),
                filename: String(cString: sqlite3_column_text(stmt, 2)),
                mimeType: String(cString: sqlite3_column_text(stmt, 3)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            )
            map[a.entryId, default: []].append(a)
        }
        return map
    }
}
