import Foundation
import Testing
@testable import MusicLibraryCore

/// The iCloud backup against a plain folder (`FolderCloudStore`); nothing here touches iCloud.
@Suite struct CloudSnapshotTests {
    @Test func copiesAreStampedAndTheLiveDatabaseIsNot() throws {
        let f = try SyncFixture()
        try f.db.exec("INSERT INTO catalog_items(work_id,json,last_seen) VALUES('w','{}',0)")
        try f.db.exec("INSERT INTO discogs_sync(item_id,basis,checked_at) VALUES('item','barcode',0)")
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        let backup = try TestSupport.tempDir().appendingPathComponent("backup.sqlite")
        try f.db.writeBackupSnapshot(to: backup, scratch: try TestSupport.tempDir(), snapshotAt: at)
        let copy = try Database(snapshotAt: backup.path)
        #expect(copy.snapshotDate() == at)
        #expect(copy.libraryID() == f.db.libraryID())
        #expect(try copy.trackCount() == 3)
        #expect(try copy.query("SELECT COUNT(*) FROM catalog_items") { $0.int(0) }.first == 0)
        // Kept, so a restore doesn't make the next Discogs sync add every copy again.
        #expect(try copy.query("SELECT COUNT(*) FROM discogs_sync") { $0.int(0) }.first == 1)
        #expect(f.db.snapshotDate() == nil)

        let sync = try TestSupport.tempDir().appendingPathComponent("sync.sqlite")
        try f.db.writeSyncSnapshot(to: sync, scratch: try TestSupport.tempDir(), snapshotAt: at.addingTimeInterval(60))
        let phone = try Database(snapshotAt: sync.path)
        #expect(phone.snapshotDate() == at.addingTimeInterval(60))
        #expect(try phone.query("SELECT COUNT(*) FROM discogs_sync") { $0.int(0) }.first == 0)
    }

    @Test func countsChangesOutsideTheCatalog() throws {
        let f = try SyncFixture()
        let start = f.db.changeCount
        try f.db.exec("INSERT INTO catalog_items(work_id,json,last_seen) VALUES('w','{}',0)")
        #expect(f.db.changeCount == start)
        try f.db.setLiked([f.tracks[0].id], true)
        #expect(f.db.changeCount > start)
    }

    @Test func namesRoundTripAndOthersAreRefused() {
        let date = Date(timeIntervalSince1970: 1_793_456_712)
        let path = CloudSnapshots.path(for: date)
        #expect(path == "Snapshots/2026-10-31T14-25-12Z.sqlite")
        #expect(CloudSnapshots.date(ofPath: path) == date)
        for bad in ["Snapshots/2026-10-31T14:25:12Z.sqlite", "Snapshots/2026-10-31T14-25-12Z.sqlite.partial", "Snapshots/x.sqlite",
                    "Snapshots/../2026-10-31T14-25-12Z.sqlite", "2026-10-31T14-25-12Z.sqlite", "Snapshots/2026-13-31T16-25-12Z.sqlite"] {
            #expect(CloudSnapshots.date(ofPath: bad) == nil, "\(bad)")
        }
    }

    @Test func retentionOverAYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
        var kept: [Date] = []
        // A backup every 6 hours, pruned after each.
        for step in 0..<(365 * 4) {
            let now = start.addingTimeInterval(TimeInterval(step) * 6 * 3600)
            kept.append(now)
            kept = Array(CloudSnapshots.kept(kept, now: now, calendar: calendar)).sorted()
        }
        let now = kept.last!
        #expect(kept.count <= 10 + 14 + 9)
        // The last 10 are all there.
        #expect(kept.suffix(10).count == 10 && kept.suffix(10).first == now.addingTimeInterval(-9 * 6 * 3600))
        // One for each of the last 14 days.
        for day in 0..<14 {
            let interval = calendar.dateInterval(of: .day, for: now.addingTimeInterval(TimeInterval(-day) * 86400))!
            #expect(kept.contains { interval.contains($0) }, "day \(day)")
        }
        // One for each of the last 8 weeks, and nothing much older.
        for week in 0..<8 {
            let interval = calendar.dateInterval(of: .weekOfYear, for: now.addingTimeInterval(TimeInterval(-week) * 7 * 86400))!
            #expect(kept.contains { interval.contains($0) }, "week \(week)")
        }
        #expect(kept.first! > now.addingTimeInterval(-9 * 7 * 86400))
    }
}

