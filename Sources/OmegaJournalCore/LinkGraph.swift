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
            return mentionRange(of: target, in: e.body) != nil
        }
    }

    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`[^`\n]*`"#)
    private static let wikiTokenRegex = try! NSRegularExpression(pattern: #"\[\[[^\]\n]*\]\]"#)

    /// UTF-16 range of the first plain-text mention of `title` in `body`: whole words only,
    /// case/diacritic-insensitive, never inside fenced code, inline code or an existing `[[link]]`.
    public static func mentionRange(of title: String, in body: String) -> NSRange? {
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !body.isEmpty else { return nil }
        // Blank out excluded spans with same-length padding so offsets map 1:1 back to `body`.
        let masked = NSMutableString(string: body)
        let full = NSRange(location: 0, length: masked.length)
        func blank(_ r: NSRange) {
            guard r.length > 0 else { return }
            masked.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        MarkdownLogic.codeBlockRanges(in: body).forEach(blank)
        inlineCodeRegex.matches(in: masked as String, range: full).forEach { blank($0.range) }
        wikiTokenRegex.matches(in: masked as String, range: full).forEach { blank($0.range) }

        func isWordChar(at i: Int) -> Bool {
            guard i >= 0, i < masked.length else { return false }
            let r = masked.rangeOfComposedCharacterSequence(at: i)
            return masked.substring(with: r).unicodeScalars.contains {
                CharacterSet.alphanumerics.contains($0) || $0 == "_"
            }
        }
        var search = full
        while search.length > 0 {
            let r = masked.range(of: target, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            guard r.location != NSNotFound, r.length > 0 else { return nil }
            if !isWordChar(at: r.location - 1) && !isWordChar(at: NSMaxRange(r)) { return r }
            let next = r.location + 1
            search = NSRange(location: next, length: full.length - next)
        }
        return nil
    }

    /// `body` with the first plain mention of `title` turned into a wiki link, or nil when none.
    /// A mention spelled differently from the title (case/accents) becomes `[[Title|as written]]`
    /// so the link resolves while the prose reads the same.
    public static func linkingFirstMention(of title: String, in body: String) -> String? {
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.contains(where: { "[]|\n".contains($0) }),
              let r = mentionRange(of: target, in: body) else { return nil }
        let ns = body as NSString
        let matched = ns.substring(with: r)
        let link = matched == target ? "[[\(target)]]" : "[[\(target)|\(matched)]]"
        return ns.replacingCharacters(in: r, with: link)
    }
}

extension WikiLinks {
    /// Test/consumer-visible wrapper around the internal code stripper.
    public static func stripCodePublic(_ text: String) -> String { stripCode(text) }
}

// MARK: - Force-directed layout (deterministic)
//
// Positions and velocities live in contiguous arrays indexed like `ids` (the
// old version rebuilt a dictionary and force-unwrapped lookups every frame).
// Repulsion is exact (O(n²)) for small graphs and Barnes–Hut (O(n log n)) above
// `exactRepulsionLimit`, so a 2,000-note graph still steps within a frame.

public struct GraphLayout: Sendable {
    /// Graphs up to this many nodes use exact pairwise repulsion.
    public static let exactRepulsionLimit = 300
    /// Barnes–Hut opening angle: larger is faster and coarser.
    public static let theta = 0.9

    public private(set) var xs: [Double]
    public private(set) var ys: [Double]
    private var vxs: [Double]
    private var vys: [Double]
    public let ids: [String]
    private let index: [String: Int]
    private let edges: [(Int, Int)]
    public var width: Double
    public var height: Double
    /// Force evaluations in the last `step` (node–node or node–cell); a
    /// deterministic stand-in for its cost.
    public private(set) var lastStepInteractions = 0

    /// Positions keyed by node id (built on demand — prefer `position(of:)`).
    public var positions: [String: GraphPoint] {
        var out: [String: GraphPoint] = [:]
        out.reserveCapacity(ids.count)
        for i in ids.indices { out[ids[i]] = GraphPoint(x: xs[i], y: ys[i]) }
        return out
    }

    public var nodeCount: Int { ids.count }

    public func position(of id: String) -> GraphPoint? {
        guard let i = index[id] else { return nil }
        return GraphPoint(x: xs[i], y: ys[i])
    }

    /// Nodes start on a circle (deterministic: no randomness, so layouts and tests are reproducible).
    public init(graph: LinkGraph, width: Double = 800, height: Double = 600) {
        self.init(nodeIDs: graph.nodes.map(\.id), links: graph.edges.map { ($0.from, $0.to) },
                  width: width, height: height)
    }

    public init(nodeIDs: [String], links: [(String, String)], width: Double = 800, height: Double = 600) {
        self.width = width; self.height = height
        ids = nodeIDs
        var index: [String: Int] = [:]
        index.reserveCapacity(nodeIDs.count)
        for (i, id) in nodeIDs.enumerated() where index[id] == nil { index[id] = i }
        self.index = index
        edges = links.compactMap { from, to in
            guard let a = index[from], let b = index[to], a != b else { return nil }
            return (a, b)
        }
        let n = max(1, nodeIDs.count)
        let radius = min(width, height) * 0.35
        xs = nodeIDs.indices.map { width / 2 + radius * cos(2 * Double.pi * Double($0) / Double(n)) }
        ys = nodeIDs.indices.map { height / 2 + radius * sin(2 * Double.pi * Double($0) / Double(n)) }
        vxs = Array(repeating: 0, count: nodeIDs.count)
        vys = Array(repeating: 0, count: nodeIDs.count)
    }

    /// Kinetic energy per node below which the layout counts as settled.
    public static let settledEnergyPerNode = 0.02

    public func isSettled(energy: Double) -> Bool {
        energy < Self.settledEnergyPerNode * Double(max(1, ids.count))
    }

    /// One simulation step. `alpha` (0…1) cools the system. Returns the total kinetic energy so callers can stop when settled.
    @discardableResult
    public mutating func step(alpha: Double = 1) -> Double {
        let n = ids.count
        guard n > 0 else { lastStepInteractions = 0; return 0 }
        var fx = [Double](repeating: 0, count: n), fy = [Double](repeating: 0, count: n)
        let k = sqrt((width * height) / Double(n)) * 0.6   // ideal edge length
        let k2 = k * k
        var interactions = 0
        if n <= Self.exactRepulsionLimit {
            for i in 0..<n {
                for j in (i + 1)..<max(i + 1, n) {
                    var dx = xs[i] - xs[j], dy = ys[i] - ys[j]
                    var d2 = dx * dx + dy * dy
                    if d2 < 0.01 { dx = Double(i - j) * 0.1 + 0.1; dy = 0.1; d2 = dx * dx + dy * dy }
                    let d = sqrt(d2)
                    let rep = k2 / d
                    fx[i] += dx / d * rep; fy[i] += dy / d * rep
                    fx[j] -= dx / d * rep; fy[j] -= dy / d * rep
                    interactions += 1
                }
            }
        } else {
            let tree = QuadTree(xs: xs, ys: ys)
            for i in 0..<n {
                let (rx, ry, count) = tree.repulsion(on: i, x: xs[i], y: ys[i], k2: k2, theta: Self.theta)
                fx[i] += rx; fy[i] += ry
                interactions += count
            }
        }
        for (a, b) in edges {
            let dx = xs[b] - xs[a], dy = ys[b] - ys[a]
            let d = max(0.01, sqrt(dx * dx + dy * dy))
            let att = (d * d) / k * 0.2
            fx[a] += dx / d * att; fy[a] += dy / d * att
            fx[b] -= dx / d * att; fy[b] -= dy / d * att
        }
        var energy = 0.0
        let cx = width / 2, cy = height / 2
        let cap = 40.0
        for i in 0..<n {
            fx[i] += (cx - xs[i]) * 0.05; fy[i] += (cy - ys[i]) * 0.05   // gravity
            var vx = (vxs[i] + fx[i] * 0.02 * alpha) * 0.82
            var vy = (vys[i] + fy[i] * 0.02 * alpha) * 0.82
            let speed = sqrt(vx * vx + vy * vy)
            if speed > cap { vx *= cap / speed; vy *= cap / speed }
            let nx = xs[i] + vx, ny = ys[i] + vy
            xs[i] = min(width - 20, max(20, nx))
            ys[i] = min(height - 20, max(20, ny))
            // The canvas edge absorbs motion: a node pinned against it would
            // otherwise keep its velocity and never let the layout settle.
            if xs[i] != nx { vx = 0 }
            if ys[i] != ny { vy = 0 }
            vxs[i] = vx; vys[i] = vy
            energy += vx * vx + vy * vy
        }
        lastStepInteractions = interactions
        return energy
    }

    public mutating func settle(iterations: Int = 200) {
        for i in 0..<iterations {
            let alpha = max(0.05, 1 - Double(i) / Double(iterations))
            if step(alpha: alpha) < 0.01 * Double(max(1, ids.count)) { break }
        }
    }

    public mutating func move(_ id: String, to p: GraphPoint) {
        guard let i = index[id] else { return }
        xs[i] = p.x; ys[i] = p.y
        vxs[i] = 0; vys[i] = 0
    }
}

// MARK: - Barnes–Hut quadtree (array-backed)

private struct QuadTree {
    private struct Cell {
        var minX: Double, minY: Double, size: Double
        var mass = 0.0, comX = 0.0, comY = 0.0
        var body = -1          // leaf with exactly one body
        var child = -1         // index of first of 4 children, or -1
    }

    private var cells: [Cell] = []
    private let xs: [Double]
    private let ys: [Double]

    init(xs: [Double], ys: [Double]) {
        self.xs = xs; self.ys = ys
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for i in xs.indices {
            minX = min(minX, xs[i]); maxX = max(maxX, xs[i])
            minY = min(minY, ys[i]); maxY = max(maxY, ys[i])
        }
        let size = max(1, max(maxX - minX, maxY - minY)) * 1.0001
        cells.reserveCapacity(xs.count * 2)
        cells.append(Cell(minX: minX, minY: minY, size: size))
        for i in xs.indices { insert(i, into: 0, depth: 0) }
        finalize(0)
    }

    private mutating func insert(_ body: Int, into start: Int, depth: Int) {
        var c = start, depth = depth
        while true {
            if cells[c].child >= 0 {
                c = cells[c].child + quadrant(of: body, in: c)
                depth += 1
                continue
            }
            if cells[c].body < 0 && cells[c].mass == 0 {
                cells[c].body = body
                cells[c].mass = 1
                return
            }
            // Coincident points (or absurd depth) share a leaf as extra mass.
            if depth > 40 {
                cells[c].mass += 1
                return
            }
            // Split the leaf and push its body down, then retry.
            let existing = cells[c].body
            let half = cells[c].size / 2
            let first = cells.count
            for q in 0..<4 {
                cells.append(Cell(minX: cells[c].minX + (q & 1 == 0 ? 0 : half),
                                  minY: cells[c].minY + (q & 2 == 0 ? 0 : half), size: half))
            }
            cells[c].child = first
            cells[c].body = -1
            let extra = cells[c].mass - 1
            cells[c].mass = 0
            if existing >= 0 {
                let target = first + quadrant(of: existing, in: c)
                cells[target].body = existing
                cells[target].mass = 1 + extra
            }
        }
    }

    private func quadrant(of body: Int, in c: Int) -> Int {
        let half = cells[c].size / 2
        let right = xs[body] >= cells[c].minX + half ? 1 : 0
        let lower = ys[body] >= cells[c].minY + half ? 2 : 0
        return right + lower
    }

    /// Fills mass and centre of mass bottom-up.
    private mutating func finalize(_ c: Int) {
        if cells[c].child < 0 {
            if cells[c].body >= 0 {
                cells[c].comX = xs[cells[c].body]; cells[c].comY = ys[cells[c].body]
            }
            return
        }
        var mass = 0.0, sx = 0.0, sy = 0.0
        for q in 0..<4 {
            let ch = cells[c].child + q
            finalize(ch)
            mass += cells[ch].mass
            sx += cells[ch].comX * cells[ch].mass
            sy += cells[ch].comY * cells[ch].mass
        }
        cells[c].mass = mass
        if mass > 0 { cells[c].comX = sx / mass; cells[c].comY = sy / mass }
    }

    /// Approximate repulsion on `body` and the number of force evaluations.
    func repulsion(on body: Int, x: Double, y: Double, k2: Double, theta: Double) -> (Double, Double, Int) {
        var fx = 0.0, fy = 0.0, count = 0
        var stack = [0]
        stack.reserveCapacity(64)
        while let c = stack.popLast() {
            let cell = cells[c]
            if cell.mass == 0 { continue }
            if cell.child < 0 && cell.body == body {
                // Coincident extra mass sharing this leaf still pushes.
                let extra = cell.mass - 1
                if extra > 0 { fx += 0.1 * k2 * extra; fy += 0.1 * k2 * extra; count += 1 }
                continue
            }
            var dx = x - cell.comX, dy = y - cell.comY
            var d2 = dx * dx + dy * dy
            if cell.child < 0 || cell.size * cell.size < theta * theta * d2 {
                if d2 < 0.01 { dx = 0.1 + Double(body % 7) * 0.05; dy = 0.1; d2 = dx * dx + dy * dy }
                let d = sqrt(d2)
                let rep = k2 * cell.mass / d
                fx += dx / d * rep; fy += dy / d * rep
                count += 1
            } else {
                for q in 0..<4 { stack.append(cell.child + q) }
            }
        }
        return (fx, fy, count)
    }
}
