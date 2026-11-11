import Foundation

// MARK: - Place stamp (place name + optional coordinates), pure
//
// Places ride in the entry body's existing trailing stamp comment
// (`<!-- stamp: loc=Paris; wx=Sunny -->`, see `EntryStampCodec`) so they are
// encrypted with the body and need no schema change. This codec adds one
// optional key, `geo=<lat>,<lon>`, that the map reads.
//
// Older builds ignore keys they don't know, so they read these bodies fine.
// `EntryStamp` keeps the raw `geo=` value, so re-saving an entry from the
// editor keeps the coordinates; editing the place name drops them.

public struct PlaceCoordinate: Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !(latitude == 0 && longitude == 0)
    }
}

public struct PlaceStamp: Equatable, Sendable {
    public var location: String
    public var weather: String
    public var coordinate: PlaceCoordinate?

    public init(location: String = "", weather: String = "", coordinate: PlaceCoordinate? = nil) {
        self.location = location; self.weather = weather; self.coordinate = coordinate
    }

    public var isEmpty: Bool { location.isEmpty && weather.isEmpty && coordinate == nil }
}

public enum PlaceStampCodec {
    private static let tailRegex = try! NSRegularExpression(pattern: #"(?:\r?\n\r?\n)?<!--\s*stamp:\s*([^>]*?)\s*-->\s*$"#)
    private static var allowed: CharacterSet {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: " ,.°+_()'/")
        return c
    }

