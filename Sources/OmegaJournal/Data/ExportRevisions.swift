import Foundation

extension ExportManager {
    /// A version-history snapshot carried in JSON exports (v6, optional). The body is plaintext
    /// inside the export, exactly like entry bodies — hidden entries' revisions are only exported
    /// when their entry is (i.e. after unlock).
    struct JSONRevision: Codable, Equatable {
        let createdAt: Date
        let title: String
        let body: String
        var isAuto: Bool? = nil
    }
}

extension DatabaseManager {
    /// Revisions of `entry` for export (decrypted).
    func exportRevisions(for entry: JournalEntry) -> [ExportManager.JSONRevision] {
        revisions(entryId: entry.id).compactMap { r in
            revisionBody(id: r.id).map { ExportManager.JSONRevision(createdAt: r.createdAt, title: r.title, body: $0, isAuto: r.isAuto) }
        }
    }
}
