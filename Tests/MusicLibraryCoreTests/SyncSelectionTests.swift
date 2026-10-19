import Foundation
import Network
import Testing
@testable import MusicLibraryCore

@Suite struct SyncSelectionTests {
    /// Artist "A" with albums X (tracks 1, 2) and Y (track 3); artist "B" with album Z (track 4); a playlist of 2 and 4.
    let library: [Track] = [
        Track(id: 1, path: "Music/A/X/1.flac", metadata: TrackMetadata(title: "1", artist: "A", album: "X"), duration: 1, format: "flac", sha256: "1"),
        Track(id: 2, path: "Music/A/X/2.flac", metadata: TrackMetadata(title: "2", artist: "A", album: "X"), duration: 1, format: "flac", sha256: "2"),
        Track(id: 3, path: "Music/A/Y/3.flac", metadata: TrackMetadata(title: "3", artist: "A", album: "Y"), duration: 1, format: "flac", sha256: "3"),
        Track(id: 4, path: "Music/B/Z/4.flac", metadata: TrackMetadata(title: "4", artist: "B", album: "Z"), duration: 1, format: "flac", sha256: "4"),
    ]

    func tracks(_ item: ExportItem) -> [Track] {
        switch item {
        case .library: return library
        case .album(let album, let artist): return library.filter { $0.album == album && $0.artist == artist }
        case .artist(let name): return library.filter { $0.artist == name }
        case .track(let id): return library.filter { $0.id == id }
        case .playlist(7): return library.filter { [2, 4].contains($0.id) }
        case .playlist, .smartPlaylist, .likedSongs: return []
        }
    }

    func ids(_ item: ExportItem) -> Set<Int64> { Set(tracks(item).map(\.id)) }
    func resolved(_ s: SyncSelection) -> [Int64] { s.resolve(tracks).map(\.id) }

    @Test func lastRuleWinsPerSong() {
        var s = SyncSelection(items: [.artist("A")])
        #expect(resolved(s) == [1, 2, 3])
        s.apply(.album(album: "X", artist: "A"), include: false, tracks: ids)
        #expect(resolved(s) == [3])
        #expect(s.rules.map(\.include) == [true, false])
        #expect(!s.contains(.album(album: "X", artist: "A"), tracks: tracks))
        #expect(s.contains(.album(album: "Y", artist: "A"), tracks: tracks))

        // Putting it back drops the exclusion; the album is covered by the artist, so no new rule is needed.
        s.apply(.album(album: "X", artist: "A"), include: true, tracks: ids)
        #expect(s.rules == [SyncSelection.Rule(item: .artist("A"), include: true)])
        #expect(resolved(s) == [1, 2, 3])
    }

    @Test func compactionDropsRulesThatDecideNothing() {
        var s = SyncSelection(items: [.track(1), .album(album: "X", artist: "A")])
        s.apply(.artist("A"), include: true, tracks: ids)
        // The song and the album are inside the artist, which came last.
        #expect(s.rules.map(\.item) == [.artist("A")])

        // Removing what nothing else adds leaves no rule at all.
        s.apply(.artist("A"), include: false, tracks: ids)
        #expect(s.isEmpty)

        // An exclusion is kept only while something earlier adds those songs.
        var p = SyncSelection(items: [.playlist(7)])
        p.apply(.track(2), include: false, tracks: ids)
        #expect(resolved(p) == [4])
        p.apply(.album(album: "X", artist: "A"), include: true, tracks: ids)
        #expect(resolved(p) == [2, 4, 1])
        #expect(p.rules.map(\.item) == [.playlist(7), .album(album: "X", artist: "A")])
    }

    @Test func emptyItemsStayOnTheList() {
        var s = SyncSelection(items: [.likedSongs])
        s.apply(.album(album: "Z", artist: "B"), include: true, tracks: ids)
        #expect(s.rules.map(\.item) == [.likedSongs, .album(album: "Z", artist: "B")])
        #expect(s.contains(.likedSongs, tracks: tracks))
    }

