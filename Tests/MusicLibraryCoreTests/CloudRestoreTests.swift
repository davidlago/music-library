import Foundation
import Testing
@testable import MusicLibraryCore

/// Restoring from the iCloud backup, against a plain folder (`FolderCloudStore`).
@Suite struct CloudRestoreTests {
    let identity = CloudBackupIdentity(macID: "mac-1", macName: "Studio Mac", appVersion: "1.30.0")
    let limits = CloudUploadLimits(snapshotTimeout: .seconds(1), poll: .milliseconds(1))
    let cover = "0f8fad5b-d9cb-469f-a165-70867728950e-0000abcd.jpg"

    /// A library with likes, plays and a CD with its own cover, backed up with `scope`.
    func backedUp(_ scope: CloudBackupScope, at now: Date = Date(timeIntervalSince1970: 1_793_456_712)) async throws
        -> (f: SyncFixture, store: FolderCloudStore, result: CloudBackupResult) {
        let f = try SyncFixture()
        try f.db.setLiked([f.tracks[0].id], true)
        try f.db.recordPlay(trackId: f.tracks[1].id, startedAt: now, listened: 100, counted: true)
        var item = CollectionItem(id: "0f8fad5b-d9cb-469f-a165-70867728950e", medium: .cd, album: "First", artist: "Artist")
        item.coverFile = cover
        try f.db.saveCollectionItem(item)
        try f.write("Music/Collection Covers/\(cover)", bytes: 40)
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        let result = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: scope,
                                                   music: f.tracks, scratch: try TestSupport.tempDir(), now: now, limits: limits)
        return (f, store, result)
    }

    @Test func restoresTheWholeLibraryIntoANewFolder() async throws {
        let (f, store, backup) = try await backedUp(.everything)
        let root = try TestSupport.tempDir().appendingPathComponent("Restored")
        let result = try await CloudRestore.restore(backup.snapshot, from: store, to: root, scratch: try TestSupport.tempDir())
        #expect(result.missing.isEmpty)
        #expect(result.files == 7)  // 3 songs, 2 album covers, the CD's cover, an artist photo

        let db = try LibraryLocation.openDatabase(root: root)
        #expect(db.libraryID() == f.db.libraryID())
        #expect(db.snapshotDate() == nil)
        #expect(try db.fetchAllTracks().map(\.path) == f.tracks.map(\.path))
        #expect(try db.likedTrackDates().keys.sorted() == [f.tracks[0].id])
        #expect(try db.plays().count == 1)
        let items = try db.collectionItems().items
        #expect(items.map(\.id) == ["0f8fad5b-d9cb-469f-a165-70867728950e"] && items.first?.coverFile == cover)
        for path in f.tracks.map(\.path) + ["Music/Collection Covers/\(cover)", "Music/Artist/First (2000)/cover.jpg", "Artist Images/artist.jpg"] {
            #expect(try Data(contentsOf: root.appendingPathComponent(path)) == Data(contentsOf: f.root.appendingPathComponent(path)), "\(path)")
        }
    }

    @Test func listsWhatTheBackupDoesNotHold() async throws {
        let (f, store, backup) = try await backedUp(.library)
        let root = try TestSupport.tempDir().appendingPathComponent("Restored")
        let result = try await CloudRestore.restore(backup.snapshot, from: store, to: root, scratch: try TestSupport.tempDir())
        #expect(result.missing == f.tracks.map(\.path))
        #expect(result.files == 4)
        #expect(FileManager.default.fileExists(atPath: LibraryLocation.databaseURL(root: root).path))
    }

    @Test func refusesAFolderInUse() async throws {
        let (_, store, backup) = try await backedUp(.library)
        let root = try TestSupport.tempDir()
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        await #expect(throws: CloudRestoreError.folderNotEmpty) {
            try await CloudRestore.restore(backup.snapshot, from: store, to: root, scratch: try TestSupport.tempDir())
        }
        #expect(!FileManager.default.fileExists(atPath: LibraryLocation.databaseURL(root: root).path))
    }

    @Test func pathsInTheCopyStayInsideTheFolder() async throws {
        let f = try SyncFixture()
        try f.db.exec("UPDATE tracks SET path='../../escape.flac' WHERE id=?", [.int(f.tracks[0].id)])
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        let backup = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .everything,
                                                   music: try f.db.fetchAllTracks(), scratch: try TestSupport.tempDir(), limits: limits)
        let parent = try TestSupport.tempDir()
        let root = parent.appendingPathComponent("a/b/Restored")
        let result = try await CloudRestore.restore(backup.snapshot, from: store, to: root, scratch: try TestSupport.tempDir())
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("a/escape.flac").path))
        #expect(result.files == 5 && result.missing.isEmpty)
    }

    @Test func restoresTheDatabaseInPlaceAndKeepsTheOneBefore() async throws {
        let (f, store, backup) = try await backedUp(.library)
        // Changes after the backup: another like, a playlist, a catalog entry (a cache the backup leaves out).
        try f.db.setLiked([f.tracks[2].id], true)
        _ = try f.db.createPlaylist(name: "After")
        try f.db.exec("INSERT INTO catalog_items(work_id,json,last_seen) VALUES('w','{}',0)")

        let before = try await CloudRestore.restoreDatabase(backup.snapshot, from: store, into: f.db, root: f.root,
                                                            scratch: try TestSupport.tempDir(), now: Date(timeIntervalSince1970: 1_793_460_000))
        #expect(before.lastPathComponent == "library-before-restore-2026-10-31T15-20-00Z.sqlite")
        #expect(try f.db.likedTrackDates().keys.sorted() == [f.tracks[0].id])
        #expect(try f.db.playlists().isEmpty)
        #expect(try f.db.query("SELECT COUNT(*) FROM catalog_items") { $0.int(0) }.first == 1)
        #expect(f.db.snapshotDate() == nil)
        #expect(try f.db.collectionItems().items.count == 1)

        let saved = try Database(snapshotAt: before.path)
        #expect(try saved.playlists().map(\.name) == ["After"])
        #expect(try saved.likedTrackDates().count == 2)
    }

    @Test func listsSnapshotsNewestFirstWithTheirCounts() async throws {
        let (f, store, first) = try await backedUp(.library)
        let second = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .library,
                                                   scratch: try TestSupport.tempDir(), now: first.snapshotAt + 3600, limits: limits)
        let listed = try CloudRestore.snapshots(in: store)
        #expect(listed.map(\.path) == [second.snapshot, first.snapshot])
        #expect(listed.map(\.isCurrent) == [true, false])
        let details = try await CloudRestore.details(of: first.snapshot, in: store, scratch: try TestSupport.tempDir())
        #expect(details == CloudSnapshotDetails(libraryID: f.db.libraryID(), tracks: 3, items: 1, plays: 1, likes: 1))
    }
}
