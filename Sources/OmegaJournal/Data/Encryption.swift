import Foundation
import AppKit
import CryptoKit
import Security

/// At-rest encryption for journal content (audit item S1 — the app's core
/// promise is privacy, and the SQLite file + auto-backups previously stored
/// everything in plaintext, readable by any process with disk access).
///
/// Scheme: a single 256-bit AES-GCM key lives in the Keychain
/// (`kSecClassGenericPassword`) and never touches disk. It is read from the
/// data-protection keychain (access group `dataProtectionAccessGroup`, App
/// Store build) first, then the legacy login keychain (every earlier build);
/// see `MASDataKeyResolver`. Body text and attachment files are sealed as
/// AES-GCM containers; auto-backup files are sealed whole.
enum JournalCrypto {

    private static let service = "com.omegajournal.encryption"
    private static let account = "journal-content-key"
    /// Keychain access group of the App Store build. Must match the
    /// `keychain-access-groups` entitlement (team ID + bundle id). Builds
    /// without that entitlement get errSecMissingEntitlement and fall back to
    /// the legacy login keychain.
    static let dataProtectionAccessGroup = "WWC5HJN6AL.com.eplisium.omega-journal"

    /// The app's key resolver: data-protection keychain, then legacy login
    /// keychain. Pure value — safe to build on any thread.
    nonisolated static func appKeyResolver() -> MASDataKeyResolver {
        MASDataKeyResolver(
            preferred: MASDataKeychainStore(kind: .dataProtection(accessGroup: dataProtectionAccessGroup),
                                            service: service, account: account),
            legacy: MASDataKeychainStore(kind: .legacyLogin, service: service, account: account))
    }

