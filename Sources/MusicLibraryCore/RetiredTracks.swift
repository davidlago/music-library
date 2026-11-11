import Foundation

/// A song removed from the library keeps its listening history, so a new copy of the same song on the same album (a
/// record digitized again, a CD ripped again, a download added again) takes back the removed song's track ID with its
/// plays and its like.
///
/// Removing a track (`Database.deleteTrack`) retires it: its ID, what identifies the song (the album key, MusicBrainz
/// release and recording, title, disc and track number) and its like go in `retired_tracks`, its plays in
/// `retired_plays`, before the track's row goes (and with it, through the foreign keys, its plays, like, playlist
/// entries, purchase, rip check and offload record, as before). Adding a track (`Database.insertTrack`) looks for a
/// retired song it is (`RetiredTrack.bestMatch`) and revives it: same ID when it's free, plays and like moved back.
///
/// Mac-only tables created on open without a schema version change (like `rip_checks`): older versions ignore them,
/// and phones on any version still read synced copies (they're emptied in the phone's snapshot, kept in backups). A
/// new track's ID is past every retired one, so an ID is never given to another song while its history waits. Older
/// versions number tracks themselves and may give a retired ID to another song after a downgrade; reviving then keeps
/// the history under a new ID. History lost before this existed (removing a track always deleted its plays) can't be
/// brought back.
public struct RetiredTrack: Equatable, Sendable {
    public var rowID: Int64
    /// The track's ID when it was removed.
    public var trackID: Int64
    public var albumKey: String
    public var releaseID: String?
    public var recordingID: String?
    public var title: String
    public var discNo: Int?
    public var trackNo: Int?
    public var sha256: String?
    public var likedAt: Date?
    public var retiredAt: Date

    public init(rowID: Int64 = 0, trackID: Int64, albumKey: String, releaseID: String? = nil, recordingID: String? = nil,
                title: String, discNo: Int? = nil, trackNo: Int? = nil, sha256: String? = nil, likedAt: Date? = nil,
                retiredAt: Date) {
        self.rowID = rowID; self.trackID = trackID; self.albumKey = albumKey; self.releaseID = releaseID
        self.recordingID = recordingID; self.title = title; self.discNo = discNo; self.trackNo = trackNo
        self.sha256 = sha256; self.likedAt = likedAt; self.retiredAt = retiredAt
    }

    /// The album a track belongs to, as the collection keys it.
    static func albumKey(of track: Track) -> String {
        SearchIndex.albumKey(album: track.metadata.album, artist: track.effectiveAlbumArtist)
    }

    /// Whether `track` is this retired song: on the same album (same album key, or both from the same MusicBrainz
    /// release), and the same recording or, failing that, the same title.
    func isSameSong(as track: Track) -> Bool {
        let m = track.metadata
        let sameAlbum = albumKey == Self.albumKey(of: track) || (releaseID != nil && releaseID == m.mbReleaseId)
        guard sameAlbum else { return false }
        if let recordingID, let other = m.mbRecordingId, recordingID == other { return true }
        let title = TextNormalizer.normalize(self.title)
        return !title.isEmpty && title == TextNormalizer.normalize(m.title)
    }

    /// Same place on the album (a song can appear twice under one title, a reprise or a hidden track).
    func isSamePosition(as track: Track) -> Bool {
        guard let trackNo, trackNo == track.metadata.trackNo else { return false }
        return (discNo ?? 1) == (track.metadata.discNo ?? 1)
    }

    /// The retired song `track` is, if any: same position first, then same recording, then the most recently removed.
    public static func bestMatch(for track: Track, in retired: [RetiredTrack]) -> RetiredTrack? {
        let m = track.metadata
        func rank(_ r: RetiredTrack) -> (Int, Int, Double, Int64) {
            let recording = r.recordingID != nil && r.recordingID == m.mbRecordingId
            return (r.isSamePosition(as: track) ? 1 : 0, recording ? 1 : 0, r.retiredAt.timeIntervalSince1970, r.rowID)
        }
        return retired.filter { $0.isSameSong(as: track) }.max { rank($0) < rank($1) }
    }
}