@Suite struct CloudBackupPlanTests {
    @Test func uploadsWhatChangedBySizeOrDate() throws {
        let f = try SyncFixture()
        let files = CloudBackupPlan.files(tracks: f.tracks, collectionCovers: [], root: f.root)
        #expect(files.map(\.path) == ["Music/Artist/First (2000)/cover.jpg", "Music/Artist/Second (2000)/cover.jpg", "Artist Images/artist.jpg"])

        let first = CloudBackupPlan(files: files, entries: [])
        #expect(first.uploads == files)
        #expect(first.bytes == 50 + 60 + 70)
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        for file in first.uploads { try store.upload(from: f.root.appendingPathComponent(file.path), to: file.path, modified: file.modified) }
        #expect(CloudBackupPlan(files: files, entries: try store.entries()).uploads.isEmpty)

        // A new cover of another size, and a retag that kept the size but not the date.
        try f.write("Music/Artist/First (2000)/cover.jpg", bytes: 55)
        let photo = f.root.appendingPathComponent("Artist Images/artist.jpg")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: photo.path)
        let again = CloudBackupPlan(files: CloudBackupPlan.files(tracks: f.tracks, collectionCovers: [], root: f.root),
                                    entries: try store.entries())
        #expect(again.uploads.map(\.path) == ["Music/Artist/First (2000)/cover.jpg", "Artist Images/artist.jpg"])
    }

    @Test func untrustedPathsAreIgnored() throws {
        let f = try SyncFixture()
        let outside = try TestSupport.tempDir()
        try Data("x".utf8).write(to: outside.appendingPathComponent("secret.jpg"))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("Artist Images/link.jpg"),
                                                   withDestinationURL: outside.appendingPathComponent("secret.jpg"))
        try f.write("Music/Collection Covers/0f8fad5b-d9cb-469f-a165-70867728950e-0000abcd.jpg", bytes: 40)
        let covers = ["Music/Collection Covers/0f8fad5b-d9cb-469f-a165-70867728950e-0000abcd.jpg", "../secret.jpg", "/etc/hosts",
                      "Notes/x.jpg", "Music/Collection Covers/missing-0000abcd.jpg"]
        let files = CloudBackupPlan.files(tracks: f.tracks, collectionCovers: covers, root: f.root)
        #expect(files.map(\.path) == ["Music/Artist/First (2000)/cover.jpg", "Music/Artist/Second (2000)/cover.jpg",
                                      covers[0], "Artist Images/artist.jpg"])

        // Entries from the container with unsafe paths never count as having a file.
        let entries = files.map { CloudEntry(path: "../" + $0.path, size: $0.size, modified: $0.modified) }
            + [CloudEntry(path: "/" + files[0].path, size: files[0].size, modified: files[0].modified)]
        #expect(CloudBackupPlan(files: files, entries: entries).uploads == files)

        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        for path in ["../x.jpg", "/tmp/x.jpg", "Notes/x.jpg", "Snapshots/x.sqlite", "library.sqlite"] {
            #expect(throws: CloudStoreError.unsafePath(path)) { try store.write(Data(), to: path) }
        }
    }
}

/// A container where iCloud never finishes uploading.
private struct OfflineStore: CloudStore {
    let base: FolderCloudStore
    func entries() throws -> [CloudEntry] { try base.entries().map { var e = $0; e.isUploaded = false; return e } }
    func upload(from source: URL, to path: String, modified: Date?) throws { try base.upload(from: source, to: path, modified: modified) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func read(_ path: String, limit: Int) throws -> Data? { try base.read(path, limit: limit) }
    func remove(_ path: String) throws { try base.remove(path) }
    func isUploaded(_ path: String) -> Bool { false }
    func evict(_ path: String) throws {}
    func waitUntilUploaded(_ path: String, timeout: Duration) async -> Bool { false }
    func copyOut(_ path: String, to destination: URL) async throws { try await base.copyOut(path, to: destination) }
}

/// A plain folder where iCloud uploads music only after being asked about it `delay` times (never, with nil), and
/// evictions are recorded.
private final class SlowStore: CloudStore, @unchecked Sendable {
    let base: FolderCloudStore
    let delay: Int?
    private let lock = NSLock()
    private var asked: [String: Int] = [:]
    private var _evicted: [String] = []
    var evicted: [String] { lock.withLock { _evicted } }

