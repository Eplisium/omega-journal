import Foundation

// MARK: - Link graph (pure)

public struct GraphPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct LinkGraph: Equatable, Sendable {
    public struct Node: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        /// Number of distinct neighbours (in + out).
        public var degree: Int
    }
    public struct Edge: Equatable, Hashable, Sendable {
        public let from: String
        public let to: String
    }

    public var nodes: [Node]
    public var edges: [Edge]

    /// Builds the wiki-link graph. Hidden entries are excluded entirely (as nodes AND as link targets/sources)
    /// unless `includeHidden`; callers pass `includeHidden: true` only while the biometric session is unlocked.
    /// Self-links and duplicate links collapse. Titles resolve case-insensitively; on a title collision the
    /// first entry in `entries` wins. Isolated notes are included only when `includeIsolated`.
    public static func build(entries: [LinkableEntry], includeHidden: Bool = false, includeIsolated: Bool = false) -> LinkGraph {
        let pool = entries.filter { includeHidden || !$0.isHidden }
        var byTitle: [String: String] = [:]
        for e in pool {
            let k = e.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !k.isEmpty, byTitle[k] == nil { byTitle[k] = e.id }
        }
        var edgeSet = Set<Edge>()
        var edges: [Edge] = []
        var neighbours: [String: Set<String>] = [:]
        for e in pool {
            for title in WikiLinks.linkTitles(in: e.body) {
                guard let target = byTitle[title.lowercased()], target != e.id else { continue }
                let edge = Edge(from: e.id, to: target)
                if edgeSet.insert(edge).inserted { edges.append(edge) }
                neighbours[e.id, default: []].insert(target)
                neighbours[target, default: []].insert(e.id)
            }
        }
        let nodes = pool.compactMap { e -> Node? in
            let d = neighbours[e.id]?.count ?? 0
            guard includeIsolated || d > 0 else { return nil }
            return Node(id: e.id, title: e.title.isEmpty ? "Untitled" : e.title, degree: d)
        }
        return LinkGraph(nodes: nodes, edges: edges)
    }

    /// Ids directly connected to `id`.
    public func neighbours(of id: String) -> Set<String> {
        var out = Set<String>()
        for e in edges {
            if e.from == id { out.insert(e.to) } else if e.to == id { out.insert(e.from) }
        }
        return out
    }
}

// MARK: - Unlinked mentions

public enum UnlinkedMentions {
    /// Entries whose body mentions `title` as plain text but does NOT already `[[link]]` to it.
    /// Hidden entries are skipped unless `includeHidden`. Titles shorter than 3 characters are ignored (too noisy).
    public static func find(forTitle title: String, in entries: [LinkableEntry], excludingId: String? = nil,
                            includeHidden: Bool = false) -> [LinkableEntry] {
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.count >= 3 else { return [] }
        let linked = Set(WikiLinks.backlinks(toTitle: target, in: entries, excludingId: excludingId, includeHidden: includeHidden).map(\.id))
        return entries.filter { e in
            if e.id == excludingId || linked.contains(e.id) { return false }
            if e.isHidden && !includeHidden { return false }
            let stripped = WikiLinks.stripCodePublic(e.body)
            // Remove existing [[...]] tokens so a link to a *longer* title doesn't count as a mention.
            let noLinks = stripped.replacingOccurrences(of: "\\[\\[[^\\]\\n]*\\]\\]", with: " ", options: .regularExpression)
            return noLinks.range(of: target, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

extension WikiLinks {
    /// Test/consumer-visible wrapper around the internal code stripper.
    public static func stripCodePublic(_ text: String) -> String { stripCode(text) }
}

// MARK: - Force-directed layout (deterministic)

public struct GraphLayout: Sendable {
    public private(set) var positions: [String: GraphPoint] = [:]
    private var velocities: [String: GraphPoint] = [:]
    private let ids: [String]
    private let edges: [(Int, Int)]
    public var width: Double
    public var height: Double

    /// Nodes start on a circle (deterministic: no randomness, so layouts and tests are reproducible).
    public init(graph: LinkGraph, width: Double = 800, height: Double = 600) {
        self.width = width; self.height = height
        ids = graph.nodes.map(\.id)
        var index: [String: Int] = [:]
        for (i, id) in ids.enumerated() { index[id] = i }
        edges = graph.edges.compactMap { e in
            guard let a = index[e.from], let b = index[e.to] else { return nil }
            return (a, b)
        }
        let n = max(1, ids.count)
        let radius = min(width, height) * 0.35
        for (i, id) in ids.enumerated() {
            let angle = 2 * Double.pi * Double(i) / Double(n)
            positions[id] = GraphPoint(x: width / 2 + radius * cos(angle), y: height / 2 + radius * sin(angle))
            velocities[id] = GraphPoint(x: 0, y: 0)
        }
    }

    /// One simulation step. `alpha` (0…1) cools the system. Returns the total kinetic energy so callers can stop when settled.
    @discardableResult
    public mutating func step(alpha: Double = 1) -> Double {
        let n = ids.count
        guard n > 0 else { return 0 }
        var fx = [Double](repeating: 0, count: n), fy = [Double](repeating: 0, count: n)
        let k = sqrt((width * height) / Double(n)) * 0.6   // ideal edge length
        let pts = ids.map { positions[$0]! }
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                var dx = pts[i].x - pts[j].x, dy = pts[i].y - pts[j].y
                var d2 = dx * dx + dy * dy
                if d2 < 0.01 { dx = Double(i - j) * 0.1 + 0.1; dy = 0.1; d2 = dx * dx + dy * dy }
                let d = sqrt(d2)
                let rep = (k * k) / d
                fx[i] += dx / d * rep; fy[i] += dy / d * rep
                fx[j] -= dx / d * rep; fy[j] -= dy / d * rep
            }
        }
        for (a, b) in edges {
            let dx = pts[b].x - pts[a].x, dy = pts[b].y - pts[a].y
            let d = max(0.01, sqrt(dx * dx + dy * dy))
            let att = (d * d) / k * 0.2
            fx[a] += dx / d * att; fy[a] += dy / d * att
            fx[b] -= dx / d * att; fy[b] -= dy / d * att
        }
        var energy = 0.0
        let cx = width / 2, cy = height / 2
        for i in 0..<n {
            fx[i] += (cx - pts[i].x) * 0.05; fy[i] += (cy - pts[i].y) * 0.05   // gravity
            var v = velocities[ids[i]]!
            v.x = (v.x + fx[i] * 0.02 * alpha) * 0.82
            v.y = (v.y + fy[i] * 0.02 * alpha) * 0.82
            let speed = sqrt(v.x * v.x + v.y * v.y)
            let cap = 40.0
            if speed > cap { v.x *= cap / speed; v.y *= cap / speed }
            velocities[ids[i]] = v
            var p = pts[i]
            p.x = min(width - 20, max(20, p.x + v.x)); p.y = min(height - 20, max(20, p.y + v.y))
            positions[ids[i]] = p
            energy += v.x * v.x + v.y * v.y
        }
        return energy
    }

    public mutating func settle(iterations: Int = 200) {
        for i in 0..<iterations {
            let alpha = max(0.05, 1 - Double(i) / Double(iterations))
            if step(alpha: alpha) < 0.01 * Double(max(1, ids.count)) { break }
        }
    }

    public mutating func move(_ id: String, to p: GraphPoint) {
        guard positions[id] != nil else { return }
        positions[id] = p
        velocities[id] = GraphPoint(x: 0, y: 0)
    }
}
