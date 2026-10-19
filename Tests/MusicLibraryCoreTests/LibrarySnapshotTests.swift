import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct LibrarySnapshotTests {
    func track(_ n: Int, album: String, artist: String, year: Int, disc: Int = 1) -> Track {
        Track(path: "Music/\(artist)/\(album) (\(year))/\(disc)-\(n).flac",
              metadata: TrackMetadata(title: "Song \(n)", artist: artist, album: album, year: year, trackNo: n, discNo: disc),
              duration: 200, format: "flac", sha256: "sha-\(artist)-\(album)-\(n)-\(disc)")
    }

    /// A library with two albums by one artist and one by another, exported to a folder where only some of the
    /// files were copied (as on the phone).
    func makeExport(present: (Track) -> Bool) throws -> (root: URL, tracks: [Track]) {
        let source = try TestSupport.tempDir()
        let db = try LibraryLocation.openDatabase(root: source)
        var tracks: [Track] = []
        for t in [track(2, album: "Second", artist: "Beta", year: 2001), track(1, album: "Second", artist: "Beta", year: 2001),
                  track(1, album: "First", artist: "Beta", year: 1999, disc: 2), track(1, album: "First", artist: "Beta", year: 1999),
                  track(1, album: "Only", artist: "alpha", year: 2010)] {
            tracks.append(try db.insertTrack(t))
        }
        let playlist = try db.createPlaylist(name: "Mix")
        try db.addTracks([tracks[4].id, tracks[0].id, tracks[1].id], toPlaylist: playlist.id)
        let empty = try db.createPlaylist(name: "Not copied")
        try db.addTracks([tracks[1].id], toPlaylist: empty.id)
        try db.setLiked([tracks[0].id], true, at: Date(timeIntervalSince1970: 100))
        try db.setLiked([tracks[4].id], true, at: Date(timeIntervalSince1970: 200))
        try db.setLiked([tracks[1].id], true, at: Date(timeIntervalSince1970: 300))
        _ = try db.createSmartPlaylist(name: "Old", query: "year:<2005")

        let root = try TestSupport.tempDir().appendingPathComponent("Music Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try db.vacuum(into: LibraryLocation.databaseURL(root: root).path)
        for t in tracks where present(t) {
            let url = root.appendingPathComponent(t.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: url)
        }
        return (root, tracks)
    }

    @Test func listsEverythingAndKnowsWhatIsPresent() throws {
        let (root, tracks) = try makeExport { $0.metadata.trackNo != 2 }
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("Music/Beta/First (1999)/cover.jpg"))
        let s = try LibrarySnapshot(root: root)

        #expect(s.tracks.count == 5)
        #expect(s.presentTracks.count == 4)
        #expect(!s.isPresent(tracks[0]))
        #expect(s.track(id: tracks[0].id) != nil)
        #expect(s.albums.map(\.album) == ["Only", "First", "Second"])
        #expect(s.albums.first { $0.album == "Second" }?.trackCount == 2)
        #expect(s.artists.map(\.name) == ["alpha", "Beta"])
        #expect(s.artists.map(\.albumCount) == [1, 2])

        let first = try #require(s.albums.first { $0.album == "First" })
        #expect(s.tracks(album: first).map(\.metadata.discNo) == [1, 2])
        #expect(s.albums(artist: "beta").map(\.album) == ["First", "Second"])
        #expect(s.tracks(artist: "Beta").count == 4)
        #expect(s.playable(s.tracks(artist: "Beta")).count == 3)

        #expect(s.playlists.map(\.playlist.name) == ["Mix", "Not copied"])
        #expect(s.playlists[0].tracks.map(\.id) == [tracks[4].id, tracks[0].id, tracks[1].id])
        #expect(s.tracks(for: .likedSongs).map(\.id) == [tracks[1].id, tracks[4].id, tracks[0].id])
        #expect(s.tracks(for: .album(album: "second", artist: "BETA")).count == 2)
        #expect(s.tracks(for: .playlist(s.playlists[1].id)).map(\.id) == [tracks[1].id])

        let old = try #require(s.smartPlaylists.first)
        #expect(Set(s.tracks(smartPlaylist: old).map(\.id)) == Set([tracks[0].id, tracks[1].id, tracks[2].id, tracks[3].id]))
        #expect(s.coverURL(album: first) != nil)
        #expect(s.index.search("first").albums.map(\.album) == ["First"])
        #expect(s.album(of: tracks[0])?.album == "Second")
    }

    @Test func carriesInfoHistoryAndOwnership() throws {
        let source = try TestSupport.tempDir()
        let db = try LibraryLocation.openDatabase(root: source)
        let t = try db.insertTrack(track(1, album: "Only", artist: "Alpha", year: 2010))
        try db.recordPlay(trackId: t.id, startedAt: Date(timeIntervalSince1970: 50), listened: 200, counted: true)
        var info = ArtistInfo(name: "Alpha")
        info.bio = "A band."
        try db.saveArtistInfo(key: "alpha", info, imageFile: "abc.jpg")
        try db.saveArtistInfo(key: "beta", info, imageFile: "../escape.jpg")
        try db.saveArtistPhoto(key: "alpha", ArtistPhotoChoice(file: "chosen.jpg", credit: "Deezer", creditURL: nil))
        try db.saveAlbumPurchase(key: SearchIndex.albumKey(album: "Only", artist: "Alpha"),
                                 AlbumPurchase(album: "Only", artist: "Alpha", price: 12))
        let root = try TestSupport.tempDir()
        try db.vacuum(into: LibraryLocation.databaseURL(root: root).path)

        let s = try LibrarySnapshot(root: root)
        #expect(s.presentTracks.isEmpty)
        #expect(s.playTotals[t.id]?.plays == 1)
        #expect(s.plays.count == 1)
        #expect(s.artistInfo("ALPHA")?.bio == "A band.")
        #expect(s.artistImageURL("Alpha")?.lastPathComponent == "chosen.jpg")
        #expect(s.artistImageURL("Beta") == nil)
        #expect(s.photoCredit("alpha")?.label == "Deezer")
        #expect(s.purchases.values.first?.price == 12)
        #expect(s.collaborations.person(named: "Alpha") != nil)
    }

    @Test func carriesTheCollection() throws {
        let source = try TestSupport.tempDir()
        let db = try LibraryLocation.openDatabase(root: source)
        let t = try db.insertTrack(track(1, album: "Only", artist: "Alpha", year: 2010))
        try db.recordPlay(trackId: t.id, startedAt: Date(timeIntervalSince1970: 86_400 * 100), listened: 200, counted: true)
        let onlyKey = SearchIndex.albumKey(album: "Only", artist: "Alpha")
        var cd = CollectionItem(id: "cd", medium: .cd, album: "Only", artist: "Alpha", now: Date(timeIntervalSince1970: 1000))
        cd.stickerNumber = 3
        cd.price = 12
        cd.purchasedOn = PurchaseDay(year: 2020, month: 6, day: 1)
        cd.digitalSource = .rip
        cd.coverFile = "cd-0000abcd.jpg"
        var lp = CollectionItem(id: "lp", medium: .vinyl, album: "Trackless", artist: "Beta", now: Date(timeIntervalSince1970: 1000))
        lp.stickerNumber = 1
        lp.coverFile = "lp-0000abcd.jpg"
        try db.saveCollectionItems([cd, lp], at: Date(timeIntervalSince1970: 1000))
        // An older Mac repriced the CD after this copy's collection was written.
        try db.exec("UPDATE album_ownership SET price='9', updated_at=2000 WHERE key=?", [.text(onlyKey)])
        try db.exec("INSERT INTO collection_items(id,medium,album,artist,album_key,created_at,updated_at) VALUES('bad id','cd','X','Y','k',0,0)")
        let root = try TestSupport.tempDir()
        try db.vacuum(into: LibraryLocation.databaseURL(root: root).path)
        let covers = root.appendingPathComponent(CollectionCovers.folder)
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: covers.appendingPathComponent("lp-0000abcd.jpg"))
        let album = root.appendingPathComponent("Music/Alpha/Only (2010)")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: album.appendingPathComponent("cover.jpg"))

        let s = try LibrarySnapshot(root: root)
        #expect(s.collection.items.map(\.id) == ["cd", "lp"])
        #expect(s.labelUnreadable == 1 && s.collection.unreadable == 1)
        #expect(s.collection.item(id: "cd")?.price == 9, "an older Mac's edit is taken in")
        #expect(s.collection.item(id: "cd")?.stickerNumber == 3)
        #expect(s.collection.digitalState(s.collection.item(id: "lp")!) == .none)
        #expect(s.purchases[onlyKey] == AlbumPurchase(album: "Only", artist: "Alpha", purchasedOn: PurchaseDay(year: 2020, month: 6, day: 1),
                                                       price: 9, labelNumber: 3))
        #expect(s.purchases.count == 1, "older call sites don't see records")
        #expect(s.coverURL(item: s.collection.item(id: "lp")!)?.lastPathComponent == "lp-0000abcd.jpg")
        #expect(s.coverURL(item: s.collection.item(id: "cd")!)?.path.hasSuffix("Only (2010)/cover.jpg") == true,
                "a cover file not on the phone falls back to the album's")
        #expect(!s.isEmpty)

        // The sample's dates move with its history: 10 whole days here.
        let now = Date(timeIntervalSince1970: 86_400 * 110 + 3600)
        let shifted = try LibrarySnapshot(root: root, datesRelativeToNow: true, now: now)
        let moved = try #require(shifted.collection.item(id: "cd"))
        #expect(moved.purchasedOn == PurchaseDay(PurchaseDay(year: 2020, month: 6, day: 1)!.date().addingTimeInterval(86_400 * 10)))
        #expect(moved.createdAt == Date(timeIntervalSince1970: 1000 + 86_400 * 10))
        #expect(moved.updatedAt == Date(timeIntervalSince1970: 2000 + 86_400 * 10))
    }

    @Test func aCollectionAloneIsALibrary() throws {
        let source = try TestSupport.tempDir()
        let db = try LibraryLocation.openDatabase(root: source)
        let emptyRoot = try TestSupport.tempDir()
        try db.vacuum(into: LibraryLocation.databaseURL(root: emptyRoot).path)
        #expect(try LibrarySnapshot(root: emptyRoot).isEmpty)

        try db.saveCollectionItem(CollectionItem(id: "lp", medium: .vinyl, album: "Blue", artist: "Joni Mitchell"))
        let root = try TestSupport.tempDir()
        try db.vacuum(into: LibraryLocation.databaseURL(root: root).path)
        let s = try LibrarySnapshot(root: root)
        #expect(!s.isEmpty && s.tracks.isEmpty && s.collection.count(.vinyl) == 1)
        #expect(s.coverURL(item: s.collection.items[0]) == nil)
    }

    /// A copy from a Mac before the collection: its items are made from `album_ownership`, as the Mac's migration does.
    @Test func copiesFromBeforeTheCollectionGetTheSameItems() throws {
        let source = try TestSupport.tempDir()
        let db = try LibraryLocation.openDatabase(root: source)
        _ = try db.insertTrack(track(1, album: "Only", artist: "Alpha", year: 2010))
        try db.saveAlbumPurchase(key: SearchIndex.albumKey(album: "Only", artist: "Alpha"),
                                 AlbumPurchase(album: "Only", artist: "Alpha", price: 12, labelNumber: 4), at: Date(timeIntervalSince1970: 50))
        try db.exec("DROP TABLE collection_items")
        let root = try TestSupport.tempDir()
        try db.vacuum(into: LibraryLocation.databaseURL(root: root).path)
        let s = try LibrarySnapshot(root: root)
        let item = try #require(s.collection.items.first)
        #expect(s.collection.items.count == 1)
        #expect(item.id == CollectionItem.legacyID(albumKey: SearchIndex.albumKey(album: "Only", artist: "Alpha")))
        #expect(item.medium == .cd && item.stickerNumber == 4 && item.price == 12)
        #expect(s.collection.digitalState(item) == .digitized(tracks: 1))
        #expect(s.purchases.values.first?.labelNumber == 4)
    }

    @Test func tracksOutsideTheRootAreNotPresent() throws {
        let (root, tracks) = try makeExport { _ in true }
        let outside = try TestSupport.tempDir()
        let album = root.appendingPathComponent("Music/alpha/Only (2010)")
        try FileManager.default.removeItem(at: album)
        try FileManager.default.createSymbolicLink(at: album, withDestinationURL: outside)
        try Data("audio".utf8).write(to: outside.appendingPathComponent("1-1.flac"))
        let s = try LibrarySnapshot(root: root)
        #expect(!s.isPresent(tracks[4]))
        #expect(s.isPresent(tracks[0]))
    }

    @Test func findsTheLibraryInDocuments() throws {
        let docs = try TestSupport.tempDir()
        #expect(LibrarySnapshot.findRoot(in: docs) == nil)

        let dragged = docs.appendingPathComponent("iPhone Export")
        try FileManager.default.createDirectory(at: dragged, withIntermediateDirectories: true)
        try Data().write(to: LibraryLocation.databaseURL(root: dragged))
        #expect(LibrarySnapshot.findRoot(in: docs)?.lastPathComponent == "iPhone Export")

        let synced = docs.appendingPathComponent(LibraryLocation.phoneFolderName)
        try FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
        try Data().write(to: LibraryLocation.databaseURL(root: synced))
        #expect(LibrarySnapshot.findRoot(in: docs)?.lastPathComponent == LibraryLocation.phoneFolderName)
    }
}
