import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    // MARK: - Attachments

    /// Decrypts an attachment file for display or external opening. Returns
    /// nil if the file is missing or fails authentication (corrupted/wrong key).
    func readAttachmentData(_ attachment: Attachment) -> Data? {
        let dir = (attachmentsDir as NSString).appendingPathComponent(attachment.id)
        let filePath = (dir as NSString).appendingPathComponent(attachment.filename)
        return try? JournalCrypto.readEncrypted(from: URL(fileURLWithPath: filePath))
    }

    /// Writes a decrypted copy to a caller-managed temp file for NSWorkspace
    /// opening. The caller should remove it after use; the plaintext lives
    /// only transiently in the system temp directory.
    func openAttachmentExternally(_ attachment: Attachment) -> URL? {
        let dir = (attachmentsDir as NSString).appendingPathComponent(attachment.id)
        let filePath = (dir as NSString).appendingPathComponent(attachment.filename)
        return try? JournalCrypto.decryptedTemporaryFile(
            from: URL(fileURLWithPath: filePath),
            preferredName: attachment.filename)
    }

    func saveAttachment(entryId: String, data: Data, filename: String, mimeType: String = "") -> Attachment? {
        let id = UUID().uuidString
        let dir = (attachmentsDir as NSString).appendingPathComponent(id)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Stored encrypted (S1): the plaintext bytes never touch disk. The
        // filename is used as the on-disk name but the content is sealed.
        let filePath = (dir as NSString).appendingPathComponent(filename)
        do {
            try JournalCrypto.writeEncrypted(data, to: URL(fileURLWithPath: filePath))
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
