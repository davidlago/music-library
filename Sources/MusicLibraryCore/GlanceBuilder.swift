import Foundation
import MusicLibraryGlance

extension Glance {
    /// The song the player has, for the summary.
    public struct Playing: Sendable {
        public var track: Track
        public var isPlaying: Bool
        public var position: Double
        public var duration: Double
        public var next: Track?

        public init(track: Track, isPlaying: Bool, position: Double, duration: Double, next: Track? = nil) {
            self.track = track; self.isPlaying = isPlaying; self.position = position; self.duration = duration; self.next = next
        }
    }

    /// The summary of a library, and a track of each album it shows (cover name → track), whose `cover.jpg` becomes
    /// that cover's thumbnail.
    public static func build(tracks: [Track], present: Set<Int64>, plays: [Play], likedDates: [Int64: Date],
                             purchases: [String: AlbumPurchase], playTotals: [Int64: PlayTotal], playing: Playing?,
                             currencyCode: String, now: Date = Date(), calendar: Calendar = .current,
                             listLimit: Int = 8) -> (glance: Glance, covers: [String: Track]) {
        var builder = GlanceBuilder(tracks: tracks, present: present)
        let liked = likedDates.keys.filter { builder.byID[$0] != nil }

        var library = LibraryCounts(songs: tracks.count, albums: builder.albums.count, duration: 0,
                                    songsOnPhone: tracks.reduce(0) { $0 + (present.contains($1.id) ? 1 : 0) },
                                    likedSongs: liked.count)
        library.duration = tracks.reduce(0) { $0 + ($1.duration.isFinite ? max(0, $1.duration) : 0) }
        library.artists = Set(tracks.map { ListeningStats.artistName($0).lowercased() }).count
        library.albumsOnPhone = builder.albums.values.filter(\.playable).count
        library.recentlyAdded = builder.albums.sorted { a, b in
            a.value.added != b.value.added ? a.value.added > b.value.added : a.key < b.key
        }.prefix(listLimit).compactMap { builder.album(key: $0.key) }

        let week = builder.listening(ListeningStats(plays: plays, tracks: tracks, period: .week, now: now, calendar: calendar), limit: listLimit)
        let monthStats = ListeningStats(plays: plays, tracks: tracks, period: .month, now: now, calendar: calendar)
        let month = builder.listening(monthStats, limit: listLimit)
        let rediscover = monthStats.forgotten.prefix(listLimit * 2).compactMap { item -> Ranked<Song>? in
            guard let id = item.trackId, let t = builder.byID[id] else { return nil }
            return Ranked(builder.song(t), plays: item.plays, listened: item.listened, lastPlayed: item.lastPlayed)
        }

        let ownership = OwnershipStats(tracks: tracks, purchases: purchases, playTotals: playTotals, now: now, calendar: calendar)
        let owned = Owned(ownedCount: ownership.ownedCount, libraryAlbumCount: ownership.libraryAlbumCount,
                          boughtThisYear: ownership.boughtThisYear, spentThisYear: ownership.spentThisYear,
                          totalSpent: ownership.totalSpent,
                          recent: ownership.albums.filter { $0.purchasedOn != nil }.prefix(listLimit).compactMap { a in
                              builder.album(key: a.id).map { Owned.Purchase(album: $0, purchasedOn: a.purchasedOn?.string, price: a.price, plays: a.plays) }
                          })

        let nowPlaying = playing.map { builder.nowPlaying($0, liked: likedDates[$0.track.id] != nil, now: now) }

        let glance = Glance(generatedAt: now, currencyCode: currencyCode, library: library, week: week, month: month,
                            owned: owned, nowPlaying: nowPlaying, rediscover: rediscover)
        return (glance, builder.usedCovers)
    }

    /// Just the song playing, for updating a summary while the rest stays the same (play, pause, next song), and the
    /// covers it shows.
    public static func nowPlaying(_ playing: Playing?, present: Set<Int64>, likedDates: [Int64: Date],
                                  now: Date = Date()) -> (nowPlaying: NowPlaying?, covers: [String: Track]) {
        guard let playing else { return (nil, [:]) }
        let tracks = [playing.track] + (playing.next.map { [$0] } ?? [])
        var builder = GlanceBuilder(tracks: tracks, present: present)
        return (builder.nowPlaying(playing, liked: likedDates[playing.track.id] != nil, now: now), builder.usedCovers)
    }
}

