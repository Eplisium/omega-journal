import Foundation

// Pure shell/list-header logic for the Journal workspace: sidebar keyboard
// order, which tag chips a picker shows, the collection header's scope line,
// and no-results recovery. No SwiftUI, no DB — unit-testable in isolation.

// MARK: - Sidebar keyboard order

public enum ShellSidebarKeyboard {
    /// One sidebar section in on-screen order. Rows inside a collapsed
    /// section are not on screen, so ↑/↓ must skip them.
    public struct Group<Item: Equatable> {
        public var items: [Item]
        public var isExpanded: Bool
        public init(_ items: [Item], isExpanded: Bool = true) {
            self.items = items
            self.isExpanded = isExpanded
        }
    }

    /// Items reachable with ↑/↓, in on-screen order. Collapsed sections are
    /// skipped, except the current selection keeps its slot so stepping from
    /// it moves to its visible neighbour instead of jumping to the top.
    public static func order<Item: Equatable>(_ groups: [Group<Item>], current: Item?) -> [Item] {
        var out: [Item] = []
        for group in groups {
            if group.isExpanded {
                for item in group.items where !out.contains(item) { out.append(item) }
            } else if let current, group.items.contains(current), !out.contains(current) {
                out.append(current)
            }
        }
        return out
    }

    /// Next/previous destination; clamps at the ends. With nothing (or an
    /// unlisted item) selected, ↓ lands on the first row and ↑ on the last.
    public static func step<Item: Equatable>(_ delta: Int, from current: Item?, in order: [Item]) -> Item? {
        guard !order.isEmpty else { return nil }
        guard let current, let i = order.firstIndex(of: current) else {
            return delta >= 0 ? order.first : order.last
        }
        return order[min(max(i + delta, 0), order.count - 1)]
    }
}

// MARK: - Tag chip choices

public enum ShellTagChoices {
    /// The first `limit` tags of `ordered` (most-used first), followed by any
    /// selected tag that did not make the cut. A selected tag must always be
    /// visible, otherwise it can narrow a list or smart folder with no way to
    /// see or deselect it from the picker.
    public static func visible(_ ordered: [String], selected: Set<String>, limit: Int) -> [String] {
        var shown = Array(ordered.prefix(max(0, limit)))
        var seen = Set(shown)
        let extras = ordered.dropFirst(max(0, limit)).filter { selected.contains($0) }
            + selected.subtracting(ordered).sorted()
        for tag in extras where seen.insert(tag).inserted { shown.append(tag) }
        return shown
    }
}

// MARK: - Collection header

public enum ShellCollectionHeader {
    /// Secondary line under the collection title. The title is always the
    /// sidebar destination; this line states what narrows it (search,
    /// filters) and which notebook it is scoped to, so destination and scope
    /// are never confused.
    public static func subtitle(isSearching: Bool, filterCount: Int, notebookName: String?) -> String {
        var parts: [String] = []
        if isSearching { parts.append("Search results") }
        if filterCount > 0 { parts.append("\(filterCount) \(filterCount == 1 ? "filter" : "filters")") }
        let scope = notebookName.map { "in \($0)" } ?? "across all notebooks"
        if parts.isEmpty {
            return notebookName.map { "Only entries in \($0)" } ?? "Across all notebooks"
        }
        return parts.joined(separator: " · ") + " " + scope
    }
}

// MARK: - Active constraints

public enum ShellListConstraints {
    /// Accessibility/visible label for the single "Clear all" control, which
    /// clears the search together with the filters when both narrow the list.
    public static func clearAllLabel(hasSearch: Bool, filterCount: Int) -> String {
        switch (hasSearch, filterCount > 0) {
        case (true, true): "Clear search and filters"
        case (true, false): "Clear search"
        default: "Clear all filters"
        }
    }
}

// MARK: - No-results recovery

public enum ShellListRecovery {
    public enum Action: String, Equatable, CaseIterable, Sendable {
        /// Clears search text and every filter.
        case clearAll
        case clearSearch
        case clearFilters
        /// Re-runs the search in All Entries (from a narrower collection).
        case searchAllEntries
        /// Drops the notebook scope.
        case showAllNotebooks

        public var title: String {
            switch self {
            case .clearAll: "Clear search and filters"
            case .clearSearch: "Clear search"
            case .clearFilters: "Clear filters"
            case .searchAllEntries: "Search all entries"
            case .showAllNotebooks: "Show all notebooks"
            }
        }
    }

    public struct EmptyState: Equatable, Sendable {
        public let title: String
        public let subtitle: String
        /// First action is the primary one.
        public let actions: [Action]
    }

    /// Recovery copy and actions for an empty list caused by search and/or
    /// filters. Returns nil when nothing narrows the list, so the caller shows
    /// its collection-specific empty state.
    ///
    /// - Parameters:
    ///   - isLibraryRoot: the destination is All Entries (searching "all
    ///     entries" from there would be a no-op).
    ///   - canWidenToLibrary: the destination draws from the library
    ///     (favorites, tags, moods, smart folders…), so its search can be
    ///     re-run in All Entries. Archive/Hidden/Trash search their own store.
    public static func emptyState(query: String, filterCount: Int, isLibraryRoot: Bool,
                                  canWidenToLibrary: Bool, notebookName: String?) -> EmptyState? {
        let q = query.trimmingCharacters(in: .whitespaces)
        let hasSearch = !q.isEmpty
        let hasFilters = filterCount > 0
        guard hasSearch || hasFilters else { return nil }

        var actions: [Action] = []
        let title: String
        var subtitle: String
        let filtersText = "\(filterCount) \(filterCount == 1 ? "filter" : "filters")"
        if hasSearch && hasFilters {
            title = "No matches"
            subtitle = "Nothing matches “\(q)” with \(filtersText) on."
            actions = [.clearAll, .clearFilters]
        } else if hasSearch {
            title = "No matches"
            subtitle = "Nothing matches “\(q)”."
            actions = [.clearSearch]
        } else {
            title = "No entries match your filters"
            subtitle = "Loosen or clear the \(filtersText) to see more."
            actions = [.clearFilters]
        }
        if hasSearch && canWidenToLibrary && !isLibraryRoot { actions.append(.searchAllEntries) }
        if let notebookName {
            subtitle += " Showing only \(notebookName)."
            actions.append(.showAllNotebooks)
        }
        return EmptyState(title: title, subtitle: subtitle, actions: actions)
    }
}

// MARK: - Persisted sidebar preferences owned by the shell track

public enum ShellSidebarPrefs {
    /// Whether the Tags section lists every tag instead of the short list.
    public static let showAllTagsKey = "shell.sidebar.showAllTags"
}
