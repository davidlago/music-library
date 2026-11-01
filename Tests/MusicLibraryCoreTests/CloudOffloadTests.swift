import Foundation
import Testing
@testable import MusicLibraryCore

/// Offloading music from the Mac (`docs/icloud-plan.md` D17–D20), against a plain folder (`FolderCloudStore`).
@Suite struct OffloadTests {
    let identity = CloudBackupIdentity(macID: "mac-1", macName: "Studio Mac", appVersion: "1.31.0")
    let limits = CloudUploadLimits(inFlightBytes: 1, runTime: .seconds(60), snapshotTimeout: .seconds(1), poll: .milliseconds(1))

    /// The fixture's library backed up with everything.
    func backedUp(now: Date = Date()) async throws -> (f: SyncFixture, store: FolderCloudStore) {
        let f = try SyncFixture()
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        _ = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .everything,
                                          music: f.tracks, scratch: try TestSupport.tempDir(), now: now, limits: limits)
        return (f, store)
    }

    func local(_ f: SyncFixture) -> [String: CloudBackupFile] {
        Dictionary(CloudBackupPlan.files(tracks: [], collectionCovers: [], music: f.tracks, root: f.root).map { ($0.path, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    func automatic(_ f: SyncFixture, _ store: CloudStore, now: Date, threshold: OffloadThreshold = .threeMonths,
                   lastPlayed: [Int64: Date] = [:], downloaded: [Int64: Date] = [:], kept: Set<Int64> = [],
                   protected: Set<Int64> = []) throws -> OffloadPlan {
        OffloadPlan(automatic: f.tracks, local: local(f), entries: try store.entries(), offloaded: Set(try f.db.offloadedTracks().keys),
                    lastPlayed: lastPlayed, downloaded: downloaded, kept: kept, protected: protected,
                    cutoff: try #require(threshold.cutoff(before: now)), now: now)
    }

    func musicInCloud(_ store: CloudStore) throws -> [String] {
        try store.entries().map(\.path).filter(CloudBackupPlan.isMusic).sorted()
    }

    @Test func albumsQualifyByTheirLastUse() async throws {
        let (f, store) = try await backedUp()
        let later = Date().addingTimeInterval(200 * 86400)
        let both = try automatic(f, store, now: later)
        #expect(both.albums.map(\.album) == ["First", "Second"])
        #expect(both.songs == 3 && both.bytes == f.tracks.reduce(0) { $0 + f.size($1.path) })
        // Played, or downloaded back, within the threshold: that album stays.
        let played = try automatic(f, store, now: later, lastPlayed: [f.tracks[1].id: later.addingTimeInterval(-10 * 86400)])
        #expect(played.albums.map(\.album) == ["Second"])
        let downloaded = try automatic(f, store, now: later, downloaded: [f.tracks[2].id: later.addingTimeInterval(-10 * 86400)])
        #expect(downloaded.albums.map(\.album) == ["First"])
        // Each threshold against the day the songs were added.
        #expect(try automatic(f, store, now: later, threshold: .sixMonths).albums.count == 2)
        #expect(try automatic(f, store, now: later, threshold: .oneYear).albums.isEmpty)
        #expect(try automatic(f, store, now: Date().addingTimeInterval(40 * 86400), threshold: .oneMonth).albums.count == 2)
        #expect(try automatic(f, store, now: Date().addingTimeInterval(40 * 86400)).albums.isEmpty)
        #expect(OffloadThreshold.off.cutoff(before: later) == nil)
    }

    @Test func keptQueuedAndUnbackedUpAlbumsStay() async throws {
        let (f, store) = try await backedUp()
        let later = Date().addingTimeInterval(200 * 86400)
        #expect(try automatic(f, store, now: later, kept: [f.tracks[0].id]).albums.map(\.album) == ["Second"])
        #expect(try automatic(f, store, now: later, protected: [f.tracks[2].id]).albums.map(\.album) == ["First"])
        // Still uploading: nothing.
        let offline = try OffloadPlan(automatic: f.tracks, local: local(f), entries: OfflineStore(base: store).entries(), offloaded: [],
                                      lastPlayed: [:], downloaded: [:], kept: [], protected: [],
                                      cutoff: #require(OffloadThreshold.threeMonths.cutoff(before: later)), now: later)
        #expect(offline.albums.isEmpty)
        // Changed since the backup (a retag that kept the size): its album waits for the next backup.
        try f.write(f.tracks[2].path, bytes: Int(f.size(f.tracks[2].path)), fill: 0xCD)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: f.root.appendingPathComponent(f.tracks[2].path).path)
        #expect(try automatic(f, store, now: later).albums.map(\.album) == ["First"])
        // Picked by hand: the same check, song by song.
        let chosen = OffloadPlan(chosen: f.tracks, local: local(f), entries: try store.entries(), offloaded: [], protected: [f.tracks[1].id])
        #expect(chosen.tracks.map(\.trackID) == [f.tracks[0].id] && chosen.notInBackup == 1)
    }

    @Test func aFileIsDeletedOnlyOnceTheBackupHoldsIt() async throws {
        let (f, store) = try await backedUp()
        let plan = OffloadPlan(chosen: f.tracks, local: local(f), entries: try store.entries(), offloaded: [], protected: [])
        #expect(plan.songs == 3)
        // Changed after the plan was made: left alone.
        try f.write(f.tracks[0].path, bytes: 5)
        // Not uploaded after all: left alone.
        let notYet = try CloudBackup.offload(plan.tracks, database: f.db, root: f.root, store: OfflineStore(base: store))
        #expect(notYet.files == 0 && notYet.skipped.count == 3)
        #expect(try f.db.offloadedTracks().isEmpty)

        let result = try CloudBackup.offload(plan.tracks, database: f.db, root: f.root, store: store)
        #expect(result.files == 2 && result.skipped == [f.tracks[0].id])
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.tracks[0].path).path))
        for track in f.tracks.dropFirst() { #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(track.path).path)) }
        #expect(Set(try f.db.offloadedTracks().keys) == Set(f.tracks.dropFirst().map(\.id)))
        // Covers stay on the Mac.
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Music/Artist/Second (2000)/cover.jpg").path))
        // The library keeps the songs.
        #expect(try f.db.trackCount() == 3)
    }

    @Test func offloadedSongsStayInTheBackupWhateverTheScope() async throws {
        let (f, store) = try await backedUp()
        let plan = OffloadPlan(chosen: f.tracks, local: local(f), entries: try store.entries(), offloaded: [], protected: [])
        _ = try CloudBackup.offload(plan.tracks, database: f.db, root: f.root, store: store)
        let music = try musicInCloud(store)
        #expect(music.count == 3)

        // A smaller scope, nothing chosen, Delete Now and a month on: none of them is listed or deleted.
        let now = Date()
        for (scope, offset, deleting) in [(CloudBackupScope.library, 60.0, false), (.chosen, 120, false), (.chosen, 180, true), (.library, 31 * 86400, false)] {
            let result = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: scope,
                                                       music: [], scratch: try TestSupport.tempDir(), now: now + offset,
                                                       deletingRemovedNow: deleting, limits: limits)
            #expect(result.removed == 0 && result.purged == 0 && result.files == 0, "\(scope)")
            #expect(try musicInCloud(store) == music)
        }
        #expect(CloudBackup.awaitingDeletion(in: store) == (0, 0))
        #expect(try CloudBackup.manifest(in: store)?.musicBytes == plan.bytes)

        // Removing an offloaded song from the library lists its file like any other.
        try f.db.deleteTrack(id: f.tracks[1].id)
        #expect(try f.db.offloadedTracks().count == 2)
        let removed = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .library,
                                                    scratch: try TestSupport.tempDir(), now: now + 32 * 86400, limits: limits)
        #expect(removed.removed == 1)
        #expect(CloudRemoval.decode(try store.read(CloudRemoval.path, limit: 1 << 20) ?? Data()).map(\.path) == [f.tracks[1].path])
    }

    @Test func downloadingBackRestoresTheFileAsItWas() async throws {
        let (f, store) = try await backedUp()
        let original = try Data(contentsOf: f.root.appendingPathComponent(f.tracks[2].path))
        let plan = OffloadPlan(chosen: f.tracks, local: local(f), entries: try store.entries(), offloaded: [], protected: [])
        _ = try CloudBackup.offload(plan.tracks, database: f.db, root: f.root, store: store)
        // The Organizer may have tidied the album's empty folder away.
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Music/Artist/Second (2000)/cover.jpg"))
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Music/Artist/Second (2000)"))

        let at = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() + 100)
        let rows = try f.db.offloadedTracks()
        let result = try await CloudBackup.download([try #require(rows[f.tracks[2].id])], database: f.db, root: f.root, store: store, now: at)
        #expect(result.files == 1)
        #expect(try Data(contentsOf: f.root.appendingPathComponent(f.tracks[2].path)) == original)
        #expect(try f.db.offloadedTracks().count == 2)
        #expect(try f.db.offloadDownloadDates()[f.tracks[2].id] == at)
        // It's a use: the album isn't offloaded again until it goes unplayed for the threshold.
        let downloaded = try f.db.offloadDownloadDates()
        #expect(try automatic(f, store, now: at.addingTimeInterval(30 * 86400), downloaded: downloaded).albums.isEmpty)
        // The backup sees it unchanged.
        let next = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .everything,
                                                 music: f.tracks, scratch: try TestSupport.tempDir(), limits: limits)
        #expect(next.files == 0)

        // A song the backup doesn't hold is skipped.
        try store.remove(f.tracks[0].path)
        let missing = try await CloudBackup.download([try #require(rows[f.tracks[0].id])], database: f.db, root: f.root, store: store)
        #expect(missing.files == 0 && missing.skipped == [f.tracks[0].id])
    }

    @Test func anotherLibrarysBackupIsNotReplacedWhileSongsAreOffloaded() async throws {
        let (f, store) = try await backedUp()
        let plan = OffloadPlan(chosen: [f.tracks[0]], local: local(f), entries: try store.entries(), offloaded: [], protected: [])
        _ = try CloudBackup.offload(plan.tracks, database: f.db, root: f.root, store: store)
        let other = try SyncFixture()
        _ = try await CloudBackup.publish(database: other.db, root: other.root, store: store,
                                          identity: CloudBackupIdentity(macID: "mac-2", macName: "Old Mac", appVersion: "1.30.0"),
                                          scope: .library, scratch: try TestSupport.tempDir(), now: Date() + 60, replacingOther: true, limits: limits)
        await #expect(throws: CloudBackupError.offloadedMusic(songs: 1)) {
            try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .library,
                                          scratch: try TestSupport.tempDir(), now: Date() + 120, replacingOther: true, limits: limits)
        }
    }

    @Test func restoresKeepOffloadedSongs() async throws {
        let (f, store) = try await backedUp()
        let before = try #require(try CloudBackup.manifest(in: store)?.current)
        let plan = OffloadPlan(chosen: f.tracks, local: local(f), entries: try store.entries(), offloaded: [], protected: [])
        _ = try CloudBackup.offload(plan.tracks, database: f.db, root: f.root, store: store)
        let after = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .everything,
                                                  music: f.tracks, scratch: try TestSupport.tempDir(), now: Date() + 60, limits: limits)

        // The database alone, back to before the offload: the songs are still offloaded.
        _ = try await CloudRestore.restoreDatabase(before, from: store, into: f.db, root: f.root, scratch: try TestSupport.tempDir())
        #expect(Set(try f.db.offloadedTracks().keys) == Set(f.tracks.map(\.id)))

        // Into a new folder: the songs are copied in, so none is offloaded there.
        let root = try TestSupport.tempDir().appendingPathComponent("Restored")
        let restored = try await CloudRestore.restore(after.snapshot, from: store, to: root, scratch: try TestSupport.tempDir())
        #expect(restored.missing.isEmpty)
        let db = try LibraryLocation.openDatabase(root: root)
        #expect(try db.offloadedTracks().isEmpty)
        #expect(try db.offloadDownloadDates().count == 3)
    }

    @Test func theBackupKeepsTheRecordAndThePhoneDoesNot() async throws {
        let (f, store) = try await backedUp()
        let plan = OffloadPlan(chosen: f.tracks, local: local(f), entries: try store.entries(), offloaded: [], protected: [])
        _ = try CloudBackup.offload(plan.tracks, database: f.db, root: f.root, store: store)
        let scratch = try TestSupport.tempDir()
        let backup = scratch.appendingPathComponent("backup.sqlite"), phone = scratch.appendingPathComponent("phone.sqlite")
        try f.db.writeBackupSnapshot(to: backup, scratch: scratch, snapshotAt: Date())
        try f.db.writeSyncSnapshot(to: phone, scratch: scratch)
        #expect(try Database(snapshotAt: backup.path).offloadedTracks().count == 3)
        #expect(try Database(snapshotAt: phone.path).offloadedTracks().isEmpty)
        // A copy from a version without the table reads as nothing offloaded.
        try f.db.exec("DROP TABLE offloaded_tracks")
        #expect(try f.db.offloadedTracks().isEmpty)
    }

    @Test func untrustedRowsAreIgnored() throws {
        let f = try SyncFixture()
        try f.db.markOffloaded([
            OffloadedTrack(trackID: f.tracks[0].id, path: "../../etc/passwd", size: 1, modified: Date(), offloadedAt: Date()),
            OffloadedTrack(trackID: f.tracks[1].id, path: f.tracks[0].path, size: 1, modified: Date(), offloadedAt: Date()),
            OffloadedTrack(trackID: f.tracks[2].id, path: f.tracks[2].path, size: -5, modified: Date(), offloadedAt: Date()),
        ])
        #expect(try f.db.offloadedTracks().isEmpty)
    }

    @Test func wiFiSyncKeepsOffloadedSongsAndLeavesTheRestToICloud() throws {
        let f = try SyncFixture()
        let size = f.size(f.tracks[0].path)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(f.tracks[0].path))
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(f.tracks[1].path))
        let offloaded = [f.tracks[0].path: size, f.tracks[1].path: f.size(f.tracks[2].path)]
        let phone = [SyncFileEntry(path: f.tracks[0].path, size: size)]
        let plan = SyncPlan(tracks: f.tracks, offloaded: offloaded, libraryRoot: f.root, phone: phone)
        #expect(plan.deletes.isEmpty && plan.missing == 0)
        #expect(!plan.sends.map(\.path).contains(f.tracks[0].path) && !plan.sends.map(\.path).contains(f.tracks[1].path))
        #expect(plan.sends.map(\.path).contains(f.tracks[2].path))
        #expect(plan.iCloudOnly == [f.tracks[1].id])
        #expect(plan.summary.iCloudOnly == [f.tracks[1].id])
        // An older Mac's plan says nothing about iCloud.
        let decoded = try JSONDecoder().decode(SyncPlanSummary.self, from: Data(#"{"files": 1, "bytes": 2, "deletes": 0}"#.utf8))
        #expect(decoded.iCloudOnly == nil)
    }
}

