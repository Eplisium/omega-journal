import Foundation
import CoreSpotlight
import SQLite3
import OmegaJournalCore

/// Opt-in (default OFF) Spotlight indexing of NON-hidden entry titles. Bodies, tags and hidden/trashed
/// entries are never handed to Spotlight; turning the setting off removes everything we indexed.
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    nonisolated static let enabledKey = "spotlight.indexTitles"
    nonisolated static let domain = "com.eplisium.omega-journal.entries"

    private var pending: Task<Void, Never>?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Debounced. The SQLite handle is main-actor only, so candidates are read here
    /// (after the debounce) and only the CoreSpotlight calls run in the background.
    func scheduleReindex(db: DatabaseManager) {
        guard Self.isEnabled else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, Self.isEnabled else { return }
            await Self.index(db.spotlightCandidates())
        }
    }

    @concurrent
    nonisolated static func index(_ candidates: [SpotlightPolicy.Candidate]) async {
        let allowed = SpotlightPolicy.indexable(candidates)
        let items = allowed.map { c -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = c.title
            return CSSearchableItem(uniqueIdentifier: c.id, domainIdentifier: domain, attributeSet: attrs)
        }
        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: [domain])
        guard !items.isEmpty else { return }
        try? await index.indexSearchableItems(items)
    }

    func removeAll() {
        pending?.cancel()
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in }
    }
}

extension DatabaseManager {
    /// Id/title/flags only — no bodies are decrypted. Hidden and trashed rows are flagged so policy can drop them.
    func spotlightCandidates() -> [SpotlightPolicy.Candidate] {
        guard let stmt = try? prepare("SELECT id, title, is_hidden, deleted_at IS NOT NULL FROM entries;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [SpotlightPolicy.Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(.init(id: String(cString: sqlite3_column_text(stmt, 0)),
                             title: String(cString: sqlite3_column_text(stmt, 1)),
                             isHidden: sqlite3_column_int(stmt, 2) != 0,
                             isTrashed: sqlite3_column_int(stmt, 3) != 0))
        }
        return out
    }
}