    /// An album that left the library (or never matched it) leaves the list, even when the phone's Remove for it comes
    /// after; a playlist stays.
    @Test func itemsThatLeftTheLibraryLeaveTheList() {
        let gone = ExportItem.album(album: "Gone", artist: "A")
        var s = SyncSelection(rules: [SyncSelection.Rule(item: .playlist(9), include: true), SyncSelection.Rule(item: gone, include: true),
                                      SyncSelection.Rule(item: .album(album: "X", artist: "A"), include: true),
                                      SyncSelection.Rule(item: .artist("Nobody"), include: true), SyncSelection.Rule(item: .track(99), include: true)])
        s.dropMissing(tracks: ids)
        #expect(s.rules.map(\.item) == [.playlist(9), .album(album: "X", artist: "A")])

        var t = SyncSelection(rules: [SyncSelection.Rule(item: .album(album: "X", artist: "A"), include: true),
                                      SyncSelection.Rule(item: gone, include: true)])
        t.apply(.album(album: "Other", artist: "Spelling"), include: false, tracks: ids)
        #expect(t.rules.map(\.item) == [.album(album: "X", artist: "A")])
    }

    @Test func oldListsDecodeAsAdditions() throws {
        let old = try JSONEncoder().encode([ExportItem.artist("A"), .track(4)])
        let items = try JSONDecoder().decode([ExportItem].self, from: old)
        let s = SyncSelection(items: items)
        #expect(resolved(s) == [1, 2, 3, 4])
        let copy = try JSONDecoder().decode(SyncSelection.self, from: try JSONEncoder().encode(s))
        #expect(copy == s)
    }

    @Test func requestQueueKeepsTheLatestPerItem() throws {
        let url = try TestSupport.tempDir().appendingPathComponent("requests.json")
        let queue = SyncRequestQueue(url: url)
        queue.add(SyncRequest(item: .artist("A"), include: true))
        queue.add(SyncRequest(item: .track(4), include: true))
        queue.add(SyncRequest(item: .artist("A"), include: false))
        #expect(queue.requests.map(\.item) == [.track(4), .artist("A")])
        #expect(queue.requests.last?.include == false)
        let reloaded = SyncRequestQueue(url: url)
        #expect(reloaded.requests == queue.requests)
        reloaded.remove([reloaded.requests[0].id])
        #expect(SyncRequestQueue(url: url).requests.map(\.item) == [.artist("A")])
    }
}

@Suite struct SyncLibraryTests {
    let mac = SyncIdentity(deviceID: "mac-id", deviceName: "Mac", appVersion: "test")
    let phone = SyncIdentity(deviceID: "phone-id", deviceName: "iPhone", appVersion: "test")