/// A Mac set up from iCloud (D21).
@Suite struct NewMacTests {
    let oldMac = CloudBackupIdentity(macID: "mac-1", macName: "Studio Mac", appVersion: "1.31.0")
    let newMac = CloudBackupIdentity(macID: "mac-2", macName: "Mac mini", appVersion: "1.31.0")
    let limits = CloudUploadLimits(inFlightBytes: 1, runTime: .seconds(60), snapshotTimeout: .seconds(1), poll: .milliseconds(1))

    @Test func movingSetsUpTheLibraryWithEverySongOffloaded() async throws {
        let f = try SyncFixture()
        try f.db.setLiked([f.tracks[0].id], true)
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        let now = Date()
        _ = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: oldMac, scope: .everything,
                                          music: f.tracks, scratch: try TestSupport.tempDir(), now: now, limits: limits)

        let root = try TestSupport.tempDir().appendingPathComponent("New Mac")
        let db = try LibraryLocation.openDatabase(root: root)
        let moved = try await CloudSetup.moveLibrary(from: store, into: db, root: root, scratch: try TestSupport.tempDir())
        #expect(moved.tracks == 3 && moved.offloaded == 3 && moved.scope == .everything && moved.macName == "Studio Mac")
        #expect(db.libraryID() == f.db.libraryID())
        #expect(try db.likedTrackDates().keys.contains(f.tracks[0].id))
        #expect(Set(try db.offloadedTracks().keys) == Set(f.tracks.map(\.id)))
        for path in ["Music/Artist/First (2000)/cover.jpg", "Music/Artist/Second (2000)/cover.jpg", "Artist Images/artist.jpg"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "\(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(f.tracks[0].path).path))
        #expect(db.snapshotDate() == nil)

        // The new Mac takes the backup over; nothing of the music is let go, even backing up less.
        _ = try await CloudBackup.publish(database: db, root: root, store: store, identity: newMac, scope: .library,
                                          scratch: try TestSupport.tempDir(), now: now + 60, takingOver: true, limits: limits)
        #expect(try CloudBackup.manifest(in: store)?.macID == "mac-2")
        #expect(CloudBackup.awaitingDeletion(in: store) == (0, 0))
        // The old Mac stops at its next backup, until it takes the backup back.
        await #expect(throws: CloudBackupError.movedToAnotherMac(macName: "Mac mini", snapshotAt: Date(timeIntervalSince1970: (now + 60).timeIntervalSince1970.rounded(.down)))) {
            try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: oldMac, scope: .everything,
                                          music: f.tracks, scratch: try TestSupport.tempDir(), now: now + 120, limits: limits)
        }
        // A song played on the new Mac comes down.
        let row = try #require(try db.offloadedTracks()[f.tracks[1].id])
        _ = try await CloudBackup.download([row], database: db, root: root, store: store)
        #expect(try Data(contentsOf: root.appendingPathComponent(f.tracks[1].path)) == Data(contentsOf: f.root.appendingPathComponent(f.tracks[1].path)))
    }

    @Test func movingNeedsAnEmptyLibraryAndABackup() async throws {
        let f = try SyncFixture()
        let empty = try FolderCloudStore(root: try TestSupport.tempDir())
        let root = try TestSupport.tempDir().appendingPathComponent("New Mac")
        let db = try LibraryLocation.openDatabase(root: root)
        await #expect(throws: CloudSetupError.noBackup) {
            try await CloudSetup.moveLibrary(from: empty, into: db, root: root, scratch: try TestSupport.tempDir())
        }
        #expect(CloudSetup.backup(in: empty) == nil)
        _ = try await CloudBackup.publish(database: f.db, root: f.root, store: empty, identity: oldMac, scope: .library,
                                          scratch: try TestSupport.tempDir(), limits: limits)
        #expect(CloudSetup.backup(in: empty)?.macName == "Studio Mac")
        await #expect(throws: CloudSetupError.libraryNotEmpty) {
            try await CloudSetup.moveLibrary(from: empty, into: f.db, root: f.root, scratch: try TestSupport.tempDir())
        }
    }
}
