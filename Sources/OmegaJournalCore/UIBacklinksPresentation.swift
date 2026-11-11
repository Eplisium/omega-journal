import Foundation

// MARK: - Reader backlinks presentation (pure)
//
// The reader used to show "LINKED FROM (0)" plus an empty-state sentence under
// every entry. Now the backlinks list appears only when something links here,
// and unlinked mentions surface as one quiet link only when there are some.

public struct UIBacklinksPresentation: Equatable, Sendable {
    /// Show the "Linked from" list.
    public let showsLinkedFrom: Bool
    /// Heading for the list, e.g. "Linked from 3 entries".
    public let linkedFromHeading: String
    /// Quiet link revealing unlinked mentions ("2 unlinked mentions"); nil
    /// when there are none, the count is not known yet, or the entry has no title.
    public let mentionsLinkTitle: String?

    public init(backlinkCount: Int, mentionCount: Int?, hasTitle: Bool) {
        showsLinkedFrom = backlinkCount > 0
        linkedFromHeading = "Linked from \(backlinkCount) \(backlinkCount == 1 ? "entry" : "entries")"
        if hasTitle, let mentionCount, mentionCount > 0 {
            mentionsLinkTitle = "\(mentionCount) unlinked \(mentionCount == 1 ? "mention" : "mentions")"
        } else {
            mentionsLinkTitle = nil
        }
    }
}
