import SwiftUI
import CryptoKit

// MARK: - Launch gate

/// Shows a window immediately at launch, then unlocks the journal.
///
/// Building `ContentView` opens the database and decrypts entries, which reads
/// the encryption key from the Keychain. When macOS asks the user to allow
/// that access, the read blocks — and it used to block on the main thread
/// before any window existed, so the app looked like it never opened. The gate
/// renders first, fetches the existing key on a background thread (load-only,
/// never minting one), and only then builds the real UI.
@MainActor
@Observable
final class LaunchGate {
    private(set) var isReady = false
    private(set) var isSlow = false
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        // Surface a hint only if the Keychain prompt is actually holding us up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            if self?.isReady == false { self?.isSlow = true }
        }
        Task { @MainActor [weak self] in
            let key: SymmetricKey? = await Task.detached(priority: .userInitiated) {
                JournalCrypto.fetchExistingAppKey()
            }.value
            JournalCrypto.adoptPrefetchedKey(key)
            self?.isReady = true
        }
    }
}

struct LaunchGateView: View {
    @State private var gate = LaunchGate()

    /// The real UI once the key is adopted, covered by the whole-app lock.
    /// Only call after the key is ready: `AppLockManager.shared` reads its
    /// settings from the database. Creating it here also installs its
    /// resign/become-active observers, and a fresh manager starts locked
    /// whenever the feature is enabled.
    @MainActor
    static func readyRoot(lock: AppLockManager? = nil) -> some View {
        ContentView().appLockGate(lock)
    }

    var body: some View {
        Group {
            if gate.isReady {
                Self.readyRoot()
            } else {
                unlocking
            }
        }
        .onAppear { gate.start() }
    }

    // Deliberately uses system styling only: ThemeManager reads its settings
    // from the database, which must not open before the key is ready.
    private var unlocking: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Opening your journal…")
                .font(.title3.weight(.semibold))
            if gate.isSlow {
                ProgressView().controlSize(.small)
                Text("Waiting for Keychain access. If macOS asks, allow Omega Journal to use its encryption key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
