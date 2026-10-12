import Foundation
import Network
import Testing
@testable import MusicLibraryCore

@Suite struct SyncProtocolTests {
    @Test func framesSurviveArbitrarySplits() throws {
        let frames = [try SyncFrame.message(.delete(["Music/A/B/1.flac"])), SyncFrame(kind: .chunk, payload: Data(repeating: 7, count: 3000)),
                      try SyncFrame.message(.paired)]
        let wire = frames.reduce(Data()) { $0 + $1.encoded() }
        for step in [1, 2, 5, 333, wire.count] {
            var decoder = SyncFrameDecoder()
            var out: [SyncFrame] = []
            var i = 0
            while i < wire.count {
                out += try decoder.append(wire.subdata(in: i..<min(i + step, wire.count)))
                i += step
            }
            #expect(out == frames)
        }
    }

    @Test func oversizedAndUnknownFramesAreRefused() {
        var decoder = SyncFrameDecoder()
        #expect(throws: SyncError.frameTooLarge(Int(UInt32.max))) { try decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 1])) }
        var other = SyncFrameDecoder()
        #expect(throws: SyncError.unknownFrameKind(9)) { try other.append(Data([0, 0, 0, 0, 9])) }
    }

    @Test func messagesRoundTrip() throws {
        var summary = SyncSummary()
        summary.copied = 3
        summary.databaseUpdated = true
        let messages: [SyncMessage] = [
            .hello(SyncHello(deviceID: "id", deviceName: "iPhone", appVersion: "1.8", freeSpace: 42)),
            .pair(SyncGrant(key: Data(repeating: 1, count: 32), macID: "mac", macName: "Mac")), .paired,
            .manifest(SyncManifest(files: [SyncFileEntry(path: "Music/a.flac", size: 9)])),
            .plan(SyncPlanSummary(files: 1, bytes: 9, deletes: 0)), .delete([]),
            .file(SyncFileHeader(path: "library.sqlite", size: 10)), .done(summary), .failure("nope"),
        ]
        for m in messages { #expect(try SyncFrame.message(m).message() == m) }
        #expect(SyncGrant(key: Data(repeating: 1, count: 32), macID: "m", macName: "M").keyData?.count == 32)
        #expect(SyncGrant(key: Data([1, 2]), macID: "m", macName: "M").keyData == nil)
    }

    @Test func pairingCodes() {
        let code = SyncPairing.newCode()
        #expect(code.count == SyncPairing.codeLength)
        #expect(SyncPairing.normalize(SyncPairing.display(code).lowercased()) == code)
        #expect(SyncPairing.normalize("abcde fghjk") == "ABCDEFGHJK")
        #expect(SyncPairing.normalize("O0IL1-23456") == "0011123456")
        #expect(SyncPairing.normalize("ABCDE-FGHJ") == nil)
        #expect(SyncPairing.normalize("ABCDE-FGHJU") == nil)
        #expect(SyncPairing.pairingKey(code: code) == SyncPairing.pairingKey(code: code))
        #expect(SyncPairing.pairingKey(code: code).count == 32)
        #expect(SyncPairing.pairingKey(code: "0000000000") != SyncPairing.pairingKey(code: "0000000001"))
        #expect(SyncPairing.newKey() != SyncPairing.newKey())
    }
}

/// A Mac library with real (tiny) files: two albums with covers, one artist photo.
struct SyncFixture {
    let root: URL
    let db: Database
    var tracks: [Track]

    init() throws {
        root = try TestSupport.tempDir().appendingPathComponent("lib")
        db = try LibraryLocation.openDatabase(root: root)
        tracks = []
        for (album, n) in [("First", 1), ("First", 2), ("Second", 1)] {
            let path = "Music/Artist/\(album) (2000)/0\(n) - Song.flac"
            let t = Track(path: path, metadata: TrackMetadata(title: "Song \(n)", artist: "Artist", album: album, trackNo: n),
                          duration: 100, format: "flac", sha256: "sha-\(album)-\(n)")
            tracks.append(try db.insertTrack(t))
            try write(path, bytes: 1000 + n * 10 + album.count)
        }
        try write("Music/Artist/First (2000)/cover.jpg", bytes: 50)
        try write("Music/Artist/Second (2000)/cover.jpg", bytes: 60)
        try write("\(LibraryExporter.artistImageFolder)/artist.jpg", bytes: 70)
    }

