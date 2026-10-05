import Foundation
import LocalAuthentication

extension BiometricAuth {
    /// Authenticates for the whole-app launch lock. Unlike `authenticate()` this
    /// never marks hidden entries as unlocked — the app lock and the hidden-entry
    /// lock are separate gates.
    func authenticateForAppLock() async -> Bool {
        if let override = evaluateOverride { return await override() }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: "Unlock Omega Journal")
        } catch {
            return false
        }
    }

    /// True when the Mac can authenticate at all (password counts).
    var canAuthenticateDevice: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
    }
}
