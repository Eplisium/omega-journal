import Foundation
import Testing
import CryptoKit
import Security
@testable import OmegaJournal

/// In-memory key store: never touches the real Keychain.
final class MASDataFakeKeyStore: MASDataKeyStore {
    var stored: Data?
    /// When set, every read reports this status (e.g. -34018).
    var readStatus: OSStatus?
    /// When set, every add returns this status and stores nothing.
    var addStatus: OSStatus?
    private(set) var reads = 0
    private(set) var adds = 0

    init(stored: Data? = nil, readStatus: OSStatus? = nil, addStatus: OSStatus? = nil) {
        self.stored = stored
        self.readStatus = readStatus
        self.addStatus = addStatus
    }

    func readKey() -> MASDataKeyRead {
        reads += 1
        if let readStatus { return .unavailable(readStatus) }
        return stored.map { .found($0) } ?? .notFound
    }

    func addKey(_ data: Data) -> OSStatus {
        adds += 1
        if let addStatus { return addStatus }
        if stored != nil { return errSecDuplicateItem }
        stored = data
        return errSecSuccess
    }
}

@Suite("MAS data: key store resolution")
struct MASDataKeyStoreTests {
    static let missingEntitlement: OSStatus = -34018 // errSecMissingEntitlement

    static func randomKeyData() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    @Test("data-protection hit wins and the legacy keychain is never read")
    func dataProtectionHit() throws {
        let dpKey = Self.randomKeyData()
        let dp = MASDataFakeKeyStore(stored: dpKey)
        let legacy = MASDataFakeKeyStore(stored: Self.randomKeyData())
        let r = try MASDataKeyResolver(preferred: dp, legacy: legacy).resolve(allowCreate: { true })
        #expect(Self.bytes(r.key) == dpKey)
        #expect(r.origin == .preferred)
        #expect(legacy.reads == 0)
        #expect(dp.adds == 0 && legacy.adds == 0)
    }

    @Test("legacy-only key is copied into data protection and the legacy item is kept")
    func legacyOnlyIsCopied() throws {
        let legacyKey = Self.randomKeyData()
        let dp = MASDataFakeKeyStore()
        let legacy = MASDataFakeKeyStore(stored: legacyKey)
        let r = try MASDataKeyResolver(preferred: dp, legacy: legacy).resolve(allowCreate: { false })
        #expect(Self.bytes(r.key) == legacyKey)
        #expect(r.origin == .legacyCopied)
        #expect(dp.stored == legacyKey)
        #expect(legacy.stored == legacyKey) // never deleted: the DMG build still needs it
        // Next launch: served straight from data protection.
        let again = try MASDataKeyResolver(preferred: dp, legacy: legacy).resolve(allowCreate: { false })
        #expect(again.origin == .preferred)
        #expect(Self.bytes(again.key) == legacyKey)
    }

    @Test("data protection unavailable (missing entitlement) → legacy used for read and create")
    func dataProtectionUnavailable() throws {
        let legacyKey = Self.randomKeyData()
        let dp = MASDataFakeKeyStore(readStatus: Self.missingEntitlement, addStatus: Self.missingEntitlement)
        let legacy = MASDataFakeKeyStore(stored: legacyKey)
        let r = try MASDataKeyResolver(preferred: dp, legacy: legacy).resolve(allowCreate: { true })
        #expect(Self.bytes(r.key) == legacyKey)
        #expect(r.origin == .legacyOnly)
        #expect(dp.adds == 0)

        // No key anywhere on such a build: the new key goes to the legacy keychain.
        let emptyLegacy = MASDataFakeKeyStore()
        let minted = try MASDataKeyResolver(preferred: dp, legacy: emptyLegacy).resolve(allowCreate: { true })
        #expect(minted.origin == .mintedLegacy)
        #expect(dp.adds == 0)
        #expect(emptyLegacy.stored == Self.bytes(minted.key))
    }