    enum KeyError: Error, LocalizedError, Equatable {
        /// The Keychain has no key but encrypted data exists. Minting a new key
        /// would make that data permanently unreadable, so we refuse.
        case keyMissing
        case keychainUnavailable(Int32)
        case keyStoreFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .keyMissing:
                return "The journal encryption key is missing from the Keychain, but encrypted entries exist. Existing data was left untouched; restore the key (or a backup) to read it."
            case .keychainUnavailable(let s): return "Keychain unavailable for the journal encryption key (status \(s))."
            case .keyStoreFailed(let s): return "Could not store the journal encryption key in the Keychain (status \(s))."
            }
        }
    }

    // MARK: - Key management

    private static var cachedKey: SymmetricKey?

    /// Probes registered by open databases: each returns true when that
    /// database holds encrypted content. A missing key is only minted when no
    /// probe reports encrypted content.
    private static var dataProbes: [ObjectIdentifier: () -> Bool] = [:]
    static func registerEncryptedDataProbe(owner: AnyObject, _ probe: @escaping () -> Bool) {
        dataProbes[ObjectIdentifier(owner)] = probe
    }
    static func unregisterEncryptedDataProbe(owner: AnyObject) {
        dataProbes[ObjectIdentifier(owner)] = nil
    }
    private static func encryptedDataExists() -> Bool { dataProbes.values.contains { $0() } }

    /// Loads the key from the Keychain, creating and storing it on first use
    /// ONLY when no encrypted data exists yet. Throws instead of trapping so
    /// the app stays launchable with an error state.
    static func key() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        // Isolated test/QA runs (temp database via OMEGA_JOURNAL_TEST_DATABASE_PATH)
        // get an ephemeral in-memory key: they must never read the user's real
        // journal key, and a freshly built binary would otherwise block launch
        // on a Keychain access prompt.
        if let testPath = ProcessInfo.processInfo.environment["OMEGA_JOURNAL_TEST_DATABASE_PATH"], !testPath.isEmpty {
            let key = SymmetricKey(size: .bits256)
            cachedKey = key
            return key
        }
        let key = try loadOrCreateKey(using: appKeyResolver(), allowCreate: { !encryptedDataExists() })
        cachedKey = key
        return key
    }

    /// Resolver-based load (data-protection → legacy, copy forward, mint into
    /// the preferred store only when `allowCreate()`). Injectable for tests.
    static func loadOrCreateKey(using resolver: MASDataKeyResolver, allowCreate: () -> Bool) throws -> SymmetricKey {
        let resolved = try resolver.resolve(allowCreate: allowCreate)
        if case .legacyCopyFailed(let status) = resolved.origin {
            print("OmegaJournal: could not copy the encryption key to the data-protection keychain (status \(status)); using the login keychain copy.")
        }
        return resolved.key
    }

    /// Legacy login-keychain logic with injectable identity so tests never
    /// touch the real key (throwaway service names only).
    static func loadOrCreateKey(service: String, account: String, allowCreate: () -> Bool) throws -> SymmetricKey {
        let resolver = MASDataKeyResolver(
            preferred: nil,
            legacy: MASDataKeychainStore(kind: .legacyLogin, service: service, account: account))
        return try loadOrCreateKey(using: resolver, allowCreate: allowCreate)
    }

    static func deleteKeyForTesting(service: String, account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    // MARK: - Launch prefetch

    /// Strictly load-only Keychain read, safe to run OFF the main thread before
    /// the database is open (it never mints a key — with no data probes
    /// registered yet, creating one could orphan existing encrypted entries).
    /// Touches no shared state; the caller hands the result to
    /// `adoptPrefetchedKey(_:)` on the main thread.
    nonisolated static func fetchExistingKey(service: String, account: String) -> SymmetricKey? {
        try? loadOrCreateKey(service: service, account: account, allowCreate: { false })
    }

    nonisolated static func fetchExistingAppKey() -> SymmetricKey? {
        if let testPath = ProcessInfo.processInfo.environment["OMEGA_JOURNAL_TEST_DATABASE_PATH"], !testPath.isEmpty {
            return nil // isolated runs use an ephemeral key; never read the real one
        }
        return fetchExistingKey(using: appKeyResolver())
    }

    /// Load-only fetch through a resolver. Copying a legacy-only key into the
    /// data-protection keychain is allowed here; minting is not.
    nonisolated static func fetchExistingKey(using resolver: MASDataKeyResolver) -> SymmetricKey? {
        try? resolver.resolve(allowCreate: { false }).key
    }

    /// Main thread only: caches a prefetched key so database startup and entry
    /// decryption don't hit the Keychain (and block the UI) again.
    @MainActor static func adoptPrefetchedKey(_ key: SymmetricKey?) {
        guard cachedKey == nil, let key else { return }
        cachedKey = key
    }

    // MARK: - Seal / open

    static func encrypt(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: try key())
        guard let combined = box.combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    static func decrypt(_ sealed: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: try key())
    }

    static func encryptString(_ plaintext: String) throws -> Data {
        try encrypt(Data(plaintext.utf8))
    }

    static func decryptString(_ sealed: Data) throws -> String {
        String(decoding: try decrypt(sealed), as: UTF8.self)
    }

    // MARK: - Files

    /// Atomically writes an encrypted copy of `data` to `url` (used for
    /// attachments and backups — the plaintext never lands on disk).
    static func writeEncrypted(_ data: Data, to url: URL) throws {
        try encrypt(data).write(to: url, options: .atomic)
    }

    static func readEncrypted(from url: URL) throws -> Data {
        try decrypt(Data(contentsOf: url))
    }

    // MARK: - Temporary decrypted copies

    /// Private (0700) directory holding decrypted attachment copies handed to
    /// external apps. Swept on launch and at quit.
    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("omega-journal-open", isDirectory: true)
    }

    /// Decrypts a file into the private temp directory (attachments opened in
    /// external apps need a real file). Cleaned by `cleanupTemporaryFiles()`.
    static func decryptedTemporaryFile(from url: URL, preferredName: String) throws -> URL {
        let plain = try readEncrypted(from: url)
        let dir = temporaryDirectory
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Tighten even if the directory pre-existed with looser permissions.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let safeName = preferredName.replacingOccurrences(of: "/", with: "-")
        let sub = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = sub.appendingPathComponent(safeName)
        try plain.write(to: temp, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        return temp
    }

    /// Removes every decrypted temp copy, including legacy `omega-open-*`
    /// files that older builds left directly in the system temp directory.
    static func cleanupTemporaryFiles() {
        let fm = FileManager.default
        try? fm.removeItem(at: temporaryDirectory)
        if let legacy = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
            for url in legacy where url.lastPathComponent.hasPrefix("omega-open-") {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static var cleanupInstalled = false
    /// Sweeps now (launch) and again when the app terminates.
    static func installTemporaryFileCleanup() {
        guard !cleanupInstalled else { return }
        cleanupInstalled = true
        cleanupTemporaryFiles()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in cleanupTemporaryFiles() }
    }

    // MARK: - Backup recovery

    /// Decrypts a backup file produced by `backupDatabase()` to a plaintext
    /// SQLite database the sqlite3 CLI can open. This is the documented
    /// disaster-recovery path for encrypted backups.
    static func decryptBackup(at sealedURL: URL, to plaintextURL: URL) throws {
        try readEncrypted(from: sealedURL).write(to: plaintextURL, options: .atomic)
    }
}
