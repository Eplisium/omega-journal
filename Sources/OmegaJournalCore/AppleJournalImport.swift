import Foundation
import CryptoKit

// MARK: - Apple Journal export → import records (pure)
//
// Export shape (Journal › File › Export on macOS 26+, "Export" in the journal's
// … menu on iPhone/iPad), as described by Apple's help pages and by every
// third-party importer we checked:
//
//   AppleJournalEntries/
//     Entries/2025-12-15_Evening_walk.html   one page per entry
//     Entries/2025-12-15_(1).html            same-day duplicates get _(n)
//     Resources/<UUID>.heic|.jpg|.mov|.m4a   photos, videos, audio
//     Resources/<UUID>.json                  per-asset metadata (date, placeName…)
//
// Inside each page: `.pageHeader` (the entry's day, written in the exporting
// device's locale), `.title`, one or more `.bodyText` blocks (Cocoa HTML) and
// `.assetGrid` / `.gridItem.assetType_<kind>` media cards whose <img>/<video>
// point at `../Resources/<file>`.
//
// The parser is deliberately tolerant: any of these may be missing, extra
// markup is ignored, and nothing here touches the disk.

public struct AppleJournalAsset: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case photo, video, audio, music, map, link, workout, activity, stateOfMind, contact, unknown
    }
    public let id: String
    public let kind: Kind
    /// `src` as written in the page (already percent-decoded), or nil.
    public let source: String?
    /// Overlay text: place for maps, label + context for state of mind, metrics for workouts.
    public let caption: String
    /// First overlay line on its own (state-of-mind label, activity type).
    public let header: String
    public let href: String?
}

public struct AppleJournalPage: Equatable, Sendable {
    public var fileName: String
    public var title: String
    public var headerDate: String
    public var markdownBody: String
    public var assets: [AppleJournalAsset]
}

public struct AppleJournalSidecar: Equatable, Sendable {
    public var date: Date?
    public var placeName: String?
    public var coordinate: PlaceCoordinate?
}

public struct AppleJournalLayout: Equatable, Sendable {
    /// Path prefix of the export root inside the folder/zip ("" or "AppleJournalEntries/").
    public let root: String
    public let entryPaths: [String]
    public let resourcePaths: Set<String>
}

public struct AppleJournalImportResult: Equatable, Sendable {
    public var entries: [ImportedEntry]
    /// Pages that had no readable date.
    public var skipped: Int
    public var attachmentCount: Int { entries.reduce(0) { $0 + $1.attachmentPaths.count } }
}

public enum AppleJournalImport {
    public static let tag = "apple-journal"

    // MARK: Layout

