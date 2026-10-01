import Foundation

// MARK: - Importer parsing (pure; file IO lives in the app target)

public struct ImportedEntry: Equatable, Sendable {
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    public var tags: [String]
    public var isFavorite: Bool
    /// 1…5 when the source carried a mood.
    public var mood: Int?
    /// Source-stable id used for duplicate detection (e.g. Day One uuid); may be nil.
    public var sourceId: String?
    /// Relative paths (to the import root) of files to attach.
    public var attachmentPaths: [String]
    public init(title: String, body: String, createdAt: Date, updatedAt: Date? = nil, tags: [String] = [],
                isFavorite: Bool = false, mood: Int? = nil, sourceId: String? = nil, attachmentPaths: [String] = []) {
        self.title = title; self.body = body; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.tags = tags; self.isFavorite = isFavorite; self.mood = mood; self.sourceId = sourceId
        self.attachmentPaths = attachmentPaths
    }
}

public enum ImportParsers {
    // MARK: Front matter

    /// Splits a leading `---` YAML block. Returns the raw key/value pairs and the remaining body.
    public static func splitFrontMatter(_ text: String) -> (fields: [String: String], lists: [String: [String]], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return ([:], [:], normalized) }
        let rest = normalized.dropFirst(4)
        var lines = rest.components(separatedBy: "\n")
        guard let endIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], [:], normalized)
        }
        let header = Array(lines[0..<endIdx])
        lines.removeSubrange(0...endIdx)
        var fields: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var currentList: String?
        for line in header {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), let key = currentList {
                lists[key, default: []].append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { currentList = key; lists[key] = lists[key] ?? []; continue }
            currentList = nil
            if value.hasPrefix("["), value.hasSuffix("]") {
                lists[key] = value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
            } else {
                fields[key] = unquote(value)
            }
        }
        var body = lines.joined(separator: "\n")
        if body.hasPrefix("\n") { body.removeFirst() }
        return (fields, lists, body)
    }

    static func unquote(_ s: String) -> String {
        var v = s
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v.replacingOccurrences(of: "\\\"", with: "\"")
    }

    public static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    /// Obsidian / plain markdown note. Front-matter `title`, `date|created`, `tags`, `mood`, `favorite`
    /// win; otherwise the first `# Heading`, otherwise the filename. Inline `#tags` are collected
    /// from the first line starting with only tags is NOT attempted — only front matter tags.
    public static func parseMarkdownNote(text: String, fallbackTitle: String, fallbackDate: Date) -> ImportedEntry {
        let (fields, lists, rawBody) = splitFrontMatter(text)
        var body = rawBody
        var title = fields["title"] ?? ""
        if title.isEmpty {
            let parsed = OmegaCore.parseMarkdownImport(text: body, fallbackTitle: fallbackTitle)
            title = parsed.title; body = parsed.body
        }
        var tags = lists["tags"] ?? lists["tag"] ?? []
        if tags.isEmpty, let single = fields["tags"] ?? fields["tag"] {
            tags = single.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        }
        tags = tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        let created = (fields["date"] ?? fields["created"] ?? fields["createdat"]).flatMap(parseDate) ?? fallbackDate
        let updated = (fields["updated"] ?? fields["modified"] ?? fields["updatedat"]).flatMap(parseDate) ?? created
        let mood = fields["mood"].flatMap { Int($0) }.map { min(5, max(1, $0)) }
        let fav = ["true", "yes", "1"].contains((fields["favorite"] ?? fields["starred"] ?? "").lowercased())
        return ImportedEntry(title: title, body: body, createdAt: created, updatedAt: updated, tags: tags,
                             isFavorite: fav, mood: mood, sourceId: fields["id"])
    }

    // MARK: Plain text

    /// Plain-text note: first non-empty line (≤ 80 chars, no terminal period) becomes the title.
    public static func parsePlainText(text: String, fallbackTitle: String, fallbackDate: Date) -> ImportedEntry {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           first.count <= 80, !first.hasSuffix("."), lines.count > 1 {
            let idx = lines.firstIndex(of: first)!
            let rest = lines[(idx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty {
                return ImportedEntry(title: first.trimmingCharacters(in: .whitespaces), body: rest, createdAt: fallbackDate)
            }
        }
        return ImportedEntry(title: fallbackTitle, body: normalized.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: fallbackDate)
    }

    // MARK: Day One JSON

    public struct DayOneResult: Equatable, Sendable {
        public var entries: [ImportedEntry]
        public var skipped: Int
    }

    /// Parses a Day One "Export as JSON" file. Photos are returned as relative paths
    /// (`photos/<md5>.<ext>`) when the entry lists them; `dayone-moment://` references
    /// in the text are rewritten to a plain "[photo]" marker (the files attach separately).
    public static func parseDayOneJSON(_ data: Data) throws -> DayOneResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["entries"] as? [[String: Any]] else {
            throw ImportParseError.notDayOne
        }
        var out: [ImportedEntry] = []
        var skipped = 0
        for e in raw {
            guard let dateStr = e["creationDate"] as? String, let created = parseDate(dateStr) else { skipped += 1; continue }
            var text = (e["text"] as? String) ?? ""
            text = unescapeDayOne(text)
            // Photo moment references.
            var photoPaths: [String] = []
            var identifierToPath: [String: String] = [:]
            for p in (e["photos"] as? [[String: Any]]) ?? [] {
                guard let md5 = p["md5"] as? String else { continue }
                let ext = (p["type"] as? String) ?? "jpeg"
                let path = "photos/\(md5).\(ext)"
                photoPaths.append(path)
                if let ident = p["identifier"] as? String { identifierToPath[ident] = path }
            }
            text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\(dayone-moment://[^)]*\\)", with: "", options: .regularExpression)
            let parsed = OmegaCore.parseMarkdownImport(text: text.trimmingCharacters(in: .whitespacesAndNewlines), fallbackTitle: "Day One entry")
            let modified = (e["modifiedDate"] as? String).flatMap(parseDate) ?? created
            let tags = ((e["tags"] as? [String]) ?? []).map { $0.replacingOccurrences(of: " ", with: "-") }
            out.append(ImportedEntry(
                title: parsed.title, body: parsed.body.trimmingCharacters(in: .whitespacesAndNewlines),
                createdAt: created, updatedAt: modified, tags: tags,
                isFavorite: (e["starred"] as? Bool) ?? false, mood: nil,
                sourceId: e["uuid"] as? String, attachmentPaths: photoPaths))
        }
        return DayOneResult(entries: out, skipped: skipped)
    }

    /// Day One escapes markdown punctuation with backslashes (`\.`, `\!`, `\-`…).
    static func unescapeDayOne(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\\([.!\\-()\\[\\]#*_>+`~{}|])", with: "$1", options: .regularExpression)
    }

    public enum ImportParseError: Error, LocalizedError {
        case notDayOne
        public var errorDescription: String? { "This doesn't look like a Day One JSON export (no \"entries\" array)." }
    }
}