extension Database {
    func createRetiredTracksTables() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS retired_tracks(
            id INTEGER PRIMARY KEY, track_id INTEGER NOT NULL, album_key TEXT NOT NULL, release_id TEXT,
            recording_id TEXT, title TEXT NOT NULL, disc_no INT, track_no INT, sha256 TEXT, liked_at REAL,
            retired_at REAL NOT NULL)
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_retired_tracks_album ON retired_tracks(album_key)")
        try exec("CREATE INDEX IF NOT EXISTS idx_retired_tracks_track ON retired_tracks(track_id)")
        try exec("""
        CREATE TABLE IF NOT EXISTS retired_plays(
            id INTEGER PRIMARY KEY,
            retired_id INTEGER NOT NULL REFERENCES retired_tracks(id) ON DELETE CASCADE,
            started_at REAL NOT NULL, listened REAL NOT NULL, counted INT NOT NULL)
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_retired_plays_retired ON retired_plays(retired_id)")
    }

    private static let retiredColumns = "id,track_id,album_key,release_id,recording_id,title,disc_no,track_no,sha256,liked_at,retired_at"

    private static func retired(_ r: Row) -> RetiredTrack {
        RetiredTrack(rowID: r.int64(0), trackID: r.int64(1), albumKey: r.string(2) ?? "", releaseID: r.string(3),
                     recordingID: r.string(4), title: r.string(5) ?? "", discNo: r.int(6), trackNo: r.int(7),
                     sha256: r.string(8), likedAt: r.string(9) == nil ? nil : Date(timeIntervalSince1970: r.double(9)),
                     retiredAt: Date(timeIntervalSince1970: r.double(10)))
    }

    /// Every song removed whose history is kept, oldest first.
    public func retiredTracks() throws -> [RetiredTrack] {
        try query("SELECT \(Self.retiredColumns) FROM retired_tracks ORDER BY id", map: Self.retired)
    }

    /// The plays kept for a retired song (by its row in `retired_tracks`), oldest first.
    public func retiredPlays(_ rowID: Int64) throws -> [Play] {
        let trackID = try query("SELECT track_id FROM retired_tracks WHERE id=?", [.int(rowID)]) { $0.int64(0) }.first ?? 0
        return try query("SELECT started_at, listened, counted FROM retired_plays WHERE retired_id=? ORDER BY started_at, id",
                         [.int(rowID)]) { r in
            Play(trackId: trackID, startedAt: Date(timeIntervalSince1970: r.double(0)), listened: r.double(1), counted: (r.int(2) ?? 0) != 0)
        }
    }

    /// Keeps the track's history before it's deleted (call inside the deleting transaction).
    func retire(_ track: Track, at date: Date = Date()) throws {
        let m = track.metadata
        let likedAt = try query("SELECT liked_at FROM liked_tracks WHERE track_id=?", [.int(track.id)]) { $0.double(0) }.first
        let rowID = try query("""
        INSERT INTO retired_tracks(track_id,album_key,release_id,recording_id,title,disc_no,track_no,sha256,liked_at,retired_at)
        VALUES(?,?,?,?,?,?,?,?,?,?) RETURNING id
        """, [.int(track.id), .text(RetiredTrack.albumKey(of: track)), .text(m.mbReleaseId), .text(m.mbRecordingId),
              .text(m.title), .int(m.discNo), .int(m.trackNo), .text(track.sha256), likedAt.map { .double($0) } ?? .null,
              .double(date.timeIntervalSince1970)]) { $0.int64(0) }.first
        guard let rowID else { return }
        try exec("""
        INSERT INTO retired_plays(retired_id,started_at,listened,counted)
        SELECT ?, started_at, listened, counted FROM plays WHERE track_id=? ORDER BY started_at, id
        """, [.int(rowID), .int(track.id)])
    }

    /// The ID for a track about to be inserted, and the retired song it revives, if any: the retired song's own ID
    /// when no track has it, else one past every track and every retired song.
    func idForNewTrack(_ track: Track) throws -> (id: Int64, revived: RetiredTrack?) {
        let m = track.metadata
        let candidates = try query("""
        SELECT \(Self.retiredColumns) FROM retired_tracks WHERE album_key=? OR (release_id IS NOT NULL AND release_id=?)
        """, [.text(RetiredTrack.albumKey(of: track)), .text(m.mbReleaseId)], map: Self.retired)
        let revived = RetiredTrack.bestMatch(for: track, in: candidates)
        if let revived, revived.trackID > 0 {
            let taken = try query("SELECT 1 FROM tracks WHERE id=?", [.int(revived.trackID)], map: { $0.int(0) })
            if taken.isEmpty { return (revived.trackID, revived) }
        }
        let highest = try query("""
        SELECT MAX(IFNULL((SELECT MAX(id) FROM tracks), 0), IFNULL((SELECT MAX(track_id) FROM retired_tracks), 0))
        """) { $0.int64(0) }.first ?? 0
        return (highest + 1, revived)
    }

    /// Gives the inserted track (`trackID`) the retired song's plays and like, and forgets the retired song.
    func revive(_ retired: RetiredTrack, as trackID: Int64) throws {
        try exec("""
        INSERT INTO plays(track_id,started_at,listened,counted)
        SELECT ?, started_at, listened, counted FROM retired_plays WHERE retired_id=? ORDER BY started_at, id
        """, [.int(trackID), .int(retired.rowID)])
        if let likedAt = retired.likedAt {
            try exec("INSERT OR IGNORE INTO liked_tracks(track_id,liked_at) VALUES(?,?)",
                     [.int(trackID), .double(likedAt.timeIntervalSince1970)])
        }
        try exec("DELETE FROM retired_plays WHERE retired_id=?", [.int(retired.rowID)])
        try exec("DELETE FROM retired_tracks WHERE id=?", [.int(retired.rowID)])
    }

    /// A play the phone recorded for a song removed here since: kept with the retired song's history (when the
    /// phone's copy is the one removed), so it comes back with it. False when there's no such retired song.
    func recordRetiredPlay(trackID: Int64, sha256: String, startedAt: Date, listened: Double, counted: Bool) throws -> Bool {
        guard let rowID = try query("SELECT id FROM retired_tracks WHERE track_id=? AND sha256=? ORDER BY id DESC LIMIT 1",
                                    [.int(trackID), .text(sha256)], map: { $0.int64(0) }).first else { return false }
        try exec("INSERT INTO retired_plays(retired_id,started_at,listened,counted) VALUES(?,?,?,?)",
                 [.int(rowID), .double(startedAt.timeIntervalSince1970), .double(listened), .int(counted ? 1 : 0)])
        return true
    }
}
