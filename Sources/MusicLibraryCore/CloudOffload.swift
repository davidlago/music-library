import Foundation

/// How long an album goes unused before it's offloaded from the Mac (`docs/icloud-plan.md` D19). Off by default.
public enum OffloadThreshold: String, Codable, Sendable, CaseIterable {
    case off
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear

    /// Albums last used before this are offloaded; nil when off.
    public func cutoff(before now: Date, calendar: Calendar = .current) -> Date? {
        let months = switch self {
        case .off: 0
        case .oneMonth: 1
        case .threeMonths: 3
        case .sixMonths: 6
        case .oneYear: 12
        }
        guard months > 0 else { return nil }
        return calendar.date(byAdding: .month, value: -months, to: now)
    }
}

/// A song whose file is only in the iCloud backup (D17): its row, plays and likes stay in the library, its file was
/// deleted from the Mac once the backup held the same file. `size` and `modified` are the file's as backed up.
public struct OffloadedTrack: Equatable, Sendable {
    public var trackID: Int64
    public var path: String
    public var size: Int64
    public var modified: Date
    public var offloadedAt: Date

    public init(trackID: Int64, path: String, size: Int64, modified: Date, offloadedAt: Date) {
        self.trackID = trackID; self.path = path; self.size = size; self.modified = modified; self.offloadedAt = offloadedAt
    }

    var file: CloudBackupFile { CloudBackupFile(path: path, size: size, modified: modified) }
}

/// One album's songs to offload.
public struct OffloadAlbum: Equatable, Sendable, Identifiable {
    /// `SearchIndex.albumKey`.
    public var key: String
    public var album: String
    public var artist: String
    public var tracks: [OffloadedTrack]
    public var id: String { key }
    public var bytes: Int64 { tracks.reduce(0) { $0 + $1.size } }
}

/// What offloading would do (D19): the albums (or, for songs picked by hand, the songs grouped by album) whose files
/// are on the Mac and in the backup as they are here, uploaded, with the same size and modification date, so
/// deleting them from the Mac leaves the backup's copy. Pure: the caller lists the files and the backup.
public struct OffloadPlan: Equatable, Sendable {
    public var albums: [OffloadAlbum] = []
    /// Songs asked for that can't be offloaded yet: not in the backup, still uploading, or changed since.
    public var notInBackup = 0

    public var tracks: [OffloadedTrack] { albums.flatMap(\.tracks) }
    public var songs: Int { albums.reduce(0) { $0 + $1.tracks.count } }
    public var bytes: Int64 { albums.reduce(0) { $0 + $1.bytes } }

    /// The backup holds `file` as it is on the Mac. Only plain paths in the managed folders count.
    public static func holds(_ entry: CloudEntry?, _ file: CloudBackupFile) -> Bool {
        guard let entry, entry.path == file.path, CloudBackupPlan.isMusic(file.path), entry.isUploaded, entry.size == file.size,
              let modified = entry.modified else { return false }
        return abs(modified.timeIntervalSince(file.modified)) < 1
    }

    /// Albums not used since `cutoff` (D19): the newest of their songs' last play, the day they were added and the
    /// last download back. An album qualifies only when every song not offloaded yet is in the backup as it is
    /// here, and none is kept on the Mac (`kept`: Keep on This Mac) or `protected` (playing or queued).
    /// `local` is the songs' files on the Mac (`CloudBackupPlan.files(music:)`), by path.
    public init(automatic tracks: [Track], local: [String: CloudBackupFile], entries: [CloudEntry], offloaded: Set<Int64>,
                lastPlayed: [Int64: Date], downloaded: [Int64: Date], kept: Set<Int64>, protected: Set<Int64>, cutoff: Date, now: Date = Date()) {
        let inCloud = Self.index(entries)
        var groups: [String: [Track]] = [:]
        var order: [String] = []
        for track in tracks {
            let key = SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }
        album: for key in order {
            guard let songs = groups[key], !songs.contains(where: { kept.contains($0.id) || protected.contains($0.id) }) else { continue }
            let lastUse = songs.map { track in
                [lastPlayed[track.id], downloaded[track.id], track.addedAt].compactMap { $0 }.max() ?? track.addedAt
            }.max() ?? .distantFuture
            guard lastUse < cutoff else { continue }
            var rows: [OffloadedTrack] = []
            for track in songs where !offloaded.contains(track.id) {
                guard let file = local[track.path], Self.holds(inCloud[track.path], file) else { continue album }
                rows.append(OffloadedTrack(trackID: track.id, path: track.path, size: file.size, modified: file.modified, offloadedAt: now))
            }
            guard let first = songs.first, !rows.isEmpty else { continue }
            albums.append(OffloadAlbum(key: key, album: first.album, artist: first.effectiveAlbumArtist, tracks: rows))
        }
    }

