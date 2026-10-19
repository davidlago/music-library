import Foundation

/// What the iPhone's widgets and the Apple Watch app show: a small summary of the library, written by the iPhone app
/// whenever something it covers changes (the library, listening history, ownership, likes or the song playing). The
/// widgets read it from the app group's container; the watch gets it over WatchConnectivity. Covers are separate JPEG
/// thumbnails next to it, named by `coverName(albumKey:)`.
///
/// Foundation only, so the widget extensions and the watch app don't need `MusicLibraryCore`.
public struct Glance: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version = Glance.currentVersion
    public var generatedAt: Date
    /// The user's currency, for prices.
    public var currencyCode: String
    public var library: LibraryCounts
    public var week: Listening
    public var month: Listening
    public var owned: Owned
    public var nowPlaying: NowPlaying?
    /// Songs played a lot that haven't been played in months, most played first.
    public var rediscover: [Ranked<Song>]
    /// The physical collection (CDs, records and album downloads, trackless ones included). Nil from a phone before
    /// the collection, or one built from older data: show `owned` instead.
    public var collection: Collection?

    public init(generatedAt: Date, currencyCode: String, library: LibraryCounts, week: Listening, month: Listening,
                owned: Owned, nowPlaying: NowPlaying?, rediscover: [Ranked<Song>], collection: Collection? = nil) {
        self.generatedAt = generatedAt; self.currencyCode = currencyCode; self.library = library
        self.week = week; self.month = month; self.owned = owned; self.nowPlaying = nowPlaying; self.rediscover = rediscover
        self.collection = collection
    }

    /// An album, by `SearchIndex.albumKey`.
    public struct Album: Codable, Hashable, Sendable, Identifiable {
        public var id: String { key }
        public var key: String
        public var title: String
        public var artist: String
        public var year: Int?
        /// File name of its cover thumbnail, if it has one.
        public var cover: String?
        /// Some of its songs are on the iPhone.
        public var playable: Bool

        public init(key: String, title: String, artist: String, year: Int? = nil, cover: String? = nil, playable: Bool) {
            self.key = key; self.title = title; self.artist = artist; self.year = year; self.cover = cover; self.playable = playable
        }
    }

    public struct Song: Codable, Hashable, Sendable, Identifiable {
        /// The track's ID in the library.
        public var id: Int64
        public var title: String
        public var artist: String
        public var album: String
        public var albumKey: String
        public var cover: String?
        /// Its file is on the iPhone.
        public var playable: Bool

        public init(id: Int64, title: String, artist: String, album: String, albumKey: String, cover: String? = nil, playable: Bool) {
            self.id = id; self.title = title; self.artist = artist; self.album = album; self.albumKey = albumKey
            self.cover = cover; self.playable = playable
        }
    }

    /// Something with its plays and listening time in a period.
    public struct Ranked<Item: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
        public var item: Item
        public var plays: Int
        public var listened: Double
        public var lastPlayed: Date?

        public init(_ item: Item, plays: Int, listened: Double, lastPlayed: Date? = nil) {
            self.item = item; self.plays = plays; self.listened = listened; self.lastPlayed = lastPlayed
        }
    }

    public struct LibraryCounts: Codable, Hashable, Sendable {
        public var songs = 0
        public var albums = 0
        public var artists = 0
        /// Seconds of music.
        public var duration: Double = 0
        public var songsOnPhone = 0
        public var albumsOnPhone = 0
        public var likedSongs = 0
        /// Most recently added first.
        public var recentlyAdded: [Album] = []

        public init(songs: Int = 0, albums: Int = 0, artists: Int = 0, duration: Double = 0, songsOnPhone: Int = 0,
                    albumsOnPhone: Int = 0, likedSongs: Int = 0, recentlyAdded: [Album] = []) {
            self.songs = songs; self.albums = albums; self.artists = artists; self.duration = duration
            self.songsOnPhone = songsOnPhone; self.albumsOnPhone = albumsOnPhone; self.likedSongs = likedSongs
            self.recentlyAdded = recentlyAdded
        }
    }

    /// Listening in the last `days` days, today included.
    public struct Listening: Codable, Hashable, Sendable {
        public struct Day: Codable, Hashable, Sendable {
            /// Start of the day.
            public var date: Date
            public var listened: Double
            public var plays: Int

            public init(date: Date, listened: Double, plays: Int) {
                self.date = date; self.listened = listened; self.plays = plays
            }
        }

        public var days: Int
        /// Seconds listened.
        public var listened: Double = 0
        /// Plays that counted (the scrobble rule).
        public var plays = 0
        /// The period before, for comparison; nil when the history doesn't go back that far.
        public var previousListened: Double?
        public var activeDays = 0
        /// Days in a row with plays, up to today or yesterday.
        public var currentStreak = 0
        public var longestStreak = 0
        /// Hour of the day (0–23) with the most listening.
        public var peakHour: Int?
        public var topSongs: [Ranked<Song>] = []
        public var topArtists: [Ranked<String>] = []
        public var topAlbums: [Ranked<Album>] = []
        /// Every day of the period, oldest first.
        public var daily: [Day] = []

        public init(days: Int) { self.days = days }

        /// How much more (or less) than the period before, as a fraction; nil without one to compare.
        public var change: Double? {
            guard let previousListened, previousListened >= 60 else { return nil }
            return listened / previousListened - 1
        }
    }

    /// Library albums you own. Its meaning is fixed, because older watches read it: the counts and `recent` cover
    /// library albums with songs only, one per album; the spending and "bought" totals cover every copy you own.
    public struct Owned: Codable, Hashable, Sendable {
        public struct Purchase: Codable, Hashable, Sendable, Identifiable {
            public var id: String { itemID ?? album.key }
            public var album: Album
            /// "yyyy-MM-dd", a calendar day with no time zone.
            public var purchasedOn: String?
            public var price: Decimal?
            /// All-time plays of its songs.
            public var plays: Int
            /// The collection item whose date and price these are; nil from older phones.
            public var itemID: String?

            public init(album: Album, purchasedOn: String?, price: Decimal?, plays: Int, itemID: String? = nil) {
                self.album = album; self.purchasedOn = purchasedOn; self.price = price; self.plays = plays; self.itemID = itemID
            }

            /// Noon on the purchase day in `calendar`, so it shows as the same day in every time zone.
            public func purchaseDate(calendar: Calendar = .current) -> Date? {
                let parts = purchasedOn?.split(separator: "-").compactMap { Int($0) } ?? []
                guard parts.count == 3 else { return nil }
                return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
            }
        }

        public var ownedCount = 0
        public var libraryAlbumCount = 0
        public var boughtThisYear = 0
        public var spentThisYear: Decimal = 0
        public var totalSpent: Decimal = 0
        /// Latest purchase first; undated ones aren't listed.
        public var recent: [Purchase] = []

        public init(ownedCount: Int = 0, libraryAlbumCount: Int = 0, boughtThisYear: Int = 0, spentThisYear: Decimal = 0,
                    totalSpent: Decimal = 0, recent: [Purchase] = []) {
            self.ownedCount = ownedCount; self.libraryAlbumCount = libraryAlbumCount; self.boughtThisYear = boughtThisYear
            self.spentThisYear = spentThisYear; self.totalSpent = totalSpent; self.recent = recent
        }
    }

    /// The physical collection. Every field is optional, so newer phones can leave some out and older ones none in.
    public struct Collection: Codable, Hashable, Sendable {
        public var items: Int?
        public var cds: Int?
        public var vinyl: Int?
        public var downloads: Int?
        /// CDs with no digital copy.
        public var toRip: Int?
        /// Records with no digital copy.
        public var vinylToDigitize: Int?
        /// The next free label number of each series.
        public var nextCD: Int?
        public var nextVinyl: Int?
        /// Newest first (by purchase day, else when added), any medium, trackless ones included.
        public var recent: [Item]?
        /// CDs with no digital copy, oldest bought first.
        public var toRipList: [Item]?

        public init(items: Int? = nil, cds: Int? = nil, vinyl: Int? = nil, downloads: Int? = nil, toRip: Int? = nil,
                    vinylToDigitize: Int? = nil, nextCD: Int? = nil, nextVinyl: Int? = nil, recent: [Item]? = nil,
                    toRipList: [Item]? = nil) {
            self.items = items; self.cds = cds; self.vinyl = vinyl; self.downloads = downloads; self.toRip = toRip
            self.vinylToDigitize = vinylToDigitize; self.nextCD = nextCD; self.nextVinyl = nextVinyl
            self.recent = recent; self.toRipList = toRipList
        }

        /// A thing you own: a CD, a record or a download.
        public struct Item: Codable, Hashable, Sendable, Identifiable {
            /// The collection item's id.
            public var id: String
            /// `SearchIndex.albumKey` of its digital copy (which may not exist).
            public var albumKey: String
            public var title: String
            public var artist: String
            public var year: Int?
            /// "cd", "vinyl", "download", or a medium a newer version knows: a string, never an enum, so a new
            /// medium can't make the whole summary unreadable.
            public var medium: String
            /// Its label number, in its medium's series.
            public var sticker: Int?
            /// Its music is in the library.
            public var digitized: Bool?
            /// Some of its songs are on the iPhone.
            public var playable: Bool?
            /// File name of its cover thumbnail: its own cover, else its album's.
            public var cover: String?
            /// "yyyy-MM-dd", a calendar day with no time zone.
            public var purchasedOn: String?
            public var price: Decimal?
            /// "yyyy-MM-dd": the day it was added to the collection, for "Added 3 days ago" without a purchase day.
            public var addedOn: String?

            public init(id: String, albumKey: String, title: String, artist: String, year: Int? = nil, medium: String,
                        sticker: Int? = nil, digitized: Bool? = nil, playable: Bool? = nil, cover: String? = nil,
                        purchasedOn: String? = nil, price: Decimal? = nil, addedOn: String? = nil) {
                self.id = id; self.albumKey = albumKey; self.title = title; self.artist = artist; self.year = year
                self.medium = medium; self.sticker = sticker; self.digitized = digitized; self.playable = playable
                self.cover = cover; self.purchasedOn = purchasedOn; self.price = price; self.addedOn = addedOn
            }

            /// "CD #12", "Vinyl #12"; nil without a label.
            public var stickerText: String? { sticker.map { GlanceFormat.sticker(medium: medium, number: $0) } }
        }
    }

    public struct NowPlaying: Codable, Hashable, Sendable {
        public var song: Song
        public var isPlaying: Bool
        /// Seconds into the song at `updatedAt`.
        public var position: Double
        public var duration: Double
        public var updatedAt: Date
        public var liked: Bool
        /// The song after this one in the queue.
        public var next: Song?

        public init(song: Song, isPlaying: Bool, position: Double, duration: Double, updatedAt: Date, liked: Bool, next: Song? = nil) {
            self.song = song; self.isPlaying = isPlaying; self.position = position; self.duration = duration
            self.updatedAt = updatedAt; self.liked = liked; self.next = next
        }

        /// When the song started (or would have, at this position), for a running progress bar.
        public var startDate: Date { updatedAt.addingTimeInterval(-position) }
        public var endDate: Date { startDate.addingTimeInterval(max(duration, position)) }

        /// The position at `date`, which keeps moving while playing.
        public func position(at date: Date) -> Double {
            guard isPlaying else { return position }
            return min(max(duration, position), position + max(0, date.timeIntervalSince(updatedAt)))
        }
    }

    /// The same summary apart from when it was made, so writing it again (and reloading widgets) can be skipped.
    public func sameContent(as other: Glance) -> Bool {
        var a = self, b = other
        a.generatedAt = .distantPast; b.generatedAt = .distantPast
        a.nowPlaying?.updatedAt = .distantPast; b.nowPlaying?.updatedAt = .distantPast
        // While playing, the position moves with the clock: compare where the song started instead.
        if let x = self.nowPlaying, let y = other.nowPlaying, x.isPlaying, y.isPlaying,
           abs(x.startDate.timeIntervalSince(y.startDate)) < 2 {
            a.nowPlaying?.position = 0; b.nowPlaying?.position = 0
        }
        return a == b
    }

    /// An empty summary, for before the library has loaded and for previews.
    public static func empty(at date: Date = Date(), currencyCode: String = "USD") -> Glance {
        Glance(generatedAt: date, currencyCode: currencyCode, library: LibraryCounts(), week: Listening(days: 7),
               month: Listening(days: 30), owned: Owned(), nowPlaying: nil, rediscover: [])
    }

    // MARK: Covers

    /// The thumbnail's file name for an album: a stable hash of its key (FNV-1a), so it's a safe name and the same on
    /// every device.
    public static func coverName(albumKey: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in albumKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "c" + String(hash, radix: 16) + ".jpg"
    }

    /// A cover name that could have been made by `coverName(albumKey:)` (names arrive from the other device).
    public static func isCoverName(_ name: String) -> Bool {
        guard name.hasPrefix("c"), name.hasSuffix(".jpg") else { return false }
        let hex = name.dropFirst().dropLast(4)
        return (1...16).contains(hex.count) && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Every cover the summary shows.
    public var coverNames: Set<String> {
        var names = Set<String>()
        func add(_ name: String?) { if let name { names.insert(name) } }
        library.recentlyAdded.forEach { add($0.cover) }
        for listening in [week, month] {
            listening.topSongs.forEach { add($0.item.cover) }
            listening.topAlbums.forEach { add($0.item.cover) }
        }
        owned.recent.forEach { add($0.album.cover) }
        collection?.recent?.forEach { add($0.cover) }
        collection?.toRipList?.forEach { add($0.cover) }
        add(nowPlaying?.song.cover)
        add(nowPlaying?.next?.cover)
        rediscover.forEach { add($0.item.cover) }
        return names
    }
}

