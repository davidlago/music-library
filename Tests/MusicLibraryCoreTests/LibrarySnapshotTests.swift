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
