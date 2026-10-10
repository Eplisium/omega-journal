import Foundation

// MARK: - Active filter chips

/// One removable chip describing an active facet of `EntryFilter`, shown under
/// the search field so the user always sees what is narrowing the list and
/// can clear any single constraint with one click.
struct EntryFilterChip: Identifiable, Equatable {
    enum Facet: Hashable {
        case mood(Mood)
        case tag(String)
        case dateRange
        case favorites
        case pinned
        case attachments
        case minWords
    }

    let facet: Facet
    let label: String
    var id: Facet { facet }
}

extension EntryFilter {
    /// Chips in a stable order: date, toggles, moods, tags, length.
    var chips: [EntryFilterChip] {
        var out: [EntryFilterChip] = []
        if dateRange != .any { out.append(.init(facet: .dateRange, label: dateRange.rawValue)) }
        if favoritesOnly { out.append(.init(facet: .favorites, label: "Favorites")) }
        if pinnedOnly { out.append(.init(facet: .pinned, label: "Pinned")) }
        if withAttachmentsOnly { out.append(.init(facet: .attachments, label: "Has files")) }
        for mood in Mood.allCases where moods.contains(mood) {
            out.append(.init(facet: .mood(mood), label: "\(mood.emoji) \(mood.label)"))
        }
        for tag in tags.sorted() { out.append(.init(facet: .tag(tag), label: "#\(tag)")) }
        if minWords > 0 { out.append(.init(facet: .minWords, label: "\(minWords)+ words")) }
        return out
    }

    /// The same filter with one facet cleared.
    func removing(_ facet: EntryFilterChip.Facet) -> EntryFilter {
        var f = self
        switch facet {
        case .mood(let m): f.moods.remove(m)
        case .tag(let t): f.tags.remove(t)
        case .dateRange: f.dateRange = .any
        case .favorites: f.favoritesOnly = false
        case .pinned: f.pinnedOnly = false
        case .attachments: f.withAttachmentsOnly = false
        case .minWords: f.minWords = 0
        }
        return f
    }
}
