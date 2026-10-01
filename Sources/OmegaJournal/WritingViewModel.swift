import Foundation
import OmegaJournalCore

extension JournalViewModel {
    /// Titles offered by `[[` autocomplete. Same gating as wiki-link resolution: trashed entries
    /// never appear and hidden entries' titles only while the biometric session is unlocked.
    func linkCandidateTitles(excluding id: String? = nil) -> [String] {
        let unlocked = BiometricAuth.shared.isAuthenticated
        let pool = (entries + archivedEntries + hiddenEntries).filter { (unlocked || !$0.isHidden) && $0.id != id }
        var seen = Set<String>()
        return pool.sorted { $0.updatedAt > $1.updatedAt }.compactMap { e in
            let t = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (!t.isEmpty && seen.insert(t.lowercased()).inserted) ? t : nil
        }
    }
}
