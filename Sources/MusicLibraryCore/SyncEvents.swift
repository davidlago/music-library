import Foundation

/// Something done on the phone that belongs in the Mac's library: a listen, liking or unliking a song, or saying
/// whether you own its album (and when you bought it and what you paid).
/// Recorded in the phone's outbox (`SyncOutbox`) and applied on the Mac at the next sync (`Database.applySyncEvents`).
public struct SyncEvent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: Codable, Hashable, Sendable {
        /// A listen of `listened` seconds; `counted` when it met the scrobble rule.
        case play(listened: Double, counted: Bool)
        case like(Bool)
        /// The album of `trackID` is owned (nil: not owned).
        case purchase(AlbumPurchase?)
    }

    /// A UUID, so applying it twice (a sync that was cut off and repeated) has no effect.
    public var id: String
    public var trackID: Int64
    /// Checked on the Mac with the ID: a song re-imported or removed since the phone's copy was made doesn't match.
    public var sha256: String
    /// When the play started, or when the song was liked or unliked.
    public var at: Date
    public var kind: Kind

    public init(id: String = UUID().uuidString, track: Track, at: Date, kind: Kind) {
        self.id = id; trackID = track.id; sha256 = track.sha256; self.at = at; self.kind = kind
    }
}

/// What applying a phone's events did on the Mac.
public struct SyncEventResult: Equatable, Sendable {
    public var plays = 0
    public var likes = 0
    public var purchases = 0
    /// Events for songs that changed or are gone on the Mac, or recorded against another library.
    public var dropped = 0
    public init() {}
}

/// The phone's events waiting for the next sync, persisted as JSON. Events are removed only once a sync finished
/// with them, so one that fails partway sends them again (the Mac skips ones it already applied).
public final class SyncOutbox: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var items: [SyncEvent]

    public init(url: URL) {
        self.url = url
        items = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([SyncEvent].self, from: $0) } ?? []
    }

    public var events: [SyncEvent] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    public func append(_ event: SyncEvent) {
        lock.lock(); defer { lock.unlock() }
        items.append(event)
        save()
    }

    public func remove(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
        } catch {}
    }

    /// Liked state after the outbox's like events, starting from the copy's: the songs and when they were liked.
    public static func liked(base: [Int64: Date], events: [SyncEvent]) -> [Int64: Date] {
        var liked = base
        for e in events.sorted(by: { $0.at < $1.at }) {
            guard case .like(let on) = e.kind else { continue }
            if on { liked[e.trackID] = liked[e.trackID] ?? e.at } else { liked[e.trackID] = nil }
        }
        return liked
    }

    /// Owned albums after the outbox's ownership events, starting from the copy's. `albumKey` gives an event's
    /// album (`SearchIndex.albumKey`) from its track. Only versions before 1.18 edited ownership on the phone: their
    /// events may still be waiting for a sync.
    public static func purchases(base: [String: AlbumPurchase], events: [SyncEvent], albumKey: (Int64) -> String?) -> [String: AlbumPurchase] {
        var owned = base
        for e in events.sorted(by: { $0.at < $1.at }) {
            guard case .purchase(let p) = e.kind, let key = albumKey(e.trackID) else { continue }
            // Label numbers come from the Mac only, as when it applies the event.
            owned[key] = p.map { var p = $0; p.labelNumber = base[key]?.labelNumber; return p }
        }
        return owned
    }
}

/// The Mac's Last.fm account, handed to a phone that isn't connected.
public struct SyncLastFM: Codable, Equatable, Sendable {
    public var apiKey: String
    public var sharedSecret: String
    public var sessionKey: String
    public var username: String
    public init(apiKey: String, sharedSecret: String, sessionKey: String, username: String) {
        self.apiKey = apiKey; self.sharedSecret = sharedSecret; self.sessionKey = sessionKey; self.username = username
    }
}

extension Database {
    /// Applies a phone's events, oldest first. Each is applied at most once (`sync_events`); events recorded against
    /// another library, or for a song whose ID and file hash no longer match, are dropped (a copy from before library
    /// IDs existed has none: its events go by the song check alone). Likes: a like adds the song
    /// (keeping an earlier like date); an unlike removes it unless the Mac liked it after the phone unliked it.
    /// The phone scrobbles its own plays, so nothing here goes to Last.fm.
    public func applySyncEvents(_ events: [SyncEvent], libraryID phoneLibrary: String?, now: Date = Date()) throws -> SyncEventResult {
        var result = SyncEventResult()
        let ours = libraryID()
        try transaction {
            for e in events.sorted(by: { $0.at < $1.at }) {
                let fresh = try query("INSERT OR IGNORE INTO sync_events(id,applied_at) VALUES(?,?) RETURNING id",
                                      [.text(e.id), .double(now.timeIntervalSince1970)]) { $0.string(0) }
                guard !fresh.isEmpty else { continue }
                guard phoneLibrary == nil || phoneLibrary == ours, let track = try track(id: e.trackID), track.sha256 == e.sha256 else {
                    result.dropped += 1
                    continue
                }
                switch e.kind {
                case .play(let listened, let counted):
                    try recordPlay(trackId: track.id, startedAt: e.at, listened: listened, counted: counted)
                    result.plays += 1
                case .like(true):
                    let liked = try query("SELECT 1 FROM liked_tracks WHERE track_id=?", [.int(track.id)]) { $0.int(0) }
                    if liked.isEmpty {
                        try setLiked([track.id], true, at: e.at)
                        result.likes += 1
                    }
                case .like(false):
                    let likedAt = try query("SELECT liked_at FROM liked_tracks WHERE track_id=?", [.int(track.id)]) { $0.double(0) }.first
                    if let likedAt, likedAt <= e.at.timeIntervalSince1970 {
                        try setLiked([track.id], false)
                        result.likes += 1
                    }
                case .purchase(let purchase):
                    // The newer of the phone's change and the Mac's last one wins.
                    let key = SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist)
                    let updated = try query("SELECT updated_at FROM album_ownership WHERE key=?", [.text(key)]) { $0.double(0) }.first ?? nil
                    if let updated, updated > e.at.timeIntervalSince1970 { continue }
                    // Label numbers are only set on the Mac: the album keeps its own.
                    let label = try albumPurchases()[key]?.labelNumber
                    try saveAlbumPurchase(key: key, purchase.map {
                        AlbumPurchase(album: track.album, artist: track.effectiveAlbumArtist, purchasedOn: $0.purchasedOn, price: $0.price,
                                      labelNumber: label)
                    }, at: e.at)
                    result.purchases += 1
                }
            }
        }
        return result
    }
}
