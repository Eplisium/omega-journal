import Foundation
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

    // MARK: - Key management

    private static var cachedKey: SymmetricKey?

    /// Loads the key from the Keychain, creating and storing it on first use.
    /// Fatal only if the Keychain itself is unusable (storing an empty key
    /// would silently fake protection).
    static func key() -> SymmetricKey {
        if let cachedKey { return cachedKey }

        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        }

        guard status == errSecItemNotFound else {
            fatalError("Keychain unavailable for journal encryption key: \(status)")
        }

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
        guard addStatus == errSecSuccess else {
            fatalError("Could not store journal encryption key in Keychain: \(addStatus)")
        }
        cachedKey = newKey
        return newKey
    }

    // MARK: - Seal / open

    static func encrypt(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key())
        guard let combined = box.combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    static func decrypt(_ sealed: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: key())
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

    /// Decrypts a file to a caller-managed temporary location (attachments
    /// opened in external apps need a real file). Caller removes the temp.
    static func decryptedTemporaryFile(from url: URL, preferredName: String) throws -> URL {
        let plain = try readEncrypted(from: url)
        let safeName = preferredName.replacingOccurrences(of: "/", with: "-")
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-open-\(UUID().uuidString)-\(safeName)")
        try plain.write(to: temp, options: .atomic)
        return temp
    }

    // MARK: - Backup recovery

    /// Decrypts a backup file produced by `backupDatabase()` to a plaintext
    /// SQLite database the sqlite3 CLI can open. This is the documented
    /// disaster-recovery path for encrypted backups.
    static func decryptBackup(at sealedURL: URL, to plaintextURL: URL) throws {
        try readEncrypted(from: sealedURL).write(to: plaintextURL, options: .atomic)
    }
}
