import Foundation
import SQLite3

public enum DatabaseError: Error, LocalizedError {
    case open(String)
    case sql(message: String, statement: String)

    public var errorDescription: String? {
        switch self {
        case .open(let m): return "Could not open library database: \(m)"
        case .sql(let m, let s): return "Database error: \(m) (\(s))"
        }
    }
}

enum Bind {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    static func text(_ s: String?) -> Bind { s.map { .text($0) } ?? .null }
    static func int(_ i: Int?) -> Bind { i.map { .int(Int64($0)) } ?? .null }
}

struct Row {
    let stmt: OpaquePointer
    func string(_ i: Int32) -> String? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    func int(_ i: Int32) -> Int? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
    }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
}

public final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0
    static let schemaVersion = 7

    public init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw DatabaseError.open(msg)
        }
        try exec("PRAGMA foreign_keys=ON")
        if path != ":memory:" { try exec("PRAGMA journal_mode=WAL") }
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: Low level

    private func error(_ sql: String) -> DatabaseError {
        .sql(message: String(cString: sqlite3_errmsg(db)), statement: sql)
    }

    func exec(_ sql: String, _ binds: [Bind] = []) throws {
        _ = try query(sql, binds) { _ in () }
    }

    @discardableResult
    func query<T>(_ sql: String, _ binds: [Bind] = [], map: (Row) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw error(sql)
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            }
        }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(map(Row(stmt: stmt))) }
            else if rc == SQLITE_DONE { break }
            else { throw error(sql) }
        }
        return out
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if transactionDepth > 0 { return try body() }
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        try exec("BEGIN")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Writes a compacted, self-contained copy of the database (WAL included) to a new file at `path`.
    public func vacuum(into path: String) throws {
        try exec("VACUUM INTO ?", [.text(path)])
    }

    private func migrate() throws {
        let version = try query("PRAGMA user_version") { $0.int(0) ?? 0 }.first ?? 0
        if version < 1 {
            try transaction {
                try exec("""
                CREATE TABLE IF NOT EXISTS tracks(
                    id INTEGER PRIMARY KEY,
                    path TEXT UNIQUE NOT NULL,
                    title TEXT, artist TEXT, album TEXT, album_artist TEXT,
                    year INT, track_no INT, track_total INT, disc_no INT, disc_total INT,
                    genre TEXT, duration REAL, format TEXT,
                    mb_recording_id TEXT, mb_release_id TEXT,
                    sha256 TEXT UNIQUE, added_at REAL)
                """)
                try exec("""
                CREATE TABLE IF NOT EXISTS playlists(
                    id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at REAL)
                """)
                try exec("""
                CREATE TABLE IF NOT EXISTS playlist_tracks(
                    playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                    track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                    position INT NOT NULL,
                    PRIMARY KEY(playlist_id, position))
                """)
                try exec("CREATE INDEX IF NOT EXISTS idx_playlist_tracks_track ON playlist_tracks(track_id)")
            }
        }
        if version < 2 {
            try transaction {
                try exec("ALTER TABLE tracks ADD COLUMN search_text TEXT")
                let rows = try query("SELECT id,title,artist,album,album_artist FROM tracks") { r in
                    (r.int64(0), Self.searchText(r.string(1), r.string(2), r.string(3), r.string(4)))
                }
                for (id, text) in rows { try exec("UPDATE tracks SET search_text=? WHERE id=?", [.text(text), .int(id)]) }
            }
        }
        if version < 3 {
            try transaction {
                try exec("ALTER TABLE tracks ADD COLUMN composer TEXT")
                try exec("ALTER TABLE tracks ADD COLUMN details_json TEXT")
                let rows = try query("SELECT id,title,artist,album,album_artist FROM tracks") { r in
                    (r.int64(0), Self.searchText(r.string(1), r.string(2), r.string(3), r.string(4)))
                }
                for (id, text) in rows { try exec("UPDATE tracks SET search_text=? WHERE id=?", [.text(text), .int(id)]) }
            }
        }
        if version < 4 {
            try transaction {
                for col in ["codec TEXT", "sample_rate INT", "bit_depth INT", "bitrate INT", "channels INT"] {
                    try exec("ALTER TABLE tracks ADD COLUMN \(col)")
                }
            }
        }
        if version < 5 {
            try exec("""
            CREATE TABLE IF NOT EXISTS smart_playlists(
                id INTEGER PRIMARY KEY, name TEXT NOT NULL, query TEXT NOT NULL, created_at REAL)
            """)
        }
        if version < 6 {
            try transaction {
                try exec("""
                CREATE TABLE IF NOT EXISTS plays(
                    id INTEGER PRIMARY KEY,
                    track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                    started_at REAL NOT NULL, listened REAL NOT NULL, counted INT NOT NULL)
                """)
                try exec("CREATE INDEX IF NOT EXISTS idx_plays_track ON plays(track_id)")
                try exec("""
                CREATE TABLE IF NOT EXISTS artist_info(
                    key TEXT PRIMARY KEY, json TEXT NOT NULL, image_file TEXT, fetched_at REAL NOT NULL)
                """)
            }
        }
        if version < 7 {
            try exec("CREATE TABLE IF NOT EXISTS album_info(key TEXT PRIMARY KEY, json TEXT NOT NULL, fetched_at REAL NOT NULL)")
        }
        try exec("PRAGMA user_version=\(Self.schemaVersion)")
    }

    // MARK: Tracks

    private static let trackColumns = "id,path,title,artist,album,album_artist,year,track_no,track_total,disc_no,disc_total,genre,duration,format,mb_recording_id,mb_release_id,sha256,added_at,composer,details_json,codec,sample_rate,bit_depth,bitrate,channels"
    private static let trackOrder = "ORDER BY artist COLLATE NOCASE, album COLLATE NOCASE, disc_no, track_no, title COLLATE NOCASE"

    private static func track(_ r: Row) -> Track {
        Track(
            id: r.int64(0), path: r.string(1) ?? "",
            metadata: TrackMetadata(
                title: r.string(2) ?? "", artist: r.string(3) ?? "", album: r.string(4) ?? "",
                albumArtist: r.string(5) ?? "", year: r.int(6), trackNo: r.int(7), trackTotal: r.int(8),
                discNo: r.int(9), discTotal: r.int(10), genre: r.string(11) ?? "",
                mbRecordingId: r.string(14), mbReleaseId: r.string(15)),
            duration: r.double(12), format: r.string(13) ?? "", sha256: r.string(16) ?? "",
            addedAt: Date(timeIntervalSince1970: r.double(17)))
            .withDetails(composer: r.string(18), json: r.string(19))
            .withAudio(codec: r.string(20), rate: r.int(21), bits: r.int(22), bitrate: r.int(23), channels: r.int(24))
    }

    static func searchText(_ m: TrackMetadata) -> String {
        searchText(m.title, m.artist, m.album, m.albumArtist, m.composer, m.extended.lyricist,
                   m.extended.conductor, m.extended.label, m.extended.workTitle)
    }

    static func searchText(_ parts: String?...) -> String {
        TextNormalizer.normalize(parts.map { $0 ?? "" }.joined(separator: " "))
    }

    private func trackBinds(_ t: Track) -> [Bind] {
        let m = t.metadata
        return [
            .text(t.path), .text(m.title), .text(m.artist), .text(m.album), .text(m.albumArtist),
            .int(m.year), .int(m.trackNo), .int(m.trackTotal), .int(m.discNo), .int(m.discTotal),
            .text(m.genre), .double(t.duration), .text(t.format),
            .text(m.mbRecordingId), .text(m.mbReleaseId), .text(t.sha256),
            .double(t.addedAt.timeIntervalSince1970),
            .text(Self.searchText(m)),
            .text(m.composer),
            m.extended == ExtendedMetadata() ? .null : .text(String(decoding: (try? JSONEncoder().encode(m.extended)) ?? Data(), as: UTF8.self)),
            .text(t.audioFormat?.codec), .int(t.audioFormat?.sampleRate), .int(t.audioFormat?.bitDepth),
            .int(t.audioFormat?.bitrate), .int(t.audioFormat?.channels),
        ]
    }

    @discardableResult
    public func insertTrack(_ track: Track) throws -> Track {
        try transaction {
            try exec("""
            INSERT INTO tracks(path,title,artist,album,album_artist,year,track_no,track_total,disc_no,disc_total,genre,duration,format,mb_recording_id,mb_release_id,sha256,added_at,search_text,composer,details_json,codec,sample_rate,bit_depth,bitrate,channels)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, trackBinds(track))
            var t = track
            t.id = try query("SELECT last_insert_rowid()") { $0.int64(0) }.first ?? 0
            return t
        }
    }

    public func updateTrack(_ track: Track) throws {
        try exec("""
        UPDATE tracks SET path=?,title=?,artist=?,album=?,album_artist=?,year=?,track_no=?,track_total=?,disc_no=?,disc_total=?,genre=?,duration=?,format=?,mb_recording_id=?,mb_release_id=?,sha256=?,added_at=?,search_text=?,composer=?,details_json=?,codec=?,sample_rate=?,bit_depth=?,bitrate=?,channels=? WHERE id=?
        """, trackBinds(track) + [.int(track.id)])
    }

    public func updateAudioFormat(id: Int64, _ f: AudioFormat) throws {
        try exec("UPDATE tracks SET codec=?,sample_rate=?,bit_depth=?,bitrate=?,channels=? WHERE id=?",
                 [.text(f.codec), .int(f.sampleRate), .int(f.bitDepth), .int(f.bitrate), .int(f.channels), .int(id)])
    }

    public func tracksMissingAudioFormat() throws -> [Track] {
        try query("SELECT \(Self.trackColumns) FROM tracks WHERE codec IS NULL ORDER BY id", map: Self.track)
    }

    public func deleteTrack(id: Int64) throws {
        try exec("DELETE FROM tracks WHERE id=?", [.int(id)])
    }

    public func deleteTracks(ids: [Int64]) throws {
        try transaction { for id in ids { try deleteTrack(id: id) } }
    }

    public func track(id: Int64) throws -> Track? {
        try query("SELECT \(Self.trackColumns) FROM tracks WHERE id=?", [.int(id)], map: Self.track).first
    }

    public func tracks(releaseId: String) throws -> [Track] {
        try query("SELECT \(Self.trackColumns) FROM tracks WHERE mb_release_id=? ORDER BY disc_no, track_no", [.text(releaseId)], map: Self.track)
    }

    public func trackBySha256(_ sha: String) throws -> Track? {
        try query("SELECT \(Self.trackColumns) FROM tracks WHERE sha256=?", [.text(sha)], map: Self.track).first
    }

    public func fetchAllTracks() throws -> [Track] {
        try query("SELECT \(Self.trackColumns) FROM tracks \(Self.trackOrder)", map: Self.track)
    }

    public func trackCount() throws -> Int {
        try query("SELECT COUNT(*) FROM tracks") { $0.int(0) ?? 0 }.first ?? 0
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    public func search(_ text: String) throws -> [Track] {
        let tokens = TextNormalizer.normalize(text).split(separator: " ").map(String.init)
        if tokens.isEmpty { return try fetchAllTracks() }
        var clauses: [String] = []
        var binds: [Bind] = []
        for token in tokens {
            clauses.append("search_text LIKE ? ESCAPE '\\'")
            binds.append(.text("%" + Self.escapeLike(token) + "%"))
        }
        return try query(
            "SELECT \(Self.trackColumns) FROM tracks WHERE \(clauses.joined(separator: " AND ")) \(Self.trackOrder)",
            binds, map: Self.track)
    }

    // MARK: Albums / artists

    private static let albumArtistExpr = "COALESCE(NULLIF(album_artist,''), artist, '')"

    public func albums(artist: String? = nil) throws -> [AlbumSummary] {
        let whereClause = artist == nil ? "" : "WHERE \(Self.albumArtistExpr) = ?"
        return try query("""
        SELECT COALESCE(album,''), \(Self.albumArtistExpr) AS aa, MAX(year), COUNT(*), MIN(path)
        FROM tracks \(whereClause) GROUP BY aa COLLATE NOCASE, COALESCE(album,'') COLLATE NOCASE
        ORDER BY aa COLLATE NOCASE, MAX(year), COALESCE(album,'') COLLATE NOCASE
        """, artist.map { [.text($0)] } ?? []) { r in
            AlbumSummary(album: r.string(0) ?? "", artist: r.string(1) ?? "", year: r.int(2),
                         trackCount: r.int(3) ?? 0, firstTrackPath: r.string(4) ?? "")
        }
    }

    public func artists() throws -> [ArtistSummary] {
        try query("""
        SELECT \(Self.albumArtistExpr) AS aa, COUNT(DISTINCT COALESCE(album,'') COLLATE NOCASE), COUNT(*)
        FROM tracks GROUP BY aa COLLATE NOCASE ORDER BY aa COLLATE NOCASE
        """) { r in
            ArtistSummary(name: r.string(0) ?? "", albumCount: r.int(1) ?? 0, trackCount: r.int(2) ?? 0)
        }
    }

    public func tracks(album: String, artist: String) throws -> [Track] {
        try query("""
        SELECT \(Self.trackColumns) FROM tracks
        WHERE COALESCE(album,'') = ? COLLATE NOCASE AND \(Self.albumArtistExpr) = ? COLLATE NOCASE
        ORDER BY disc_no, track_no, title COLLATE NOCASE
        """, [.text(album), .text(artist)], map: Self.track)
    }

    // MARK: Playlists

    @discardableResult
    public func createPlaylist(name: String) throws -> Playlist {
        let now = Date()
        try exec("INSERT INTO playlists(name,created_at) VALUES(?,?)", [.text(name), .double(now.timeIntervalSince1970)])
        let id = try query("SELECT last_insert_rowid()") { $0.int64(0) }.first ?? 0
        return Playlist(id: id, name: name, createdAt: now)
    }

    public func renamePlaylist(id: Int64, name: String) throws {
        try exec("UPDATE playlists SET name=? WHERE id=?", [.text(name), .int(id)])
    }

    public func deletePlaylist(id: Int64) throws {
        try exec("DELETE FROM playlists WHERE id=?", [.int(id)])
    }

    public func playlists() throws -> [Playlist] {
        try query("""
        SELECT p.id, p.name, p.created_at, (SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id=p.id)
        FROM playlists p ORDER BY p.name COLLATE NOCASE, p.id
        """) { r in
            Playlist(id: r.int64(0), name: r.string(1) ?? "", createdAt: Date(timeIntervalSince1970: r.double(2)),
                     trackCount: r.int(3) ?? 0)
        }
    }

    public func playlistTrackIds(_ playlistId: Int64) throws -> [Int64] {
        try query("SELECT track_id FROM playlist_tracks WHERE playlist_id=? ORDER BY position", [.int(playlistId)]) { $0.int64(0) }
    }

    public func playlistTracks(_ playlistId: Int64) throws -> [Track] {
        let cols = Self.trackColumns.split(separator: ",").map { "t.\($0)" }.joined(separator: ",")
        return try query("""
        SELECT \(cols) FROM playlist_tracks pt JOIN tracks t ON t.id = pt.track_id
        WHERE pt.playlist_id=? ORDER BY pt.position
        """, [.int(playlistId)], map: Self.track)
    }

    // MARK: Plays

    /// Records one listen. `counted` marks plays long enough to count (the scrobble rule).
    public func recordPlay(trackId: Int64, startedAt: Date, listened: Double, counted: Bool) throws {
        try exec("INSERT INTO plays(track_id,started_at,listened,counted) VALUES(?,?,?,?)",
                 [.int(trackId), .double(startedAt.timeIntervalSince1970), .double(listened), .int(counted ? 1 : 0)])
    }

    /// Per-track listening totals.
    public func playTotals() throws -> [Int64: PlayTotal] {
        let rows = try query("""
        SELECT track_id, SUM(counted), SUM(listened), MAX(started_at) FROM plays GROUP BY track_id
        """) { r in (r.int64(0), PlayTotal(plays: r.int(1) ?? 0, listened: r.double(2), lastPlayed: Date(timeIntervalSince1970: r.double(3)))) }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Artist info

    public func saveArtistInfo(key: String, _ info: ArtistInfo, imageFile: String?) throws {
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        try exec("INSERT OR REPLACE INTO artist_info(key,json,image_file,fetched_at) VALUES(?,?,?,?)",
                 [.text(key), .text(json), .text(imageFile), .double(info.fetchedAt.timeIntervalSince1970)])
    }

    /// Cached info keyed as saved, with the local image file name (relative to the artist image folder).
    public func artistInfos() throws -> [String: (info: ArtistInfo, imageFile: String?)] {
        let rows = try query("SELECT key, json, image_file FROM artist_info") { r -> (String, ArtistInfo, String?)? in
            guard let key = r.string(0), let json = r.string(1),
                  let info = try? JSONDecoder().decode(ArtistInfo.self, from: Data(json.utf8)) else { return nil }
            return (key, info, r.string(2))
        }
        var out: [String: (info: ArtistInfo, imageFile: String?)] = [:]
        for case let (key, info, file)? in rows { out[key] = (info, file) }
        return out
    }

    // MARK: Album info

    public func saveAlbumInfo(key: String, _ info: AlbumInfo) throws {
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        try exec("INSERT OR REPLACE INTO album_info(key,json,fetched_at) VALUES(?,?,?)",
                 [.text(key), .text(json), .double(info.fetchedAt.timeIntervalSince1970)])
    }

    public func albumInfos() throws -> [String: AlbumInfo] {
        let rows = try query("SELECT key, json FROM album_info") { r -> (String, AlbumInfo)? in
            guard let key = r.string(0), let json = r.string(1),
                  let info = try? JSONDecoder().decode(AlbumInfo.self, from: Data(json.utf8)) else { return nil }
            return (key, info)
        }
        var out: [String: AlbumInfo] = [:]
        for case let (key, info)? in rows { out[key] = info }
        return out
    }

    // MARK: Smart playlists

    @discardableResult
    public func createSmartPlaylist(name: String, query text: String) throws -> SmartPlaylist {
        let now = Date()
        try exec("INSERT INTO smart_playlists(name,query,created_at) VALUES(?,?,?)",
                 [.text(name), .text(text), .double(now.timeIntervalSince1970)])
        let id = try query("SELECT last_insert_rowid()") { $0.int64(0) }.first ?? 0
        return SmartPlaylist(id: id, name: name, query: text, createdAt: now)
    }

    public func updateSmartPlaylist(id: Int64, name: String, query: String) throws {
        try exec("UPDATE smart_playlists SET name=?, query=? WHERE id=?", [.text(name), .text(query), .int(id)])
    }

    public func deleteSmartPlaylist(id: Int64) throws {
        try exec("DELETE FROM smart_playlists WHERE id=?", [.int(id)])
    }

    public func smartPlaylists() throws -> [SmartPlaylist] {
        try query("SELECT id, name, query, created_at FROM smart_playlists ORDER BY name COLLATE NOCASE, id") { r in
            SmartPlaylist(id: r.int64(0), name: r.string(1) ?? "", query: r.string(2) ?? "",
                          createdAt: Date(timeIntervalSince1970: r.double(3)))
        }
    }

    private func rewritePlaylist(_ playlistId: Int64, ids: [Int64]) throws {
        try transaction {
            try exec("DELETE FROM playlist_tracks WHERE playlist_id=?", [.int(playlistId)])
            for (pos, tid) in ids.enumerated() {
                try exec("INSERT INTO playlist_tracks(playlist_id,track_id,position) VALUES(?,?,?)",
                         [.int(playlistId), .int(tid), .int(Int64(pos))])
            }
        }
    }

    public func addTracks(_ trackIds: [Int64], toPlaylist playlistId: Int64) throws {
        try transaction {
            let existing = try playlistTrackIds(playlistId)
            try rewritePlaylist(playlistId, ids: existing + trackIds)
        }
    }

    public func removeTracks(atPositions positions: [Int], fromPlaylist playlistId: Int64) throws {
        try transaction {
            let drop = Set(positions)
            let ids = try playlistTrackIds(playlistId)
            let kept = ids.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            try rewritePlaylist(playlistId, ids: kept)
        }
    }

    /// Same semantics as `Array.move(fromOffsets:toOffset:)`.
    public func moveTracks(inPlaylist playlistId: Int64, fromOffsets offsets: [Int], toOffset: Int) throws {
        try transaction {
            let ids = try playlistTrackIds(playlistId)
            let valid = Set(offsets.filter { ids.indices.contains($0) })
            let moved = ids.enumerated().filter { valid.contains($0.offset) }.map(\.element)
            var rest = ids.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
            let insertAt = max(0, min(rest.count, toOffset - valid.filter { $0 < toOffset }.count))
            rest.insert(contentsOf: moved, at: insertAt)
            try rewritePlaylist(playlistId, ids: rest)
        }
    }
}

private extension Track {
    func withAudio(codec: String?, rate: Int?, bits: Int?, bitrate: Int?, channels: Int?) -> Track {
        guard let codec else { return self }
        var t = self
        t.audioFormat = AudioFormat(codec: codec, sampleRate: rate, bitDepth: bits, bitrate: bitrate, channels: channels)
        return t
    }

    func withDetails(composer: String?, json: String?) -> Track {
        var t = self
        t.metadata.composer = composer ?? ""
        if let json, let data = json.data(using: .utf8),
           let ext = try? JSONDecoder().decode(ExtendedMetadata.self, from: data) {
            t.metadata.extended = ext
        }
        return t
    }
}
