import Testing
import Foundation
import CryptoKit
@testable import OmegaJournal

/// The launch gate fetches the Keychain key off the main thread BEFORE the
/// database is open, so it must be strictly load-only: with no database
/// probes registered yet, a "create if missing" fetch could mint a fresh key
/// and orphan existing encrypted entries.
@Suite("Launch key prefetch", .serialized)
struct LaunchKeyPrefetchTests {
    @Test("prefetch never creates a key when none exists")
    func neverMints() {
        let service = "com.omegajournal.tests.\(UUID().uuidString)"
        defer { JournalCrypto.deleteKeyForTesting(service: service, account: "k") }
        #expect(JournalCrypto.fetchExistingKey(service: service, account: "k") == nil)
        // Still nothing stored afterwards: a strict load must also miss.
        #expect(throws: JournalCrypto.KeyError.keyMissing) {
            _ = try JournalCrypto.loadOrCreateKey(service: service, account: "k", allowCreate: { false })
        }
    }

    @Test("prefetch returns the stored key unchanged")
    func returnsExisting() throws {
        let service = "com.omegajournal.tests.\(UUID().uuidString)"
        defer { JournalCrypto.deleteKeyForTesting(service: service, account: "k") }
        let stored = try JournalCrypto.loadOrCreateKey(service: service, account: "k", allowCreate: { true })
        let fetched = try #require(JournalCrypto.fetchExistingKey(service: service, account: "k"))
        #expect(fetched.withUnsafeBytes { Data($0) } == stored.withUnsafeBytes { Data($0) })
    }
}
