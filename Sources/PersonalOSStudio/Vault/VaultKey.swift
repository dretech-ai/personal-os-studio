import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Where the vault's symmetric key lives at runtime. Protocol-isolated so tests
/// inject a fixed key and never touch (or prompt for) the login Keychain.
protocol VaultKeyStore {
    func load() -> SymmetricKey?
    func save(_ key: SymmetricKey) throws
    func delete()
}

/// Keychain-backed store: one generic password entry. The key bytes never touch disk.
struct KeychainVaultKeyStore: VaultKeyStore {
    static let service = "com.dretech.PersonalOSStudio.vault"
    static let account = "vault-key"

    func load() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    func save(_ key: SymmetricKey) throws {
        delete()
        let data = key.withUnsafeBytes { Data($0) }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrLabel as String: "Personal OS Studio — PII vault key",
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultError.keychain("SecItemAdd failed (\(status))")
        }
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum VaultError: LocalizedError {
    case keychain(String)
    case noKey
    case badPassphrase
    case corrupt(String)
    case nothingToSnapshot

    var errorDescription: String? {
        switch self {
        case .keychain(let s): return "Keychain error: \(s)"
        case .noKey: return "The vault key is not available — enable the vault or import a key file."
        case .badPassphrase: return "Wrong passphrase (or the key file is damaged)."
        case .corrupt(let s): return "Vault data unreadable: \(s)"
        case .nothingToSnapshot: return "No content documents to snapshot."
        }
    }
}

/// Passphrase wrap/unwrap for machine migration and disaster recovery: the vault key
/// is sealed (AES-GCM) under a PBKDF2-derived KEK and written as a small JSON file.
/// Losing both the Keychain entry and this file (or its passphrase) loses the vault.
enum VaultKeyExport {
    struct Envelope: Codable {
        let version: Int
        let salt: Data
        let iterations: Int
        let sealed: Data      // AES.GCM combined box of the 32 raw key bytes
    }

    static let defaultIterations = 600_000

    /// PBKDF2-HMAC-SHA256 → 256-bit key-encryption key.
    static func kek(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        var derived = Data(count: 32)
        let pw = Array(passphrase.utf8)
        derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.map { Int8(bitPattern: $0) }, pw.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return SymmetricKey(data: derived)
    }

    /// Wrap `key` under a passphrase → `.vaultkey` file contents (JSON).
    static func wrap(key: SymmetricKey, passphrase: String,
                     iterations: Int = defaultIterations) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        let kek = kek(passphrase: passphrase, salt: salt, iterations: iterations)
        let raw = key.withUnsafeBytes { Data($0) }
        let box = try AES.GCM.seal(raw, using: kek)
        let envelope = Envelope(version: 1, salt: salt, iterations: iterations,
                                sealed: box.combined!)
        return try JSONEncoder().encode(envelope)
    }

    /// Unwrap a `.vaultkey` file back into the vault key.
    static func unwrap(_ data: Data, passphrase: String) throws -> SymmetricKey {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw VaultError.corrupt("not a vault key file")
        }
        let kek = kek(passphrase: passphrase, salt: envelope.salt,
                      iterations: envelope.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
              let raw = try? AES.GCM.open(box, using: kek), raw.count == 32 else {
            throw VaultError.badPassphrase
        }
        return SymmetricKey(data: raw)
    }
}
