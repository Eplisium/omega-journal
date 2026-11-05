import Foundation

/// Where `.shared` singletons (DatabaseManager, ThemeManager, JournalCrypto's
/// test key) point during the test run. The test-mode env vars are process
/// global: a suite that points them into its own temp dir and then deletes
/// that dir breaks any suite whose `.shared` happens to open in between
/// (seen as a filtered parallel run failing in another suite). This directory
/// lives for the whole run and is never deleted mid-run.
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
