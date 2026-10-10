import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct DatabaseTests {
    func makeTrack(_ n: Int, title: String = "", artist: String = "Artist", album: String = "Album", albumArtist: String = "") -> Track {
        Track(path: "Music/\(artist)/\(album)/\(n).mp3",
              metadata: TrackMetadata(title: title.isEmpty ? "Song \(n)" : title, artist: artist, album: album, albumArtist: albumArtist, year: 2000, trackNo: n),
              duration: 100, format: "mp3", sha256: "sha\(artist)\(album)\(n)")
    }

    @Test func crud() throws {
        let db = try Database(path: ":memory:")
        var t = try db.insertTrack(makeTrack(1))
        #expect(t.id > 0)
        #expect(try db.trackBySha256(t.sha256)?.id == t.id)
        t.metadata.title = "Renamed"
        try db.updateTrack(t)
        #expect(try db.track(id: t.id)?.title == "Renamed")
        #expect(try db.fetchAllTracks().count == 1)
        try db.deleteTrack(id: t.id)
        #expect(try db.trackCount() == 0)
    }

    @Test func uniqueSha() throws {
        let db = try Database(path: ":memory:")
        try db.insertTrack(makeTrack(1))
        var dup = makeTrack(2)
        dup.sha256 = makeTrack(1).sha256
        #expect(throws: DatabaseError.self) { try db.insertTrack(dup) }
    }

    @Test func searchTokensAndedAcrossFields() throws {
        let db = try Database(path: ":memory:")
        try db.insertTrack(makeTrack(1, title: "Airbag", artist: "Radiohead", album: "OK Computer"))
        try db.insertTrack(makeTrack(2, title: "Karma Police", artist: "Radiohead", album: "OK Computer"))
        try db.insertTrack(makeTrack(3, title: "Airbag Cover", artist: "Someone", album: "Tributes", albumArtist: "Various Artists"))
        #expect(try db.search("airbag").count == 2)
        #expect(try db.search("AIRBAG radiohead").map(\.title) == ["Airbag"])
        #expect(try db.search("computer karma").count == 1)
        #expect(try db.search("various").count == 1)
        #expect(try db.search("  ").count == 3)
        #expect(try db.search("100%").count == 0)
        #expect(try db.search("zzz").isEmpty)
    }

    @Test func albumsAndArtists() throws {
        let db = try Database(path: ":memory:")
        try db.insertTrack(makeTrack(1, artist: "A", album: "X"))
        try db.insertTrack(makeTrack(2, artist: "A", album: "X"))
        try db.insertTrack(makeTrack(1, artist: "A", album: "Y"))
        try db.insertTrack(makeTrack(1, artist: "Guest", album: "Comp", albumArtist: "Various Artists"))
        try db.insertTrack(makeTrack(2, artist: "Other", album: "Comp", albumArtist: "Various Artists"))
        let albums = try db.albums()
        #expect(albums.count == 3)
        #expect(albums.first { $0.album == "Comp" }?.trackCount == 2)
        let artists = try db.artists()
        #expect(artists.map(\.name) == ["A", "Various Artists"])
        #expect(artists.first?.albumCount == 2)
        #expect(try db.albums(artist: "A").count == 2)
        #expect(try db.tracks(album: "X", artist: "A").map(\.trackNo) == [1, 2])
    }

    func seededPlaylist(_ db: Database, count: Int) throws -> (Playlist, [Track]) {
        var tracks: [Track] = []
        for i in 1...count { tracks.append(try db.insertTrack(makeTrack(i))) }
        let p = try db.createPlaylist(name: "P")
        try db.addTracks(tracks.map(\.id), toPlaylist: p.id)
        return (p, tracks)
    }

    func positions(_ db: Database, _ id: Int64) throws -> [Int] {
        try db.query("SELECT position FROM playlist_tracks WHERE playlist_id=? ORDER BY position", [.int(id)]) { $0.int(0) ?? -1 }
    }

    @Test func playlistAddRemoveKeepsContiguous() throws {
        let db = try Database(path: ":memory:")
        let (p, t) = try seededPlaylist(db, count: 5)
        #expect(try positions(db, p.id) == [0, 1, 2, 3, 4])
        try db.removeTracks(atPositions: [1, 3], fromPlaylist: p.id)
        #expect(try db.playlistTrackIds(p.id) == [t[0].id, t[2].id, t[4].id])
        #expect(try positions(db, p.id) == [0, 1, 2])
        try db.addTracks([t[1].id, t[1].id], toPlaylist: p.id)
        #expect(try positions(db, p.id) == [0, 1, 2, 3, 4])
        #expect(try db.playlists().first?.trackCount == 5)
    }

    @Test func playlistMove() throws {
        let db = try Database(path: ":memory:")
        let (p, t) = try seededPlaylist(db, count: 5)
        let ids = t.map(\.id)
        try db.moveTracks(inPlaylist: p.id, fromOffsets: [0], toOffset: 3)
        #expect(try db.playlistTrackIds(p.id) == [ids[1], ids[2], ids[0], ids[3], ids[4]])
        try db.moveTracks(inPlaylist: p.id, fromOffsets: [4], toOffset: 0)
        #expect(try db.playlistTrackIds(p.id) == [ids[4], ids[1], ids[2], ids[0], ids[3]])
        try db.moveTracks(inPlaylist: p.id, fromOffsets: [0, 1], toOffset: 5)
        #expect(try db.playlistTrackIds(p.id) == [ids[2], ids[0], ids[3], ids[4], ids[1]])
        #expect(try positions(db, p.id) == [0, 1, 2, 3, 4])
    }

    @Test func cascadeOnTrackAndPlaylistDelete() throws {
        let db = try Database(path: ":memory:")
        let (p, t) = try seededPlaylist(db, count: 3)
        try db.deleteTrack(id: t[1].id)
        #expect(try db.playlistTrackIds(p.id) == [t[0].id, t[2].id])
        try db.deletePlaylist(id: p.id)
        #expect(try db.query("SELECT COUNT(*) FROM playlist_tracks") { $0.int(0) ?? 0 }.first == 0)
        #expect(try db.trackCount() == 2)
    }

    @Test func renamePlaylist() throws {
        let db = try Database(path: ":memory:")
        let p = try db.createPlaylist(name: "Old")
        try db.renamePlaylist(id: p.id, name: "New")
        #expect(try db.playlists().map(\.name) == ["New"])
    }

    @Test func persistsOnDiskWithWAL() throws {
        let dir = try TestSupport.tempDir()
        let path = dir.appendingPathComponent("l.sqlite").path
        do { let db = try Database(path: path); try db.insertTrack(makeTrack(1)) }
        let db2 = try Database(path: path)
        #expect(try db2.trackCount() == 1)
        #expect(try db2.query("PRAGMA user_version") { $0.int(0) }.first == Database.schemaVersion)
    }
}
