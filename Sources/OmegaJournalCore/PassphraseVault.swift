import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Passphrase-encrypted export container
//
// Layout: "OJPX1" (5 bytes) | salt (16) | iterations (UInt32 BE) | AES-GCM combined (nonce|ciphertext|tag)
// Key = PBKDF2-HMAC-SHA256(passphrase, salt, iterations). Independent of the Keychain key,
// so an export can be opened on any machine with just the passphrase.

public enum PassphraseVault {
    public static let magic = Data("OJPX1".utf8)
    public static let defaultIterations: UInt32 = 250_000

    public enum VaultError: Error, LocalizedError, Equatable {
        case emptyPassphrase, notAVault, wrongPassphraseOrCorrupt, keyDerivationFailed
        public var errorDescription: String? {
            switch self {
            case .emptyPassphrase: return "Enter a passphrase."
            case .notAVault: return "This file is not a passphrase-protected Omega Journal export."
            case .wrongPassphraseOrCorrupt: return "Wrong passphrase, or the file is damaged."
            case .keyDerivationFailed: return "Could not derive an encryption key."
            }
        }
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(passphrase.utf8)
        let status = pw.withUnsafeBufferPointer { pwp in
            salt.withUnsafeBytes { sp in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(pwp.baseAddress!).assumingMemoryBound(to: CChar.self), pw.count,
                    sp.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, out.count)
            }
        }
        guard status == kCCSuccess else { throw VaultError.keyDerivationFailed }
        return SymmetricKey(data: Data(out))
    }

    public static func seal(_ plaintext: Data, passphrase: String, iterations: UInt32 = defaultIterations) throws -> Data {
        guard !passphrase.isEmpty else { throw VaultError.emptyPassphrase }
        var salt = Data(count: 16)
        let rc = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw VaultError.keyDerivationFailed }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: magic)
        guard let combined = box.combined else { throw VaultError.keyDerivationFailed }
        var out = magic
        out.append(salt)
        var it = iterations.bigEndian
        out.append(Data(bytes: &it, count: 4))
        out.append(combined)
        return out
    }

    public static func isVault(_ data: Data) -> Bool { data.starts(with: magic) }

    public static func open(_ sealed: Data, passphrase: String) throws -> Data {
        guard isVault(sealed), sealed.count > magic.count + 16 + 4 + 28 else { throw VaultError.notAVault }
        guard !passphrase.isEmpty else { throw VaultError.emptyPassphrase }
        let base = sealed.startIndex + magic.count
        let salt = sealed.subdata(in: base..<base + 16)
        let itData = sealed.subdata(in: base + 16..<base + 20)
        let iterations = itData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard iterations >= 1, iterations <= 10_000_000 else { throw VaultError.notAVault }
        let body = sealed.subdata(in: base + 20..<sealed.endIndex)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: body), using: key, authenticating: magic)
        } catch {
            throw VaultError.wrongPassphraseOrCorrupt
        }
    }
}
