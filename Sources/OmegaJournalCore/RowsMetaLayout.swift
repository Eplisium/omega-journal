import Foundation

/// Layout candidates for an entry row's meta line (mood · date · words · tag
/// chips), tried widest-first by a `ViewThatFits`.
///
/// In a 280–292pt list column every piece used to be squeezed at once: tag
/// chips wrapped inside words ("gratitu/de") and the date wrapped onto two
/// lines. Each candidate is drawn at its ideal (unwrapped) width, so the row
/// picks the richest arrangement that fits on one line and drops detail in a
/// fixed order instead: extra chips first, then the time of day, then the
/// word count. Hidden chips collapse into one "+N" chip.
public enum RowsMetaLayout {
    public enum DateStyle: Equatable, Sendable {
        /// "Oct 13, 2026 at 8:45 AM"
        case dateAndTime
        /// "Oct 13, 2026"
        case dateOnly
    }

    public struct Candidate: Equatable, Sendable {
        public let dateStyle: DateStyle
        public let showsWordCount: Bool
        /// Tags drawn as chips, in entry order.
        public let visibleTags: [String]
        /// Tags folded into the "+N" chip. Empty means no "+N" chip.
        public let hiddenTags: [String]

        public init(dateStyle: DateStyle, showsWordCount: Bool, visibleTags: [String], hiddenTags: [String]) {
            self.dateStyle = dateStyle
            self.showsWordCount = showsWordCount
            self.visibleTags = visibleTags
            self.hiddenTags = hiddenTags
        }

        public var overflowCount: Int { hiddenTags.count }
    }

    /// Most chips any candidate draws. Wider columns (400pt+) can fit three.
    public static let maxVisibleChips = 3

    /// Ordered candidates, richest first. The last one always contains only
    /// the mood and short date, so something always fits.
    ///
    /// - Parameters:
    ///   - tags: display names (already leaf-shortened) in entry order.
    ///   - canShowContent: false for a locked hidden entry. Then no tags and
    ///     no word count appear in ANY candidate (title/mood/date only).
    ///   - hasWordCount: the entry has a non-zero word count worth showing.
    public static func candidates(tags: [String], canShowContent: Bool, hasWordCount: Bool) -> [Candidate] {
        let tags = canShowContent ? tags : []
        let words = canShowContent && hasWordCount
        var out: [Candidate] = []
        func add(_ style: DateStyle, _ showWords: Bool, visible: Int) {
            let c = Candidate(dateStyle: style, showsWordCount: showWords,
                              visibleTags: Array(tags.prefix(visible)),
                              hiddenTags: Array(tags.dropFirst(visible)))
            if !out.contains(c) { out.append(c) }
        }
        let most = min(tags.count, maxVisibleChips)
        if most > 0 {
            for k in stride(from: most, through: 1, by: -1) { add(.dateAndTime, words, visible: k) }
            for k in stride(from: most, through: 1, by: -1) { add(.dateOnly, words, visible: k) }
            if words { for k in stride(from: most, through: 1, by: -1) { add(.dateOnly, false, visible: k) } }
            // Only the "+N" chip: still says "this entry has tags".
            add(.dateOnly, words, visible: 0)
            if words { add(.dateOnly, false, visible: 0) }
        } else {
            add(.dateAndTime, words, visible: 0)
            add(.dateOnly, words, visible: 0)
            if words { add(.dateOnly, false, visible: 0) }
        }
        // Last resort: mood + short date only (nothing else can be dropped).
        out.append(Candidate(dateStyle: .dateOnly, showsWordCount: false, visibleTags: [], hiddenTags: []))
        if out.count >= 2, out[out.count - 1] == out[out.count - 2] { out.removeLast() }
        return out
    }

    /// Text of the overflow chip, e.g. "+3".
    public static func overflowText(_ hiddenCount: Int) -> String { "+\(hiddenCount)" }

    /// VoiceOver label / tooltip for the "+N" chip. Lists the tags it hides,
    /// but only when content may be shown; a locked hidden entry gets nil (the
    /// chip is never drawn for it, and its tags must not leak).
    public static func overflowAccessibilityLabel(hiddenTags: [String], canShowContent: Bool) -> String? {
        guard canShowContent, !hiddenTags.isEmpty else { return nil }
        let noun = hiddenTags.count == 1 ? "more tag" : "more tags"
        return "\(hiddenTags.count) \(noun): \(hiddenTags.joined(separator: ", "))"
    }
}
