import Foundation

/// The Collection pane of Insights: what you own (CDs, records, downloads, with or without tracks in the library),
/// how much of it is digitized, the label series, what it cost and what it's been worth. Computed in one pass;
/// build it off the main thread. The Library pane (`LibraryStats`) describes the digital music and is separate.
public struct CollectionStats: Sendable {
    /// One medium's items, by digital state, labels and spending.
    public struct MediumShare: Identifiable, Hashable, Sendable {
        public var id: String { medium.rawValue }
        public var medium: CollectionMedium
        public var items = 0
        /// `DigitalState.digitized`.
        public var digitized = 0
        public var partial = 0
        /// The music is in the library from another copy.
        public var otherCopy = 0
        /// Physical items without a digital copy (`needsDigitizing`), `missing` included.
        public var toDigitize = 0
        /// Items whose digital copy is gone from the library.
        public var missing = 0
        /// Physical items with and without a label number (media with a series only).
        public var labeled = 0
        public var unlabeled = 0
        public var priced = 0
        public var spent: Decimal = 0

        public var averagePrice: Decimal? { priced == 0 ? nil : spent / Decimal(priced) }

        public init(medium: CollectionMedium) { self.medium = medium }
    }

    /// One label series: CDs or records.
    public struct SeriesStats: Identifiable, Hashable, Sendable {
        public var id: StickerSeries { series }
        public var series: StickerSeries
        public var labeled = 0
        /// Items of the series' medium with no number.
        public var unlabeled = 0
        public var highest: Int?
        /// The number to put on the next one: one past the highest (1 for the first).
        public var next = 1
        /// Numbers missing from 1 to the highest, as ranges.
        public var gaps: [ClosedRange<Int>] = []
        /// How many numbers `gaps` holds.
        public var gapCount = 0
        /// Numbers on more than one item: the items' ids.
        public var duplicates: [Int: [String]] = [:]
    }

    /// Spending in one month or year.
    public struct Period: Identifiable, Hashable, Sendable {
        public var id: PurchaseDay { start }
        /// The first day of the month or year.
        public var start: PurchaseDay
        /// By `CollectionMedium.rawValue`.
        public var spentByMedium: [String: Decimal]
        public var items: Int
        public var spent: Decimal
        /// Spent up to and including this period.
        public var cumulative: Decimal
    }

    public struct ItemRow: Identifiable, Hashable, Sendable {
        public var id: String { item.id }
        public var item: CollectionItem
        public var state: DigitalState
        /// Counted plays of the album's tracks (once per album, however many copies).
        public var plays: Int
        /// The item's price per play, or for Best Value the album's spend per play; nil when free, unpriced or
        /// never played.
        public var pricePerPlay: Decimal?
    }

