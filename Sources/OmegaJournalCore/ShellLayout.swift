import Foundation

// Pure geometry/copy rules for the window shell (wave 3, Shell track).
// No SwiftUI, no DB — unit-testable in isolation.

// MARK: - Window structure

public enum ShellColumns: Equatable, Sendable {
    /// Entry list + entry detail beside the sidebar.
    case listAndDetail
    /// One full-width page (Today, Calendar, Insights, On This Day).
    case page

    /// Which columns a workspace shows to the right of the sidebar. The
    /// sidebar itself is never part of this decision: it is one persistent
    /// column, so switching workspaces cannot reset its width or scroll.
    public static func forWorkspace(usesEntryCollection: Bool) -> ShellColumns {
        usesEntryCollection ? .listAndDetail : .page
    }
}

// MARK: - Entry list column width

public enum ShellListColumn {
    public static let minWidth: Double = 280
    public static let idealWidth: Double = 340
    public static let maxWidth: Double = 460
    /// Room always left for the reader/editor beside the list. 414pt is what
    /// the old three-column split left the detail at the 940pt minimum window
    /// (list 292pt), which the editor/reader geometry was tuned against.
    public static let detailMinWidth: Double = 414
    /// Width of the draggable divider between list and detail.
    public static let dividerWidth: Double = 1
    /// Keyboard/VoiceOver resize step.
    public static let step: Double = 20
    public static let storageKey = "shell.listColumnWidth"

    /// Minimum width of everything right of the sidebar, in EVERY workspace.
    /// One value for all workspaces means the split view limits the sidebar
    /// the same way on Today, Calendar and the Library, so its width never
    /// has to change on a workspace switch (at 940pt it can reach 244pt).
    public static var paneMinWidth: Double { minWidth + dividerWidth + detailMinWidth }

    /// The list width actually laid out: the user's stored width clamped to
    /// [min, max], then shrunk so the detail keeps `detailMinWidth`. It never
    /// goes below `minWidth`, even if the window is narrower than both.
    public static func width(stored: Double, available: Double) -> Double {
        let preferred = clampStored(stored)
        let room = available - dividerWidth - detailMinWidth
        return max(minWidth, min(preferred, room))
    }

    /// The value to persist after a drag or an adjust action.
    public static func clampStored(_ width: Double) -> Double {
        guard width.isFinite else { return idealWidth }
        return min(max(width, minWidth), maxWidth)
    }

    /// Width while dragging the divider: follows the pointer but stops where
    /// the layout stops (detail minimum), so dragging back has no dead zone.
    public static func dragged(from origin: Double, by translation: Double, available: Double) -> Double {
        let room = available - dividerWidth - detailMinWidth
        return max(minWidth, min(clampStored(origin + translation), room))
    }
}

// MARK: - Collection header subtitle

public enum ShellHeaderText {
    /// Secondary line under the list title. When the notebook scope pill is
    /// on screen it already names the notebook (and sits beside this line,
    /// leaving ~110pt in the 280pt list), so the subtitle doesn't repeat
    /// it: the long name used to be middle-truncated into "Search r…ng Name".
    public static func subtitle(isSearching: Bool, filterCount: Int, notebookName: String?,
                                scopePillVisible: Bool) -> String {
        var parts: [String] = []
        if isSearching { parts.append("Search results") }
        if filterCount > 0 { parts.append("\(filterCount) \(filterCount == 1 ? "filter" : "filters")") }
        let joined = parts.joined(separator: " · ")
        guard let notebookName else {
            return parts.isEmpty ? "Across all notebooks" : joined + " across all notebooks"
        }
        if scopePillVisible { return parts.isEmpty ? "In one notebook" : joined }
        return parts.isEmpty ? "Only entries in \(notebookName)" : joined + " in \(notebookName)"
    }
}
