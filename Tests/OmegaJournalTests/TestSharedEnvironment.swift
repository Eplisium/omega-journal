import Foundation
import Testing

/// Where `.shared` singletons (DatabaseManager, ThemeManager, JournalCrypto's
/// test key) point during the test run. The test-mode env vars are process
/// global: a suite that points them into its own temp dir and then deletes
/// that dir breaks any suite whose `.shared` happens to open in between
/// (seen as a filtered parallel run failing in another suite). This directory
/// lives for the whole run and is never deleted mid-run.
///
/// Every suite calls `pin()` before it builds anything that may reach a
/// `.shared` singleton. A suite that needs a journal of its own (asserts on
/// empty lists, counts, settings) builds a private
/// `DatabaseManager(databasePath:attachmentsPath:)` and passes it to
/// `JournalViewModel(database:)`; it may delete that directory afterwards.
enum TestSharedEnvironment {
    static let root: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oj-tests-shared-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    /// Points the test-mode env vars at the run-wide directory (keeps every
    /// `.shared` singleton off the real journal and real Keychain).
    static func pin() {
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("shared.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("shared-att", isDirectory: true).path, 1)
    }
}

// MARK: - Process-wide lock state

/// FIFO async mutex shared across suites. Waiting suspends the task; it never
/// blocks the main thread, so main-actor tests can queue on it.
nonisolated final class TestAsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if held {
                waiters.append(continuation)
                lock.unlock()
            } else {
                held = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            held = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()   // ownership passes straight to the next waiter
        }
    }
}

/// `.serialized` only orders tests inside one suite. `BiometricAuth.shared`
/// (the hidden-entries lock) is process-global, so a test that unlocks, or
/// that expects hidden entries to stay masked, races every other suite that
/// flips it while the full suite runs in parallel (`swift test` without
/// `--no-parallel`). Tag such suites with `.lockState`: each of their test
/// cases holds one process-wide mutex for its whole run, so no two of them
/// overlap, while every other suite still runs in parallel.
///
///     @Suite("Hidden entry masking", .serialized, .lockState)
///
/// Rule: any suite that calls `BiometricAuth.shared.setAuthenticatedForTesting`,
/// or asserts on hidden-entry masking through a `JournalViewModel`, carries it.
nonisolated struct LockStateTrait: SuiteTrait, TestTrait, TestScoping {
    static let mutex = TestAsyncMutex()

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        // Suites themselves pass through; only each concrete test case locks.
        guard testCase != nil, !test.isSuite else {
            try await function()
            return
        }
        await Self.mutex.acquire()
        defer { Self.mutex.release() }
        try await function()
    }
}

extension Trait where Self == LockStateTrait {
    /// Run each test case exclusively with respect to `BiometricAuth.shared`.
    static var lockState: Self { LockStateTrait() }
}