    /// Items and spending under one artist, genre, decade or record label.
    public struct Breakdown: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public var name: String
        public var items: Int
        public var spent: Decimal
    }

    public enum Granularity: String, Sendable { case month, year }

    // Counts
    /// Stored items and derived downloads.
    public var itemCount = 0
    /// CDs, records and other physical media.
    public var physicalCount = 0
    /// Distinct albums (album keys) among the items.
    public var albumsOwned = 0
    /// Library albums with tracks.
    public var libraryAlbumCount = 0
    /// Library albums with tracks and no item (the Borrowed badge). Never negative.
    public var notInCollection = 0
    public var cdCount = 0
    public var vinylCount = 0
    public var downloadCount = 0
    public var otherCount = 0
    /// CDs, records, other media, downloads; only media you have something in.
    public var media: [MediumShare] = []

    // Digitization
    /// Physical items with music ÷ physical items (0 with none).
    public var digitizedShare: Double = 0
    /// Physical items without a digital copy, oldest bought first (undated ones by when they were added).
    public var toDigitize: [ItemRow] = []
    public var toDigitizeCount = 0
    /// CDs among them.
    public var toRipCount = 0
    /// Records among them: waiting for a turntable.
    public var vinylToDigitizeCount = 0

    // Labels
    /// CDs, then records, always both.
    public var series: [SeriesStats] = []

    // Spending
    public var totalSpent: Decimal = 0
    public var pricedCount = 0
    public var datedCount = 0
    public var spentThisYear: Decimal = 0
    public var boughtThisYear = 0
    public var averagePrice: Decimal?
    public var medianPrice: Decimal?
    public var priciest: ItemRow?
    /// Only with two or more priced items.
    public var cheapest: ItemRow?
    /// Monthly while dated purchases span less than 24 months, else yearly; every period from the first purchase to
    /// now (or the last, if later). Undated items are left out.
    public var timeline: [Period] = []
    public var granularity = Granularity.year

    // Value
    /// Spend ÷ counted plays over the albums with music and plays.
    public var costPerPlay: Decimal?
    /// Spend ÷ hours listened over the albums with music that have been listened to.
    public var costPerHour: Decimal?

    // Lists
    /// Newest bought (else added) first.
    public var recentlyAdded: [ItemRow] = []
    public var priciestList: [ItemRow] = []
    /// One row per album with music you paid for and played (its preferred copy), lowest spend per play first.
    public var bestValue: [ItemRow] = []
    /// Items with music whose album has never been played (counted plays), oldest bought first.
    public var stillInWrapper: [ItemRow] = []
    /// Editable items with no purchase day or price, and physical items with no label number.
    public var needsDetails: [ItemRow] = []
    /// Labeled items per series, in number order (not capped).
    public var byLabel: [StickerSeries: [ItemRow]] = [:]

    // Breakdowns
    public var artists: [Breakdown] = []
    /// The linked tracks' genres, else the album info's.
    public var genres: [Breakdown] = []
    /// By the item's year, else the tracks' ("1950s"), oldest first.
    public var decades: [Breakdown] = []
    /// The item's record label, else the tracks' tag.
    public var recordLabels: [Breakdown] = []

    // Facts
    /// The physical item with the earliest year.
    public var oldestRelease: CollectionItem?
    public var newestAddition: CollectionItem?
    /// The album with the most copies (two or more): its preferred copy and how many.
    public var mostCopies: (item: CollectionItem, copies: Int)?
    /// The item with the most discs (two or more).
    public var biggestBox: CollectionItem?
    /// The music of every album you own: the library tracks of albums with music, plus the album info's tracklist
    /// for trackless ones when known. Seconds.
    public var runtime: Double = 0

    /// Records waiting to be digitized.
    public var waitingForTurntable: Int { vinylToDigitizeCount }

    public init() {}

    public init(collection: MusicCollection, tracks: [Track], playTotals: [Int64: PlayTotal], albumInfos: [String: AlbumInfo],
                now: Date = Date(), calendar: Calendar = .current, listLimit: Int = 50) {
        struct Album {
            var duration = 0.0, plays = 0, listened = 0.0
            var year: Int?
            var genres: [String] = []
            var labels: [String: Int] = [:]
        }
        var albums: [String: Album] = [:]
        for t in tracks {
            let key = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
            var a = albums[key] ?? Album()
            a.duration += t.duration.isFinite ? max(0, t.duration) : 0
            if let y = t.year, (1000...9999).contains(y) { a.year = max(a.year ?? y, y) }
            if let p = playTotals[t.id] { a.plays += p.plays; a.listened += p.listened }
            for g in SearchIndex.genres(of: t.metadata) where !a.genres.contains(where: { $0.caseInsensitiveCompare(g) == .orderedSame }) {
                a.genres.append(g)
            }
            let label = t.metadata.extended.label.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { a.labels[label, default: 0] += 1 }
            albums[key] = a
        }
        libraryAlbumCount = albums.count

        let items = collection.items
        let owned = Set(items.map(\.albumKey))
        notInCollection = albums.keys.reduce(0) { $0 + (owned.contains($1) ? 0 : 1) }
        guard !items.isEmpty else {
            series = StickerSeries.allCases.map { SeriesStats(series: $0) }
            return
        }
        itemCount = items.count
        albumsOwned = owned.count

        let states = Dictionary(items.map { ($0.id, collection.digitalState($0)) }, uniquingKeysWith: { a, _ in a })
        func row(_ item: CollectionItem, pricePerPlay: Decimal? = nil) -> ItemRow {
            let plays = albums[item.albumKey]?.plays ?? 0
            var perPlay = pricePerPlay
            if perPlay == nil, let price = item.price, price > 0, plays > 0 { perPlay = price / Decimal(plays) }
            return ItemRow(item: item, state: states[item.id] ?? .none, plays: plays, pricePerPlay: perPlay)
        }
        let byTitle: (CollectionItem, CollectionItem) -> Bool = {
            let c = $0.album.localizedCaseInsensitiveCompare($1.album)
            if c != .orderedSame { return c == .orderedAscending }
            let a = $0.artist.localizedCaseInsensitiveCompare($1.artist)
            return a != .orderedSame ? a == .orderedAscending : $0.id < $1.id
        }
        /// When it was bought, else when it was added.
        func when(_ item: CollectionItem) -> Date { item.purchasedOn?.date(calendar: calendar) ?? item.createdAt }
        let oldestFirst: (CollectionItem, CollectionItem) -> Bool = { when($0) != when($1) ? when($0) < when($1) : byTitle($0, $1) }

        // Counts and media
        var shares: [CollectionMedium: MediumShare] = [:]
        for item in items {
            let state = states[item.id] ?? .none
            var s = shares[item.medium] ?? MediumShare(medium: item.medium)
            s.items += 1
            switch state {
            case .digitized: s.digitized += 1
            case .partial: s.partial += 1
            case .otherCopy: s.otherCopy += 1
            case .missing: s.missing += 1
            case .none: break
            }
            if item.medium.isPhysical, state.needsDigitizing { s.toDigitize += 1 }
            if item.medium.series != nil { if item.stickerNumber == nil { s.unlabeled += 1 } else { s.labeled += 1 } }
            if let price = item.price { s.priced += 1; s.spent += price }
            shares[item.medium] = s
        }
        media = shares.values.sorted { $0.medium < $1.medium }
        cdCount = shares[.cd]?.items ?? 0
        vinylCount = shares[.vinyl]?.items ?? 0
        downloadCount = shares[.download]?.items ?? 0
        otherCount = itemCount - cdCount - vinylCount - downloadCount

        // Digitization
        let physical = items.filter(\.medium.isPhysical)
        physicalCount = physical.count
        if !physical.isEmpty {
            digitizedShare = Double(physical.filter { states[$0.id]?.hasMusic == true }.count) / Double(physical.count)
        }
        let waiting = physical.filter { states[$0.id]?.needsDigitizing ?? true }.sorted(by: oldestFirst)
        toDigitizeCount = waiting.count
        toRipCount = waiting.filter { $0.medium == .cd }.count
        vinylToDigitizeCount = waiting.filter { $0.medium == .vinyl }.count
        toDigitize = waiting.prefix(listLimit).map { row($0) }

        // Labels
        series = StickerSeries.allCases.map { s in
            var stats = SeriesStats(series: s)
            let numbers = items.compactMap { $0.sticker?.series == s ? $0.stickerNumber : nil }
            stats.labeled = numbers.count
            stats.unlabeled = items.filter { $0.medium == s.medium && $0.stickerNumber == nil }.count
            stats.highest = numbers.max()
            stats.next = collection.nextNumber(in: s)
            stats.gaps = collection.gaps(in: s)
            stats.gapCount = stats.gaps.reduce(0) { $0 + $1.count }
            stats.duplicates = collection.duplicates(in: s).mapValues { $0.map(\.id) }
            return stats
        }
        for s in StickerSeries.allCases {
            byLabel[s] = items.filter { $0.sticker?.series == s }
                .sorted { $0.stickerNumber! != $1.stickerNumber! ? $0.stickerNumber! < $1.stickerNumber! : byTitle($0, $1) }
                .map { row($0) }
        }

        // Spending
        let priced = items.filter { $0.price != nil }
        pricedCount = priced.count
        totalSpent = priced.reduce(Decimal(0)) { $0 + $1.price! }
        if !priced.isEmpty {
            averagePrice = totalSpent / Decimal(priced.count)
            let prices = priced.map { $0.price! }.sorted()
            let mid = prices.count / 2
            medianPrice = prices.count % 2 == 1 ? prices[mid] : (prices[mid - 1] + prices[mid]) / 2
        }
        let byPrice: (CollectionItem, CollectionItem) -> Bool = { $0.price! != $1.price! ? $0.price! < $1.price! : byTitle($0, $1) }
        let priciestFirst = priced.sorted { byPrice($1, $0) }
        priciest = priciestFirst.first.map { row($0) }
        cheapest = priced.count > 1 ? priced.min(by: byPrice).map { row($0) } : nil
        priciestList = priciestFirst.prefix(listLimit).map { row($0) }
        let thisYear = calendar.component(.year, from: now)
        let dated = items.filter { $0.purchasedOn != nil }
        datedCount = dated.count
        for item in dated where item.purchasedOn?.year == thisYear {
            boughtThisYear += 1
            spentThisYear += item.price ?? 0
        }
        if let first = dated.map({ $0.purchasedOn! }).min(), let last = dated.map({ $0.purchasedOn! }).max() {
            let end = max(last, PurchaseDay(now, calendar: calendar))
            let months = (end.year - first.year) * 12 + end.month - first.month
            granularity = months < 24 ? .month : .year
            func bucket(_ d: PurchaseDay) -> Int { granularity == .month ? d.year * 12 + d.month - 1 : d.year }
            var buckets: [Int: (items: Int, spent: Decimal, byMedium: [String: Decimal])] = [:]
            for item in dated {
                let b = bucket(item.purchasedOn!)
                var v = buckets[b] ?? (0, 0, [:])
                v.items += 1
                if let price = item.price {
                    v.spent += price
                    v.byMedium[item.medium.rawValue, default: 0] += price
                }
                buckets[b] = v
            }
            var running: Decimal = 0
            timeline = (bucket(first)...bucket(end)).compactMap { b in
                let v = buckets[b] ?? (0, 0, [:])
                running += v.spent
                let start = granularity == .month ? PurchaseDay(year: b / 12, month: b % 12 + 1, day: 1) : PurchaseDay(year: b, month: 1, day: 1)
                return start.map { Period(start: $0, spentByMedium: v.byMedium, items: v.items, spent: v.spent, cumulative: running) }
            }
        }

        // Value, per album with music: the spend of every priced copy, the plays of its tracks once.
        var spendByKey: [String: Decimal] = [:]
        for item in priced { spendByKey[item.albumKey, default: 0] += item.price! }
        var playedSpend: Decimal = 0, plays = 0, listenedSpend: Decimal = 0, listened = 0.0
        var values: [(item: CollectionItem, perPlay: Decimal)] = []
        for key in owned {
            guard let a = albums[key] else { continue }
            let spend = spendByKey[key] ?? 0
            if a.plays > 0 {
                playedSpend += spend
                plays += a.plays
                if spend > 0, let primary = collection.copies(albumKey: key).first {
                    values.append((primary, spend / Decimal(a.plays)))
                }
            }
            if a.listened > 0 { listenedSpend += spend; listened += a.listened }
        }
        if plays > 0, playedSpend > 0 { costPerPlay = playedSpend / Decimal(plays) }
        if listened >= 60, listenedSpend > 0 { costPerHour = listenedSpend / Decimal(listened / 3600) }
        bestValue = values.sorted { $0.perPlay != $1.perPlay ? $0.perPlay < $1.perPlay : byTitle($0.item, $1.item) }
            .prefix(listLimit).map { row($0.item, pricePerPlay: $0.perPlay) }
        stillInWrapper = items.filter { states[$0.id]?.hasMusic == true && (albums[$0.albumKey]?.plays ?? 0) == 0 }
            .sorted(by: oldestFirst).prefix(listLimit).map { row($0) }
        needsDetails = items.filter { item in
            (item.isEditable && (item.purchasedOn == nil || item.price == nil))
                || (item.medium.isPhysical && item.medium.series != nil && item.stickerNumber == nil)
        }.prefix(listLimit).map { row($0) }
        recentlyAdded = items.sorted { when($0) != when($1) ? when($0) > when($1) : byTitle($0, $1) }.prefix(listLimit).map { row($0) }

        // Breakdowns
        func tally(_ dict: inout [String: Breakdown], _ name: String, _ item: CollectionItem) {
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let key = name.lowercased()
            var b = dict[key] ?? Breakdown(name: name, items: 0, spent: 0)
            b.items += 1
            b.spent += item.price ?? 0
            dict[key] = b
        }
        var artistSpend: [String: Breakdown] = [:], genreSpend: [String: Breakdown] = [:]
        var labelSpend: [String: Breakdown] = [:], decadeSpend: [Int: Breakdown] = [:]
        for item in items {
            let album = albums[item.albumKey]
            tally(&artistSpend, item.artist, item)
            let genres = album.map(\.genres).flatMap { $0.isEmpty ? nil : $0 } ?? albumInfos[item.albumKey]?.genres ?? []
            for g in genres { tally(&genreSpend, g, item) }
            if let label = item.recordLabel.flatMap({ $0.isEmpty ? nil : $0 }) ?? album.flatMap({ Self.mostCommonLabel($0.labels) }) {
                tally(&labelSpend, label, item)
            }
            if let y = Self.year(item, album?.year) {
                let decade = y / 10 * 10
                var b = decadeSpend[decade] ?? Breakdown(name: "\(decade)s", items: 0, spent: 0)
                b.items += 1
                b.spent += item.price ?? 0
                decadeSpend[decade] = b
            }
        }
        let bySpend: (Breakdown, Breakdown) -> Bool = {
            if $0.spent != $1.spent { return $0.spent > $1.spent }
            if $0.items != $1.items { return $0.items > $1.items }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        artists = Array(artistSpend.values.sorted(by: bySpend).prefix(listLimit))
        genres = Array(genreSpend.values.sorted(by: bySpend).prefix(listLimit))
        recordLabels = Array(labelSpend.values.sorted(by: bySpend).prefix(listLimit))
        decades = decadeSpend.sorted { $0.key < $1.key }.map(\.value)

        // Facts
        oldestRelease = physical.compactMap { item in Self.year(item, albums[item.albumKey]?.year).map { (item, $0) } }
            .min { $0.1 != $1.1 ? $0.1 < $1.1 : byTitle($0.0, $1.0) }?.0
        newestAddition = items.max { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : byTitle($1, $0) }
        var most: (item: CollectionItem, copies: Int)?
        for key in owned.sorted() {
            let copies = collection.copies(albumKey: key)
            if copies.count > 1, copies.count > (most?.copies ?? 0), let first = copies.first { most = (first, copies.count) }
        }
        mostCopies = most
        biggestBox = items.filter { ($0.discCount ?? 0) > 1 }
            .max { $0.discCount! != $1.discCount! ? $0.discCount! < $1.discCount! : byTitle($1, $0) }
        for key in owned {
            if let a = albums[key] {
                runtime += a.duration
            } else if let list = albumInfos[key]?.tracklist {
                runtime += list.compactMap(\.duration).filter { $0.isFinite && $0 > 0 }.reduce(0, +)
            }
        }
    }

    /// The item's year, else its tracks'.
    static func year(_ item: CollectionItem, _ tracksYear: Int?) -> Int? { item.year ?? tracksYear }

    /// The most frequent record label of an album's tracks, the first alphabetically among equals.
    static func mostCommonLabel(_ counts: [String: Int]) -> String? {
        counts.min { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }?.key
    }
}
