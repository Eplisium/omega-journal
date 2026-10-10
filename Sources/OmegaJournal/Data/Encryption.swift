import Foundation
import AppKit
import CryptoKit
import Security

/// At-rest encryption for journal content (audit item S1 — the app's core
/// promise is privacy, and the SQLite file + auto-backups previously stored
/// everything in plaintext, readable by any process with disk access).
///
/// Scheme: a single 256-bit AES-GCM key lives in the Keychain
/// (`kSecClassGenericPassword`, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
/// and never touches disk. Body text and attachment files are sealed as
/// AES-GCM containers; auto-backup files are sealed whole.
enum JournalCrypto {

    private static let service = "com.omegajournal.encryption"
    private static let account = "journal-content-key"

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
        let key = try loadOrCreateKey(service: service, account: account, allowCreate: { !encryptedDataExists() })
        cachedKey = key
        return key
    }

    /// Keychain logic with injectable identity so tests never touch the real key.
    static func loadOrCreateKey(service: String, account: String, allowCreate: () -> Bool) throws -> SymmetricKey {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw KeyError.keychainUnavailable(status) }
        guard allowCreate() else { throw KeyError.keyMissing }

        let newKey = SymmetricKey(size: .bits256)
        let newData = newKey.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: newData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeyError.keyStoreFailed(addStatus) }
        return newKey
    }

    static func deleteKeyForTesting(service: String, account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
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
