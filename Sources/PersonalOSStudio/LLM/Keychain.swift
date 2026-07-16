import Foundation
import Security

/// Minimal wrapper over the macOS Keychain for storing LLM API keys.
/// Keys are stored as generic passwords under one service, keyed by provider id.
/// Secrets never touch UserDefaults and are never logged.
enum Keychain {
    static let service = "com.dretech.PersonalOSStudio.llm"

    /// Store (or replace) the secret for `account`. Passing an empty string deletes it.
    @discardableResult
    static func set(_ secret: String, account: String) -> Bool {
        guard !secret.isEmpty else { return delete(account: account) }
        let data = Data(secret.utf8)

        // Delete any existing item first so we can cleanly re-add.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Read the secret for `account`, or nil if none is stored.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(account: String) -> Bool {
        get(account: account) != nil
    }
}