    /// Songs picked by hand (Offload from This Mac), grouped by album: each one the backup holds as it is here, except
    /// `protected` ones (the song playing). Keep on This Mac doesn't apply: the user asked.
    public init(chosen tracks: [Track], local: [String: CloudBackupFile], entries: [CloudEntry], offloaded: Set<Int64>,
                protected: Set<Int64>, now: Date = Date()) {
        let inCloud = Self.index(entries)
        var index: [String: Int] = [:]
        var seen = Set<Int64>()
        for track in tracks where !offloaded.contains(track.id) && !protected.contains(track.id) && seen.insert(track.id).inserted {
            guard let file = local[track.path], Self.holds(inCloud[track.path], file) else { notInBackup += 1; continue }
            let row = OffloadedTrack(trackID: track.id, path: track.path, size: file.size, modified: file.modified, offloadedAt: now)
            let key = SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist)
            if let i = index[key] {
                albums[i].tracks.append(row)
            } else {
                index[key] = albums.count
                albums.append(OffloadAlbum(key: key, album: track.album, artist: track.effectiveAlbumArtist, tracks: [row]))
            }
        }
    }

    private static func index(_ entries: [CloudEntry]) -> [String: CloudEntry] {
        var inCloud: [String: CloudEntry] = [:]
        for entry in entries where SyncPlan.isManaged(entry.path) { inCloud[entry.path] = entry }
        return inCloud
    }
}

/// What offloading or downloading back did.
public struct OffloadResult: Equatable, Sendable {
    public var files = 0
    public var bytes: Int64 = 0
    /// Songs left as they were: changed since they were backed up, not uploaded, or (downloading) not in the backup.
    public var skipped: Set<Int64> = []
}

public enum OffloadError: Error, LocalizedError, Equatable {
    case notEnoughSpace(needed: Int64, available: Int64)
    /// The backup doesn't hold the song's file: it can't be downloaded.
    case notInBackup(String)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "There isn't room on this Mac: the songs need \(f.string(fromByteCount: needed)), and \(f.string(fromByteCount: available)) is free."
        case .notInBackup(let path):
            return "\((path as NSString).lastPathComponent) isn't in the iCloud backup."
        }
    }
}

