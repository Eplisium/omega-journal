import Foundation
import LocalAuthentication

/// Manages biometric (Touch ID / Face ID) or password authentication
/// for accessing hidden journal entries.
@MainActor
@Observable
final class BiometricAuth {
    static let shared = BiometricAuth()

    /// Whether the user has successfully authenticated in this session.
    private(set) var isAuthenticated = false {
        didSet { if isAuthenticated != oldValue { notifySessionObservers() } }
    }
    /// True while the system auth dialog is on screen (the app resigns active then).
    private(set) var isAuthenticating = false

    // MARK: - Session change observers

    private struct SessionObserver {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    @ObservationIgnored private var sessionObservers: [SessionObserver] = []

    /// Calls `handler` after every real lock-state change (never for a
    /// redundant write), asynchronously on the main queue, for as long as
    /// `owner` is alive. Replaces the `$isAuthenticated` Combine pipeline
    /// (`dropFirst().removeDuplicates().receive(on: .main)`).
    func observeSessionChanges(owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        sessionObservers.removeAll { $0.owner == nil }
        sessionObservers.append(SessionObserver(owner: owner, handler: handler))
    }

    private func notifySessionObservers() {
        sessionObservers.removeAll { $0.owner == nil }
        for observer in sessionObservers {
            let handler = observer.handler
            DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
        }
    }

    /// Where the idle-relock setting lives; `nil` means `DatabaseManager.shared` (resolved lazily).
    private let settingsDB: DatabaseManager?

    private init() { settingsDB = nil }

    /// Independent instance for tests (the shared one is touched by other suites).
    init(forTesting: Void, db: DatabaseManager? = nil) { settingsDB = db }

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

    /// Test seam: replaces the system prompt.
    @ObservationIgnored var evaluateOverride: (() async -> Bool)?
    /// The single in-flight prompt. Concurrent callers await it instead of
    /// starting a second dialog, so one caller's completion cannot clear
    /// `isAuthenticating` (or flip `isAuthenticated`) under another.
    @ObservationIgnored private var inFlight: Task<Bool, Never>?

    /// Prompts the user to authenticate. Returns true on success. A failed or
    /// cancelled prompt never revokes an existing session.
    func authenticate() async -> Bool {
        if isAuthenticated { return true }
        if let inFlight { return await inFlight.value }

        isAuthenticating = true
        let override = evaluateOverride
        let task = Task { @MainActor () -> Bool in
            if let override { return await override() }
            let context = LAContext()
            context.localizedReason = "Unlock hidden journal entries"
            context.localizedCancelTitle = "Cancel"
            do {
                return try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Unlock hidden journal entries")
            } catch {
                return false
            }
        }
        inFlight = task
        let success = await task.value
        inFlight = nil
        isAuthenticating = false
        if success {
            isAuthenticated = true
            scheduleIdleRelock()
        }
        return success
    }

    /// Locks hidden entries (e.g. when navigating away or after timeout).
    func lock() {
        isAuthenticated = false
        idleTimer?.cancel()
    }

    // MARK: - Idle auto-relock

    /// Re-locks hidden entries after this much idle time once unlocked.
    /// Zero disables the timer (lock still happens on app resign or manually).
    static let autoRelockIdleMinutesKey = "autoRelockIdleMinutes"
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    private var idleMinutes: Int {
        (settingsDB ?? .shared).int(Self.autoRelockIdleMinutesKey, default: 5)
    }

    /// Test seam: overrides the idle interval (seconds) instead of the setting.
    @ObservationIgnored var idleSecondsOverride: TimeInterval?
    /// Minimum spacing between re-arms from `noteActivity()` so per-keystroke
    /// signals don't churn tasks and settings reads.
    @ObservationIgnored var activityThrottle: TimeInterval = 1.0
    @ObservationIgnored private var lastArm = Date.distantPast

    private var idleInterval: TimeInterval {
        idleSecondsOverride ?? TimeInterval(idleMinutes * 60)
    }

    /// Arms (or re-arms) the idle relock timer. Called on unlock and on any
    /// documented user activity signal; a no-op while locked or disabled.
    func scheduleIdleRelock() {
        idleTimer?.cancel()
        guard isAuthenticated, idleInterval > 0 else { return }
        lastArm = Date()
        let interval = idleInterval
        idleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, self?.isAuthenticated == true else { return }
            NotificationCenter.default.post(name: .lockHiddenEntries, object: nil)
        }
    }

    /// Call on user activity (typing, clicking, scrolling) while hidden
    /// entries are unlocked: pushes the idle relock deadline out. Cheap and
    /// throttled; a no-op while locked.
    func noteActivity() {
        guard isAuthenticated else { return }
        guard Date().timeIntervalSince(lastArm) >= activityThrottle else { return }
        scheduleIdleRelock()
    }

    #if DEBUG
    func setAuthenticatedForTesting(_ value: Bool) { isAuthenticated = value }
    #endif

    /// Cancels the pending idle relock without changing auth state (activity
    /// happened; the caller re-arms via `scheduleIdleRelock`).
    func cancelIdleRelock() {
        idleTimer?.cancel()
    }
}