    func write(_ path: String, bytes: Int, fill: UInt8 = 0xAB) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    func size(_ path: String) -> Int64 { LibraryExporter.size(of: root.appendingPathComponent(path))! }
}

@Suite struct SyncPlanTests {
    @Test func sendsWhatThePhoneLacksAndDeletesTheRest() throws {
        let f = try SyncFixture()
        let first = Array(f.tracks.prefix(2))
        let fresh = SyncPlan(tracks: first, libraryRoot: f.root, phone: [])
        #expect(fresh.sends.map(\.path) == [first[0].path, "Music/Artist/First (2000)/cover.jpg", first[1].path, "Artist Images/artist.jpg"])
        #expect(fresh.bytes == fresh.sends.reduce(0) { $0 + $1.size })
        #expect(fresh.deletes.isEmpty)

        let phone = [SyncFileEntry(path: first[0].path, size: f.size(first[0].path)),        // same: skipped
                     SyncFileEntry(path: first[1].path, size: 1),                             // changed: sent again
                     SyncFileEntry(path: f.tracks[2].path, size: f.size(f.tracks[2].path)),  // not selected: deleted
                     SyncFileEntry(path: "Music/../../etc/passwd", size: 1),                  // unsafe: ignored
                     SyncFileEntry(path: "Notes/readme.txt", size: 1),                        // not managed: left alone
                     SyncFileEntry(path: "library.sqlite", size: 1)]
        let plan = SyncPlan(tracks: first, libraryRoot: f.root, phone: phone)
        #expect(plan.sends.map(\.path) == ["Music/Artist/First (2000)/cover.jpg", first[1].path, "Artist Images/artist.jpg"])
        #expect(plan.deletes == [f.tracks[2].path])
    }

    @Test func missingAndUnsafeTracksAreSkipped() throws {
        let f = try SyncFixture()
        var gone = f.tracks[2]
        gone.path = "Music/Artist/Gone (2000)/01 - Song.flac"
        var escaping = f.tracks[2]
        escaping.path = "../outside.flac"
        let plan = SyncPlan(tracks: [f.tracks[0], gone, escaping], libraryRoot: f.root, phone: [])
        #expect(plan.missing == 2)
        #expect(plan.sends.contains { $0.path == f.tracks[0].path })
    }

    @Test func snapshotDropsTheCatalog() throws {
        let f = try SyncFixture()
        try f.db.exec("INSERT INTO catalog_items(work_id,json,last_seen) VALUES('w','{}',0)")
        let out = try TestSupport.tempDir().appendingPathComponent("snap.sqlite")
        try f.db.writeSyncSnapshot(to: out, scratch: try TestSupport.tempDir())
        let snap = try Database(snapshotAt: out.path)
        #expect(try snap.trackCount() == 3)
        #expect(try snap.query("SELECT COUNT(*) FROM catalog_items") { $0.int(0) }.first == 0)
        #expect(try f.db.query("SELECT COUNT(*) FROM catalog_items") { $0.int(0) }.first == 1)
    }
}

@Suite struct SyncReceiverTests {
    @Test func writesFilesAtomicallyAndListsThem() throws {
        let root = try TestSupport.tempDir().appendingPathComponent("Music Library")
        let r = try SyncReceiver(root: root)
        #expect(try r.begin(SyncFileHeader(path: "Music/A/B (1)/01.flac", size: 6)) == false)
        #expect(try r.write(Data("abc".utf8)) == false)
        // Not in place until complete.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Music/A/B (1)/01.flac").path))
        #expect(try r.write(Data("def".utf8)) == true)
        #expect(try Data(contentsOf: root.appendingPathComponent("Music/A/B (1)/01.flac")) == Data("abcdef".utf8))
        #expect(try r.begin(SyncFileHeader(path: "Artist Images/x.jpg", size: 0)) == true)
        #expect(throws: SyncError.self) { try r.write(Data([1])) }
        #expect(r.manifest() == [SyncFileEntry(path: "Artist Images/x.jpg", size: 0), SyncFileEntry(path: "Music/A/B (1)/01.flac", size: 6)])
        #expect(r.summary.copied == 2)
    }