    /// Finds the export inside a list of root-relative file paths: the folder
    /// prefix whose `Entries/` holds the most `.html` pages. nil = not an export.
    public static func layout(paths: [String]) -> AppleJournalLayout? {
        var byRoot: [String: [String]] = [:]
        var resources = Set<String>()
        for raw in paths {
            let p = AppleJournalZipReader.normalize(raw)
            guard !p.isEmpty, !AppleJournalZipReader.isFinderJunk(p) else { continue }
            let comps = p.split(separator: "/").map(String.init)
            guard comps.count >= 2 else { continue }
            let parent = comps[comps.count - 2].lowercased()
            let rootPrefix = comps.dropLast(2).map { $0 + "/" }.joined()
            let ext = (p as NSString).pathExtension.lowercased()
            if parent == "entries", ext == "html" || ext == "htm" {
                byRoot[rootPrefix, default: []].append(p)
            } else if parent == "resources" {
                resources.insert(p)
            }
        }
        guard let best = byRoot.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }) else { return nil }
        let res = resources.filter { $0.hasPrefix(best.key) && $0.dropFirst(best.key.count).lowercased().hasPrefix("resources/") }
        return AppleJournalLayout(root: best.key, entryPaths: best.value.sorted(), resourcePaths: res)
    }

    // MARK: Page parsing

    public static func parsePage(html: String, fileName: String) -> AppleJournalPage {
        let doc = AppleJournalHTML.parse(html)
        let css = doc.descendants { $0.name == "style" }.map(\.textContent).joined(separator: "\n")
        let styles = AppleJournalHTML.classTraits(fromCSS: css)
        let header = doc.first { $0.hasClass("pageHeader") }.map { collapse($0.textContent) } ?? ""
        var title = doc.first { $0.hasClass("title") }.map { collapse($0.textContent) } ?? ""
        if title.isEmpty { title = titleFromFileName(fileName) }

        let bodies = doc.descendants { $0.hasClass("bodyText") }
        var markdown: String
        if bodies.isEmpty {
            // No `.bodyText`: use the page body minus the known chrome.
            let stripped = removing(doc) { $0.hasClass("pageHeader") || $0.hasClass("title") || $0.hasClass("assetGrid") || $0.hasClass("gridItem") }
            markdown = AppleJournalHTML.markdown(from: stripped, classStyles: styles)
        } else {
            markdown = bodies.map { AppleJournalHTML.markdown(from: $0, classStyles: styles) }
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        markdown = ImportParsers.normalizeNewlines(markdown)

        var assets: [AppleJournalAsset] = []
        var seen = Set<String>()
        for grid in doc.descendants(where: { $0.hasClass("assetGrid") }) {
            let items = grid.descendants { $0.hasClass("gridItem") }
            for item in items.isEmpty ? [grid] : items {
                guard let a = asset(from: item) else { continue }
                if seen.insert(a.id.isEmpty ? (a.source ?? UUID().uuidString) : a.id).inserted { assets.append(a) }
            }
        }
        // Grid items outside an `.assetGrid` (older pages).
        for item in doc.descendants(where: { $0.hasClass("gridItem") }) {
            guard let a = asset(from: item), !seen.contains(a.id.isEmpty ? (a.source ?? "") : a.id) else { continue }
            seen.insert(a.id.isEmpty ? (a.source ?? "") : a.id)
            assets.append(a)
        }
        return AppleJournalPage(fileName: fileName, title: title, headerDate: header, markdownBody: markdown, assets: assets)
    }

    static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removing(_ node: AppleJournalHTMLNode, where drop: (AppleJournalHTMLNode) -> Bool) -> AppleJournalHTMLNode {
        var n = node
        n.children = node.children.compactMap { c in
            if c.kind == .element && drop(c) { return nil }
            return removing(c, where: drop)
        }
        return n
    }

    static func kind(fromClasses classes: [String]) -> AppleJournalAsset.Kind {
        guard let cls = classes.first(where: { $0.hasPrefix("assetType_") }) else { return .unknown }
        switch cls.dropFirst("assetType_".count).lowercased() {
        case "photo", "livephoto", "panorama", "screenshot": return .photo
        case "video": return .video
        case "audio", "voicememo": return .audio
        case "music", "podcast", "book": return .music
        case "genericmap", "multipinmap", "map", "location": return .map
        case "link": return .link
        case "workoutroute", "workouticon", "workout": return .workout
        case "motionactivity", "activity": return .activity
        case "stateofmind": return .stateOfMind
        case "contact": return .contact
        default: return .unknown
        }
    }

    static func asset(from item: AppleJournalHTMLNode) -> AppleJournalAsset? {
        let kind = kind(fromClasses: item.classes)
        let id = (item.attributes["id"] ?? "").trimmingCharacters(in: .whitespaces)
        func src(_ n: AppleJournalHTMLNode?) -> String? {
            guard let v = n?.attributes["src"]?.trimmingCharacters(in: .whitespaces), !v.isEmpty,
                  !v.lowercased().hasPrefix("data:") else { return nil }
            return v
        }
        let raw = src(item.first { $0.name == "img" && $0.hasClass("asset_image") })
            ?? src(item.first { $0.name == "video" })
            ?? src(item.first { $0.name == "source" })
            ?? src(item.first { $0.name == "audio" })
            ?? src(item.first { $0.name == "img" && !$0.hasClass("mediaPlayIcon") && !$0.hasClass("mediaTypeIcon") })
        let decoded = raw.map { $0.removingPercentEncoding ?? $0 }
        func text(_ cls: String) -> String { item.first { $0.hasClass(cls) }.map { collapse($0.textContent) } ?? "" }
        let overlayHeader = text("gridItemOverlayHeader")
        let overlayFooter = text("gridItemOverlayFooter")
        let activityType = text("activityType")
        let activityMetrics = text("activityMetrics")
        let header = !overlayHeader.isEmpty ? overlayHeader : activityType
        var caption = [overlayHeader, overlayFooter].filter { !$0.isEmpty }.joined(separator: " · ")
        if caption.isEmpty { caption = [activityType, activityMetrics].filter { !$0.isEmpty }.joined(separator: " · ") }
        let href = kind == .link
            ? item.first { $0.name == "a" }?.attributes["href"].flatMap { h -> String? in
                let t = h.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
            : nil
        guard !id.isEmpty || decoded != nil || !caption.isEmpty else { return nil }
        return AppleJournalAsset(id: id, kind: kind, source: decoded, caption: caption, header: header, href: href)
    }

    // MARK: Dates

    /// `2024-08-28_Evening_walk.html` → "Evening walk"; dates and `_(n)` suffixes give "".
    public static func titleFromFileName(_ name: String) -> String {
        let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let m = base.range(of: #"^\d{4}-\d{2}-\d{2}(?:_(.+))?$"#, options: .regularExpression), m.lowerBound == base.startIndex else {
            return base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        }
        let rest = base.count > 11 ? String(base.dropFirst(11)) : ""
        if rest.range(of: #"^\(\d+\)$"#, options: .regularExpression) != nil { return "" }
        let cleaned = rest.replacingOccurrences(of: #"_\(\d+\)$"#, with: "", options: .regularExpression)
        return cleaned.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// (year, month, day) and same-day index (`_(2)` → 2, otherwise 0) from a page file name.
    public static func fileNameDate(_ name: String) -> (day: DateComponents, index: Int)? {
        let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        let parts = base.prefix(10).split(separator: "-")
        guard base.count >= 10, parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var idx = 0
        if let r = base.range(of: #"\((\d+)\)$"#, options: .regularExpression) {
            idx = Int(base[r].dropFirst().dropLast()) ?? 0
        }
        return (DateComponents(year: y, month: m, day: d), idx)
    }

    static let headerFormats = ["EEEE, MMMM d, yyyy", "EEEE, d MMMM yyyy", "EEEE d MMMM yyyy", "MMMM d, yyyy",
                                "d MMMM yyyy", "EEEE, MMM d, yyyy", "MMM d, yyyy", "d MMM yyyy", "yyyy-MM-dd",
                                "EEEE, d. MMMM yyyy", "d. MMMM yyyy", "EEEE d. MMMM yyyy", "EEEE, d 'de' MMMM 'de' yyyy",
                                "d 'de' MMMM 'de' yyyy", "yyyy年M月d日EEEE", "yyyy年M月d日"]

    /// The page header's day ("Monday, 15 December 2025", "Friday, December 5, 2025", …).
    /// Tries English, then common European formats in `locales` (the user's
    /// own locale first in the app). Returns y/m/d only — no time zone games.
    public static func parseHeaderDate(_ text: String, locales: [Locale] = [Locale(identifier: "en_US_POSIX")]) -> DateComponents? {
        let t = collapse(text).replacingOccurrences(of: "\u{202F}", with: " ")
        guard !t.isEmpty else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var tried = Set<String>()
        for loc in locales + [Locale(identifier: "en_US_POSIX"), Locale(identifier: "en_GB")] where tried.insert(loc.identifier).inserted {
            let f = DateFormatter()
            f.locale = loc
            f.calendar = utc
            f.timeZone = utc.timeZone
            f.isLenient = false
            var formats = headerFormats
            for style in [DateFormatter.Style.full, .long, .medium] {
                f.dateStyle = style; f.timeStyle = .none
                formats.append(f.dateFormat)
            }
            for fmt in formats {
                f.dateFormat = fmt
                if let d = f.date(from: t) {
                    let c = utc.dateComponents([.year, .month, .day], from: d)
                    if let y = c.year, y > 1900 { return DateComponents(year: c.year, month: c.month, day: c.day) }
                }
            }
        }
        return nil
    }

    // MARK: Sidecar metadata

    /// `Resources/<id>.json`. Known keys: `date` (seconds since 2001, Apple's
    /// reference date), `placeName`; coordinates are read from any of the
    /// common spellings when present (not seen in public samples — tolerant).
    public static func parseSidecar(_ data: Data) -> AppleJournalSidecar? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var s = AppleJournalSidecar()
        if let d = number(obj["date"]) ?? number(obj["creationDate"]) {
            // Plausible Cocoa reference seconds (1990…2100); anything else is ignored.
            if d > -400_000_000, d < 3_200_000_000 { s.date = Date(timeIntervalSinceReferenceDate: d) }
        } else if let str = obj["date"] as? String, let d = ImportParsers.parseDate(str) {
            s.date = d
        }
        for key in ["placeName", "place", "locationName", "name"] {
            if let p = obj[key] as? String, !collapse(p).isEmpty { s.placeName = collapse(p); break }
        }
        func coord(_ dict: [String: Any]) -> PlaceCoordinate? {
            guard let lat = number(dict["latitude"]) ?? number(dict["lat"]),
                  let lon = number(dict["longitude"]) ?? number(dict["lon"]) ?? number(dict["lng"]) else { return nil }
            let c = PlaceCoordinate(latitude: lat, longitude: lon)
            return c.isValid ? c : nil
        }
        s.coordinate = coord(obj)
            ?? (obj["location"] as? [String: Any]).flatMap(coord)
            ?? (obj["coordinate"] as? [String: Any]).flatMap(coord)
            ?? (obj["placeCoordinate"] as? [String: Any]).flatMap(coord)
        return s
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: State of mind → mood

    static let valence: [String: Int] = [
        "very unpleasant": 1, "unpleasant": 2, "slightly unpleasant": 2, "neutral": 3,
        "slightly pleasant": 4, "pleasant": 4, "very pleasant": 5,
    ]
    static let strongPositive: Set<String> = ["amazed", "excited", "joyful", "passionate", "proud", "grateful", "happy"]
    static let positive: Set<String> = ["amused", "brave", "calm", "confident", "content", "hopeful", "peaceful",
                                        "relieved", "satisfied", "surprised"]
    static let negative: Set<String> = ["annoyed", "anxious", "disappointed", "discouraged", "drained", "embarrassed",
                                        "frustrated", "irritated", "jealous", "lonely", "sad", "stressed", "worried", "guilty"]
    static let strongNegative: Set<String> = ["angry", "ashamed", "disgusted", "hopeless", "overwhelmed", "scared"]

    /// Omega mood (1 awful … 5 great) from a State of Mind valence or emotion label.
    public static func mood(fromStateOfMind label: String) -> Int? {
        let l = collapse(label).lowercased()
        guard !l.isEmpty else { return nil }
        if let v = valence[l] { return v }
        for (phrase, v) in valence.sorted(by: { $0.key.count > $1.key.count }) where l.contains(phrase) { return v }
        let words = Set(l.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        if !words.isDisjoint(with: strongNegative) { return 1 }
        if !words.isDisjoint(with: negative) { return 2 }
        if !words.isDisjoint(with: strongPositive) { return 5 }
        if !words.isDisjoint(with: positive) { return 4 }
        if words.contains("indifferent") { return 3 }
        return nil
    }

    // MARK: Records

    /// Resolves an asset to a root-relative resource path inside `layout`
    /// (never outside its `Resources/`), falling back to `<id>.*` lookup.
    public static func resourcePath(for asset: AppleJournalAsset, pagePath: String, layout: AppleJournalLayout) -> String? {
        let resourcesDir = layout.root + "Resources/"
        func contained(_ p: String) -> String? {
            let n = AppleJournalZipReader.normalize(p)
            guard n.lowercased().hasPrefix(resourcesDir.lowercased()) else { return nil }
            if layout.resourcePaths.contains(n) { return n }
            return layout.resourcePaths.first { $0.lowercased() == n.lowercased() }
        }
        if let src = asset.source, !src.contains("://"), !src.hasPrefix("/") {
            let pageDir = (pagePath as NSString).deletingLastPathComponent
            if let p = contained(pageDir + "/" + src) ?? contained(layout.root + src) { return p }
        }
        guard !asset.id.isEmpty else { return nil }
        let prefix = (resourcesDir + asset.id + ".").lowercased()
        return layout.resourcePaths.filter { $0.lowercased().hasPrefix(prefix) && !$0.lowercased().hasSuffix(".json") }.min()
    }

    static let attachableKinds: Set<AppleJournalAsset.Kind> = [.photo, .video, .audio, .unknown]

    /// Builds import records. `read` returns a root-relative file's bytes (or nil).
    public static func records(layout: AppleJournalLayout, read: (String) -> Data?,
                               calendar: Calendar = .current,
                               headerLocales: [Locale] = [Locale.current]) -> AppleJournalImportResult {
        var out: [ImportedEntry] = []
        var skipped = 0
        for path in layout.entryPaths {
            guard let data = read(path) else { skipped += 1; continue }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let page = parsePage(html: html, fileName: (path as NSString).lastPathComponent)
            guard let record = Self.record(page: page, pagePath: path, layout: layout, read: read,
                                      calendar: calendar, headerLocales: headerLocales) else { skipped += 1; continue }
            out.append(record)
        }
        return AppleJournalImportResult(entries: out.sorted { $0.createdAt < $1.createdAt }, skipped: skipped)
    }

    public static func record(page: AppleJournalPage, pagePath: String, layout: AppleJournalLayout,
                              read: (String) -> Data?, calendar: Calendar = .current,
                              headerLocales: [Locale] = [Locale.current]) -> ImportedEntry? {
        let fromName = fileNameDate(page.fileName)
        guard let day = parseHeaderDate(page.headerDate, locales: headerLocales) ?? fromName?.day,
              let startOfDay = DayKey.gregorian(matching: calendar).date(from: day) else { return nil }

        var sidecars: [AppleJournalSidecar] = []
        var attachments: [String] = []
        var place = ""
        var coordinate: PlaceCoordinate?
        var mood: Int?
        var extras: [String] = []
        for a in page.assets {
            let sidecar = a.id.isEmpty ? nil : read(layout.root + "Resources/" + a.id + ".json").flatMap(parseSidecar)
            if let sidecar { sidecars.append(sidecar) }
            switch a.kind {
            case .map:
                if place.isEmpty { place = sidecar?.placeName ?? a.caption }
                if coordinate == nil { coordinate = sidecar?.coordinate }
            case .stateOfMind:
                if mood == nil { mood = Self.mood(fromStateOfMind: a.header.isEmpty ? a.caption : a.header) }
                if !a.caption.isEmpty { extras.append("State of mind: \(a.caption)") }
            case .link:
                if let href = a.href, AppleJournalHTML.isSafeLink(href) {
                    extras.append("[\(a.caption.isEmpty ? href : a.caption)](\(href.replacingOccurrences(of: " ", with: "%20")))")
                }
            case .workout:
                if !a.caption.isEmpty { extras.append("Workout: \(a.caption)") }
            case .activity:
                if !a.caption.isEmpty { extras.append("Activity: \(a.caption)") }
            case .music:
                if !a.caption.isEmpty { extras.append("Listening: \(a.caption)") }
            case .contact:
                if !a.caption.isEmpty { extras.append("With: \(a.caption)") }
            case .photo, .video, .audio, .unknown:
                if place.isEmpty, let p = sidecar?.placeName { place = p }
                if coordinate == nil, let c = sidecar?.coordinate { coordinate = c }
            }
            if attachableKinds.contains(a.kind), let p = resourcePath(for: a, pagePath: pagePath, layout: layout),
               !attachments.contains(p) {
                attachments.append(p)
            }
        }

        // Time of day: a sidecar timestamp on the same local day, else noon
        // (+1 minute per same-day duplicate so two untitled pages stay distinct).
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86_400)
        let created = sidecars.compactMap(\.date).filter { $0 >= startOfDay && $0 < endOfDay }.min()
            ?? calendar.date(byAdding: .minute, value: 12 * 60 + (fromName?.index ?? 0), to: startOfDay)
            ?? startOfDay

        var body = page.markdownBody
        if !extras.isEmpty { body += (body.isEmpty ? "" : "\n\n") + extras.joined(separator: "\n") }
        if !place.isEmpty || coordinate != nil {
            body = PlaceStampCodec.join(stamp: PlaceStamp(location: place, coordinate: coordinate), rest: body)
        }
        return ImportedEntry(title: page.title, body: body, createdAt: created, updatedAt: created, tags: [],
                             isFavorite: false, mood: mood,
                             sourceId: Self.sourceId(day: day, title: page.title, body: page.markdownBody, assets: page.assets),
                             attachmentPaths: attachments)
    }

    /// Deterministic UUID for a page's content (day + title + text + asset ids),
    /// used as the imported entry's id so a re-import is recognised exactly —
    /// even when Journal renumbers same-day file names between exports.
    public static func sourceId(day: DateComponents, title: String, body: String, assets: [AppleJournalAsset]) -> String {
        let key = ["applejournal", "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)", title, body,
                   assets.map(\.id).sorted().joined(separator: ",")].joined(separator: "\u{1F}")
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let u = uuid_t(bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: u).uuidString
    }
}