/// The library grouped by album, and the covers the summary ends up using.
private struct GlanceBuilder {
    struct AlbumGroup {
        var title: String
        var artist: String
        var year: Int?
        var first: Track
        var added: Date
        var playable: Bool
    }

    let byID: [Int64: Track]
    let present: Set<Int64>
    let albums: [String: AlbumGroup]
    private(set) var usedCovers: [String: Track] = [:]

    init(tracks: [Track], present: Set<Int64>) {
        byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.present = present
        var albums: [String: AlbumGroup] = [:]
        for t in tracks {
            let key = Self.albumKey(t)
            if var g = albums[key] {
                if let y = t.year, y > 0 { g.year = max(g.year ?? y, y) }
                g.added = max(g.added, t.addedAt)
                g.playable = g.playable || present.contains(t.id)
                if (t.metadata.discNo ?? 1, t.trackNo ?? 0) < (g.first.metadata.discNo ?? 1, g.first.trackNo ?? 0) { g.first = t }
                albums[key] = g
            } else {
                albums[key] = AlbumGroup(title: t.album.isEmpty ? "Unknown Album" : t.album, artist: ListeningStats.artistName(t),
                                         year: t.year.flatMap { $0 > 0 ? $0 : nil }, first: t, added: t.addedAt,
                                         playable: present.contains(t.id))
            }
        }
        self.albums = albums
    }

    static func albumKey(_ t: Track) -> String { SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist) }

    mutating func album(key: String) -> Glance.Album? {
        guard let g = albums[key] else { return nil }
        return Glance.Album(key: key, title: g.title, artist: g.artist, year: g.year, cover: cover(key, g.first), playable: g.playable)
    }

    mutating func song(_ t: Track) -> Glance.Song {
        let key = Self.albumKey(t)
        return Glance.Song(id: t.id, title: t.title.isEmpty ? "Untitled" : t.title, artist: t.artist.isEmpty ? ListeningStats.artistName(t) : t.artist,
                           album: t.album, albumKey: key, cover: albums[key].map { cover(key, $0.first) },
                           playable: present.contains(t.id))
    }

    mutating func nowPlaying(_ p: Glance.Playing, liked: Bool, now: Date) -> Glance.NowPlaying {
        Glance.NowPlaying(song: song(p.track), isPlaying: p.isPlaying, position: p.position.isFinite ? max(0, p.position) : 0,
                          duration: p.duration.isFinite ? max(0, p.duration) : 0, updatedAt: now, liked: liked,
                          next: p.next.map { song($0) })
    }

    private mutating func cover(_ key: String, _ track: Track) -> String {
        let name = Glance.coverName(albumKey: key)
        usedCovers[name] = track
        return name
    }

    mutating func listening(_ s: ListeningStats, limit: Int) -> Glance.Listening {
        var l = Glance.Listening(days: s.period.days ?? s.dayCount)
        l.listened = s.listened
        l.plays = s.plays
        l.previousListened = s.previousListened
        l.activeDays = s.activeDays
        l.currentStreak = s.currentStreak
        l.longestStreak = s.longestStreak
        l.peakHour = s.peakHour
        l.topSongs = s.songs.byPlays.prefix(limit).compactMap { item in
            item.trackId.flatMap { byID[$0] }.map { Glance.Ranked(song($0), plays: item.plays, listened: item.listened) }
        }
        l.topArtists = s.artists.byPlays.prefix(limit).map { Glance.Ranked($0.name, plays: $0.plays, listened: $0.listened) }
        l.topAlbums = s.albums.byPlays.prefix(limit).compactMap { item in
            album(key: String(item.id.dropFirst(3))).map { Glance.Ranked($0, plays: item.plays, listened: item.listened) }
        }
        // Only the period's own days (a short history pads the activity chart back a week).
        let start = s.start ?? .distantPast
        l.daily = s.activity.filter { $0.date >= start }.map { Glance.Listening.Day(date: $0.date, listened: $0.listened, plays: $0.plays) }
        return l
    }
}
