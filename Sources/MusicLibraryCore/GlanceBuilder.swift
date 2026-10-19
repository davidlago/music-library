import Foundation
import MusicLibraryGlance

/// Where a cover thumbnail of the summary or the shelf index comes from.
public enum GlanceCoverSource: Hashable, Sendable {
    /// The album's `cover.jpg`, next to this track.
    case track(Track)
    /// A file relative to the library root (a collection item's own cover).
    case file(relativePath: String)

    /// The image in the library at `root`, through `LibraryPath` (paths come from the database).
    public func url(root: URL) -> URL? {
        switch self {
        case .track(let t): t.coverURL(root: root)
        case .file(let path): LibraryPath.resolve(path, in: root)
        }
    }
}

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

    /// The summary of a library and its collection, and where each cover it shows comes from (cover name → source):
    /// an album's first track, whose `cover.jpg` becomes the thumbnail, or an item's own cover file.
    ///
    /// `owned` keeps the meaning older watches know (library albums with songs, one per album: each album's latest
    /// dated copy); its spending and "bought" totals and `collection` cover every item, trackless ones included.
    public static func build(tracks: [Track], present: Set<Int64>, plays: [Play], likedDates: [Int64: Date],
                             collection: MusicCollection, playTotals: [Int64: PlayTotal], playing: Playing?,
                             currencyCode: String, now: Date = Date(), calendar: Calendar = .current,
                             listLimit: Int = 8) -> (glance: Glance, covers: [String: GlanceCoverSource]) {
        var (builder, glance) = base(tracks: tracks, present: present, plays: plays, likedDates: likedDates, playing: playing,
                                     currencyCode: currencyCode, now: now, calendar: calendar, listLimit: listLimit)
        glance.owned = builder.owned(collection, playTotals: playTotals, now: now, calendar: calendar, limit: listLimit)
        glance.collection = builder.collection(collection, now: now, calendar: calendar, limit: listLimit)
        return (glance, builder.coverSources)
    }

    /// The summary from album purchases, as before the collection (`collection` stays nil).
    /// Deprecated: use `build(…collection:…)`; kept until the apps move to it.
    public static func build(tracks: [Track], present: Set<Int64>, plays: [Play], likedDates: [Int64: Date],
                             purchases: [String: AlbumPurchase], playTotals: [Int64: PlayTotal], playing: Playing?,
                             currencyCode: String, now: Date = Date(), calendar: Calendar = .current,
                             listLimit: Int = 8) -> (glance: Glance, covers: [String: Track]) {
        var (builder, glance) = base(tracks: tracks, present: present, plays: plays, likedDates: likedDates, playing: playing,
                                     currencyCode: currencyCode, now: now, calendar: calendar, listLimit: listLimit)
        let ownership = OwnershipStats(tracks: tracks, purchases: purchases, playTotals: playTotals, now: now, calendar: calendar)
        glance.owned = Owned(ownedCount: ownership.ownedCount, libraryAlbumCount: ownership.libraryAlbumCount,
                             boughtThisYear: ownership.boughtThisYear, spentThisYear: ownership.spentThisYear,
                             totalSpent: ownership.totalSpent,
                             recent: ownership.albums.filter { $0.purchasedOn != nil }.prefix(listLimit).compactMap { a in
                                 builder.album(key: a.id).map { Owned.Purchase(album: $0, purchasedOn: a.purchasedOn?.string, price: a.price, plays: a.plays) }
                             })
        return (glance, builder.usedCovers)
    }

    /// Everything but `owned` and `collection`, which the two `build`s fill in.
    private static func base(tracks: [Track], present: Set<Int64>, plays: [Play], likedDates: [Int64: Date], playing: Playing?,
                             currencyCode: String, now: Date, calendar: Calendar, listLimit: Int) -> (GlanceBuilder, Glance) {
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

        let nowPlaying = playing.map { builder.nowPlaying($0, liked: likedDates[$0.track.id] != nil, now: now) }

        let glance = Glance(generatedAt: now, currencyCode: currencyCode, library: library, week: week, month: month,
                            owned: Owned(), nowPlaying: nowPlaying, rediscover: rediscover)
        return (builder, glance)
    }

    /// The watch's shelf index: every labeled CD and record (up to `GlanceShelf.maxEntries`, and as many as fit in
    /// `GlanceShelf.maxBytes`), and where each cover it names comes from.
    public static func shelf(collection: MusicCollection, now: Date = Date()) -> (shelf: GlanceShelf, covers: [String: GlanceCoverSource]) {
        var covers: [String: GlanceCoverSource] = [:]
        var entries: [GlanceShelf.Entry] = []
        for item in collection.items {
            guard let sticker = item.sticker, entries.count < GlanceShelf.maxEntries else { continue }
            let cover = GlanceBuilder.cover(of: item, in: collection)
            if let cover { covers[cover.name] = cover.source }
            entries.append(GlanceShelf.Entry(id: item.id, series: sticker.series.rawValue, number: sticker.number,
                                             title: item.album.isEmpty ? "Unknown Album" : item.album,
                                             artist: item.artist.isEmpty ? "Unknown Artist" : item.artist, year: item.year,
                                             digitized: collection.digitalState(item).hasMusic, cover: cover?.name))
        }
        var shelf = GlanceShelf(generatedAt: now, entries: entries)
        // Long titles in scripts that take several bytes a character could pass the limit: drop the highest labels.
        while let size = try? GlanceStore.encodeShelf(shelf).count, size > GlanceShelf.maxBytes, !shelf.entries.isEmpty {
            shelf.entries.removeLast(max(1, shelf.entries.count * (size - GlanceShelf.maxBytes) / size + 1))
        }
        let kept = shelf.coverNames
        return (shelf, covers.filter { kept.contains($0.key) })
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

    /// Every cover used, with the collection items' own covers.
    var coverSources: [String: GlanceCoverSource] {
        var out = itemCovers
        for (name, track) in usedCovers { out[name] = .track(track) }
        return out
    }
    private var itemCovers: [String: GlanceCoverSource] = [:]

    /// An item's cover: its own file, named after the file (a new one on each change, so the thumbnail is made again),
    /// else its album's when the album has songs.
    static func cover(of item: CollectionItem, in collection: MusicCollection) -> (name: String, source: GlanceCoverSource)? {
        if let file = item.coverFile, let path = CollectionCovers.path(file) {
            return (Glance.coverName(albumKey: "item:\(item.id)/\(file)"), .file(relativePath: path))
        }
        guard let first = collection.libraryTracks(item).first else { return nil }
        return (Glance.coverName(albumKey: item.albumKey), .track(first))
    }

    /// `Glance.Owned` with its fixed meaning: library albums with songs that have any copy, each with its latest dated
    /// copy; spending over every copy.
    mutating func owned(_ collection: MusicCollection, playTotals: [Int64: PlayTotal], now: Date, calendar: Calendar,
                        limit: Int) -> Glance.Owned {
        var owned = Glance.Owned(libraryAlbumCount: albums.count)
        let thisYear = calendar.component(.year, from: now)
        for item in collection.items {
            owned.totalSpent += item.price ?? 0
            if item.purchasedOn?.year == thisYear { owned.boughtThisYear += 1; owned.spentThisYear += item.price ?? 0 }
        }
        var latest: [(key: String, item: CollectionItem, day: PurchaseDay)] = []
        for key in albums.keys {
            let copies = collection.copies(albumKey: key)
            guard !copies.isEmpty else { continue }
            owned.ownedCount += 1
            let dated = copies.compactMap { c in c.purchasedOn.map { (c, $0) } }
            if let best = dated.max(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id > $1.0.id }) { latest.append((key, best.0, best.1)) }
        }
        latest.sort { a, b in
            if a.day != b.day { return a.day > b.day }
            let x = albums[a.key]!, y = albums[b.key]!
            let c = x.title.localizedCaseInsensitiveCompare(y.title)
            return c != .orderedSame ? c == .orderedAscending : a.key < b.key
        }
        owned.recent = latest.prefix(limit).compactMap { entry in
            guard let album = album(key: entry.key) else { return nil }
            let plays = collection.libraryTracks(entry.item).reduce(0) { $0 + (playTotals[$1.id]?.plays ?? 0) }
            return Glance.Owned.Purchase(album: album, purchasedOn: entry.day.string, price: entry.item.price, plays: plays,
                                         itemID: entry.item.id)
        }
        return owned
    }

    mutating func collection(_ collection: MusicCollection, now: Date, calendar: Calendar, limit: Int) -> Glance.Collection {
        var c = Glance.Collection(items: collection.items.count, cds: 0, vinyl: 0, downloads: 0, toRip: 0, vinylToDigitize: 0,
                                  nextCD: collection.nextNumber(in: .cd), nextVinyl: collection.nextNumber(in: .vinyl))
        var toRip: [CollectionItem] = []
        for item in collection.items {
            let state = collection.digitalState(item)
            switch item.medium {
            case .cd:
                c.cds? += 1
                if state.needsDigitizing { c.toRip? += 1; toRip.append(item) }
            case .vinyl:
                c.vinyl? += 1
                if state.needsDigitizing { c.vinylToDigitize? += 1 }
            case .download: c.downloads? += 1
            case .other: break
            }
        }
        // Undated items by when they were added: noon on the purchase day otherwise, as everywhere else.
        func when(_ item: CollectionItem) -> Date {
            item.purchasedOn.flatMap { calendar.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day, hour: 12)) }
                ?? item.createdAt
        }
        let recent = collection.items.map { ($0, when($0)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
        c.recent = recent.prefix(limit).map { glanceItem($0.0, in: collection, calendar: calendar) }
        let oldest = toRip.map { ($0, when($0)) }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id < $1.0.id }
        c.toRipList = oldest.prefix(limit).map { glanceItem($0.0, in: collection, calendar: calendar) }
        return c
    }

    private mutating func glanceItem(_ item: CollectionItem, in collection: MusicCollection, calendar: Calendar) -> Glance.Collection.Item {
        let cover = Self.cover(of: item, in: collection)
        if let cover {
            if case .track(let t) = cover.source { usedCovers[cover.name] = t } else { itemCovers[cover.name] = cover.source }
        }
        return Glance.Collection.Item(id: item.id, albumKey: item.albumKey, title: item.album.isEmpty ? "Unknown Album" : item.album,
                                      artist: item.artist.isEmpty ? "Unknown Artist" : item.artist, year: item.year,
                                      medium: item.medium.rawValue, sticker: item.stickerNumber,
                                      digitized: collection.digitalState(item).hasMusic,
                                      playable: albums[item.albumKey]?.playable ?? false, cover: cover?.name,
                                      purchasedOn: item.purchasedOn?.string, price: item.price,
                                      addedOn: PurchaseDay(item.createdAt, calendar: calendar).string)
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