    init(base: FolderCloudStore, delay: Int?) { self.base = base; self.delay = delay }
    func entries() throws -> [CloudEntry] {
        try base.entries().map { var e = $0; if CloudBackupPlan.isMusic(e.path) { e.isUploaded = delay != nil }; return e }
    }
    func upload(from source: URL, to path: String, modified: Date?) throws { try base.upload(from: source, to: path, modified: modified) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func read(_ path: String, limit: Int) throws -> Data? { try base.read(path, limit: limit) }
    func remove(_ path: String) throws { try base.remove(path) }
    func isUploaded(_ path: String) -> Bool {
        guard CloudBackupPlan.isMusic(path) else { return true }
        return lock.withLock {
            asked[path, default: 0] += 1
            return delay.map { asked[path]! > $0 } ?? false
        }
    }
    func evict(_ path: String) throws { lock.withLock { _evicted.append(path) } }
    func copyOut(_ path: String, to destination: URL) async throws { try await base.copyOut(path, to: destination) }
}

@Suite struct CloudPublishTests {
    let identity = CloudBackupIdentity(macID: "mac-1", macName: "Studio Mac", appVersion: "1.30.0")

    @Test func publishesTheSnapshotThenTheManifest() async throws {
        let f = try SyncFixture()
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        let now = Date(timeIntervalSince1970: 1_793_456_712.6)
        let result = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .library,
                                                   scratch: try TestSupport.tempDir(), now: now)
        #expect(result.isCurrent && result.files == 3 && result.bytes == 180)
        #expect(result.snapshot == "Snapshots/2026-10-31T14-25-12Z.sqlite")

        let manifest = try #require(try CloudBackup.manifest(in: store))
        #expect(manifest.current == result.snapshot)
        #expect(manifest.libraryID == f.db.libraryID())
        #expect(manifest.macName == "Studio Mac" && manifest.scope == "library" && manifest.schemaVersion == 14)
        #expect(manifest.tracks == 3)
        #expect(manifest.musicBytes == f.tracks.reduce(0) { $0 + f.size($1.path) })
        let snapshot = try Database(snapshotAt: store.root.appendingPathComponent(result.snapshot).path)
        #expect(snapshot.snapshotDate() == manifest.snapshotAt)
        #expect(try snapshot.trackCount() == 3)
        // Music isn't part of "Library and covers".
        #expect(try store.entries().map(\.path).filter { $0.hasSuffix(".flac") }.isEmpty)

        // Later, with nothing new: only a snapshot.
        let later = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .library,
                                                  scratch: try TestSupport.tempDir(), now: now.addingTimeInterval(3600))
        #expect(later.files == 0)
        #expect(try CloudBackup.manifest(in: store)?.current == later.snapshot)
        #expect(try store.entries().filter { CloudSnapshots.date(ofPath: $0.path) != nil }.count == 2)
    }

    @Test func theManifestWaitsForItsSnapshot() async throws {
        let f = try SyncFixture()
        let base = try FolderCloudStore(root: try TestSupport.tempDir())
        let now = Date(timeIntervalSince1970: 1_793_456_712)
        let first = try await CloudBackup.publish(database: f.db, root: f.root, store: base, identity: identity, scope: .library,
                                                  scratch: try TestSupport.tempDir(), now: now)
        let offline = OfflineStore(base: base)
        let second = try await CloudBackup.publish(database: f.db, root: f.root, store: offline, identity: identity, scope: .library,
                                                   scratch: try TestSupport.tempDir(), now: now.addingTimeInterval(60))
        #expect(!second.isCurrent)
        #expect(try CloudBackup.manifest(in: base)?.current == first.snapshot)
    }

    @Test func neverMixesTwoLibraries() async throws {
        let mine = try SyncFixture(), theirs = try SyncFixture()
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        let now = Date(timeIntervalSince1970: 1_793_456_712)
        let other = CloudBackupIdentity(macID: "mac-2", macName: "Old Mac", appVersion: "1.30.0")
        let old = try await CloudBackup.publish(database: theirs.db, root: theirs.root, store: store, identity: other, scope: .library,
                                                scratch: try TestSupport.tempDir(), now: now)
        await #expect(throws: CloudBackupError.otherLibrary(macName: "Old Mac", snapshotAt: old.snapshotAt)) {
            try await CloudBackup.publish(database: mine.db, root: mine.root, store: store, identity: identity, scope: .library,
                                          scratch: try TestSupport.tempDir(), now: now.addingTimeInterval(60))
        }
        #expect(try CloudBackup.manifest(in: store)?.libraryID == theirs.db.libraryID())

