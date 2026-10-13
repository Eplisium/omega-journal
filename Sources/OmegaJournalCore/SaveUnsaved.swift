import Foundation

// MARK: - Unsaved entries after the editor closes (Save track, wave 4)
//
// A failed save used to be visible only as the editor footer and a 4-second
// toast. These pure helpers back the persistent reader banner, the published
// unsaved count, the quit warning and the tag rewrites applied to unsaved
// snapshots. Wording carries the fixed failure reason only — never the entry
// title, body or tags.

/// A tag change that must also be applied to snapshots still held in memory,
/// so a later retry (which writes the snapshot's tags) cannot bring back a
/// renamed or deleted tag. Rules mirror the database:
/// `renameTagTree` re-roots `from` and `from/…` (case-sensitive, like
/// `TagPath.renamed`); `deleteTagEverywhere` removes the tag and every
/// descendant (case-insensitive, like `TagPath.isSameOrDescendant`).
public enum SaveTagRewrite: Equatable, Sendable {
    case rename(from: String, to: String)
    case delete(String)

    /// Rewritten tags, order kept, duplicates (e.g. after a merge) dropped.
    public func apply(to tags: [String]) -> [String] {
        let mapped: [String]
        switch self {
        case .rename(let from, let to):
            mapped = tags.map { TagPath.renamed($0, from: from, to: to) ?? $0 }
        case .delete(let tag):
            mapped = tags.filter { !TagPath.isSameOrDescendant($0, of: tag) }
        }
        var seen = Set<String>()
        return mapped.filter { seen.insert($0).inserted }
    }
}

/// What to do when the app is asked to quit.
public enum SaveQuitDecision: Equatable, Sendable {
    case terminate
    case confirm(unsavedCount: Int)

    public static func decide(unsavedCount: Int) -> SaveQuitDecision {
        unsavedCount > 0 ? .confirm(unsavedCount: unsavedCount) : .terminate
    }
}

public enum SaveUnsavedPresentation {
    public static let bannerTitle = "Not saved"

    /// Reader banner: "Not saved · <reason>".
    public static func bannerText(_ reason: SaveFailureReason) -> String {
        "\(bannerTitle) · \(reason.message)"
    }

    public static func bannerAccessibilityLabel(_ reason: SaveFailureReason) -> String {
        "This entry is not saved. \(reason.message). Your text is kept in memory; Retry tries to save it again."
    }

    /// Short count for sidebars/toolbars; nil when everything is saved.
    public static func countLabel(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 entry not saved" : "\(count) entries not saved"
    }

    public static let quitAlertTitle = "Quit without saving?"

    public static func quitAlertMessage(unsavedCount: Int) -> String {
        let what = unsavedCount == 1 ? "1 entry has" : "\(unsavedCount) entries have"
        return "\(what) changes that couldn't be saved. Quitting now loses them. Retry first, or quit anyway."
    }

    public static let quitRetryButton = "Retry and Quit"
    public static let quitAnywayButton = "Quit Anyway"
    public static let quitCancelButton = "Cancel"
}