    @Test func refusesPathsOutsideTheManagedFolders() throws {
        let base = try TestSupport.tempDir()
        let root = base.appendingPathComponent("lib")
        let r = try SyncReceiver(root: root)
        for path in ["../x.flac", "/etc/passwd", "Music/../../x", "Notes/x.txt", "Music", "library.sqlite-wal", ""] {
            #expect(throws: SyncError.unsafePath(path)) { try r.begin(SyncFileHeader(path: path, size: 1)) }
        }
        // A symlinked folder leading out of the library.
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Music"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Music/Evil"), withDestinationURL: outside)
        #expect(throws: SyncError.unsafePath("Music/Evil/x.flac")) { try r.begin(SyncFileHeader(path: "Music/Evil/x.flac", size: 1)) }
        #expect(throws: SyncError.unsafePath("Music/Evil/x.flac")) { try r.delete(["Music/Evil/x.flac"]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func deletesPruneEmptyFolders() throws {
        let root = try TestSupport.tempDir().appendingPathComponent("lib")
        let r = try SyncReceiver(root: root)
        for path in ["Music/A/One (1)/01.flac", "Music/A/Two (2)/01.flac"] {
            _ = try r.begin(SyncFileHeader(path: path, size: 1))
            _ = try r.write(Data([1]))
        }
        try r.delete(["Music/A/One (1)/01.flac", "Music/A/Missing/x.flac"])
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Music/A/One (1)").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Music/A/Two (2)/01.flac").path))
        try r.delete(["Music/A/Two (2)/01.flac"])
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Music/A").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Music").path))
        #expect(r.summary.deleted == 2)
    }

    @Test func replacesTheDatabaseAndClearsLeftovers() throws {
        let root = try TestSupport.tempDir().appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Music/A"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("library.sqlite-wal"))
        try Data([1]).write(to: root.appendingPathComponent("Music/A/.x.flac" + SyncReceiver.partialSuffix))
        let r = try SyncReceiver(root: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Music/A/.x.flac" + SyncReceiver.partialSuffix).path))
        _ = try r.begin(SyncFileHeader(path: "library.sqlite", size: 2))
        _ = try r.write(Data([1, 2]))
        #expect(r.summary.databaseUpdated)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite-wal").path))
        #expect(try Data(contentsOf: root.appendingPathComponent("library.sqlite")) == Data([1, 2]))
    }
}

/// Real sessions over a loopback TLS connection (no Bonjour, no network beyond this machine).
@Suite(.serialized) struct SyncSessionTests {
    let mac = SyncIdentity(deviceID: "mac-id", deviceName: "Mac", appVersion: "test")
    let phone = SyncIdentity(deviceID: "phone-id", deviceName: "iPhone", appVersion: "test")

    /// Starts a phone listener with `key` and returns its port and the result of the first session.
    func listen(key: Data, root: URL, pairing: Bool, grants: GrantBox = GrantBox()) async throws -> (NWEndpoint.Port, Task<(SyncHello, SyncSummary), Error>) {
        let sessions = AsyncStream<NWConnection>.makeStream()
        let identity = phone
        let advertiser = try SyncAdvertiser(deviceID: phone.deviceID, name: "test", key: key, pairing: pairing, advertise: false,
                                            onState: { _ in }, onConnection: { sessions.continuation.yield($0) })
        advertiser.start()
        for _ in 0..<100 where advertiser.port == nil || advertiser.port == .any { try await Task.sleep(for: .milliseconds(20)) }
        let task = Task { () async throws -> (SyncHello, SyncSummary) in
            defer { advertiser.stop() }
            for await connection in sessions.stream {
                let result = try await SyncPhoneSession.run(SyncConnection(connection), identity: identity, root: root, freeSpace: nil,
                                                            pairing: pairing, storeGrant: { await grants.store($0) })
                return (result.mac, result.summary)
            }
            throw SyncError.connection("no session")
        }
        return (advertiser.port!, task)
    }

    actor GrantBox {
        var grant: SyncGrant?
        func store(_ g: SyncGrant) { grant = g }
    }

