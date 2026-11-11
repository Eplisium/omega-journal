import Foundation

// MARK: - Voice memo transcripts (pure)
//
// Transcription itself runs on-device in the app (Speech framework). These
// rules decide when it is offered and how a transcript lands in the entry —
// in the body, so it is encrypted with it and searchable.

public enum TranscriptAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    public var isAvailable: Bool { self == .available }

    /// - osSupported: macOS 26 or later.
    /// - hasUsageDescription: the bundle declares `NSSpeechRecognitionUsageDescription`
    ///   (asking for permission without it would terminate the app).
    /// - onDeviceSupported: the recognizer for the user's language can run
    ///   without a network connection. Transcription never falls back to a server.
    public static func decide(osSupported: Bool, hasUsageDescription: Bool, onDeviceSupported: Bool) -> TranscriptAvailability {
        guard osSupported else { return .unavailable("Transcription needs macOS 26 or later.") }
        guard hasUsageDescription else { return .unavailable("Transcription isn't available in this build.") }
        guard onDeviceSupported else {
            return .unavailable("On-device transcription isn't available for your language on this Mac.")
        }
        return .available
    }
}

public enum TranscriptText {
    public static let label = "Voice memo transcript"

    /// Collapses runs of spaces, keeps paragraph breaks, trims the ends.
    public static func clean(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .split(whereSeparator: { $0.isEmpty })
            .map { $0.joined(separator: " ") }
            .joined(separator: "\n\n")
    }

    /// The block inserted at the caret: a small label line, then the text.
    public static func block(_ transcript: String, atLineStart: Bool) -> String {
        let text = clean(transcript)
        guard !text.isEmpty else { return "" }
        let lead = atLineStart ? "" : "\n\n"
        return lead + "*\(label)*\n\n" + text + "\n"
    }

    /// The block appended to the end of an existing stored body (reader path).
    /// A trailing place/weather stamp stays the last line of the body.
    public static func appending(_ transcript: String, to body: String) -> String {
        let block = block(transcript, atLineStart: true)
        guard !block.isEmpty else { return body }
        let parts = EntryStampCodec.split(body)
        let trimmed = parts.rest.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let rest = trimmed.isEmpty ? block : trimmed + "\n\n" + block
        return EntryStampCodec.join(stamp: parts.stamp, rest: rest)
    }
}
