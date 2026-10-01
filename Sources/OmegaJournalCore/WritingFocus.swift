import Foundation

// MARK: - Focus / typewriter helpers (pure)
//
// Preferences for the writing surface and the UTF-16 maths the editor adapter needs.

public enum EditorFontChoice: String, CaseIterable, Sendable, Equatable {
    case system, serif, sans, mono

    public var label: String {
        switch self {
        case .system: "System"
        case .serif: "Serif"
        case .sans: "Sans"
        case .mono: "Mono"
        }
    }

    /// Unknown / empty raw values fall back to the system font.
    public static func from(raw: String) -> EditorFontChoice { EditorFontChoice(rawValue: raw) ?? .system }
}

public enum WritingFocusLogic {
    public static let lineHeightRange: ClosedRange<Double> = 1.2...2.2
    public static let defaultLineHeight = 1.65
    public static let columnWidthRange: ClosedRange<Double> = 480...1100
    public static let defaultColumnWidth = 0.0   // 0 = fill the pane

    public static func clampedLineHeight(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return defaultLineHeight }
        return min(max(v, lineHeightRange.lowerBound), lineHeightRange.upperBound)
    }

    /// 0 (or any non-positive / non-finite value) means "no column limit".
    public static func clampedColumnWidth(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 0 }
        return min(max(v, columnWidthRange.lowerBound), columnWidthRange.upperBound)
    }

    /// Extra inter-line spacing (points) that yields roughly `lineHeight` × font size per line.
    public static func lineSpacing(fontSize: Double, lineHeight: Double) -> Double {
        max(0, (clampedLineHeight(lineHeight) - 1.2) * max(fontSize, 1))
    }

    /// The paragraph (run of non-blank lines) containing `caret`; a blank line is its own paragraph.
    public static func paragraphRange(in text: String, caret: Int) -> NSRange {
        let ns = text as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let c = min(max(caret, 0), ns.length)
        // A caret at the very end sits on the last line.
        let probe = (c == ns.length && c > 0) ? c - 1 : c
        var line = ns.lineRange(for: NSRange(location: probe, length: 0))
        func isBlank(_ r: NSRange) -> Bool {
            ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if isBlank(line) { return line }
        var start = line.location
        while start > 0 {
            let prev = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(prev) { break }
            start = prev.location
        }
        var end = NSMaxRange(line)
        while end < ns.length {
            let next = ns.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(next) { break }
            end = NSMaxRange(next)
        }
        line = NSRange(location: start, length: end - start)
        return line
    }

    /// Ranges to dim: everything outside `active`.
    public static func dimRanges(textLength: Int, active: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        if active.location > 0 { out.append(NSRange(location: 0, length: min(active.location, textLength))) }
        let end = NSMaxRange(active)
        if end < textLength { out.append(NSRange(location: end, length: textLength - end)) }
        return out
    }

    /// Scroll offset that puts `caretMidY` in the middle of a viewport, clamped to the document.
    public static func typewriterOffset(caretMidY: Double, viewportHeight: Double, documentHeight: Double) -> Double {
        let target = caretMidY - viewportHeight / 2
        return min(max(0, target), max(0, documentHeight - viewportHeight))
    }
}
