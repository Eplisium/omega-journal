import Foundation

// MARK: - Save status (Save track)
//
// Pure model + wording for the editor's save indicator. A failed write used to
// be invisible: the indicator only knew idle/pending/saved and flipped
// `pending` to `saved` even when the database refused the write. The reason
// carried by `.failed` is a closed enum with fixed wording, so raw error text
// (which could echo SQL or entry content) can never reach the UI.

/// Why the last write of an entry did not land. Wording is fixed per case and
/// never includes the entry title, body or tags.
public enum SaveFailureReason: String, Equatable, Sendable, CaseIterable {
    case readOnly
    case encryptionUnavailable
    case undecryptable
    case diskFull
    case databaseBusy
    case writeFailed

    /// Short user-facing reason (one sentence fragment, no entry content).
    public var message: String {
        switch self {
        case .readOnly: "The journal is open read-only"
        case .encryptionUnavailable: "The encryption key is unavailable"
        case .undecryptable: "The stored text can't be decrypted"
        case .diskFull: "The disk is full"
        case .databaseBusy: "The journal database is busy"
        case .writeFailed: "The journal database refused the write"
        }
    }

    /// Maps a low-level error description to a fixed reason. The input is only
    /// pattern-matched, never echoed, so it may safely contain anything.
    public static func classify(_ description: String?) -> SaveFailureReason {
        let text = (description ?? "").lowercased()
        if text.contains("can't be decrypted") || text.contains("cannot be decrypted") { return .undecryptable }
        if text.contains("readonly") || text.contains("read-only") || text.contains("read only")
            || text.contains("query_only") { return .readOnly }
        if text.contains("encrypt") || text.contains("keychain") || text.contains("key is") || text.contains("key was") {
            return .encryptionUnavailable
        }
        if text.contains("disk is full") || text.contains("database or disk is full") || text.contains("no space") {
            return .diskFull
        }
        if text.contains("locked") || text.contains("busy") { return .databaseBusy }
        return .writeFailed
    }
}

/// Editor save indicator state. `.failed` means at least one snapshot is
/// still held in memory, unsaved.
public enum SaveStatus: Equatable, Sendable {
    case idle, pending, saved
    case failed(SaveFailureReason)

    public var isFailed: Bool { if case .failed = self { true } else { false } }
    public var failureReason: SaveFailureReason? { if case .failed(let r) = self { r } else { nil } }
}

/// Wording, icon and accessibility text for the footer indicator.
public enum SaveStatusPresentation {
    public static func label(_ status: SaveStatus) -> String {
        switch status {
        case .pending: "Saving…"
        case .idle, .saved: "Saved"
        case .failed: "Not saved"
        }
    }

    public static func systemImage(_ status: SaveStatus) -> String {
        switch status {
        case .pending: "arrow.triangle.2.circlepath"
        case .idle, .saved: "checkmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    public static func accessibilityLabel(_ status: SaveStatus) -> String {
        switch status {
        case .pending: "Saving"
        case .idle, .saved: "All changes saved"
        case .failed(let reason):
            "Not saved. \(reason.message). Your text is kept; editing again or Retry will try to save it."
        }
    }

    /// Hover help for the failed indicator.
    public static func help(_ status: SaveStatus) -> String? {
        guard case .failed(let reason) = status else { return nil }
        return "\(reason.message). Your text is kept in this window — keep typing or click Retry to save it again."
    }

    /// Toast shown once when saving starts failing.
    public static func failureToast(_ reason: SaveFailureReason) -> String {
        "Couldn't save your entry — \(reason.message). Your text is kept; use Retry in the editor footer."
    }

    public static let retryLabel = "Retry"
    public static let retryAccessibilityLabel = "Retry saving"
}
