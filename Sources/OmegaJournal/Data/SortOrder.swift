import Foundation

// MARK: - Sort Order

enum SortOrder: String, CaseIterable, Identifiable {
    case dateDesc = "Newest first"
    case dateAsc = "Oldest first"
    case updatedDesc = "Recently edited"
    case titleAsc = "Title A–Z"
    case titleDesc = "Title Z–A"
    case wordsDesc = "Longest first"
    case moodDesc = "Happiest first"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dateDesc: "arrow.down.circle"
        case .dateAsc: "arrow.up.circle"
        case .updatedDesc: "clock.arrow.circlepath"
        case .titleAsc: "textformat.abc"
        case .titleDesc: "textformat.abc.dottedunderline"
        case .wordsDesc: "text.alignleft"
        case .moodDesc: "face.smiling"
        }
    }
}