// MARK: Shelf index

/// Every labeled CD and record, for finding one by its label on the watch while the iPhone is away. Too big for the
/// application context (about 64 KB), so the iPhone sends it as a file, which the watch keeps under a fixed name.
/// Keys are one letter to keep it small (about 100 bytes an item).
public struct GlanceShelf: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "shelf.json"
    public static let maxBytes = 2_000_000
    public static let maxEntries = 20_000
    /// Titles and artists are cut to this many characters.
    public static let maxText = 80

    public var version = GlanceShelf.currentVersion
    public var generatedAt: Date
    /// CDs then records, each by number (duplicates next to each other).
    public var entries: [Entry]

    public init(generatedAt: Date, entries: [Entry]) {
        self.generatedAt = generatedAt
        self.entries = entries.sorted(by: Self.shelfOrder)
    }

    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        /// The collection item's id.
        public var i: String
        /// The series: "cd" or "vinyl".
        public var s: String
        /// The label number.
        public var n: Int
        public var t: String
        public var a: String
        public var y: Int?
        /// Its music is in the library.
        public var d: Bool?
        /// Its cover thumbnail's name.
        public var c: String?
        public var id: String { i }

        public init(id: String, series: String, number: Int, title: String, artist: String, year: Int? = nil,
                    digitized: Bool? = nil, cover: String? = nil) {
            i = id; s = series; n = number
            t = String(title.prefix(GlanceShelf.maxText)); a = String(artist.prefix(GlanceShelf.maxText))
            y = year; d = digitized; c = cover
        }

        /// "CD #12", "Vinyl #12".
        public var stickerText: String { GlanceFormat.sticker(medium: s, number: n) }
    }

    /// The series this version knows, in shelf order.
    public static let series = ["cd", "vinyl"]

    static func shelfOrder(_ x: Entry, _ y: Entry) -> Bool {
        let sx = series.firstIndex(of: x.s) ?? series.count, sy = series.firstIndex(of: y.s) ?? series.count
        if sx != sy { return sx < sy }
        return x.n != y.n ? x.n < y.n : x.i < y.i
    }

    /// The items with this label (more than one is a duplicate).
    public func entries(series: String, number: Int) -> [Entry] {
        entries.filter { $0.s == series && $0.n == number }
    }

    /// The labeled items just before and after the number in its series, whether or not the number is used.
    public func neighbors(series: String, number: Int) -> (previous: Entry?, next: Entry?) {
        var previous: Entry?, next: Entry?
        for e in entries where e.s == series {
            if number > e.n, e.n > (previous?.n ?? Int.min) { previous = e }
            if e.n > number, (next?.n ?? Int.max) > e.n { next = e }
        }
        return (previous, next)
    }

    /// A stable hash of the entries (not of when the index was made), so an unchanged shelf isn't sent again.
    public var contentHash: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ s: String) {
            for byte in s.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x1f
            hash = hash &* 0x0000_0100_0000_01b3
        }
        for e in entries {
            for field in [e.i, e.s, String(e.n), e.t, e.a, e.y.map(String.init) ?? "", e.d.map { $0 ? "1" : "0" } ?? "", e.c ?? ""] {
                mix(field)
            }
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Every cover the index refers to.
    public var coverNames: Set<String> { Set(entries.compactMap(\.c)) }

    /// An entry this version can show: a known series, a label in range, a plain id and one of our cover names.
    static func isValid(_ e: Entry) -> Bool {
        series.contains(e.s) && (1...9_999_999).contains(e.n)
            && (1...64).contains(e.i.count) && e.i.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
            && (e.c.map(Glance.isCoverName) ?? true)
    }
}

