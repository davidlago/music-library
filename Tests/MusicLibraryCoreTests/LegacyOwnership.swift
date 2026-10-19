import Foundation
@testable import MusicLibraryCore

/// What the app showed as owned before the collection, for the tests that compare the collection with it. These are
/// private copies of the algorithms 1.20 shipped (and the collection's view of them), kept here when the app's own
/// copies were removed: the migration tests must keep comparing against the old behavior, not against nothing.
enum LegacyOwnership {
    /// 1.20's `AlbumPurchase.including(songs:tracks:in:)`, verbatim: `records` (albums you said you own) plus, for
    /// each album without one, a download made of the songs you bought from it: their total (nil when none has a
    /// price) and the first one's day.
    static func including(songs: [Int64: TrackPurchase], tracks: [Track], in records: [String: AlbumPurchase]) -> [String: AlbumPurchase] {
        guard !songs.isEmpty else { return records }
        var all = records
        var bought: [String: AlbumPurchase] = [:]
        for t in tracks {
            guard let song = songs[t.id] else { continue }
            let key = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
            guard records[key] == nil else { continue }
            var p = bought[key] ?? AlbumPurchase(album: t.album, artist: t.effectiveAlbumArtist, format: .digital)
            if let price = song.price { p.price = (p.price ?? 0) + price }
            if let day = song.purchasedOn { p.purchasedOn = min(p.purchasedOn ?? day, day) }
            bought[key] = p
        }
        all.merge(bought) { a, _ in a }
        return all
    }

    /// The collection as versions before it saw it, by album key: each album's primary CD or download
    /// (`CollectionLegacy.primary`), else the download made of its bought songs. Records aren't in it. (What
    /// `MusicCollection.legacyPurchases`, `LibrarySnapshot.purchases` and the apps' `purchases` were.)
    static func purchases(of collection: MusicCollection) -> [String: AlbumPurchase] {
        var out: [String: AlbumPurchase] = [:]
        for key in Set(collection.items.map(\.albumKey)) {
            let copies = collection.copies(albumKey: key)
            if let p = CollectionLegacy.primary(copies, albumKey: key) {
                out[key] = CollectionLegacy.purchase(of: p)
            } else if let d = copies.first(where: { $0.origin == .songs }) {
                out[key] = AlbumPurchase(album: d.album, artist: d.artist, format: .digital, purchasedOn: d.purchasedOn, price: d.price)
            }
        }
        return out
    }

    /// The totals of 1.20's `OwnershipStats` (the Owned pane of Insights), computed as it did, which are also what
    /// its `Glance.build(purchases:)` put in `Glance.Owned`: only albums in the library count.
    struct Totals: Equatable {
        var libraryAlbumCount = 0
        var ownedCount = 0
        var totalSpent: Decimal = 0
        var spentThisYear: Decimal = 0
        var boughtThisYear = 0

        /// Library albums you don't own.
        var borrowedCount: Int { libraryAlbumCount - ownedCount }

        init(tracks: [Track], purchases: [String: AlbumPurchase], now: Date = Date(), calendar: Calendar = .current) {
            let keys = Set(tracks.map { SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist) })
            libraryAlbumCount = keys.count
            let owned = purchases.filter { keys.contains($0.key) }.map(\.value)
            ownedCount = owned.count
            totalSpent = owned.compactMap(\.price).reduce(Decimal(0), +)
            let thisYear = calendar.component(.year, from: now)
            for p in owned where p.purchasedOn?.year == thisYear {
                boughtThisYear += 1
                spentThisYear += p.price ?? 0
            }
        }
    }
}