    @Test("no key anywhere + encrypted data exists → refuses to mint")
    func refusesToMintOverEncryptedData() {
        let dp = MASDataFakeKeyStore()
        let legacy = MASDataFakeKeyStore()
        #expect(throws: JournalCrypto.KeyError.keyMissing) {
            _ = try MASDataKeyResolver(preferred: dp, legacy: legacy).resolve(allowCreate: { false })
        }
        #expect(dp.adds == 0 && legacy.adds == 0)
        #expect(dp.stored == nil && legacy.stored == nil)
    }

    @Test("no key + empty journal → mints into the data-protection keychain only")
    func mintsIntoPreferredStore() throws {
        let dp = MASDataFakeKeyStore()
        let legacy = MASDataFakeKeyStore()
        let r = try MASDataKeyResolver(preferred: dp, legacy: legacy).resolve(allowCreate: { true })
        #expect(r.origin == .mintedPreferred)
        #expect(dp.stored == Self.bytes(r.key))
        #expect(legacy.stored == nil)
    }

    @Test("data-protection write refused at mint time falls back to legacy")
    func mintFallsBackWhenPreferredWriteFails() throws {
        let dp = MASDataFakeKeyStore(addStatus: Self.missingEntitlement)
        let legacy = MASDataFakeKeyStore()
        let r = try MASDataKeyResolver(preferred: dp, legacy: legacy).resolve(allowCreate: { true })
        #expect(r.origin == .mintedLegacy)
        #expect(legacy.stored == Self.bytes(r.key))
    }

    @Test("a failed copy into data protection does not block launch")
    func copyFailureDoesNotBlock() throws {
        let legacyKey = Self.randomKeyData()
        let dp = MASDataFakeKeyStore(addStatus: errSecInteractionNotAllowed)
        let legacy = MASDataFakeKeyStore(stored: legacyKey)
        let r = try MASDataKeyResolver(preferred: dp, legacy: legacy).resolve(allowCreate: { false })
        #expect(Self.bytes(r.key) == legacyKey)
        #expect(r.origin == .legacyCopyFailed(errSecInteractionNotAllowed))
        #expect(legacy.stored == legacyKey)
        // The JournalCrypto wrapper returns the key too (just logs).
        let viaCrypto = try JournalCrypto.loadOrCreateKey(
            using: MASDataKeyResolver(preferred: dp, legacy: legacy), allowCreate: { false })
        #expect(Self.bytes(viaCrypto) == legacyKey)
    }

    @Test("launch-gate fetch is load-only: copies an existing key, never mints")
    func gateFetchIsLoadOnly() {
        let dp = MASDataFakeKeyStore()
        let legacy = MASDataFakeKeyStore()
        #expect(JournalCrypto.fetchExistingKey(using: MASDataKeyResolver(preferred: dp, legacy: legacy)) == nil)
        #expect(dp.adds == 0 && legacy.adds == 0)

        let legacyKey = Self.randomKeyData()
        legacy.stored = legacyKey
        let fetched = JournalCrypto.fetchExistingKey(using: MASDataKeyResolver(preferred: dp, legacy: legacy))
        #expect(fetched.map(Self.bytes) == legacyKey)
        #expect(dp.stored == legacyKey)
    }

    @Test("unreadable legacy item is an error, never a reason to mint")
    func legacyErrorNeverMints() {
        let dp = MASDataFakeKeyStore()
        let legacy = MASDataFakeKeyStore(readStatus: errSecAuthFailed)
        #expect(throws: JournalCrypto.KeyError.keychainUnavailable(errSecAuthFailed)) {
            _ = try MASDataKeyResolver(preferred: dp, legacy: legacy).resolve(allowCreate: { true })
        }
        #expect(dp.adds == 0)
    }

    @Test("malformed data-protection item is ignored and never overwritten")
    func malformedPreferredIgnored() throws {
        let legacyKey = Self.randomKeyData()
        let dp = MASDataFakeKeyStore(stored: Data([1, 2, 3]))
        let legacy = MASDataFakeKeyStore(stored: legacyKey)
        let r = try MASDataKeyResolver(preferred: dp, legacy: legacy).resolve(allowCreate: { true })
        #expect(Self.bytes(r.key) == legacyKey)
        #expect(r.origin == .legacyOnly)
        #expect(dp.stored == Data([1, 2, 3]))
    }

    @Test("app resolver targets the App Store access group and the legacy identity")
    func appResolverIdentity() throws {
        let resolver = JournalCrypto.appKeyResolver()
        let dp = try #require(resolver.preferred as? MASDataKeychainStore)
        let legacy = try #require(resolver.legacy as? MASDataKeychainStore)
        #expect(dp.kind == .dataProtection(accessGroup: "WWC5HJN6AL.com.eplisium.omega-journal"))
        #expect(legacy.kind == .legacyLogin)
        #expect(dp.service == "com.omegajournal.encryption" && legacy.service == "com.omegajournal.encryption")
        #expect(dp.account == "journal-content-key" && legacy.account == "journal-content-key")
    }
}
