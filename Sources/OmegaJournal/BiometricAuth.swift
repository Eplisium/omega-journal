import Foundation
import LocalAuthentication

/// Manages biometric (Touch ID / Face ID) or password authentication
/// for accessing hidden journal entries.
@MainActor
final class BiometricAuth: ObservableObject {
    static let shared = BiometricAuth()

    /// Whether the user has successfully authenticated in this session.
    @Published private(set) var isAuthenticated = false
    /// True while the system auth dialog is on screen (the app resigns active then).
    @Published private(set) var isAuthenticating = false

    private init() {}

    /// Returns true if biometric auth is available on this device.
    var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Returns a user-facing description of the available biometric type.
    var biometricType: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return "Password"
        }
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        case .none:    return "Password"
        @unknown default: return "Password"
        }
    }

    /// Prompts the user to authenticate. Returns true on success.
    func authenticate() async -> Bool {
        // Already authenticated this session
        if isAuthenticated { return true }

        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedReason = "Unlock hidden journal entries"
        context.localizedCancelTitle = "Cancel"

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock hidden journal entries"
            )
            isAuthenticated = success
            return success
        } catch {
            isAuthenticated = false
            return false
        }
    }

    /// Locks hidden entries (e.g. when navigating away or after timeout).
    func lock() {
        isAuthenticated = false
    }
}
