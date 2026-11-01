import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct CloudContainerTests {
    @Test func acceptsWellFormedIdentifiers() {
        #expect(CloudContainer.identifier(from: "iCloud.io.github.davidlago.MusicLibrary") == "iCloud.io.github.davidlago.MusicLibrary")
        #expect(CloudContainer.identifier(from: "iCloud.com.example-team.app2") != nil)
    }

    @Test func refusesEverythingElse() {
        for value: Any? in [nil, 42, "", "iCloud.", "iCloud.single", "io.github.davidlago.MusicLibrary",
                            "icloud.io.github.x", "iCloud.$(APP_BUNDLE_ID)", "$(ICLOUD_CONTAINER)", "iCloud.a..b",
                            "iCloud.a.b.", "iCloud.a b.c", "iCloud.a/b.c", "iCloud.é.com",
                            "iCloud.a." + String(repeating: "b", count: 250)] {
            #expect(CloudContainer.identifier(from: value) == nil, "\(String(describing: value))")
        }
    }
}

@Suite(.serialized) struct DefaultsImportTests {
    let old = "local.musiclibrary.tests.old.\(UUID().uuidString)"
    let new = "local.musiclibrary.tests.new.\(UUID().uuidString)"

    private func withDomains(_ body: (UserDefaults, UserDefaults) throws -> Void) throws {
        let oldDefaults = try #require(UserDefaults(suiteName: old))
        let newDefaults = try #require(UserDefaults(suiteName: new))
        defer {
            oldDefaults.removePersistentDomain(forName: old)
            newDefaults.removePersistentDomain(forName: new)
        }
        try body(oldDefaults, newDefaults)
    }

    @Test func copiesTheOldSettingsOnce() throws {
        try withDomains { oldDefaults, newDefaults in
            oldDefaults.set("/Volumes/Music/Library", forKey: "libraryRoot")
            oldDefaults.set(["a", "b"], forKey: "exportList")
            oldDefaults.set(3, forKey: "count")
            newDefaults.set("light", forKey: "appearance")
            oldDefaults.set("dark", forKey: "appearance")

            #expect(DefaultsImport.run(from: old, into: newDefaults, domain: new) == 3)
            #expect(newDefaults.string(forKey: "libraryRoot") == "/Volumes/Music/Library")
            #expect(newDefaults.stringArray(forKey: "exportList") == ["a", "b"])
            #expect(newDefaults.integer(forKey: "count") == 3)
            // What the new build already has wins.
            #expect(newDefaults.string(forKey: "appearance") == "light")

            // Later changes to the old domain (an older build run again) don't come over.
            oldDefaults.set("/elsewhere", forKey: "libraryRoot")
            oldDefaults.set(true, forKey: "added")
            #expect(DefaultsImport.run(from: old, into: newDefaults, domain: new) == 0)
            #expect(newDefaults.string(forKey: "libraryRoot") == "/Volumes/Music/Library")
            #expect(newDefaults.object(forKey: "added") == nil)
            // The old domain is left as it was, so going back to the older build keeps its settings.
            #expect(oldDefaults.string(forKey: "libraryRoot") == "/elsewhere")
        }
    }

    @Test func marksTheImportEvenWithNothingToCopy() throws {
        try withDomains { oldDefaults, newDefaults in
            #expect(DefaultsImport.run(from: old, into: newDefaults, domain: new) == 0)
            oldDefaults.set("/Volumes/Music/Library", forKey: "libraryRoot")
            #expect(DefaultsImport.run(from: old, into: newDefaults, domain: new) == 0)
            #expect(newDefaults.object(forKey: "libraryRoot") == nil)
        }
    }
}
