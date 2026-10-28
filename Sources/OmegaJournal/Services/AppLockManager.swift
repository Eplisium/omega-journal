import AppKit
import Foundation
import OmegaJournalCore
import SwiftUI

// MARK: - Whole-app lock

/// Optional launch / away lock. Settings live in the `settings` table.
@MainActor
@Observable
final class AppLockManager {
    static let shared = AppLockManager()
    static let enabledKey = "appLockEnabled"
    static let timeoutKey = "appLockTimeoutSeconds"

    private(set) var isLocked: Bool
    var isEnabled: Bool { didSet { persistEnabled() } }
    var timeout: AppLockTimeout { didSet { persistTimeout() } }
    private(set) var failedAttempt = false

    private let db: DatabaseManager
    private let auth: BiometricAuth
    @ObservationIgnored private var lastActive: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var authInFlight = false
    var isObservingApp: Bool { !observers.isEmpty }

    init(db: DatabaseManager? = nil, auth: BiometricAuth? = nil, observeApp: Bool = true) {
        let db = db ?? DatabaseManager.shared
        let auth = auth ?? BiometricAuth.shared
        self.db = db
        self.auth = auth
        let enabled = db.getSetting(Self.enabledKey, defaultValue: "false") == "true"
        let raw = Int(db.getSetting(Self.timeoutKey, defaultValue: "0")) ?? 0
        let timeout = AppLockTimeout(rawValue: raw) ?? .immediately
        isEnabled = enabled
        self.timeout = timeout
        // Fresh launch: locked whenever the feature is on.
        isLocked = AppLockPolicy.shouldLock(enabled: enabled, timeout: timeout, lastActive: nil, now: Date())
        if observeApp { installObservers() }
    }

    private func persistEnabled() {
        db.setSetting(Self.enabledKey, value: isEnabled ? "true" : "false")
        if !isEnabled { isLocked = false }
    }

    private func persistTimeout() { db.setSetting(Self.timeoutKey, value: "\(timeout.rawValue)") }

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appResigned() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        })
    }

    func appResigned(now: Date = Date()) {
        // The system auth sheet itself resigns the app — don't count that as leaving.
        guard !authInFlight, !auth.isAuthenticating else { return }
        lastActive = now
    }

    func appBecameActive(now: Date = Date()) {
        if AppLockPolicy.shouldLock(enabled: isEnabled, timeout: timeout, lastActive: lastActive, now: now), !isLocked, lastActive != nil {
            lock()
        }
        lastActive = nil
        if isLocked && isEnabled { Task { await unlock() } }
    }

    func lock() {
        guard isEnabled else { return }
        isLocked = true
        // Locking the app also re-masks hidden entries.
        NotificationCenter.default.post(name: .lockHiddenEntries, object: nil)
    }

    @discardableResult
    func unlock() async -> Bool {
        guard isLocked else { return true }
        guard !authInFlight else { return false }
        authInFlight = true
        defer { authInFlight = false }
        let ok = await auth.authenticateForAppLock()
        if ok { isLocked = false; failedAttempt = false } else { failedAttempt = true }
        return ok
    }
}

/// Hides and disables the wrapped content while the app is locked, covers it
/// with `AppLockOverlay`, and asks for authentication as soon as a locked
/// window appears (the launch-time didBecomeActive fired before the gate).
struct AppLockGate: ViewModifier {
    var lock: AppLockManager
    func body(content: Content) -> some View {
        content
            .disabled(lock.isLocked)
            .accessibilityHidden(lock.isLocked)
            .overlay(AppLockOverlay(lock: lock))
            .onAppear {
                if lock.isLocked { Task { await lock.unlock() } }
            }
    }
}

/// Full-window cover shown while the app is locked.
struct AppLockOverlay: View {
    var lock: AppLockManager
    private let theme = ThemeManager.shared

    var body: some View {
        if lock.isLocked {
            ZStack {
                theme.backgroundColor.ignoresSafeArea()
                VStack(spacing: OmegaTheme.Spacing.l) {
                    Image(systemName: "lock.fill")
                        .font(OmegaTheme.font(.display, .light))
                        .foregroundColor(theme.accentColor)
                        .accessibilityHidden(true)
                    Text("Omega Journal is locked")
                        .font(OmegaTheme.serifTitleFont)
                        .foregroundColor(theme.titleTextColor)
                    if lock.failedAttempt {
                        Text("Authentication didn't complete.")
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(theme.dangerColor)
                    }
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Label("Unlock", systemImage: "touchid")
                            .font(OmegaTheme.font(.body, .semibold))
                            .foregroundColor(theme.onAccentColor)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(theme.accentColor))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .transition(.opacity)
        }
    }
}

extension View {
    /// Covers the content with the lock screen while `AppLockManager` is locked.
    /// Embed once at the root: `ContentView().appLockGate()`.
    @MainActor func appLockGate(_ lock: AppLockManager? = nil) -> some View {
        modifier(AppLockGate(lock: lock ?? AppLockManager.shared))
    }
}
