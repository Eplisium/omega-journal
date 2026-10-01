import Foundation

// MARK: - Nested tags (`work/projects/alpha`)

public enum TagPath {
    public static let separator: Character = "/"

    /// Trims, drops a leading `#`, commas (the legacy text-column separator) and empty path segments.
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.replacingOccurrences(of: ",", with: "")
        let parts = s.split(separator: separator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: String(separator))
    }

    public static func components(_ tag: String) -> [String] {
        tag.split(separator: separator, omittingEmptySubsequences: true).map(String.init)
    }

    public static func parent(of tag: String) -> String? {
        let c = components(tag)
        return c.count > 1 ? c.dropLast().joined(separator: String(separator)) : nil
    }

    public static func leaf(of tag: String) -> String { components(tag).last ?? tag }

    public static func depth(of tag: String) -> Int { max(0, components(tag).count - 1) }

    /// `a/b/c` → `["a", "a/b"]`.
    public static func ancestors(of tag: String) -> [String] {
        let c = components(tag)
        guard c.count > 1 else { return [] }
        return (1..<c.count).map { c[0..<$0].joined(separator: String(separator)) }
    }

    /// True when `tag` equals `ancestor` or sits underneath it (case-insensitive).
    public static func isSameOrDescendant(_ tag: String, of ancestor: String) -> Bool {
        let t = tag.lowercased(), a = ancestor.lowercased()
        return t == a || t.hasPrefix(a + String(separator))
    }

    /// Autocomplete for tag entry. Matches the whole path by prefix first (`wor` → `work/alpha`), then any
    /// path segment by prefix (`alp` → `work/alpha`). Already-chosen tags are excluded; case-insensitive.
    public static func suggestions(prefix: String, from tags: [String], excluding: [String], limit: Int = 6) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "").lowercased()
        guard !p.isEmpty else { return [] }
        let taken = Set(excluding.map { $0.lowercased() })
        var seen = Set<String>()
        var head: [String] = [], segment: [String] = []
        for t in tags {
            let l = t.lowercased()
            guard !taken.contains(l), seen.insert(l).inserted else { continue }
            if l.hasPrefix(p) { head.append(t) }
            else if l.split(separator: separator).contains(where: { $0.hasPrefix(p) }) { segment.append(t) }
        }
        return Array((head + segment).prefix(limit))
    }

    /// Re-roots `tag` when `old` is renamed to `new`. Nil when `tag` is not `old` or one of its children.
    public static func renamed(_ tag: String, from old: String, to new: String) -> String? {
        if tag == old { return new }
        let prefix = old + String(separator)
        guard tag.hasPrefix(prefix) else { return nil }
        return new + String(separator) + tag.dropFirst(prefix.count)
    }
}

public struct TagNode: Identifiable, Equatable, Sendable {
    /// Full path, e.g. `work/alpha`.
    public let path: String
    /// Entries carrying exactly this tag.
    public var ownCount: Int
    /// Distinct entries carrying this tag or any descendant.
    public var totalCount: Int
    public var children: [TagNode]
    public var id: String { path }
    public var name: String { TagPath.leaf(of: path) }
    public var depth: Int { TagPath.depth(of: path) }
}

public enum TagTree {
    /// Builds a tree from per-entry tag lists. `totalCount` counts DISTINCT entries so an entry tagged both
    /// `a` and `a/b` counts once under `a`. Siblings are ordered by total count, then name.
    public static func build(entryTags: [[String]]) -> [TagNode] {
        var own: [String: Int] = [:]
        var entriesUnder: [String: Set<Int>] = [:]
        for (i, tags) in entryTags.enumerated() {
            for tag in Set(tags) {
                own[tag, default: 0] += 1
                entriesUnder[tag, default: []].insert(i)
                for a in TagPath.ancestors(of: tag) { entriesUnder[a, default: []].insert(i) }
            }
        }
        func children(of parent: String?) -> [TagNode] {
            let paths = entriesUnder.keys.filter { TagPath.parent(of: $0) == parent }
            return paths.map { p in
                TagNode(path: p, ownCount: own[p] ?? 0, totalCount: entriesUnder[p]?.count ?? 0, children: children(of: p))
            }
            .sorted { $0.totalCount != $1.totalCount ? $0.totalCount > $1.totalCount : $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        }
        return children(of: nil)
    }

    /// Depth-first flattening honoring collapsed parents.
    public static func flatten(_ nodes: [TagNode], collapsed: Set<String> = []) -> [TagNode] {
        var out: [TagNode] = []
        func walk(_ ns: [TagNode]) {
            for n in ns {
                out.append(n)
                if !collapsed.contains(n.path) { walk(n.children) }
            }
        }
        walk(nodes)
        return out
    }
}

// MARK: - Tag colors

public enum TagColors {
    /// Curated palette (hex) offered by the tag manager.
    public static let palette: [String] = [
        "#8B5CF6", "#EC4899", "#EF4444", "#F59E0B", "#10B981", "#06B6D4", "#3B82F6", "#94A3B8",
    ]

    /// Accepts `#RRGGBB` / `RRGGBB`; returns canonical upper-case `#RRGGBB`, or nil if invalid.
    public static func normalizedHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + s
    }

    public static func rgb(hex: String) -> (r: Double, g: Double, b: Double)? {
        guard let h = normalizedHex(hex), let v = UInt32(h.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}
