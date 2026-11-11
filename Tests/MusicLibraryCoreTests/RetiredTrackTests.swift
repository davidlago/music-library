import Foundation
import Testing
@testable import MusicLibraryCore

/// Removing a song and adding a new copy of it to the same album (digitized again, ripped again, downloaded again)
/// keeps its track ID, plays and like.
@Suite struct RetiredTrackTests {
    static let day: TimeInterval = 86400

    func song(_ n: Int, title: String? = nil, album: String = "Album", artist: String = "Artist", disc: Int? = nil,
              recording: String? = nil, release: String? = nil, sha: String? = nil) -> Track {
        var m = TrackMetadata(title: title ?? "Song \(n)", artist: artist, album: album)
        m.trackNo = n
        m.discNo = disc
        m.mbRecordingId = recording
        m.mbReleaseId = release
        return Track(path: "Music/\(artist)/\(album)/\(n) \(UUID().uuidString).flac", metadata: m, duration: 100, format: "flac",
                     sha256: sha ?? UUID().uuidString)
    }

    func play(_ db: Database, _ track: Track, times: Int, from start: TimeInterval = 1_000) throws {
        for i in 0..<times {
            try db.recordPlay(trackId: track.id, startedAt: Date(timeIntervalSince1970: start + Double(i) * Self.day),
                              listened: 90, counted: true)
        }
    }

    @Test func aNewCopyOfTheSameSongTakesBackItsIDPlaysAndLike() throws {
        let db = try Database(path: ":memory:")
        let tracks = try (1...3).map { try db.insertTrack(song($0)) }
        try play(db, tracks[1], times: 4)
        try db.recordPlay(trackId: tracks[1].id, startedAt: Date(timeIntervalSince1970: 50), listened: 5, counted: false)
        let liked = Date(timeIntervalSince1970: 3_000)
        try db.setLiked([tracks[1].id], true, at: liked)
        let before = try db.plays().filter { $0.trackId == tracks[1].id }

        try db.deleteTrack(id: tracks[1].id)
        #expect(try db.playTotals()[tracks[1].id] == nil)
        #expect(try db.likedTrackDates().isEmpty)
        #expect(try db.retiredTracks().map(\.trackID) == [tracks[1].id])

        // A new file (another rip: other bytes, other path) of the same song on the same album.
        let again = try db.insertTrack(song(2))
        #expect(again.id == tracks[1].id)
        #expect(try db.playTotals()[again.id]?.plays == 4)
        #expect(try db.plays().filter { $0.trackId == again.id } == before)
        #expect(try db.likedTrackDates() == [again.id: liked])
        #expect(try db.retiredTracks().isEmpty)
        #expect(try db.query("SELECT COUNT(*) FROM retired_plays") { $0.int(0) ?? 0 }.first == 0)
    }

    @Test func otherSongsNeverTakeARemovedSongsID() throws {
        let db = try Database(path: ":memory:")
        let a = try db.insertTrack(song(1))
        let b = try db.insertTrack(song(2))
        try play(db, b, times: 2)
        // The highest ID: SQLite alone would give it to the next track.
        try db.deleteTrack(id: b.id)
        let other = try db.insertTrack(song(1, title: "Something Else", album: "Another Album"))
        #expect(other.id != b.id && other.id > b.id && other.id != a.id)
        #expect(try db.playTotals()[other.id] == nil)
        // And the removed one still comes back as itself.
        #expect(try db.insertTrack(song(2)).id == b.id)
        #expect(try db.playTotals()[b.id]?.plays == 2)
    }

    @Test func onlyTheSameSongOnTheSameAlbumMatches() throws {
        let db = try Database(path: ":memory:")
        let t = try db.insertTrack(song(1, title: "Intro"))
        try play(db, t, times: 3)
        try db.deleteTrack(id: t.id)
        // Same title on another album, another title on the same album: new songs.
        let elsewhere = try db.insertTrack(song(1, title: "Intro", album: "Live"))
        let otherTitle = try db.insertTrack(song(1, title: "Outro"))
        #expect(elsewhere.id != t.id && otherTitle.id != t.id)
        #expect(try db.playTotals().isEmpty)
        // Titles match loosely (case, accents, punctuation), and the album artist decides the album.
        let back = try db.insertTrack(song(1, title: "  intro! "))
        #expect(back.id == t.id)
        #expect(try db.playTotals()[t.id]?.plays == 3)
    }