    func endpoint(_ port: NWEndpoint.Port) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: port) }

    @Test func pairingHandsOverAKey() async throws {
        let code = SyncPairing.newCode()
        let grants = GrantBox()
        let phoneRoot = try TestSupport.tempDir().appendingPathComponent("phone")
        let (port, session) = try await listen(key: SyncPairing.pairingKey(code: code), root: phoneRoot, pairing: true, grants: grants)
        let (hello, key) = try await SyncMacSession.pair(endpoint: endpoint(port), code: code, identity: mac)
        #expect(hello.deviceID == "phone-id")
        session.cancel()
        _ = try? await session.value
        let grant = await grants.grant
        #expect(grant?.keyData == key)
        #expect(grant?.macID == "mac-id")
    }

    @Test func aWrongCodeFails() async throws {
        let phoneRoot = try TestSupport.tempDir().appendingPathComponent("phone")
        let (port, session) = try await listen(key: SyncPairing.pairingKey(code: "AAAAAAAAAA"), root: phoneRoot, pairing: true)
        await #expect(throws: (any Error).self) {
            _ = try await SyncMacSession.pair(endpoint: endpoint(port), code: "BBBBBBBBBB", identity: mac)
        }
        session.cancel()
    }

    @Test func syncMirrorsTheSelection() async throws {
        let f = try SyncFixture()
        let key = SyncPairing.newKey()
        let phoneRoot = try TestSupport.tempDir().appendingPathComponent("Music Library")
        let scratch = try TestSupport.tempDir()

        var (port, session) = try await listen(key: key, root: phoneRoot, pairing: false)
        let first = try await SyncMacSession.sync(endpoint: endpoint(port), key: key, identity: mac, tracks: f.tracks,
                                                  libraryRoot: f.root, database: f.db, scratch: scratch)
        #expect(first.copied == 6)
        #expect(first.databaseUpdated)
        #expect(try await session.value.1 == first)
        for path in f.tracks.map(\.path) + ["Music/Artist/First (2000)/cover.jpg", "Artist Images/artist.jpg"] {
            #expect(try Data(contentsOf: phoneRoot.appendingPathComponent(path)) == Data(contentsOf: f.root.appendingPathComponent(path)))
        }
        let library = try LibrarySnapshot(root: phoneRoot)
        #expect(library.tracks.count == 3)

        // Narrow the selection to the first album and change a file: one resent, the other album removed.
        try f.write(f.tracks[0].path, bytes: 5000, fill: 0xCD)
        (port, session) = try await listen(key: key, root: phoneRoot, pairing: false)
        let second = try await SyncMacSession.sync(endpoint: endpoint(port), key: key, identity: mac, tracks: Array(f.tracks.prefix(2)),
                                                   libraryRoot: f.root, database: f.db, scratch: scratch)
        _ = try await session.value
        #expect(second.copied == 1)
        #expect(second.deleted == 2)
        #expect(try Data(contentsOf: phoneRoot.appendingPathComponent(f.tracks[0].path)) == Data(repeating: 0xCD, count: 5000))
        #expect(!FileManager.default.fileExists(atPath: phoneRoot.appendingPathComponent("Music/Artist/Second (2000)").path))
        #expect(try LibrarySnapshot(root: phoneRoot).tracks.count == 2)

        // Declining the deletions keeps what's on the phone.
        (port, session) = try await listen(key: key, root: phoneRoot, pairing: false)
        let third = try await SyncMacSession.sync(endpoint: endpoint(port), key: key, identity: mac, tracks: [f.tracks[0]],
                                                  libraryRoot: f.root, database: f.db, scratch: scratch, approveDeletes: { _ in false })
        _ = try await session.value
        #expect(third.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: phoneRoot.appendingPathComponent(f.tracks[1].path).path))
    }

    @Test func anOtherKeyIsRefused() async throws {
        let f = try SyncFixture()
        let phoneRoot = try TestSupport.tempDir().appendingPathComponent("phone")
        let (port, session) = try await listen(key: SyncPairing.newKey(), root: phoneRoot, pairing: false)
        await #expect(throws: (any Error).self) {
            _ = try await SyncMacSession.sync(endpoint: endpoint(port), key: SyncPairing.newKey(), identity: mac, tracks: f.tracks,
                                              libraryRoot: f.root, database: f.db, scratch: try TestSupport.tempDir())
        }
        session.cancel()
        #expect(!FileManager.default.fileExists(atPath: phoneRoot.appendingPathComponent("Music").path))
    }
}
