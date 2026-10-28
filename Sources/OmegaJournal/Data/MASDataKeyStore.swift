import Foundation
import CryptoKit
import Security

// MARK: - Key store abstraction (Mac App Store wave)
//
// The journal content key used to live only in the legacy file-based login
// keychain. The sandboxed App Store build keeps it in the data-protection
// keychain under the team's access group instead, but existing DMG users
// already have a key in the login keychain that encrypts every entry, backup
// and attachment. `MASDataKeyResolver` reads the data-protection keychain
// first, then the legacy one, copies (never moves) a legacy-only key forward,
// and silently falls back to the legacy keychain when the build has no
// `keychain-access-groups` entitlement (direct / dev builds).

/// Result of a single keychain read.
nonisolated enum MASDataKeyRead: Equatable {
    case found(Data)
    case notFound
    /// Any other status, e.g. `errSecMissingEntitlement` (-34018) when the
    /// build is not entitled to the data-protection keychain.
    case unavailable(OSStatus)
}

/// One place a content key can live. Tests use an in-memory fake; the app
/// uses `MASDataKeychainStore`.
nonisolated protocol MASDataKeyStore {
    func readKey() -> MASDataKeyRead
    /// Adds the key. Returns the `SecItemAdd`-style status.
    func addKey(_ data: Data) -> OSStatus
}

/// Real Keychain backends.
nonisolated struct MASDataKeychainStore: MASDataKeyStore {
    enum Kind: Equatable {
        /// Modern data-protection keychain, scoped to an access group.
        case dataProtection(accessGroup: String)
        /// The legacy file-based login keychain (what every build before the
        /// App Store wave used). Same query as before, no access group.
        case legacyLogin
    }

    let kind: Kind
    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if case .dataProtection(let group) = kind {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = group
        }
        return q
    }

    func readKey() -> MASDataKeyRead {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .unavailable(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
    }

    func addKey(_ data: Data) -> OSStatus {
        var add = baseQuery
        add[kSecValueData as String] = data
        // Honoured by the data-protection keychain; ignored (as before) by the
        // legacy file keychain.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }
}

/// Decides where the content key is read from and where a new one goes.
nonisolated struct MASDataKeyResolver {
    /// Where the returned key came from (diagnostics and tests).
    enum Origin: Equatable {
        /// Found in the data-protection keychain.
        case preferred
        /// Found only in the legacy keychain and copied into the
        /// data-protection keychain (legacy item kept).
        case legacyCopied
        /// Found only in the legacy keychain; copying it forward failed. The
        /// key still works — the copy is retried on the next launch.
        case legacyCopyFailed(OSStatus)
        /// Found in the legacy keychain; the data-protection keychain is not
        /// usable by this build (no entitlement), so nothing was copied.
        case legacyOnly
        /// No key anywhere and no encrypted data: a new key was stored here.
        case mintedPreferred
        case mintedLegacy
    }

    /// Data-protection keychain. `nil` = not applicable (legacy-only callers).
    let preferred: MASDataKeyStore?
    let legacy: MASDataKeyStore

    static let keyByteCount = 32

    /// Loads the key, copying a legacy-only key forward when possible. Mints
    /// a new key ONLY when `allowCreate()` says no encrypted data exists.
    /// Pass `{ false }` for a strictly load-only read (launch gate).
    func resolve(allowCreate: () -> Bool) throws -> (key: SymmetricKey, origin: Origin) {
        // 1. Data-protection keychain.
        var preferredUsable = false
        if let preferred {
            switch preferred.readKey() {
            case .found(let data) where data.count == Self.keyByteCount:
                return (SymmetricKey(data: data), .preferred)
            case .found:
                // Something malformed sits there; never overwrite it, never
                // trust it. Fall through to the legacy key.
                preferredUsable = false
            case .notFound:
                preferredUsable = true
            case .unavailable:
                // errSecMissingEntitlement (-34018) and friends: direct/dev
                // builds have no keychain-access-groups. Legacy only.
                preferredUsable = false
            }
        }

        // 2. Legacy login keychain.
        switch legacy.readKey() {
        case .found(let data):
            guard data.count == Self.keyByteCount else {
                throw JournalCrypto.KeyError.keychainUnavailable(errSecDecode)
            }
            let key = SymmetricKey(data: data)
            guard let preferred, preferredUsable else { return (key, .legacyOnly) }
            // Copy forward; never delete the legacy item (the DMG build keeps
            // reading it). A failed copy must not block launch.
            let status = preferred.addKey(data)
            if status == errSecSuccess || status == errSecDuplicateItem {
                return (key, .legacyCopied)
            }
            return (key, .legacyCopyFailed(status))
        case .unavailable(let status):
            // Same as before the App Store wave: an unreadable legacy item is
            // an error, never a reason to mint (that could orphan data).
            throw JournalCrypto.KeyError.keychainUnavailable(status)
        case .notFound:
            break
        }

        // 3. Nothing stored anywhere. Mint only when no encrypted data exists.
        guard allowCreate() else { throw JournalCrypto.KeyError.keyMissing }
        let newKey = SymmetricKey(size: .bits256)
        let newData = newKey.withUnsafeBytes { Data($0) }
        if let preferred, preferredUsable {
            let status = preferred.addKey(newData)
            if status == errSecSuccess { return (newKey, .mintedPreferred) }
            if status == errSecDuplicateItem,
               case .found(let raced) = preferred.readKey(), raced.count == Self.keyByteCount {
                return (SymmetricKey(data: raced), .preferred)
            }
            // Data-protection write refused (e.g. entitlement missing after
            // all): fall back to the legacy keychain below.
        }
        let status = legacy.addKey(newData)
        guard status == errSecSuccess else { throw JournalCrypto.KeyError.keyStoreFailed(status) }
        return (newKey, .mintedLegacy)
    }
}
