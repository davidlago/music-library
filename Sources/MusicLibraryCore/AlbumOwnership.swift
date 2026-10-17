import Foundation

/// A calendar day with no time or time zone, so a purchase date never shifts when the clock or zone changes.
public struct PurchaseDay: Hashable, Comparable, Codable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1000...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year ?? 2000; month = c.month ?? 1; day = c.day ?? 1
    }

    /// Parses "yyyy-MM-dd"; anything else (the database may come from elsewhere) is nil.
    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var string: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Noon on that day, which stays on the same day whatever the time zone's offset.
    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }

    public static func < (a: PurchaseDay, b: PurchaseDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

/// An album you own a copy of: when you bought it, what you paid and the number on the sticker you put on the case,
/// all optional. Saved per album (`SearchIndex.albumKey`) in the `album_ownership` table, apart from the tracks, so
/// re-importing an album keeps it.
public struct AlbumPurchase: Hashable, Sendable {
    public var album: String
    public var artist: String
    public var purchasedOn: PurchaseDay?
    /// In the user's currency. Never negative.
    public var price: Decimal?
    /// The number on the label you stuck on your copy to find it on the shelf (`validLabelNumber`). Set on the Mac only.
    public var labelNumber: Int? {
        didSet { if let n = labelNumber, Self.validLabelNumber(n) == nil { labelNumber = nil } }
    }

    public init(album: String, artist: String, purchasedOn: PurchaseDay? = nil, price: Decimal? = nil, labelNumber: Int? = nil) {
        self.album = album; self.artist = artist; self.purchasedOn = purchasedOn
        self.price = price.flatMap(Self.validPrice)
        self.labelNumber = labelNumber.flatMap(Self.validLabelNumber)
    }

    /// Label numbers run from 1 to `maxLabelNumber`.
    public static let maxLabelNumber = 9_999_999

    public static func validLabelNumber(_ n: Int) -> Int? { (1...maxLabelNumber).contains(n) ? n : nil }

    /// The number to suggest for the next album you label: one past the highest in use (counting albums no longer in
    /// the library, whose stickers are still on the shelf), or 1 for the first.
    public static func nextLabelNumber(in purchases: [String: AlbumPurchase]) -> Int {
        min((purchases.values.compactMap(\.labelNumber).max() ?? 0) + 1, maxLabelNumber)
    }

    /// Another album already labeled with this number, if any (the album with key `excluding` doesn't count).
    public static func album(labeled number: Int, in purchases: [String: AlbumPurchase], excluding key: String?) -> AlbumPurchase? {
        purchases.filter { $0.key != key && $0.value.labelNumber == number }
            .min { ($0.value.album, $0.value.artist, $0.key) < ($1.value.album, $1.value.artist, $1.key) }?.value
    }

    /// The price if it's a usable amount (not NaN, not negative), else nil.
    public static func validPrice(_ price: Decimal) -> Decimal? {
        price.isNaN || price < 0 ? nil : price
    }

    /// Prices are stored as plain decimal text ("12.99"), the same in every locale.
    static func priceText(_ price: Decimal?) -> String? {
        price.map { NSDecimalNumber(decimal: $0).description(withLocale: Locale(identifier: "en_US_POSIX")) }
    }

    static func price(text: String?) -> Decimal? {
        text.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }.flatMap(validPrice)
    }
}

/// For ownership edits sent with a sync by phones before 1.18 (now ownership is edited on the Mac only): the date and
/// price as the database stores them, and checked again when read (they come from another device). There's no label
/// number: the Mac keeps its own when it applies the change.
extension AlbumPurchase: Codable {
    private enum CodingKeys: String, CodingKey { case album, artist, purchasedOn, price }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(album: try c.decode(String.self, forKey: .album), artist: try c.decode(String.self, forKey: .artist),
                  purchasedOn: try c.decodeIfPresent(String.self, forKey: .purchasedOn).flatMap(PurchaseDay.init(string:)),
                  price: Self.price(text: try c.decodeIfPresent(String.self, forKey: .price)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(album, forKey: .album)
        try c.encode(artist, forKey: .artist)
        try c.encodeIfPresent(purchasedOn?.string, forKey: .purchasedOn)
        try c.encodeIfPresent(Self.priceText(price), forKey: .price)
    }
}

extension Decimal {
    public var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}

/// What you own and what you paid for it: the Owned pane of Insights. Only albums in the library count; purchases
/// saved for albums no longer in it are kept (and come back if the album does) but left out.
public struct OwnershipStats: Sendable {
    public struct OwnedAlbum: Identifiable, Hashable, Sendable {
        /// `SearchIndex.albumKey`.
        public var id: String
        public var album: String
        public var artist: String
        public var year: Int?
        public var trackCount: Int
        public var duration: Double
        public var purchasedOn: PurchaseDay?
        public var price: Decimal?
        public var labelNumber: Int?
        /// All-time plays of the album's tracks.
        public var plays: Int
        public var listened: Double

