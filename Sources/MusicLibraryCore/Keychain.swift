import Foundation
import Security

/// Secrets (API keys, session keys, passwords) kept in the user's keychain instead of the plaintext preferences
/// plist. They're all stored in ONE generic-password item, as a small JSON dictionary, read once per launch:
/// the app is ad-hoc signed, so macOS treats every new build as a different app and asks to allow access once
/// per item. Values in the separate per-secret items older versions wrote move into the shared item the first
/// time they're read.
public struct KeychainStore: Sendable {
    public static let app = KeychainStore(service: "local.musiclibrary")

    public let service: String
    /// The account of the item holding every secret.
    static let sharedAccount = "secrets"

    public init(service: String) { self.service = service }

    private var cache: Cache { Cache.forService(service) }

    public func string(for account: String) -> String? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        let values = loaded()
        if let value = values[account] { return value }
        guard cache.legacyChecked.insert(account).inserted, let legacy = readItem(account) else { return nil }
        let value = String(decoding: legacy, as: UTF8.self)
        var updated = values
        updated[account] = value
        if save(updated) { deleteItem(account) }
        return value.isEmpty ? nil : value
    }

    /// Stores `value`, replacing any existing one; an empty value removes it.
    @discardableResult
    public func set(_ value: String, for account: String) -> Bool {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        var values = loaded()
        guard values[account] != (value.isEmpty ? nil : value) else { return true }
        if value.isEmpty { values.removeValue(forKey: account) } else { values[account] = value }
        // A value saved here supersedes an old separate item, which then isn't read again.
        cache.legacyChecked.insert(account)
        return save(values)
    }

    @discardableResult
    public func remove(_ account: String) -> Bool { set("", for: account) }

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

    /// Deletes the shared item and any separate items (tests, and starting over).
    public func removeAll() {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        cache.values = [:]
        cache.legacyChecked = []
    }

    // MARK: Items

    /// The shared dictionary, read from the keychain the first time (callers hold the lock).
    private func loaded() -> [String: String] {
        if let values = cache.values { return values }
        var values: [String: String] = [:]
        if let data = readItem(Self.sharedAccount),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            values = decoded
        }
        cache.values = values
        return values
    }

    private func save(_ values: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(values), writeItem(Self.sharedAccount, data) else { return false }
        cache.values = values
        return true
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func readItem(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func writeItem(_ account: String, _ data: Data) -> Bool {
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account)
        add.merge(update) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func deleteItem(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    /// The decoded dictionary per service, shared by every `KeychainStore` value for it.
    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: String]?
        /// Accounts whose old separate item has been looked for.
        var legacyChecked = Set<String>()

        private static let registryLock = NSLock()
        nonisolated(unsafe) private static var registry: [String: Cache] = [:]

        static func forService(_ service: String) -> Cache {
            registryLock.lock()
            defer { registryLock.unlock() }
            if let cache = registry[service] { return cache }
            let cache = Cache()
            registry[service] = cache
            return cache
        }
    }
}