        let replaced = try await CloudBackup.publish(database: mine.db, root: mine.root, store: store, identity: identity, scope: .library,
                                                     scratch: try TestSupport.tempDir(), now: now.addingTimeInterval(120), replacingOther: true)
        #expect(try CloudBackup.manifest(in: store)?.libraryID == mine.db.libraryID())
        #expect(try store.entries().compactMap { CloudSnapshots.date(ofPath: $0.path) } == [replaced.snapshotAt])
    }

    @Test func refusesANewerOrGarbledManifestSafely() async throws {
        let f = try SyncFixture()
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        try store.write(Data(#"{"format": 2, "anything": true}"#.utf8), to: CloudBackupManifest.path)
        await #expect(throws: CloudBackupError.newerBackup) {
            try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .library,
                                          scratch: try TestSupport.tempDir())
        }
        // Garbage is replaced.
        for garbage in [Data("not json".utf8), Data(#"{"format": 1, "current": "../../etc/passwd"}"#.utf8),
                        Data(repeating: 0x20, count: CloudBackupManifest.sizeLimit + 1)] {
            try store.write(garbage, to: CloudBackupManifest.path)
            #expect(try CloudBackup.manifest(in: store) == nil)
        }
        let result = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .library,
                                                   scratch: try TestSupport.tempDir())
        #expect(try CloudBackup.manifest(in: store)?.current == result.snapshot)
    }
}

@Suite struct CloudMusicBackupTests {
    let identity = CloudBackupIdentity(macID: "mac-1", macName: "Studio Mac", appVersion: "1.30.0")
    let quick = CloudUploadLimits(inFlightBytes: 1, runTime: .seconds(60), snapshotTimeout: .seconds(1), poll: .milliseconds(1))

