import Foundation

// MARK: - Sort Order

enum SortOrder: String, CaseIterable, Identifiable {
    case dateDesc = "Newest First"
    case dateAsc = "Oldest First"
    case titleAsc = "Title A→Z"
    case titleDesc = "Title Z→A"
    var id: String { rawValue }
}