extension CloudBackup {
    /// Deletes the songs' files from the Mac (D17), each only after checking it against the backup again, just
    /// before: the file on the Mac must still be as planned and iCloud must hold it uploaded, at the same size and
    /// modification date. Each is recorded as offloaded first, so an interrupted run never leaves a song whose file
    /// is gone without the record. A song that changed since is left alone (the next backup uploads it first).
    public static func offload(_ tracks: [OffloadedTrack], database: Database, root: URL, store: CloudStore,
                               now: Date = Date()) throws -> OffloadResult {
        var result = OffloadResult()
        var folders: [String: [String: CloudEntry]] = [:]
        let fm = FileManager.default
        for track in tracks {
            guard CloudBackupPlan.isMusic(track.path), let url = LibraryPath.resolve(track.path, in: root),
                  let attributes = try? fm.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value, let modified = attributes[.modificationDate] as? Date,
                  size == track.size, abs(modified.timeIntervalSince(track.modified)) < 1 else {
                result.skipped.insert(track.trackID)
                continue
            }
            let folder = (track.path as NSString).deletingLastPathComponent
            if folders[folder] == nil {
                folders[folder] = Dictionary((try store.entries(under: folder)).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            }
            guard OffloadPlan.holds(folders[folder]?[track.path], track.file), store.isUploaded(track.path) else {
                result.skipped.insert(track.trackID)
                continue
            }
            var row = track
            row.offloadedAt = now
            try database.markOffloaded([row])
            do {
                try fm.removeItem(at: url)
            } catch {
                try? database.forgetOffloaded([track.trackID])
                result.skipped.insert(track.trackID)
                continue
            }
            result.files += 1; result.bytes += size
        }
        return result
    }

    /// Brings offloaded songs back to the Mac (D20): each is copied out of the backup into the library folder (made
    /// aside and renamed into place; evicted from the container again), given its backed-up modification date so
    /// the next backup sees it unchanged, and recorded as downloaded `now`, which counts as a use (D19). Refuses when
    /// the songs don't fit. A song the backup doesn't hold is skipped.
    public static func download(_ tracks: [OffloadedTrack], database: Database, root: URL, store: CloudStore, now: Date = Date(),
                                progress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws -> OffloadResult {
        var result = OffloadResult()
        var inCloud: [String: CloudEntry] = [:]
        for folder in Set(tracks.map { ($0.path as NSString).deletingLastPathComponent }) {
            for entry in try store.entries(under: folder) { inCloud[entry.path] = entry }
        }
        var wanted: [(track: OffloadedTrack, url: URL)] = []
        for track in tracks {
            guard CloudBackupPlan.isMusic(track.path), inCloud[track.path] != nil, let url = LibraryPath.resolve(track.path, in: root) else {
                result.skipped.insert(track.trackID)
                continue
            }
            wanted.append((track, url))
        }
        let needed = wanted.reduce(0) { $0 + (inCloud[$1.track.path]?.size ?? $1.track.size) }
        if let available = LibraryExporter.availableCapacity(at: root), needed > available {
            throw OffloadError.notEnoughSpace(needed: needed, available: available)
        }
        let fm = FileManager.default
        progress(0, wanted.count)
        for (index, file) in wanted.enumerated() {
            try Task.checkCancellation()
            if LibraryExporter.size(of: file.url) != inCloud[file.track.path]?.size {
                try await store.copyOut(file.track.path, to: file.url)
                try? fm.setAttributes([.modificationDate: file.track.modified], ofItemAtPath: file.url.path)
            }
            try database.markDownloaded([file.track.trackID], at: now)
            result.files += 1; result.bytes += file.track.size
            progress(index + 1, wanted.count)
        }
        return result
    }
}

extension Database {
    /// Mac-only, created without a schema version change (see `createRipChecksTable`); kept in backup snapshots (a
    /// restore, or a Mac set up from iCloud, needs it) and emptied in the phone's. A row is a song offloaded at
    /// `offloaded_at` while `downloaded_at` is NULL, and a song downloaded back after.
    func createOffloadedTracksTable() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS offloaded_tracks(
            track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
            path TEXT NOT NULL, size INTEGER NOT NULL, modified REAL NOT NULL, offloaded_at REAL NOT NULL, downloaded_at REAL)
        """)
    }

    /// The songs whose files are only in the backup, by track ID. Rows are untrusted (the file may come from
    /// elsewhere): only a music file's plain path in the managed folders, the track's own, counts.
    public func offloadedTracks() throws -> [Int64: OffloadedTrack] {
        guard try !columns(of: "offloaded_tracks").isEmpty else { return [:] }
        let rows = try query("""
        SELECT o.track_id, o.path, o.size, o.modified, o.offloaded_at FROM offloaded_tracks o
        JOIN tracks t ON t.id = o.track_id AND t.path = o.path WHERE o.downloaded_at IS NULL
        """) { r -> OffloadedTrack? in
            guard let path = r.string(1), CloudBackupPlan.isMusic(path), let size = r.int(2), size >= 0 else { return nil }
            return OffloadedTrack(trackID: r.int64(0), path: path, size: Int64(size), modified: Date(timeIntervalSince1970: r.double(3)),
                                  offloadedAt: Date(timeIntervalSince1970: r.double(4)))
        }
        return Dictionary(rows.compactMap { $0 }.map { ($0.trackID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// When each song was last downloaded back from the backup.
    public func offloadDownloadDates() throws -> [Int64: Date] {
        guard try !columns(of: "offloaded_tracks").isEmpty else { return [:] }
        let rows = try query("SELECT track_id, downloaded_at FROM offloaded_tracks WHERE downloaded_at IS NOT NULL") {
            ($0.int64(0), Date(timeIntervalSince1970: $0.double(1)))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    public func markOffloaded(_ tracks: [OffloadedTrack]) throws {
        try transaction {
            for t in tracks {
                try exec("INSERT OR REPLACE INTO offloaded_tracks(track_id,path,size,modified,offloaded_at,downloaded_at) VALUES(?,?,?,?,?,NULL)",
                         [.int(t.trackID), .text(t.path), .int(t.size), .double(t.modified.timeIntervalSince1970),
                          .double(t.offloadedAt.timeIntervalSince1970)])
            }
        }
    }

    public func markDownloaded(_ ids: [Int64], at date: Date = Date()) throws {
        try transaction {
            for id in ids {
                try exec("UPDATE offloaded_tracks SET downloaded_at=? WHERE track_id=?", [.double(date.timeIntervalSince1970), .int(id)])
            }
        }
    }

    func forgetOffloaded(_ ids: [Int64]) throws {
        try transaction {
            for id in ids { try exec("DELETE FROM offloaded_tracks WHERE track_id=?", [.int(id)]) }
        }
    }

    /// Songs recorded as offloaded whose files are back in the library folder (a restore copied them, or someone put
    /// them back by hand) count as downloaded.
    public func settleOffloaded(root: URL, now: Date = Date()) throws {
        let back = try offloadedTracks().values.filter { track in
            LibraryPath.resolve(track.path, in: root).flatMap(LibraryExporter.size(of:)) != nil
        }
        try markDownloaded(back.map(\.trackID), at: now)
    }
}