// MARK: Storage

/// Where the summary and its covers are kept: a `Glance` folder in the app group's container, shared by an app and
/// its widgets. The group's identifier is the `MusicLibraryAppGroup` key of the bundle's Info.plist (set from the
/// `APP_GROUP_IDENTIFIER` build setting).
public struct GlanceStore: Sendable {
    public static let appGroupInfoKey = "MusicLibraryAppGroup"
    static let fileName = "glance.json"

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The app group's store, or nil when the app isn't signed with the group.
    public static var shared: GlanceStore? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String, !group.isEmpty,
              !group.contains("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return GlanceStore(directory: container.appendingPathComponent("Glance", isDirectory: true))
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public func read() -> Glance? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return Self.decode(data)
    }

    public func write(_ glance: Glance) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(glance).write(to: fileURL, options: .atomic)
    }

    /// The cover's file, if the name is one of ours (names can come from another device).
    public func coverURL(_ name: String) -> URL? {
        Glance.isCoverName(name) ? directory.appendingPathComponent(name) : nil
    }

    public func hasCover(_ name: String) -> Bool {
        coverURL(name).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Saves a cover's JPEG data (atomically).
    public func saveCover(_ data: Data, name: String) throws {
        guard let url = coverURL(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Deletes the covers the summary no longer shows, except the shelf covers looked up most recently
    /// (`rememberShelfCover`).
    public func pruneCovers(keeping names: Set<String>) {
        let keep = names.union(shelfCovers)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where Glance.isCoverName(file) && !keep.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    // MARK: Shelf

    static let shelfCoversFileName = "shelf-covers.json"
    /// How many covers of items looked up on the shelf are kept beyond the summary's own.
    public static let shelfCoverLimit = 40

    public var shelfURL: URL { directory.appendingPathComponent(GlanceShelf.fileName) }

    public func readShelf() -> GlanceShelf? {
        guard let data = try? Data(contentsOf: shelfURL) else { return nil }
        return Self.decodeShelf(data)
    }

    /// Saves the index under its fixed name (atomically). Throws when it's over `GlanceShelf.maxBytes`.
    public func writeShelf(_ shelf: GlanceShelf) throws {
        let data = try Self.encodeShelf(shelf)
        guard data.count <= GlanceShelf.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: shelfURL, options: .atomic)
    }

    public static func encodeShelf(_ shelf: GlanceShelf) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(shelf)
    }

    /// Nil for anything over `maxBytes` or `maxEntries` or of another version. The file comes from the other device:
    /// entries of an unknown series, with a label out of range, an unusual id or a cover name that isn't ours are
    /// dropped, and the rest are put in shelf order.
    public static func decodeShelf(_ data: Data) -> GlanceShelf? {
        guard data.count <= GlanceShelf.maxBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let shelf = try? decoder.decode(GlanceShelf.self, from: data), shelf.version == GlanceShelf.currentVersion,
              shelf.entries.count <= GlanceShelf.maxEntries else { return nil }
        let entries = shelf.entries.filter(GlanceShelf.isValid).map {
            GlanceShelf.Entry(id: $0.i, series: $0.s, number: $0.n, title: $0.t, artist: $0.a, year: $0.y, digitized: $0.d, cover: $0.c)
        }
        return GlanceShelf(generatedAt: shelf.generatedAt, entries: entries)
    }

    /// The shelf covers looked up most recently, newest first, which `pruneCovers` keeps.
    public var shelfCovers: [String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.shelfCoversFileName)),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Array(names.filter(Glance.isCoverName).prefix(Self.shelfCoverLimit))
    }

    /// Notes that a shelf item's cover was shown, so it stays (up to `shelfCoverLimit` of them) when the summary
    /// changes.
    public func rememberShelfCover(_ name: String) {
        guard Glance.isCoverName(name) else { return }
        let names = Array(([name] + shelfCovers.filter { $0 != name }).prefix(Self.shelfCoverLimit))
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(Self.shelfCoversFileName), options: .atomic)
    }

    public static func encode(_ glance: Glance) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(glance)
    }

    /// Nil for anything that isn't a summary this version understands.
    public static func decode(_ data: Data) -> Glance? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let glance = try? decoder.decode(Glance.self, from: data), glance.version == Glance.currentVersion else { return nil }
        return glance
    }
}
