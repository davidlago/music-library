import Foundation
import SQLite3
import Testing
@testable import MusicLibraryCore

private struct Rel {
    var title: String
    var status = "Official"
    var type = "Album"
    var secondary: [String] = []
    var date: String?
}

private func searchJSON(score: Int = 100, _ rels: [Rel]) -> Data {
    let releases: [[String: Any]] = rels.enumerated().map { i, r in
        var group: [String: Any] = ["id": "rg\(i)", "primary-type": r.type]
        if !r.secondary.isEmpty { group["secondary-types"] = r.secondary }
        var rel: [String: Any] = ["id": "rel\(i)", "title": r.title, "status": r.status, "release-group": group]
        if let d = r.date { rel["date"] = d }
        return rel
    }
    let rec: [String: Any] = ["id": "rec", "score": score, "title": "Song", "length": 200_000,
                              "artist-credit": [["name": "Artist"]], "releases": releases]
    return try! JSONSerialization.data(withJSONObject: ["recordings": [rec]])
}

@Suite struct RankingTests {
    @Test func albumHintBeatsCompilationAtSameScore() throws {
        let data = searchJSON([Rel(title: "Greatest Hits", type: "Album", secondary: ["Compilation"], date: "1990"),
                               Rel(title: "The Album", date: "2000")])
        let c = try MusicBrainzParser.parseSearch(data, albumHint: "the album")
        #expect(c.first?.album == "The Album")
        #expect(c[1].secondaryTypes == ["Compilation"])
    }

    @Test func secondaryTypesArePenalized() throws {
        let data = searchJSON([Rel(title: "A", secondary: ["Live"], date: "1990"), Rel(title: "B", date: "2000")])
        #expect(try MusicBrainzParser.parseSearch(data).map(\.album) == ["B", "A"])
    }

    @Test func officialAndAlbumPreferred() throws {
        let data = searchJSON([Rel(title: "Bootleg", status: "Bootleg", type: "Album"), Rel(title: "Single", type: "Single"), Rel(title: "Real")])
        #expect(try MusicBrainzParser.parseSearch(data).map(\.album) == ["Real", "Single", "Bootleg"])
    }

    @Test func scoreStaysPrimary() throws {
        let hi = searchJSON(score: 100, [Rel(title: "Other", status: "Bootleg")])
        let lo = searchJSON(score: 80, [Rel(title: "Wanted")])
        let merged = try MusicBrainzParser.parseSearch(hi, albumHint: "Wanted") + MusicBrainzParser.parseSearch(lo, albumHint: "Wanted")
        #expect(merged.map(\.score) == [100, 80])
    }

    @Test func earliestDateFirstUnknownLast() throws {
        let data = searchJSON([Rel(title: "X"), Rel(title: "X", date: "2009-03-24"), Rel(title: "X", date: "1997-05-21")])
        #expect(try MusicBrainzParser.parseSearch(data, albumHint: "x").map(\.date) == ["1997-05-21", "2009-03-24", nil])
    }

    @Test func fixtureHasSecondaryTypes() throws {
        let c = try MusicBrainzParser.parseSearch(try TestSupport.fixture("mb_search_airbag"))
        #expect(c.contains { $0.secondaryTypes.contains("Compilation") })
        #expect(c.last { $0.score == 100 }?.secondaryTypes.isEmpty == false)
    }

    @Test func autoMatchRequiresAlbumHintMatch() {
        let c = MatchCandidate(recordingId: "r", releaseId: "x", title: "T", artist: "A", album: "Greatest Hits", durationSeconds: 100, score: 100)
        #expect(AutoMatch.isConfident(c, trackDuration: 100))
        #expect(!AutoMatch.isConfident(c, trackDuration: 100, albumHint: "Real Album"))
        #expect(AutoMatch.isConfident(c, trackDuration: 100, albumHint: "greatest  hits!"))
    }
}