    @Test func everyCoverAndPhotoGoesEvenForUnselectedAlbums() throws {
        let f = try SyncFixture()
        let plan = SyncPlan(tracks: [f.tracks[2]], library: f.tracks, libraryRoot: f.root, phone: [])
        #expect(plan.sends.map(\.path) == [f.tracks[2].path, "Music/Artist/Second (2000)/cover.jpg",
                                           "Music/Artist/First (2000)/cover.jpg", "Artist Images/artist.jpg"])
        // An album taken off the phone keeps its cover there.
        let onPhone = plan.sends + [SyncFileEntry(path: f.tracks[0].path, size: f.size(f.tracks[0].path))]
        let next = SyncPlan(tracks: [f.tracks[2]], library: f.tracks, libraryRoot: f.root, phone: onPhone)
        #expect(next.sends.isEmpty)
        #expect(next.deletes == [f.tracks[0].path])
    }

    @Test func ownershipFromThePhoneIsAppliedOnceAndTheLatestWins() throws {
        let f = try SyncFixture()
        let key = SearchIndex.albumKey(album: "First", artist: "Artist")
        let bought = AlbumPurchase(album: "ignored", artist: "ignored", purchasedOn: PurchaseDay(year: 2020, month: 5, day: 1), price: 9.5,
                                   labelNumber: 31)
        let events = [SyncEvent(track: f.tracks[0], at: Date(timeIntervalSince1970: 1000), kind: .purchase(bought))]
        var result = try f.db.applySyncEvents(events, libraryID: f.db.libraryID(), now: Date(timeIntervalSince1970: 1001))
        #expect(result.purchases == 1)
        let saved = try #require(try f.db.albumPurchases()[key])
        #expect(saved.album == "First")
        #expect(saved.price == 9.5)
        #expect(saved.purchasedOn == PurchaseDay(year: 2020, month: 5, day: 1))
        #expect(saved.labelNumber == nil, "label numbers are set on the Mac only")
        #expect(try f.db.applySyncEvents(events, libraryID: nil).purchases == 0)

        // The Mac changed it after the phone did: the phone's older change loses.
        try f.db.saveAlbumPurchase(key: key, AlbumPurchase(album: "First", artist: "Artist", price: 20, labelNumber: 7), at: Date(timeIntervalSince1970: 3000))
        let older = SyncEvent(track: f.tracks[1], at: Date(timeIntervalSince1970: 2000), kind: .purchase(nil))
        result = try f.db.applySyncEvents([older], libraryID: nil)
        #expect(result.purchases == 0)
        #expect(try f.db.albumPurchases()[key]?.price == 20)
        // A newer change from the phone keeps the Mac's label number.
        let repriced = SyncEvent(track: f.tracks[1], at: Date(timeIntervalSince1970: 3500), kind: .purchase(AlbumPurchase(album: "First", artist: "Artist", price: 18)))
        #expect(try f.db.applySyncEvents([repriced], libraryID: nil).purchases == 1)
        #expect(try f.db.albumPurchases()[key] == AlbumPurchase(album: "First", artist: "Artist", price: 18, labelNumber: 7))
        // A label is a fact only the Mac records: "not owned" from the phone doesn't remove a labeled CD.
        let newer = SyncEvent(track: f.tracks[1], at: Date(timeIntervalSince1970: 4000), kind: .purchase(nil))
        #expect(try f.db.applySyncEvents([newer], libraryID: nil).purchases == 0)
        #expect(try f.db.albumPurchases()[key]?.labelNumber == 7)

        let overlay = SyncOutbox.purchases(base: [:], events: events + [older]) { _ in key }
        #expect(overlay[key] == nil)
        let labeled = SyncOutbox.purchases(base: [key: AlbumPurchase(album: "First", artist: "Artist", labelNumber: 7)], events: events) { _ in key }
        #expect(labeled[key]?.labelNumber == 7 && labeled[key]?.price == 9.5)
        let download = SyncOutbox.purchases(base: [key: AlbumPurchase(album: "First", artist: "Artist", format: .digital)], events: events) { _ in key }
        #expect(download[key]?.format == .digital && download[key]?.price == 9.5)
    }

    /// Phones before 1.18 send ownership changes without a format: the Mac's stays.
    @Test func ownershipFromThePhoneKeepsTheFormat() throws {
        let f = try SyncFixture()
        let key = SearchIndex.albumKey(album: "First", artist: "Artist")
        try f.db.saveAlbumPurchase(key: key, AlbumPurchase(album: "First", artist: "Artist", format: .digital, price: 10), at: Date(timeIntervalSince1970: 1000))
        let repriced = SyncEvent(track: f.tracks[0], at: Date(timeIntervalSince1970: 2000), kind: .purchase(AlbumPurchase(album: "First", artist: "Artist", price: 8)))
        #expect(try f.db.applySyncEvents([repriced], libraryID: f.db.libraryID()).purchases == 1)
        #expect(try f.db.albumPurchases()[key] == AlbumPurchase(album: "First", artist: "Artist", format: .digital, price: 8))
    }

    /// Pre-1.18 events change only the album's primary CD or download: never a record, a label or the medium.
    @Test func legacyEventsChangeOnlyThePrimaryCopy() throws {
        let f = try SyncFixture()
        let key = SearchIndex.albumKey(album: "First", artist: "Artist")
        let t0 = Date(timeIntervalSince1970: 1000)
        var vinyl = CollectionItem(id: "vinyl", medium: .vinyl, album: "First", artist: "Artist", now: t0)
        vinyl.stickerNumber = 3
        vinyl.price = 30
        var cd = CollectionItem(id: "cd-low", medium: .cd, album: "First", artist: "Artist", now: t0)
        cd.stickerNumber = 2
        var cd2 = CollectionItem(id: "cd-high", medium: .cd, album: "First", artist: "Artist", now: t0)
        cd2.stickerNumber = 9
        cd2.price = 5
        try f.db.saveCollectionItems([vinyl, cd, cd2], at: t0)

        let repriced = SyncEvent(track: f.tracks[0], at: Date(timeIntervalSince1970: 2000),
                                 kind: .purchase(AlbumPurchase(album: "x", artist: "y", purchasedOn: PurchaseDay(year: 2001, month: 2, day: 3), price: 11)))
        #expect(try f.db.applySyncEvents([repriced], libraryID: nil).purchases == 1)
        var items = Dictionary(uniqueKeysWithValues: try f.db.collectionItems().items.map { ($0.id, $0) })
        #expect(items["cd-low"]?.price == 11 && items["cd-low"]?.purchasedOn == PurchaseDay(year: 2001, month: 2, day: 3))
        #expect(items["cd-low"]?.stickerNumber == 2 && items["cd-low"]?.medium == .cd && items["cd-low"]?.album == "First")
        #expect(items["cd-high"]?.price == 5)
        #expect(items["vinyl"] == vinyl, "records are never touched")
        #expect(try f.db.albumPurchases()[key] == AlbumPurchase(album: "First", artist: "Artist", purchasedOn: PurchaseDay(year: 2001, month: 2, day: 3),
                                                                price: 11, labelNumber: 2))

        // An older event loses to the copy's later change; "not owned" keeps labeled copies.
        let stale = SyncEvent(track: f.tracks[0], at: Date(timeIntervalSince1970: 1500), kind: .purchase(AlbumPurchase(album: "x", artist: "y", price: 1)))
        let unowned = SyncEvent(track: f.tracks[0], at: Date(timeIntervalSince1970: 3000), kind: .purchase(nil))
        #expect(try f.db.applySyncEvents([stale, unowned], libraryID: nil).purchases == 0)
        items = Dictionary(uniqueKeysWithValues: try f.db.collectionItems().items.map { ($0.id, $0) })
        #expect(items.count == 3 && items["cd-low"]?.price == 11)

        // An unlabeled primary copy is removed by a newer "not owned"; a record alone isn't projected or removed.
        let other = SearchIndex.albumKey(album: "Second", artist: "Artist")
        let lp = CollectionItem(id: "lp", medium: .vinyl, album: "Second", artist: "Artist", now: t0)
        let dl = CollectionItem(id: "dl", medium: .download, album: "Second", artist: "Artist", now: t0)
        try f.db.saveCollectionItems([lp, dl], at: t0)
        #expect(try f.db.albumPurchases()[other]?.format == .digital)
        let gone = SyncEvent(track: f.tracks[2], at: Date(timeIntervalSince1970: 4000), kind: .purchase(nil))
        #expect(try f.db.applySyncEvents([gone], libraryID: nil).purchases == 1)
        #expect(try f.db.collectionItems().items.map(\.id).sorted() == ["cd-high", "cd-low", "lp", "vinyl"])
        #expect(try f.db.albumPurchases()[other] == nil, "a record-only album reads as not owned on older phones")

        // A purchase for an album with only a record adds an unlabeled CD next to it.
        let bought = SyncEvent(track: f.tracks[2], at: Date(timeIntervalSince1970: 5000), kind: .purchase(AlbumPurchase(album: "x", artist: "y", price: 4)))
        #expect(try f.db.applySyncEvents([bought], libraryID: nil).purchases == 1)
        let added = try #require(try f.db.collectionItems().items.first { $0.albumKey == other && $0.medium == .cd })
        #expect(added.album == "Second" && added.stickerNumber == nil && added.price == 4 && added.id == CollectionItem.legacyID(albumKey: other))
    }

    /// The phone shows its outbox's pre-1.18 changes with the same rules.
    @Test func legacyEventsOverlayTheSnapshotItems() {
        let key = "k"
        let t0 = Date(timeIntervalSince1970: 1000)
        var cd = CollectionItem(id: "cd", medium: .cd, album: "A", artist: "B", albumKey: key, now: t0)
        cd.stickerNumber = 4
        let vinyl = CollectionItem(id: "v", medium: .vinyl, album: "A", artist: "B", albumKey: key, now: t0)
        let track = Track(id: 1, path: "p", metadata: TrackMetadata(title: "t"), duration: 1, format: "flac", sha256: "s")
        let events = [
            SyncEvent(track: track, at: Date(timeIntervalSince1970: 3000), kind: .purchase(AlbumPurchase(album: "A", artist: "B", price: 9))),
            SyncEvent(track: track, at: Date(timeIntervalSince1970: 2000), kind: .purchase(AlbumPurchase(album: "A", artist: "B", price: 7))),
            SyncEvent(track: track, at: Date(timeIntervalSince1970: 4000), kind: .purchase(nil)),
        ]
        let items = CollectionLegacy.overlay(events: events, on: [cd, vinyl]) { _ in key }
        #expect(items.count == 2, "the labeled CD stays")
        #expect(items.first { $0.id == "cd" }?.price == 9, "the newest change wins")
        #expect(items.first { $0.id == "v" } == vinyl)
        #expect(CollectionLegacy.overlay(events: events, on: []) { _ in key }.isEmpty, "added, then removed: unlabeled")
        #expect(CollectionLegacy.overlay(events: Array(events.prefix(2)), on: []) { _ in key }.map(\.price) == [9])
    }

    @Test func purchasesFromAnotherDeviceAreChecked() throws {
        let json = #"{"album":"A","artist":"B","purchasedOn":"2020-13-40","price":"-5"}"#
        let p = try JSONDecoder().decode(AlbumPurchase.self, from: Data(json.utf8))
        #expect(p.purchasedOn == nil)
        #expect(p.price == nil)
        let good = AlbumPurchase(album: "A", artist: "B", purchasedOn: PurchaseDay(year: 2021, month: 1, day: 2), price: Decimal(string: "12.99"))
        #expect(try JSONDecoder().decode(AlbumPurchase.self, from: try JSONEncoder().encode(good)) == good)
        let labeled = String(decoding: try JSONEncoder().encode(AlbumPurchase(album: "A", artist: "B", labelNumber: 5)), as: UTF8.self)
        #expect(!labeled.contains("label"), "label numbers stay on the Mac")
        let download = String(decoding: try JSONEncoder().encode(AlbumPurchase(album: "A", artist: "B", format: .digital)), as: UTF8.self)
        #expect(!download.contains("format") && !download.contains("digital"), "formats stay on the Mac")
    }

    actor Box<T: Sendable> {
        var value: T?
        func set(_ v: T) { value = v }
    }

    /// The phone connects to the Mac's listener (as when Download is tapped on the phone): its request changes the
    /// Mac's selection, and the songs and every cover arrive.
    @Test func thePhoneStartsASyncAndItsRequestIsApplied() async throws {
        let f = try SyncFixture()
        let key = SyncPairing.newKey()
        let phoneRoot = try TestSupport.tempDir().appendingPathComponent("Music Library")
        let scratch = try TestSupport.tempDir()
        let concerts = SyncConcertSettings(home: HomeLocation(postalCode: "02139", country: "US",
                                                              point: try #require(GeoPoint(latitude: 42.36, longitude: -71.1)), place: "Cambridge, MA"),
                                           radius: 50, unit: .miles, ticketmasterKey: "tm", jambaseKey: "")
        let receivedConcerts = Box<SyncConcertSettings>()
        let selectionBox = Box<SyncSelection>()
        let tracks = f.tracks

        let sessions = AsyncStream<NWConnection>.makeStream()
        let listener = try SyncAdvertiser(macID: "mac-id", phoneID: "phone-id", name: "Mac", key: key, advertise: false,
                                          onConnection: { sessions.continuation.yield($0) })
        listener.start()
        for _ in 0..<100 where listener.port == nil || listener.port == .any { try await Task.sleep(for: .milliseconds(20)) }
        let identity = mac, db = f.db, root = f.root
        let macSide = Task { () async throws -> SyncSummary in
            defer { listener.stop() }
            for await connection in sessions.stream {
                return try await SyncMacSession.sync(SyncConnection(connection), identity: identity, selection: { manifest in
                    var selection = SyncSelection()
                    for r in manifest.requests {
                        selection.apply(r.item, include: r.include) { item in
                            if case .album(let album, _) = item { return Set(tracks.filter { $0.album == album }.map(\.id)) }
                            return []
                        }
                    }
                    await selectionBox.set(selection)
                    return SyncTracks(tracks: selection.resolve { item in
                        if case .album(let album, _) = item { return tracks.filter { $0.album == album } }
                        return []
                    }, library: tracks)
                }, libraryRoot: root, database: db, scratch: scratch, concerts: concerts).summary
            }
            throw SyncError.connection("no session")
        }

        let request = SyncRequest(item: .album(album: "Second", artist: "Artist"), include: true)
        let connection = SyncConnection(endpoint: .hostPort(host: "127.0.0.1", port: listener.port!), key: key)
        let summary = try await SyncPhoneSession.run(connection, identity: phone, root: phoneRoot, freeSpace: nil, pairing: false,
                                                     requests: [request], storeGrant: { _ in },
                                                     storeConcerts: { await receivedConcerts.set($0) }).summary
        #expect(try await macSide.value == summary)
        #expect(await selectionBox.value?.included == [.album(album: "Second", artist: "Artist")])
        #expect(await receivedConcerts.value == concerts)
        let copy = try LibrarySnapshot(root: phoneRoot)
        #expect(copy.presentTracks.map(\.id) == [f.tracks[2].id])
        #expect(copy.tracks.count == 3)
        #expect(FileManager.default.fileExists(atPath: phoneRoot.appendingPathComponent("Music/Artist/First (2000)/cover.jpg").path))
    }
}