        /// What each play has cost so far; nil when unpriced, free or never played.
        public var pricePerPlay: Decimal? {
            guard let price, price > 0, plays > 0 else { return nil }
            return price / Decimal(plays)
        }
    }

    public struct Spend: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public var name: String
        public var albums: Int
        public var spent: Decimal
    }

    public enum Granularity: String, Sendable { case month, year }

    public struct Period: Identifiable, Hashable, Sendable {
        public var id: Date { start }
        public var start: Date
        public var albums: Int
        public var spent: Decimal
        /// Spent up to and including this period.
        public var cumulative: Decimal
    }

    public var libraryAlbumCount = 0
    public var ownedCount = 0
    public var pricedCount = 0
    public var datedCount = 0
    public var totalSpent: Decimal = 0
    public var averagePrice: Decimal?
    public var medianPrice: Decimal?
    public var spentThisYear: Decimal = 0
    public var boughtThisYear = 0
    /// Owned albums' music, and the plays and listening of the albums that have a price.
    public var ownedDuration: Double = 0
    public var pricedDuration: Double = 0
    public var pricedPlays = 0

    /// Every owned album, most recent purchase first (undated ones last, by title).
    public var albums: [OwnedAlbum] = []
    public var mostExpensive: OwnedAlbum?
    public var cheapest: OwnedAlbum?
    public var firstPurchase: OwnedAlbum?
    public var latestPurchase: OwnedAlbum?
    public var mostPlayed: OwnedAlbum?
    /// Albums you paid for, cheapest per play first.
    public var bestValue: [OwnedAlbum] = []
    /// Owned albums never played (counted plays), oldest purchase first.
    public var unplayed: [OwnedAlbum] = []
    /// Owned albums without a purchase date or price.
    public var missingDetails: [OwnedAlbum] = []
    /// Owned albums with a label number, in label order.
    public var labeled: [OwnedAlbum] = []

    /// Spending per month or year, every period from the first purchase to now (or the last, if later).
    public var timeline: [Period] = []
    public var granularity = Granularity.year
    public var busiestPeriod: Period?
    public var artists: [Spend] = []
    public var genres: [Spend] = []
    /// By release decade ("1990s"), oldest first.
    public var decades: [Spend] = []

    public var ownedFraction: Double { libraryAlbumCount == 0 ? 0 : Double(ownedCount) / Double(libraryAlbumCount) }
    public var costPerPlay: Decimal? { pricedPlays == 0 || totalSpent == 0 ? nil : totalSpent / Decimal(pricedPlays) }
    public var costPerHour: Decimal? { pricedDuration < 60 || totalSpent == 0 ? nil : totalSpent / Decimal(pricedDuration / 3600) }

    public init() {}

    public init(tracks: [Track], purchases: [String: AlbumPurchase], playTotals: [Int64: PlayTotal] = [:],
                now: Date = Date(), calendar: Calendar = .current, listLimit: Int = 25) {
        struct Group {
            var album: String, artist: String, year: Int?, tracks = 0, duration = 0.0, plays = 0, listened = 0.0
            var genres: [String] = []
        }
        var groups: [String: Group] = [:]
        for t in tracks {
            let key = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
            var g = groups[key] ?? Group(album: t.album.isEmpty ? "Unknown Album" : t.album,
                                         artist: t.effectiveAlbumArtist.isEmpty ? "Unknown Artist" : t.effectiveAlbumArtist, year: nil)
            g.tracks += 1
            g.duration += t.duration.isFinite ? max(0, t.duration) : 0
            if let y = t.year, y > 0 { g.year = max(g.year ?? y, y) }
            if let p = playTotals[t.id] { g.plays += p.plays; g.listened += p.listened }
            for genre in SearchIndex.genres(of: t.metadata) where !g.genres.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) {
                g.genres.append(genre)
            }
            groups[key] = g
        }
        libraryAlbumCount = groups.count

        var owned: [(album: OwnedAlbum, genres: [String])] = []
        for (key, p) in purchases {
            guard let g = groups[key] else { continue }
            owned.append((OwnedAlbum(id: key, album: g.album, artist: g.artist, year: g.year, trackCount: g.tracks,
                                     duration: g.duration, purchasedOn: p.purchasedOn, price: p.price,
                                     labelNumber: p.labelNumber, plays: g.plays, listened: g.listened), g.genres))
        }
        guard !owned.isEmpty else { return }

