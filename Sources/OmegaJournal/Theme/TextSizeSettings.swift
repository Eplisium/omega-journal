import Foundation
import Observation
import OmegaJournalCore

// MARK: - App-wide text size (live)
//
// One observable value read by `OmegaTheme.font(_:)`. Because every view body
// that draws text calls `OmegaTheme.font`, Observation re-renders exactly those
// views when the size changes — no app relaunch and no environment plumbing.
//
// Stored in UserDefaults (not the journal database) so it can be read before
// the launch gate adopts the encryption key.

@MainActor
@Observable
final class TextSizeSettings {
    static let shared = TextSizeSettings()

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var size: UITextSize

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        size = UITextSize.from(stored: defaults.string(forKey: UITextSize.storageKey))
    }

    /// Changes and persists the size. Equal values are ignored so views that
    /// read `size` never redraw for nothing.
    func set(_ new: UITextSize) {
        guard new != size else { return }
        size = new
        defaults.set(new.rawValue, forKey: UITextSize.storageKey)
    }

    /// Point size for a base token at the current size.
    func points(_ base: CGFloat) -> CGFloat { CGFloat(size.scaled(Double(base))) }
}