    @Test func musicComesAfterCoversAndPhotos() throws {
        let f = try SyncFixture()
        let files = CloudBackupPlan.files(tracks: f.tracks, collectionCovers: [], music: [f.tracks[2], f.tracks[0]], root: f.root)
        #expect(files.map(\.path) == ["Music/Artist/First (2000)/cover.jpg", "Music/Artist/Second (2000)/cover.jpg", "Artist Images/artist.jpg",
                                      f.tracks[2].path, f.tracks[0].path])
        #expect(files.filter { CloudBackupPlan.isMusic($0.path) }.count == 2)
        #expect(!CloudBackupPlan.isMusic("Music/Artist/First (2000)/cover.jpg") && !CloudBackupPlan.isMusic("Snapshots/x.flac"))
    }

    @Test func unwantedFilesAreListedThenPurgedAfter30Days() {
        let now = Date(timeIntervalSince1970: 1_793_456_712)
        let day: TimeInterval = 86400
        let keep = CloudBackupFile(path: "Music/A/B (1)/cover.jpg", size: 5, modified: now)
        let entries = [CloudEntry(path: keep.path, size: 5, modified: now),
                       CloudEntry(path: "Music/A/B (1)/01 - New.flac", size: 10, modified: now),      // newly unwanted
                       CloudEntry(path: "Music/A/B (1)/02 - Old.flac", size: 20, modified: now),      // listed 31 days ago
                       CloudEntry(path: "Music/A/B (1)/03 - Back.flac", size: 30, modified: now),     // listed, wanted again
                       CloudEntry(path: "Snapshots/2026-10-31T14-25-12Z.sqlite", size: 1, modified: now)]
        let listed = [CloudRemoval(path: "Music/A/B (1)/02 - Old.flac", size: 20, removedAt: now - 31 * day),
                      CloudRemoval(path: "Music/A/B (1)/03 - Back.flac", size: 30, removedAt: now - 2 * day),
                      CloudRemoval(path: "Music/A/B (1)/04 - Gone.flac", size: 40, removedAt: now - 2 * day),   // no longer in iCloud
                      CloudRemoval(path: "../../etc/passwd", size: 1, removedAt: now - 99 * day)]
        let back = CloudBackupFile(path: "Music/A/B (1)/03 - Back.flac", size: 30, modified: now)
        let plan = CloudBackupPlan(files: [keep, back], entries: entries, removals: listed, now: now)
        #expect(plan.uploads.isEmpty)
        #expect(plan.removals == [CloudRemoval(path: "Music/A/B (1)/01 - New.flac", size: 10, removedAt: now)])
        #expect(plan.purges == ["Music/A/B (1)/02 - Old.flac"])

        // A month later, the new one goes too.
        let later = CloudBackupPlan(files: [keep, back], entries: entries.filter { !$0.path.contains("02 -") }, removals: plan.removals,
                                    now: now + 30 * day)
        #expect(later.purges == ["Music/A/B (1)/01 - New.flac"] && later.removals.isEmpty)
    }

    @Test func theRemovalListIsReadWithCare() throws {
        #expect(CloudRemoval.decode(Data("garbage".utf8)).isEmpty)
        #expect(CloudRemoval.decode(Data(repeating: 0x20, count: CloudRemoval.sizeLimit + 1)).isEmpty)
        let now = Date(timeIntervalSince1970: 1_793_456_712)
        let list = [CloudRemoval(path: "Music/A/x.flac", size: 1, removedAt: now), CloudRemoval(path: "/etc/hosts", size: 1, removedAt: now),
                    CloudRemoval(path: "Notes/x.flac", size: 1, removedAt: now)]
        #expect(CloudRemoval.decode(try CloudRemoval.encode(list)) == [list[0]])
    }

    @Test func switchingScopesListsThenPurgesMusic() async throws {
        let f = try SyncFixture()
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        let now = Date(timeIntervalSince1970: 1_793_456_712)
        let all = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .everything,
                                                music: f.tracks, scratch: try TestSupport.tempDir(), now: now, limits: quick)
        #expect(all.files == 6 && all.remaining == 0)
        #expect(try store.entries().filter { CloudBackupPlan.isMusic($0.path) }.count == 3)
        #expect(try CloudBackup.manifest(in: store)?.scope == "everything")

        // Only one album chosen: the others' songs are listed, not deleted.
        let chosen = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .chosen,
                                                   music: [f.tracks[2]], scratch: try TestSupport.tempDir(), now: now + 60, limits: quick)
        #expect(chosen.files == 0 && chosen.removed == 2 && chosen.purged == 0)
        let listed = CloudRemoval.decode(try #require(try store.read(CloudRemoval.path, limit: 1 << 20)))
        #expect(Set(listed.map(\.path)) == Set(f.tracks.prefix(2).map(\.path)))
        #expect(try store.entries().filter { CloudBackupPlan.isMusic($0.path) }.count == 3)

        // Picked again before the month is up: off the list.
        let back = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .chosen,
                                                 music: [f.tracks[0], f.tracks[2]], scratch: try TestSupport.tempDir(), now: now + 120, limits: quick)
        #expect(back.files == 0)
        #expect(CloudRemoval.decode(try store.read(CloudRemoval.path, limit: 1 << 20) ?? Data()).map(\.path) == [f.tracks[1].path])

        // 31 days on, what's still unwanted is deleted, and "Library and covers" lists the rest.
        let month = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .library,
                                                  music: f.tracks, scratch: try TestSupport.tempDir(), now: now + 31 * 86400, limits: quick)
        #expect(month.purged == 1 && month.removed == 2)
        #expect(try store.entries().filter { CloudBackupPlan.isMusic($0.path) }.map(\.path) == [f.tracks[0].path, f.tracks[2].path])
    }

    @Test func musicWaitsForICloudAndIsEvictedOnceUploaded() async throws {
        let f = try SyncFixture()
        let store = SlowStore(base: try FolderCloudStore(root: try TestSupport.tempDir()), delay: 3)
        let result = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .everything,
                                                   music: f.tracks, scratch: try TestSupport.tempDir(), limits: quick)
        #expect(result.isCurrent && result.remaining == 0 && result.waiting == 0 && result.files == 6)
        #expect(Set(store.evicted) == Set(f.tracks.map(\.path)))
        #expect(store.evicted.allSatisfy(CloudBackupPlan.isMusic))
    }

    @Test func aRunStopsCopyingWhenICloudFallsBehind() async throws {
        let f = try SyncFixture()
        let store = SlowStore(base: try FolderCloudStore(root: try TestSupport.tempDir()), delay: nil)
        let limits = CloudUploadLimits(inFlightBytes: 1, runTime: .milliseconds(200), snapshotTimeout: .seconds(1), poll: .milliseconds(5))
        let result = try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .everything,
                                                   music: f.tracks, scratch: try TestSupport.tempDir(), limits: limits)
        // The database backup is current; one song is waiting for iCloud and the other two wait for the next run.
        #expect(result.isCurrent && result.remaining == 2 && result.waiting == 1)
        #expect(try CloudBackup.manifest(in: store.base)?.current == result.snapshot)
        #expect(store.evicted.isEmpty)
    }

    @Test func cancellingStopsTheMusicCopy() async throws {
        let f = try SyncFixture()
        let store = SlowStore(base: try FolderCloudStore(root: try TestSupport.tempDir()), delay: nil)
        let limits = CloudUploadLimits(inFlightBytes: 1, runTime: .seconds(600), snapshotTimeout: .seconds(1), poll: .milliseconds(5))
        let identity = identity, scratch = try TestSupport.tempDir()
        let run = Task {
            try await CloudBackup.publish(database: f.db, root: f.root, store: store, identity: identity, scope: .everything,
                                          music: f.tracks, scratch: scratch, limits: limits)
        }
        try await Task.sleep(for: .milliseconds(100))
        run.cancel()
        let result = try await run.value
        #expect(result.isCurrent && result.remaining == 2 && result.waiting == 1)
    }
}
