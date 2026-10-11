import Foundation
import Testing
@testable import MusicLibraryCore

@Suite(.serialized) struct KeychainStoreTests {
    let store = KeychainStore(service: "local.musiclibrary.tests.\(UUID().uuidString)")

    @Test func storesUpdatesAndRemoves() {
        defer { store.remove("secret") }
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
            store.remove("sk")
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
}