    /// Same split rule as `EntryStampCodec.split`, plus `geo=`.
    public static func split(_ body: String) -> (stamp: PlaceStamp?, rest: String) {
        guard body.contains("<!--") else { return (nil, body) }
        let ns = body as NSString
        guard let m = tailRegex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return (nil, body) }
        var stamp = PlaceStamp()
        for part in ns.substring(with: m.range(at: 1)).components(separatedBy: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("loc=") { stamp.location = String(kv.dropFirst(4)).removingPercentEncoding ?? "" }
            else if kv.hasPrefix("wx=") { stamp.weather = String(kv.dropFirst(3)).removingPercentEncoding ?? "" }
            else if kv.hasPrefix("geo=") { stamp.coordinate = parseCoordinate(String(kv.dropFirst(4))) }
        }
        return (stamp, ns.substring(to: m.range.location))
    }

    static func parseCoordinate(_ s: String) -> PlaceCoordinate? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        let c = PlaceCoordinate(latitude: lat, longitude: lon)
        return c.isValid ? c : nil
    }

    /// 5 decimals ≈ 1 m — plenty for a journal, and stable across round trips.
    static func format(_ c: PlaceCoordinate) -> String {
        String(format: "%.5f,%.5f", locale: Locale(identifier: "en_US_POSIX"), c.latitude, c.longitude)
    }

    /// `rest` with the stamp appended; output stays readable by `EntryStampCodec.split`.
    public static func join(stamp: PlaceStamp?, rest: String) -> String {
        guard let stamp, !stamp.isEmpty else { return rest }
        var parts: [String] = []
        let loc = stamp.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let wx = stamp.weather.trimmingCharacters(in: .whitespacesAndNewlines)
        if !loc.isEmpty { parts.append("loc=" + (loc.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")) }
        if !wx.isEmpty { parts.append("wx=" + (wx.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")) }
        if let c = stamp.coordinate, c.isValid { parts.append("geo=" + format(c)) }
        guard !parts.isEmpty else { return rest }
        let comment = "<!-- stamp: " + parts.joined(separator: "; ") + " -->"
        return rest.isEmpty ? comment : rest + "\n\n" + comment
    }

    /// Replaces (or adds) the place on `body`, keeping any weather already stamped.
    public static func settingPlace(_ name: String, coordinate: PlaceCoordinate?, on body: String) -> String {
        let (old, rest) = split(body)
        var stamp = old ?? PlaceStamp()
        stamp.location = name
        stamp.coordinate = coordinate
        return join(stamp: stamp, rest: rest)
    }
}

// MARK: - Map points and clustering

/// One entry on the map. Built only from entries whose content may be shown.
public struct PlacePoint: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { entryId }
    public let entryId: String
    public let title: String
    public let date: Date
    public let placeName: String
    public let coordinate: PlaceCoordinate
    public init(entryId: String, title: String, date: Date, placeName: String, coordinate: PlaceCoordinate) {
        self.entryId = entryId; self.title = title; self.date = date; self.placeName = placeName; self.coordinate = coordinate
    }
}

/// Minimal facts the map needs about an entry (keeps Core free of the app model).
public struct PlaceSourceEntry: Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let createdAt: Date
    public let isHidden: Bool
    public let isTrashed: Bool
    public init(id: String, title: String, body: String, createdAt: Date, isHidden: Bool, isTrashed: Bool = false) {
        self.id = id; self.title = title; self.body = body; self.createdAt = createdAt
        self.isHidden = isHidden; self.isTrashed = isTrashed
    }
}

public struct PlaceCluster: Equatable, Sendable, Identifiable {
    /// Stable for a given member set (first member's id + count).
    public let id: String
    public let points: [PlacePoint]
    public let center: PlaceCoordinate
    public var count: Int { points.count }
    public var isSingle: Bool { points.count == 1 }
}

public enum PlaceIndex {
    /// Entries with a stamped coordinate. Privacy: a hidden entry's place lives
    /// in its body, so while hidden entries are locked they never appear —
    /// not even as an anonymous pin. Trashed entries never appear.
    public static func points(from entries: [PlaceSourceEntry], hiddenLocked: Bool) -> [PlacePoint] {
        entries.compactMap { e in
            guard !e.isTrashed, !(e.isHidden && hiddenLocked) else { return nil }
            guard let stamp = PlaceStampCodec.split(e.body).stamp, let c = stamp.coordinate else { return nil }
            return PlacePoint(entryId: e.id, title: e.title.isEmpty ? "Untitled" : e.title, date: e.createdAt,
                              placeName: stamp.location, coordinate: c)
        }
        .sorted { $0.date > $1.date }
    }

    /// Entries that name a place but have no coordinates (shown as a count).
    public static func namedOnlyCount(in entries: [PlaceSourceEntry], hiddenLocked: Bool) -> Int {
        entries.reduce(0) { n, e in
            guard !e.isTrashed, !(e.isHidden && hiddenLocked),
                  let s = PlaceStampCodec.split(e.body).stamp, s.coordinate == nil, !s.location.isEmpty else { return n }
            return n + 1
        }
    }

    /// Grid clustering in degrees: points whose cells (span / `cellsAcross`)
    /// match merge into one pin. Deterministic and order-independent.
    public static func clusters(_ points: [PlacePoint], latitudeSpan: Double, longitudeSpan: Double,
                                cellsAcross: Double = 10) -> [PlaceCluster] {
        let latCell = max(latitudeSpan / cellsAcross, 1e-6)
        let lonCell = max(longitudeSpan / cellsAcross, 1e-6)
        struct Key: Hashable { let a: Int; let b: Int }
        var buckets: [Key: [PlacePoint]] = [:]
        for p in points {
            let k = Key(a: Int((p.coordinate.latitude / latCell).rounded(.down)),
                        b: Int((p.coordinate.longitude / lonCell).rounded(.down)))
            buckets[k, default: []].append(p)
        }
        return buckets.values.map { members in
            let sorted = members.sorted { ($0.date, $0.entryId) > ($1.date, $1.entryId) }
            let lat = sorted.map(\.coordinate.latitude).reduce(0, +) / Double(sorted.count)
            let lon = sorted.map(\.coordinate.longitude).reduce(0, +) / Double(sorted.count)
            let ids = sorted.map(\.entryId).sorted()
            return PlaceCluster(id: "\(ids[0])#\(ids.count)", points: sorted,
                                center: PlaceCoordinate(latitude: lat, longitude: lon))
        }
        .sorted { ($0.count, $0.id) > ($1.count, $1.id) }
    }

    /// Region that fits every point, padded; nil for no points.
    public static func boundingRegion(_ points: [PlacePoint], padding: Double = 1.4,
                                      minimumSpan: Double = 0.02) -> (center: PlaceCoordinate, latSpan: Double, lonSpan: Double)? {
        guard let first = points.first else { return nil }
        var minLat = first.coordinate.latitude, maxLat = minLat
        var minLon = first.coordinate.longitude, maxLon = minLon
        for p in points {
            minLat = min(minLat, p.coordinate.latitude); maxLat = max(maxLat, p.coordinate.latitude)
            minLon = min(minLon, p.coordinate.longitude); maxLon = max(maxLon, p.coordinate.longitude)
        }
        let latSpan = min(170, max(minimumSpan, (maxLat - minLat) * padding))
        let lonSpan = min(350, max(minimumSpan, (maxLon - minLon) * padding))
        return (PlaceCoordinate(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2), latSpan, lonSpan)
    }

    /// What clicking a pin does.
    public enum PinAction: Equatable, Sendable {
        /// One entry: open it.
        case open(entryId: String)
        /// Entries spread out: zoom so they separate.
        case zoom(center: PlaceCoordinate, latSpan: Double, lonSpan: Double)
        /// Entries at (nearly) the same spot: zooming won't help, list them.
        case list([PlacePoint])
    }

    public static func action(for cluster: PlaceCluster, minimumSpan: Double = 0.002) -> PinAction {
        if cluster.isSingle, let p = cluster.points.first { return .open(entryId: p.entryId) }
        guard let r = boundingRegion(cluster.points, padding: 2.2, minimumSpan: minimumSpan) else { return .list(cluster.points) }
        // Everything within ~20 m: the region bottoms out at the minimum span.
        if r.latSpan <= minimumSpan && r.lonSpan <= minimumSpan { return .list(cluster.points) }
        return .zoom(center: r.center, latSpan: r.latSpan, lonSpan: r.lonSpan)
    }
}
