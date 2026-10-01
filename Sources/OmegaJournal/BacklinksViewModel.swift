import Foundation
import OmegaJournalCore

extension JournalViewModel {
    /// Entries visible to link analysis. Hidden entries only participate while unlocked; trash never does.
    private var linkPool: [JournalEntry] {
        let unlocked = !hiddenLocked
        return (entries + archivedEntries + hiddenEntries).filter { unlocked || !$0.isHidden }
            .reduce(into: [JournalEntry]()) { acc, e in if !acc.contains(where: { $0.id == e.id }) { acc.append(e) } }
    }

    /// Entries that mention `entry`'s title without linking to it.
    func unlinkedMentions(for entry: JournalEntry) -> [JournalEntry] {
        let unlocked = !hiddenLocked
        let pool = linkPool
        let linkable = pool.map { LinkableEntry(id: $0.id, title: $0.title, body: $0.body, isHidden: $0.isHidden) }
        let ids = Set(UnlinkedMentions.find(forTitle: entry.title, in: linkable, excludingId: entry.id, includeHidden: unlocked).map(\.id))
        return pool.filter { ids.contains($0.id) }
    }

    /// Link graph of everything the current session may see (hidden excluded while locked).
    func linkGraph(includeIsolated: Bool = false) -> LinkGraph {
        let unlocked = !hiddenLocked
        let linkable = linkPool.map { LinkableEntry(id: $0.id, title: $0.title, body: $0.body, isHidden: $0.isHidden) }
        return LinkGraph.build(entries: linkable, includeHidden: unlocked, includeIsolated: includeIsolated)
    }

    /// Turns a plain mention in `source` into `[[Title]]` (first unlinked occurrence). Immediate mutation.
    func linkMention(in source: JournalEntry, to target: JournalEntry) {
        guard !target.title.isEmpty,
              let range = source.body.range(of: target.title, options: [.caseInsensitive, .diacriticInsensitive]) else { return }
        var body = source.body
        body.replaceSubrange(range, with: "[[\(body[range])]]")
        updateBody(body, for: source)
        showToast("Linked “\(target.displayTitle)” in “\(source.displayTitle)”")
    }
}
