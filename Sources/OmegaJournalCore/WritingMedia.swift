import Foundation

// MARK: - Inline image references, entry stamp, waveform (pure)

public struct MarkdownImageRef: Equatable, Sendable {
    /// Range of the whole `![alt](omega-attachment://file#w=N)` token (UTF-16).
    public let range: NSRange
    public let alt: String
    public let filename: String
    public let width: Int?
}

public enum ImageRefs {
    public static let scheme = "omega-attachment"
    public static let presetWidths = [240, 480, 720]
    public static let widthRange = 80...1600

    private static let regex = try! NSRegularExpression(
        pattern: #"!\[([^\]\n]*)\]\(omega-attachment://([^)\s#]+)(?:#w=(\d{1,4}))?\)"#)

    private static func encodeName(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public static func markdown(alt: String, filename: String, width: Int? = nil) -> String {
        let cleanAlt = alt.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        let w = width.map { "#w=\(min(max($0, widthRange.lowerBound), widthRange.upperBound))" } ?? ""
        return "![\(cleanAlt)](\(scheme)://\(encodeName(filename))\(w))"
    }

    /// All image refs in `text` outside fenced code.
    public static func refs(in text: String) -> [MarkdownImageRef] {
        guard text.contains(scheme + "://") else { return [] }
        let ns = text as NSString
        let fences = MarkdownLogic.codeBlockRanges(in: text)
        var out: [MarkdownImageRef] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, !MarkdownLogic.intersectsAny(m.range, sortedRanges: fences) else { return }
            let name = ns.substring(with: m.range(at: 2)).removingPercentEncoding ?? ns.substring(with: m.range(at: 2))
            let w = m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) : nil
            out.append(MarkdownImageRef(range: m.range, alt: ns.substring(with: m.range(at: 1)), filename: name, width: w))
        }
        return out
    }

    /// A paragraph line that is exactly one image ref (what the renderer draws as a block image).
    public static func standaloneRef(inLine line: String) -> MarkdownImageRef? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let r = refs(in: t).first, r.range.location == 0, r.range.length == (t as NSString).length else { return nil }
        return r
    }

    /// Rewrites the ref on source line `lineIndex` to the given width (nil = natural size).
    public static func resizing(body: String, lineIndex: Int, width: Int?) -> String? {
        var lines = body.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count, let ref = standaloneRef(inLine: lines[lineIndex]) else { return nil }
        lines[lineIndex] = markdown(alt: ref.alt, filename: ref.filename, width: width)
        return lines.joined(separator: "\n")
    }

    /// Display size for an image of `natural` pixels: never upscaled past natural, never wider than `available`.
    public static func displayWidth(requested: Int?, natural: Double, available: Double) -> Double {
        guard natural > 0, available > 0 else { return max(available, 0) }
        let want = requested.map(Double.init) ?? natural
        return min(max(want, 40), min(natural, available))
    }
}

// MARK: - Entry stamp (optional place/weather line, stored as a trailing HTML comment)
//
// Kept at the END of the body so list previews and search snippets (which read from the start)
// never show it; the editor and reader strip it and show structured fields instead.

public struct EntryStamp: Equatable, Sendable {
    public var location: String
    public var weather: String
    public init(location: String = "", weather: String = "") { self.location = location; self.weather = weather }
    public var isEmpty: Bool { location.isEmpty && weather.isEmpty }
    public var summary: String { [location, weather].filter { !$0.isEmpty }.joined(separator: " · ") }
}

public enum EntryStampCodec {
    private static let tailRegex = try! NSRegularExpression(pattern: #"(?:\r?\n)*<!--\s*stamp:\s*([^>]*?)\s*-->\s*$"#)
    private static var allowed: CharacterSet {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: " ,.°+_()'/")
        return c
    }

    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }

    /// Splits a trailing stamp comment off `body`. No stamp → (nil, body).
    public static func split(_ body: String) -> (stamp: EntryStamp?, rest: String) {
        guard body.contains("<!--") else { return (nil, body) }
        let ns = body as NSString
        guard let m = tailRegex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return (nil, body) }
        var stamp = EntryStamp()
        for part in ns.substring(with: m.range(at: 1)).components(separatedBy: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("loc=") { stamp.location = String(kv.dropFirst(4)).removingPercentEncoding ?? "" }
            else if kv.hasPrefix("wx=") { stamp.weather = String(kv.dropFirst(3)).removingPercentEncoding ?? "" }
        }
        return (stamp, ns.substring(to: m.range.location))
    }

    /// `rest` with the stamp appended (an empty/nil stamp returns `rest` unchanged).
    public static func join(stamp: EntryStamp?, rest: String) -> String {
        guard let stamp, !stamp.isEmpty else { return rest }
        var parts: [String] = []
        let loc = stamp.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let wx = stamp.weather.trimmingCharacters(in: .whitespacesAndNewlines)
        if !loc.isEmpty { parts.append("loc=" + enc(loc)) }
        if !wx.isEmpty { parts.append("wx=" + enc(wx)) }
        guard !parts.isEmpty else { return rest }
        let comment = "<!-- stamp: " + parts.joined(separator: "; ") + " -->"
        return rest.isEmpty ? comment : rest + "\n\n" + comment
    }
}

// MARK: - Waveform

public enum WaveformMath {
    /// Peak amplitude per bar (0...1), normalised so the loudest bar is 1. Empty/silent → zeros.
    public static func bars(samples: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !samples.isEmpty else { return [Float](repeating: 0, count: count) }
        var out = [Float](repeating: 0, count: count)
        let per = Double(samples.count) / Double(count)
        for i in 0..<count {
            let lo = Int(Double(i) * per)
            let hi = min(samples.count, max(lo + 1, Int(Double(i + 1) * per)))
            var peak: Float = 0
            for s in samples[lo..<hi] { peak = max(peak, abs(s)) }
            out[i] = peak
        }
        let top = out.max() ?? 0
        return top > 0 ? out.map { $0 / top } : out
    }

    /// Average-power dB (≈ -160…0) → 0...1 for live meters.
    public static func level(fromDecibels db: Float, floor: Float = -50) -> Float {
        guard db.isFinite else { return 0 }
        return min(1, max(0, (db - floor) / -floor))
    }
}
