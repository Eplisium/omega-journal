import Foundation

// MARK: - Journals / notebooks (pure helpers)

public enum JournalDefaults {
    /// Stable id of the journal every pre-V11 entry is migrated into.
    public static let defaultJournalId = "default"
    public static let defaultJournalName = "Journal"
    public static let palette = TagColors.palette
    public static let maxNameLength = 40

    public static func normalizedName(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return String(s.prefix(maxNameLength))
    }
}

// MARK: - Reader outline (table of contents)

public struct OutlineHeading: Equatable, Identifiable, Sendable {
    public let level: Int
    public let title: String
    /// Zero-based line index in the body.
    public let line: Int
    public var id: Int { line }
}

public enum MarkdownOutline {
    /// ATX headings (`# …`), skipping fenced code. A TOC is only worthwhile for long entries.
    public static func headings(in body: String) -> [OutlineHeading] {
        var out: [OutlineHeading] = []
        var inFence = false
        for (i, rawLine) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.drop(while: { $0 == " " })
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { continue }
            let title = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            out.append(OutlineHeading(level: hashes, title: title, line: i))
        }
        return out
    }

    /// Show a table of contents for long entries with at least `minHeadings` headings.
    public static func shouldShow(headings: [OutlineHeading], wordCount: Int, minHeadings: Int = 3, minWords: Int = 400) -> Bool {
        headings.count >= minHeadings && wordCount >= minWords
    }
}

// MARK: - First run / What's new

public enum ReleaseNotes {
    /// Dotted-version compare: -1, 0, 1.
    public static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// First-time users get the tour, not "What's new". Returning users see it once per newer version.
    public static func shouldShowWhatsNew(lastSeenVersion: String?, current: String, hasCompletedOnboarding: Bool) -> Bool {
        guard hasCompletedOnboarding else { return false }
        guard let last = lastSeenVersion, !last.isEmpty else { return true }
        return compare(last, current) < 0
    }
}

// MARK: - Spotlight policy

public enum SpotlightPolicy {
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let title: String
        public let isHidden: Bool
        public let isTrashed: Bool
        public init(id: String, title: String, isHidden: Bool, isTrashed: Bool) {
            self.id = id; self.title = title; self.isHidden = isHidden; self.isTrashed = isTrashed
        }
    }

    /// Only titles of non-hidden, non-trashed, titled entries are ever handed to Spotlight. Bodies never are.
    public static func indexable(_ candidates: [Candidate]) -> [Candidate] {
        candidates.filter { !$0.isHidden && !$0.isTrashed && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
