#if os(macOS)
import Foundation
import Testing
@testable import MusicLibraryCore

/// The Mac App Store build's pieces that run outside the sandbox too: the sample library's copy and the folder
/// bookmarks (which, unsandboxed, just pass paths through).
@Suite struct MacAppStoreTests {
    @Test func sampleCopyMovesItsHistoryUpToToday() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try LibrarySnapshot(root: SampleLibraryTests.root)
        let originalLast = try #require(original.plays.last?.startedAt)
        let now = originalLast.addingTimeInterval(10 * 86_400 + 3_600)

        let copy = try SampleLibraryCopy.install(from: SampleLibraryTests.root, to: dir.appendingPathComponent("Sample Library"), now: now)
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("Info.plist").path))
        let moved = try LibrarySnapshot(root: copy)
        #expect(moved.tracks.count == original.tracks.count)
        let last = try #require(moved.plays.last?.startedAt)
        #expect(last.timeIntervalSince(originalLast) == 10 * 86_400)
        #expect(now.timeIntervalSince(last) < 86_400)
        // Purchase days move by whole days too.
        let before = original.collection.items.compactMap(\.purchasedOn).map { $0.date() }
        let after = moved.collection.items.compactMap(\.purchasedOn).map { $0.date() }
        #expect(before.count == after.count && !before.isEmpty)
        for (b, a) in zip(before.sorted(), after.sorted()) {
            #expect(Calendar(identifier: .gregorian).dateComponents([.day], from: b, to: a).day == 10)
        }
        // A second install starts over from the bundle.
        try SampleLibraryCopy.install(from: SampleLibraryTests.root, to: copy, now: now)
        #expect(try LibrarySnapshot(root: copy).plays.last?.startedAt == last)
    }

    @Test @MainActor func bookmarksPassPathsThroughOutsideTheSandbox() throws {
        let suite = "bookmarks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = FolderBookmarks(defaults: defaults, sandboxed: false)
        #expect(bookmarks.resolve(path: "/tmp/somewhere", for: "libraryRoot")?.path == "/tmp/somewhere")
        #expect(bookmarks.resolve(path: nil, for: "libraryRoot") == nil)
        #expect(bookmarks.save(URL(fileURLWithPath: "/tmp/somewhere"), for: "libraryRoot"))
        #expect(defaults.data(forKey: "libraryRootBookmark") == nil)
    }

    @Test @MainActor func sandboxedBookmarksNeedOne() throws {
        let suite = "bookmarks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Without a bookmark the sandboxed build can't reach a stored path, and says so with nil.
        let bookmarks = FolderBookmarks(defaults: defaults, sandboxed: true)
        #expect(bookmarks.resolve(path: "/tmp/somewhere", for: "libraryRoot") == nil)
    }

    @Test func unsandboxedToolsIncludeInstalledOnes() {
        #expect(!AppSandbox.isActive)
        #expect(ToolLocator().searchPaths.contains("/opt/homebrew/bin"))
        #expect(AppSandbox.realHome.path == NSHomeDirectory())
    }
}
#endif