@Suite struct OriginalYearTests {
    @Test func releaseOriginalYearUsedWhenApplying() throws {
        let data = Data(#"""
        {"id":"r1","title":"OK Computer","date":"2009-03-24","artist-credit":[{"name":"Radiohead"}],
         "release-group":{"id":"g","first-release-date":"1997-05-21"},
         "media":[{"position":1,"track-count":1,"tracks":[{"position":1,"title":"Airbag","recording":{"id":"rec"}}]}]}
        """#.utf8)
        let r = try MusicBrainzParser.parseRelease(data)
        #expect(r.year == 2009 && r.originalYear == 1997)
        var m = TrackMetadata(year: 2000)
        r.apply(r.tracks[0], to: &m)
        #expect(m.year == 1997)
    }

    @Test func fixtureOriginalYear() throws {
        let r = try MusicBrainzParser.parseRelease(try TestSupport.fixture("mb_release_okcomputer"))
        #expect(r.year == 2009 && r.originalYear == 1997)
    }

    @Test func fallsBackToReleaseYear() {
        let r = ReleaseInfo(id: "r", releaseGroupId: nil, album: "A", albumArtist: "B", date: "2009", year: 2009, originalYear: nil, discTotal: 1,
                            tracks: [ReleaseTrack(recordingId: "x", title: "T", artist: "B", discNo: 1, trackNo: 1, trackTotal: 1, durationSeconds: nil)])
        var m = TrackMetadata(year: 1990)
        r.apply(r.tracks[0], to: &m)
        #expect(m.year == 2009)
    }
}

@Suite struct GroupingTests {
    @Test func groupKey() {
        #expect(AlbumGrouping.key(for: TrackMetadata(artist: "Radiohead", album: "OK Computer")) == "radiohead|ok computer")
        #expect(AlbumGrouping.key(for: TrackMetadata(artist: "Guest", album: "Café!", albumArtist: "Various Artists")) == "various artists|cafe")
        #expect(AlbumGrouping.key(for: TrackMetadata(artist: "Radiohead", album: "")) == nil)
        #expect(AlbumGrouping.key(for: TrackMetadata(artist: "RADIOHEAD", album: "ok computer"))
                == AlbumGrouping.key(for: TrackMetadata(artist: "Radiohead", album: "OK Computer")))
    }

    func release() throws -> ReleaseInfo { try MusicBrainzParser.parseRelease(try TestSupport.fixture("mb_release_okcomputer")) }

    @Test func siblingMatchPositive() throws {
        let r = try release()
        let sibling = (tags: TrackMetadata(artist: "Radiohead", album: "OK Computer"), release: r)
        let hit = SiblingMatcher.match(tags: TrackMetadata(title: "Karma Police", artist: "radiohead", album: "OK COMPUTER", trackNo: nil),
                                       entryId: "e", siblings: [sibling])
        #expect(hit == nil)
        let hit2 = SiblingMatcher.match(tags: TrackMetadata(title: "Paranoid Android", artist: "Radiohead", album: "OK Computer"),
                                        entryId: "e", siblings: [sibling])
        #expect(hit2?.1.title == "Paranoid Android")
        #expect(hit2?.0.id == r.id)
    }

    @Test func siblingMatchDifferentAlbumAndEmptyAlbum() throws {
        let r = try release()
        let sibling = (tags: TrackMetadata(artist: "Radiohead", album: "OK Computer"), release: r)
        #expect(SiblingMatcher.match(tags: TrackMetadata(title: "Airbag", artist: "Radiohead", album: "The Bends"), entryId: "e", siblings: [sibling]) == nil)
        #expect(SiblingMatcher.match(tags: TrackMetadata(title: "Airbag", artist: "Radiohead", album: ""), entryId: "e", siblings: [sibling]) == nil)
        #expect(SiblingMatcher.match(tags: TrackMetadata(title: "Airbag", artist: "Radiohead", album: "OK Computer"), entryId: "e", siblings: []) == nil)
    }
}

@Suite struct SearchNormalizationTests {
    func track(_ n: Int, _ title: String, _ artist: String, _ album: String = "Alb") -> Track {
        Track(path: "p\(n)", metadata: TrackMetadata(title: title, artist: artist, album: album), duration: 1, format: "mp3", sha256: "s\(n)")
    }

    @Test func accentAndPunctuationInsensitive() throws {
        let db = try Database(path: ":memory:")
        try db.insertTrack(track(1, "Café", "X"))
        try db.insertTrack(track(2, "Halo", "Beyoncé"))
        try db.insertTrack(track(3, "Thunderstruck", "AC/DC"))
        #expect(try db.search("cafe").map(\.title) == ["Café"])
        #expect(try db.search("beyonce").map(\.title) == ["Halo"])
        #expect(try db.search("ac dc").map(\.title) == ["Thunderstruck"])
        #expect(try db.search("BEYONCÉ halo").count == 1)
    }

    @Test func updateRefreshesSearchText() throws {
        let db = try Database(path: ":memory:")
        var t = try db.insertTrack(track(1, "Old", "X"))
        t.metadata.title = "Señorita"
        try db.updateTrack(t)
        #expect(try db.search("senorita").count == 1)
        #expect(try db.search("old").isEmpty)
    }

    @Test func v1DatabaseIsMigratedAndBackfilled() throws {
        let path = try TestSupport.tempDir().appendingPathComponent("v1.sqlite").path
        var raw: OpaquePointer?
        #expect(sqlite3_open(path, &raw) == SQLITE_OK)
        let sql = """
        CREATE TABLE tracks(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, title TEXT, artist TEXT, album TEXT, album_artist TEXT,
          year INT, track_no INT, track_total INT, disc_no INT, disc_total INT, genre TEXT, duration REAL, format TEXT,
          mb_recording_id TEXT, mb_release_id TEXT, sha256 TEXT UNIQUE, added_at REAL);
        CREATE TABLE playlists(id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at REAL);
        CREATE TABLE playlist_tracks(playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
          track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE, position INT NOT NULL, PRIMARY KEY(playlist_id, position));
        INSERT INTO tracks(path,title,artist,album,album_artist,sha256,added_at) VALUES('a.mp3','Déjà Vu','Beyoncé','Lemonade','','sha',0);
        PRAGMA user_version=1;
        """
        #expect(sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let db = try Database(path: path)
        #expect(try db.search("deja vu beyonce").count == 1)
        #expect(try db.query("PRAGMA user_version") { $0.int(0) }.first == Database.schemaVersion)
    }
}