    @Test func matchesByRecordingOrReleaseWhenNamesDiffer() throws {
        let db = try Database(path: ":memory:")
        let recording = "11111111-1111-1111-1111-111111111111", release = "22222222-2222-2222-2222-222222222222"
        let t = try db.insertTrack(song(5, title: "Song (2009 Remaster)", recording: recording, release: release))
        try play(db, t, times: 1)
        try db.deleteTrack(id: t.id)
        // Retagged album name, but the same release and recording.
        let back = try db.insertTrack(song(5, title: "Song", album: "Album (Deluxe)", recording: recording, release: release))
        #expect(back.id == t.id)
        #expect(try db.playTotals()[t.id]?.plays == 1)
    }

    @Test func aTitleThatAppearsTwiceGoesByPosition() throws {
        let db = try Database(path: ":memory:")
        let first = try db.insertTrack(song(1, title: "Theme", disc: 1))
        let second = try db.insertTrack(song(1, title: "Theme", disc: 2))
        try play(db, first, times: 1)
        try play(db, second, times: 5)
        try db.deleteTracks(ids: [first.id, second.id])
        let disc2 = try db.insertTrack(song(1, title: "Theme", disc: 2))
        let disc1 = try db.insertTrack(song(1, title: "Theme", disc: 1))
        #expect(disc2.id == second.id && disc1.id == first.id)
        #expect(try db.playTotals()[second.id]?.plays == 5)
        #expect(try db.playTotals()[first.id]?.plays == 1)
    }

    @Test func removedAndAddedAgainSeveralTimesKeepsEverything() throws {
        let db = try Database(path: ":memory:")
        var t = try db.insertTrack(song(1))
        for round in 1...3 {
            try play(db, t, times: 1, from: Double(round) * 10 * Self.day)
            try db.deleteTrack(id: t.id)
            let id = t.id
            t = try db.insertTrack(song(1))
            #expect(t.id == id)
            #expect(try db.playTotals()[t.id]?.plays == round)
        }
    }

    /// After a downgrade an older version may give the removed song's ID to another track: the history comes back
    /// under a new ID instead, never mixed into the other song's.
    @Test func aTakenIDRevivesUnderANewOne() throws {
        let db = try Database(path: ":memory:")
        let t = try db.insertTrack(song(1))
        try play(db, t, times: 2)
        try db.deleteTrack(id: t.id)
        // What an older version's insert does: SQLite's next rowid.
        try db.exec("INSERT INTO tracks(id,path,title,artist,album,sha256) VALUES(?,'Music/x.flac','Other','Someone','Else','x')", [.int(t.id)])
        let back = try db.insertTrack(song(1))
        #expect(back.id != t.id)
        #expect(try db.playTotals()[back.id]?.plays == 2)
        #expect(try db.playTotals()[t.id] == nil)
        #expect(try db.retiredTracks().isEmpty)
    }

    @Test func thePhonesPlaysOfARemovedSongWaitWithIt() throws {
        let db = try Database(path: ":memory:")
        let t = try db.insertTrack(song(1))
        let played = SyncEvent(track: t, at: Date(timeIntervalSince1970: 7 * Self.day), kind: .play(listened: 100, counted: true))
        let liked = SyncEvent(track: t, at: Date(timeIntervalSince1970: 7 * Self.day), kind: .like(true))
        try db.deleteTrack(id: t.id)
        let result = try db.applySyncEvents([played, liked], libraryID: nil)
        #expect(result.plays == 1 && result.dropped == 1)
        #expect(try db.retiredTracks().first.map { try db.retiredPlays($0.rowID).count } == 1)
        // Another library's events never do.
        let foreign = SyncEvent(track: t, at: Date(timeIntervalSince1970: 8 * Self.day), kind: .play(listened: 100, counted: true))
        #expect(try db.applySyncEvents([foreign], libraryID: "another-library").dropped == 1)
        #expect(try db.insertTrack(song(1)).id == t.id)
        #expect(try db.playTotals()[t.id]?.plays == 1)
    }

