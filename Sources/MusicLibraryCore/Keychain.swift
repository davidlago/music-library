import Foundation
import Security

/// Generic-password items in the user's keychain, one per account name, under a single service.
/// Used for API keys, secrets and session keys so they aren't kept in the plaintext preferences plist.
public struct KeychainStore: Sendable {
    public static let app = KeychainStore(service: "local.musiclibrary")

    public let service: String

    public init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func string(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, replacing any existing item; an empty value removes the item.
    @discardableResult
    public func set(_ value: String, for account: String) -> Bool {
        if value.isEmpty { return remove(account) }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account)
        add.merge(update) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func remove(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Reads `account`, first moving a value left in `defaults` under `key` (by older versions) into the
    /// keychain. The defaults entry is deleted once the keychain holds the value.
    public func migratedString(for account: String, from defaults: UserDefaults, key: String) -> String? {
        let stored = string(for: account)
        guard let legacy = defaults.string(forKey: key) else { return stored }
        if stored != nil || legacy.isEmpty || set(legacy, for: account) {
            defaults.removeObject(forKey: key)
        }
        return stored ?? (legacy.isEmpty ? nil : legacy)
    }
}