        let list = owned.map(\.album)
        let byTitle: (OwnedAlbum, OwnedAlbum) -> Bool = {
            let c = $0.album.localizedCaseInsensitiveCompare($1.album)
            return c != .orderedSame ? c == .orderedAscending : $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
        }
        albums = list.sorted { a, b in
            switch (a.purchasedOn, b.purchasedOn) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: byTitle(a, b)
            }
        }
        ownedCount = list.count
        ownedDuration = list.reduce(0) { $0 + $1.duration }

        let priced = list.filter { $0.price != nil }
        pricedCount = priced.count
        datedCount = list.filter { $0.purchasedOn != nil }.count
        totalSpent = priced.reduce(Decimal(0)) { $0 + $1.price! }
        pricedDuration = priced.reduce(0) { $0 + $1.duration }
        pricedPlays = priced.reduce(0) { $0 + $1.plays }
        if !priced.isEmpty {
            averagePrice = totalSpent / Decimal(priced.count)
            let prices = priced.map { $0.price! }.sorted()
            let mid = prices.count / 2
            medianPrice = prices.count % 2 == 1 ? prices[mid] : (prices[mid - 1] + prices[mid]) / 2
        }
        let byPrice: (OwnedAlbum, OwnedAlbum) -> Bool = { $0.price! != $1.price! ? $0.price! < $1.price! : byTitle($0, $1) }
        mostExpensive = priced.max(by: byPrice)
        cheapest = priced.count > 1 ? priced.min(by: byPrice) : nil

        let thisYear = calendar.component(.year, from: now)
        for a in list where a.purchasedOn?.year == thisYear {
            boughtThisYear += 1
            spentThisYear += a.price ?? 0
        }
        let dated = albums.filter { $0.purchasedOn != nil }
        latestPurchase = dated.first
        firstPurchase = dated.count > 1 ? dated.last : nil
        mostPlayed = list.filter { $0.plays > 0 }.max { $0.plays != $1.plays ? $0.plays < $1.plays : byTitle($1, $0) }
        bestValue = Array(list.filter { $0.pricePerPlay != nil }
            .sorted { $0.pricePerPlay! != $1.pricePerPlay! ? $0.pricePerPlay! < $1.pricePerPlay! : byTitle($0, $1) }
            .prefix(listLimit))
        unplayed = albums.filter { $0.plays == 0 }.sorted { a, b in
            switch (a.purchasedOn, b.purchasedOn) {
            case let (x?, y?) where x != y: x < y
            case (_?, nil): true
            case (nil, _?): false
            default: byTitle(a, b)
            }
        }
        missingDetails = albums.filter { $0.purchasedOn == nil || $0.price == nil }
        labeled = list.filter { $0.labelNumber != nil }
            .sorted { $0.labelNumber! != $1.labelNumber! ? $0.labelNumber! < $1.labelNumber! : byTitle($0, $1) }

        // Spending over time: by month for up to two years of purchases, by year beyond that.
        if let first = dated.last?.purchasedOn, let last = dated.first?.purchasedOn {
            let end = max(last, PurchaseDay(now, calendar: calendar))
            let months = (end.year - first.year) * 12 + end.month - first.month
            granularity = months < 24 ? .month : .year
            func bucket(_ d: PurchaseDay) -> Int { granularity == .month ? d.year * 12 + d.month - 1 : d.year }
            var spent: [Int: (albums: Int, spent: Decimal)] = [:]
            for a in dated {
                let b = bucket(a.purchasedOn!)
                spent[b, default: (0, 0)].albums += 1
                spent[b, default: (0, 0)].spent += a.price ?? 0
            }
            var running: Decimal = 0
            timeline = (bucket(first)...bucket(end)).map { b in
                let s = spent[b] ?? (0, 0)
                running += s.spent
                let comps = granularity == .month ? DateComponents(year: b / 12, month: b % 12 + 1, day: 1)
                                                  : DateComponents(year: b, month: 1, day: 1)
                return Period(start: calendar.date(from: comps) ?? now, albums: s.albums, spent: s.spent, cumulative: running)
            }
            busiestPeriod = timeline.filter { $0.albums > 0 }
                .max { $0.spent != $1.spent ? $0.spent < $1.spent : ($0.albums != $1.albums ? $0.albums < $1.albums : $0.start > $1.start) }
        }

        // Breakdowns
        func tally(_ dict: inout [String: Spend], _ name: String, _ a: OwnedAlbum) {
            let key = name.lowercased()
            var s = dict[key] ?? Spend(name: name, albums: 0, spent: 0)
            s.albums += 1
            s.spent += a.price ?? 0
            dict[key] = s
        }
        var artistSpend: [String: Spend] = [:], genreSpend: [String: Spend] = [:], decadeSpend: [Int: Spend] = [:]
        for (a, genres) in owned {
            tally(&artistSpend, a.artist, a)
            for g in genres { tally(&genreSpend, g, a) }
            if let y = a.year {
                let decade = y / 10 * 10
                var s = decadeSpend[decade] ?? Spend(name: "\(decade)s", albums: 0, spent: 0)
                s.albums += 1
                s.spent += a.price ?? 0
                decadeSpend[decade] = s
            }
        }
        let bySpend: (Spend, Spend) -> Bool = {
            if $0.spent != $1.spent { return $0.spent > $1.spent }
            if $0.albums != $1.albums { return $0.albums > $1.albums }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        artists = Array(artistSpend.values.sorted(by: bySpend).prefix(listLimit))
        genres = Array(genreSpend.values.sorted(by: bySpend).prefix(listLimit))
        decades = decadeSpend.sorted { $0.key < $1.key }.map(\.value)
    }
}
