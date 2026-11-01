import Foundation
import Testing
@testable import MusicLibraryCore

/// The phone reading the backup (P4), against a plain folder.
@Suite struct CloudReceiverTests {
    let identity = CloudBackupIdentity(macID: "mac-1", macName: "Studio Mac", appVersion: "1.30.0")
    let limits = CloudUploadLimits(snapshotTimeout: .seconds(1), poll: .milliseconds(1))
    let t0 = Date(timeIntervalSince1970: 1_793_456_712)

    func backup(_ f: SyncFixture, at now: Date, into store: FolderCloudStore? = nil) async throws -> FolderCloudStore {
        let store = try store ?? FolderCloudStore(root: try TestSupport.tempDir())
        _ = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .everything,
                                          music: f.tracks, scratch: try TestSupport.tempDir(), now: now, limits: limits)
        return store
    }

    func phone() throws -> URL { try TestSupport.tempDir().appendingPathComponent("Music Library") }

    @Test func aPhoneWithoutALibraryGetsOne() async throws {
        let f = try SyncFixture()
        let store = try await backup(f, at: t0)
        let root = try phone()
        let outcome = try await CloudReceiver.receive(from: store, into: root, scratch: try TestSupport.tempDir())
        #expect(outcome.database == .replaced && outcome.backupAt == t0 && outcome.macName == "Studio Mac")
        #expect(outcome.files == 3)  // two album covers and the artist photo; never music
        let db = try Database(snapshotAt: LibraryLocation.databaseURL(root: root).path)
        #expect(try db.trackCount() == 3 && db.snapshotDate() == t0 && db.libraryID() == f.db.libraryID())
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(f.tracks[0].path).path))
        #expect(try Data(contentsOf: root.appendingPathComponent("Artist Images/artist.jpg")).count == 70)
        // Nothing new the second time.
        let again = try await CloudReceiver.receive(from: store, into: root, scratch: try TestSupport.tempDir())
        #expect(again.database == .current && again.files == 0)
    }

    @Test func theNewestCopyWinsWhicheverWayItCame() async throws {
        let f = try SyncFixture()
        let store = try await backup(f, at: t0)
        let root = try phone()
        let target = LibraryLocation.databaseURL(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // A Wi-Fi sync an hour after the backup: iCloud's older copy doesn't replace it.
        try f.db.writeSyncSnapshot(to: target, scratch: try TestSupport.tempDir(), snapshotAt: t0 + 3600)
        #expect(try await CloudReceiver.receive(from: store, into: root, scratch: try TestSupport.tempDir()).database == .current)
        #expect(try Database(snapshotAt: target.path).snapshotDate() == t0 + 3600)

        // A newer backup does.
        try f.db.setLiked([f.tracks[1].id], true)
        _ = try await backup(f, at: t0 + 7200, into: store)
        #expect(try await CloudReceiver.receive(from: store, into: root, scratch: try TestSupport.tempDir()).database == .replaced)
        #expect(try Database(snapshotAt: target.path).snapshotDate() == t0 + 7200)

        // A copy from an older Mac, with no stamp, counts as older than any.
        try FileManager.default.removeItem(at: target)
        try f.db.vacuum(into: target.path)
        #expect(try Database(snapshotAt: target.path).snapshotDate() == nil)
        #expect(try await CloudReceiver.receive(from: store, into: root, scratch: try TestSupport.tempDir()).database == .replaced)
    }

    @Test func anotherLibraryIsLeftAlone() async throws {
        let mine = try SyncFixture(), other = try SyncFixture()
        let store = try await backup(mine, at: t0)
        let root = try phone()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = LibraryLocation.databaseURL(root: root)
        try other.db.writeSyncSnapshot(to: target, scratch: try TestSupport.tempDir(), snapshotAt: t0 - 3600)
        let outcome = try await CloudReceiver.receive(from: store, into: root, scratch: try TestSupport.tempDir())
        #expect(outcome.database == .otherLibrary && outcome.files == 0)
        #expect(try Database(snapshotAt: target.path).libraryID() == other.db.libraryID())
    }

    @Test func aNewerSchemaIsRefusedAndNothingIsReplaced() async throws {
        let f = try SyncFixture()
        let store = try await backup(f, at: t0)
        let manifest = try #require(try CloudBackup.manifest(in: store))
        let snapshot = store.root.appendingPathComponent(manifest.current)
        do {
            let raw = try Database(path: snapshot.path)
            try raw.exec("PRAGMA user_version=99")
        }
        let root = try phone()
        await #expect(throws: DatabaseError.self) {
            try await CloudReceiver.receive(from: store, into: root, scratch: try TestSupport.tempDir())
        }
        #expect(!FileManager.default.fileExists(atPath: LibraryLocation.databaseURL(root: root).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".sqlite") }.isEmpty)
    }

    @Test func onlyArtworkIsTakenAndChangedCoversComeAgain() async throws {
        let f = try SyncFixture()
        let store = try await backup(f, at: t0)
        // Something in the container that isn't artwork of the library.
        try FileManager.default.createDirectory(at: store.root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.root.appendingPathComponent("Notes/cover.jpg"))
        let root = try phone()
        _ = try await CloudReceiver.receive(from: store, into: root, scratch: try TestSupport.tempDir())
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes").path))

        try f.write("Music/Artist/First (2000)/cover.jpg", bytes: 99)
        _ = try await backup(f, at: t0 + 60, into: store)
        let outcome = try await CloudReceiver.receive(from: store, into: root, scratch: try TestSupport.tempDir())
        #expect(outcome.files == 1 && outcome.bytes == 99)
        #expect(LibraryExporter.size(of: root.appendingPathComponent("Music/Artist/First (2000)/cover.jpg")) == 99)
    }

    @Test func noBackupYet() async throws {
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        let outcome = try await CloudReceiver.receive(from: store, into: try phone(), scratch: try TestSupport.tempDir())
        #expect(outcome == CloudReceiveOutcome(database: .noBackup))
    }

    @Test func placeholdersStandForFilesNotDownloadedYet() throws {
        let dir = try TestSupport.tempDir()
        let album = dir.appendingPathComponent("Music/A/B (1)")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["NSURLNameKey": "cover.jpg", "NSURLFileSizeKey": 1234],
                                                       format: .binary, options: 0)
        try plist.write(to: album.appendingPathComponent(".cover.jpg.icloud"))
        try Data("x".utf8).write(to: album.appendingPathComponent(".DS_Store"))
        let store = try FolderCloudStore(root: dir, coordinated: true)
        let listed = try store.entries()
        #expect(listed == [CloudEntry(path: "Music/A/B (1)/cover.jpg", size: 1234, modified: nil, isLocal: false)])
        // A plain folder has no placeholders: a hidden file there is just hidden.
        #expect(try FolderCloudStore(root: dir).entries().isEmpty)
        #expect(FolderCloudStore.placeholder(album.appendingPathComponent(".icloud")) == nil)
    }
}