    @Test func thePhonesCopyLeavesTheHistoryOutAndBackupsKeepIt() throws {
        let dir = try TestSupport.tempDir()
        let db = try Database(path: dir.appendingPathComponent("library.sqlite").path)
        let t = try db.insertTrack(song(1))
        try play(db, t, times: 2)
        try db.deleteTrack(id: t.id)
        let phone = dir.appendingPathComponent("phone.sqlite"), backup = dir.appendingPathComponent("backup.sqlite")
        try db.writeSyncSnapshot(to: phone, scratch: dir.appendingPathComponent("scratch"))
        try db.writeBackupSnapshot(to: backup, scratch: dir.appendingPathComponent("scratch"), snapshotAt: Date())
        func count(_ url: URL, _ table: String) throws -> Int {
            try Database(snapshotAt: url.path).query("SELECT COUNT(*) FROM \(table)") { $0.int(0) ?? 0 }.first ?? -1
        }
        #expect(try count(phone, "retired_tracks") == 0 && count(phone, "retired_plays") == 0)
        #expect(try count(backup, "retired_tracks") == 1 && count(backup, "retired_plays") == 2)
    }

    /// A library from a version before this: the tables are made on open (no schema version change, so phones on
    /// older versions still read synced copies), and nothing else changes.
    @Test func aLibraryFromAnEarlierVersionGetsTheTablesOnOpen() throws {
        let dir = try TestSupport.tempDir()
        let path = dir.appendingPathComponent("library.sqlite").path
        var db: Database? = try Database(path: path)
        let t = try db!.insertTrack(song(1))
        try play(db!, t, times: 3)
        try db!.exec("DROP TABLE retired_plays")
        try db!.exec("DROP TABLE retired_tracks")
        db = nil
        let reopened = try Database(path: path)
        #expect(try reopened.query("PRAGMA user_version") { $0.int(0) ?? 0 }.first == Database.schemaVersion)
        #expect(try reopened.playTotals()[t.id]?.plays == 3)
        try reopened.deleteTrack(id: t.id)
        #expect(try reopened.insertTrack(song(1)).id == t.id)
        #expect(try reopened.playTotals()[t.id]?.plays == 3)
    }

    @Test func matchingRules() {
        let removed = RetiredTrack(rowID: 1, trackID: 9, albumKey: SearchIndex.albumKey(album: "Album", artist: "Band"),
                                   title: "Song", discNo: nil, trackNo: 3, retiredAt: Date(timeIntervalSince1970: 0))
        var t = song(3, title: "song", album: "ALBUM", artist: "Someone")
        t.metadata.albumArtist = "Band"
        #expect(RetiredTrack.bestMatch(for: t, in: [removed]) == removed)
        t.metadata.albumArtist = ""
        #expect(RetiredTrack.bestMatch(for: t, in: [removed]) == nil)
        // Nothing to go by: an untitled song never matches.
        let untitled = RetiredTrack(rowID: 2, trackID: 10, albumKey: removed.albumKey, title: "", retiredAt: Date())
        var blank = song(1, title: "", album: "Album", artist: "Band")
        blank.metadata.title = ""
        #expect(RetiredTrack.bestMatch(for: blank, in: [untitled]) == nil)
        // The most recently removed of two equal matches.
        let newer = RetiredTrack(rowID: 3, trackID: 11, albumKey: removed.albumKey, title: "Song", trackNo: 3,
                                 retiredAt: Date(timeIntervalSince1970: 100))
        t.metadata.albumArtist = "Band"
        #expect(RetiredTrack.bestMatch(for: t, in: [removed, newer]) == newer)
    }
}
