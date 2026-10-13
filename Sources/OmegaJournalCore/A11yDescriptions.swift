import Foundation

// MARK: - Accessibility descriptions (pure, testable)
//
// VoiceOver strings for Browse/Reading surfaces. Every builder takes a
// `canShowContent` gate (see `ContentMasking`) so a locked hidden entry only
// ever contributes its title, mood and date — never body-derived data such as
// tags, word counts, reading time, attachments or place stamps.

/// The facts a list row may announce. Body-derived fields are ignored when
/// `canShowContent` is false, whatever the caller passes in.
public struct A11yEntrySummary: Sendable, Equatable {
    public var title: String
    public var moodLabel: String
    /// Already formatted by the caller (creation date, or trash countdown).
    public var dateText: String
    public var isPinned: Bool
    public var isFavorite: Bool
    public var isHidden: Bool
    /// `ContentMasking.canShowContent(isHidden:hiddenLocked:)` for this entry.
    public var canShowContent: Bool
    public var wordCount: Int
    public var tags: [String]
    public var attachmentCount: Int

    public init(title: String, moodLabel: String, dateText: String,
                isPinned: Bool = false, isFavorite: Bool = false, isHidden: Bool = false,
                canShowContent: Bool = true, wordCount: Int = 0, tags: [String] = [],
                attachmentCount: Int = 0) {
        self.title = title
        self.moodLabel = moodLabel
        self.dateText = dateText
        self.isPinned = isPinned
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.canShowContent = canShowContent
        self.wordCount = wordCount
        self.tags = tags
        self.attachmentCount = attachmentCount
    }
}

/// VoiceOver custom actions on an entry row. Hover-only quick actions are
/// invisible to VoiceOver and keyboard users; these expose the same commands.
public enum A11yEntryRowAction: String, CaseIterable, Sendable {
    case edit, togglePin, toggleFavorite, toggleArchive, moveToTrash, restore, deleteForever

    public static func available(isTrash: Bool) -> [A11yEntryRowAction] {
        isTrash ? [.restore, .deleteForever]
                : [.edit, .togglePin, .toggleFavorite, .toggleArchive, .moveToTrash]
    }

    public func title(isPinned: Bool, isFavorite: Bool, isArchived: Bool) -> String {
        switch self {
        case .edit: "Edit"
        case .togglePin: isPinned ? "Unpin" : "Pin"
        case .toggleFavorite: isFavorite ? "Unfavorite" : "Favorite"
        case .toggleArchive: isArchived ? "Unarchive" : "Archive"
        case .moveToTrash: "Move to Trash"
        case .restore: "Restore"
        case .deleteForever: "Delete Forever"
        }
    }
}

public enum A11yDescriptions {
    /// Maximum tags read aloud for one row; the rest are summarised as "+N more".
    public static let maxSpokenTags = 3

    /// Row label: title first, then state flags, mood and date. Body-derived
    /// details (tags, words, attachments) are appended only when unlocked.
    public static func entryRowLabel(_ s: A11yEntrySummary) -> String {
        let title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = [title.isEmpty ? "Untitled" : title]
        if s.isPinned { parts.append("pinned") }
        if s.isFavorite { parts.append("favorite") }
        if s.isHidden { parts.append(s.canShowContent ? "hidden, unlocked" : "hidden, locked") }
        parts.append(s.moodLabel)
        parts.append(s.dateText)
        guard s.canShowContent else { return parts.joined(separator: ", ") }

        if s.wordCount > 0 { parts.append(s.wordCount == 1 ? "1 word" : "\(s.wordCount) words") }
        if s.attachmentCount > 0 {
            parts.append(s.attachmentCount == 1 ? "1 attachment" : "\(s.attachmentCount) attachments")
        }
        if !s.tags.isEmpty {
            let spoken = s.tags.prefix(maxSpokenTags).joined(separator: ", ")
            let extra = s.tags.count - maxSpokenTags
            parts.append("tags " + spoken + (extra > 0 ? ", +\(extra) more" : ""))
        }
        return parts.joined(separator: ", ")
    }

    /// Row value describing selection, so VoiceOver states it after the label.
    public static func entryRowValue(isSelected: Bool, isBulkSelecting: Bool, isBulkSelected: Bool) -> String {
        if isBulkSelecting { return isBulkSelected ? "checked" : "unchecked" }
        return isSelected ? "selected" : ""
    }

    /// Row hint, in macOS phrasing (no iOS "double tap").
    public static func entryRowHint(isBulkSelecting: Bool, isTrash: Bool) -> String {
        if isBulkSelecting { return "Toggles this entry in the bulk selection" }
        return isTrash ? "Shows this deleted entry" : "Opens this entry; double-click to edit"
    }

    /// Reader header chips. A locked hidden entry shows mood and date only —
    /// word count, reading time and the place/weather stamp come from the body.
    public static func readerMetaChips(mood: String, date: String, wordCount: Int, readingTime: String,
                                       stampSummary: String?, canShowContent: Bool) -> [String] {
        var chips = [mood, date]
        guard canShowContent else { return chips }
        chips.append(wordCount == 1 ? "1 word" : "\(wordCount) words")
        chips.append(readingTime)
        if let stampSummary, !stampSummary.isEmpty { chips.append("📍 " + stampSummary) }
        return chips
    }

    /// Filter-bar toggle chip label: icon-only/emoji chips must say what they filter.
    public static func filterChipLabel(kind: String, name: String) -> String {
        kind.isEmpty ? "\(name) filter" : "\(name) \(kind) filter"
    }

    /// Filter-bar chip value: on/off read as part of the control.
    public static func filterChipValue(isOn: Bool) -> String { isOn ? "on" : "off" }

    /// Command palette status line, also used as the results list label.
    public static func paletteResultCount(_ count: Int) -> String {
        count == 1 ? "1 result" : "\(count) results"
    }
}
