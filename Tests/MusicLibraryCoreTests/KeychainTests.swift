import Foundation
import Testing
@testable import MusicLibraryCore

@Suite(.serialized) struct KeychainStoreTests {
    let store = KeychainStore(service: "local.musiclibrary.tests.\(UUID().uuidString)")

    @Test func storesUpdatesAndRemoves() {
        defer { store.removeAll() }
        #expect(store.string(for: "secret") == nil)
        #expect(store.set("one", for: "secret"))
        #expect(store.string(for: "secret") == "one")
        #expect(store.set("two", for: "secret"))
        #expect(store.string(for: "secret") == "two")
        #expect(store.set("", for: "secret"))
        #expect(store.string(for: "secret") == nil)
    }

    @Test func migratesFromDefaultsAndDeletesThem() throws {
        let suite = "local.musiclibrary.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            store.removeAll()
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set("legacy-key", forKey: "lastfmSessionKey")
        #expect(store.migratedString(for: "sk", from: defaults, key: "lastfmSessionKey") == "legacy-key")
        #expect(defaults.object(forKey: "lastfmSessionKey") == nil)
        #expect(store.string(for: "sk") == "legacy-key")
        // The keychain value wins over a stale defaults entry, which is still deleted.
        defaults.set("stale", forKey: "lastfmSessionKey")
        #expect(store.migratedString(for: "sk", from: defaults, key: "lastfmSessionKey") == "legacy-key")
        #expect(defaults.object(forKey: "lastfmSessionKey") == nil)
    }

    /// The service's items by account (attributes first: the keychain won't return data for several items).
    private func items() -> [String: String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for account in rows.compactMap({ $0[kSecAttrAccount as String] as? String }) {
            let one: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
                                      kSecAttrAccount as String: account, kSecReturnData as String: true]
            var data: CFTypeRef?
            SecItemCopyMatching(one as CFDictionary, &data)
            out[account] = (data as? Data).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        return out
    }

    @Test func keepsEverySecretInOneItem() throws {
        defer { store.removeAll() }
        #expect(store.set("k", for: "apiKey") && store.set("s", for: "secret") && store.set("p", for: "password"))
        let stored = items()
        #expect(Array(stored.keys) == [KeychainStore.sharedAccount])
        let json = try #require(stored[KeychainStore.sharedAccount])
        #expect(try JSONDecoder().decode([String: String].self, from: Data(json.utf8)) == ["apiKey": "k", "secret": "s", "password": "p"])
        // Another store for the same service sees the same values.
        #expect(KeychainStore(service: store.service).string(for: "secret") == "s")
        store.remove("secret")
        #expect(store.string(for: "secret") == nil && store.string(for: "apiKey") == "k")
    }

    @Test func movesSeparateItemsIntoTheSharedOne() {
        defer { store.removeAll() }
        // An item as older versions wrote it: one per secret.
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
                                  kSecAttrAccount as String: "lastfmSessionKey", kSecValueData as String: Data("legacy".utf8)]
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(store.string(for: "lastfmSessionKey") == "legacy")
        #expect(items().keys.sorted() == [KeychainStore.sharedAccount])
        #expect(store.string(for: "lastfmSessionKey") == "legacy")
    }
}
