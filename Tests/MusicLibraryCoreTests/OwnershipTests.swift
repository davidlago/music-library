import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct AlbumOwnershipTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func purchaseDayParsing() {
        #expect(PurchaseDay(string: "2024-03-05")?.string == "2024-03-05")
        for bad in ["", "2024-3-5", "2024-13-01", "2024-00-10", "0999-01-01", "2024-01-32", "20240101", "2024-01-01T00", "abcd-ef-gh"] {
            #expect(PurchaseDay(string: bad) == nil, "\(bad)")
        }
        #expect(PurchaseDay(year: 2020, month: 1, day: 2)! < PurchaseDay(year: 2020, month: 2, day: 1)!)
    }

    @Test func purchaseDayKeepsTheDayAcrossTimeZones() {
        let day = PurchaseDay(year: 2023, month: 12, day: 31)!
        for zone in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC"] {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: zone)!
            #expect(PurchaseDay(day.date(calendar: c), calendar: c) == day)
        }
    }

    @Test func pricesAreValidatedAndStoredLocaleIndependently() {
        #expect(AlbumPurchase(album: "A", artist: "B", price: -1).price == nil)
        #expect(AlbumPurchase(album: "A", artist: "B", price: .nan).price == nil)
        #expect(AlbumPurchase.priceText(Decimal(string: "12.99")) == "12.99")
        #expect(AlbumPurchase.price(text: "12.99") == Decimal(string: "12.99"))
        #expect(AlbumPurchase.price(text: "-3") == nil)
        #expect(AlbumPurchase.price(text: "lots") == nil)
        #expect(AlbumPurchase.price(text: nil) == nil)
    }

    @Test func databaseRoundTrip() throws {
        let db = try Database(path: ":memory:")
        let key = SearchIndex.albumKey(album: "OK Computer", artist: "Radiohead")
        let p = AlbumPurchase(album: "OK Computer", artist: "Radiohead", purchasedOn: PurchaseDay(string: "1997-06-16"), price: Decimal(string: "15.49"))
        try db.saveAlbumPurchase(key: key, p)
        try db.saveAlbumPurchase(key: "x", AlbumPurchase(album: "X", artist: "Y"))
        #expect(try db.albumPurchases() == [key: p, "x": AlbumPurchase(album: "X", artist: "Y")])
        try db.saveAlbumPurchase(key: key, nil)
        #expect(try db.albumPurchases().keys.sorted() == ["x"])
    }

    @Test func malformedRowsReadAsUnknown() throws {
        let db = try Database(path: ":memory:")
        try db.exec("INSERT INTO album_ownership(key,album,artist,purchased_on,price,updated_at) VALUES('k','A','B','yesterday','-5',0)")
        let p = try #require(try db.albumPurchases()["k"])
        #expect(p.purchasedOn == nil && p.price == nil)
    }

    // MARK: Stats

    func key(_ album: String, _ artist: String) -> String { SearchIndex.albumKey(album: album, artist: artist) }

    func purchase(_ album: String, _ artist: String, _ day: String?, _ price: String?) -> (String, AlbumPurchase) {
        (key(album, artist), AlbumPurchase(album: album, artist: artist, purchasedOn: day.flatMap(PurchaseDay.init(string:)),
                                           price: price.flatMap { Decimal(string: $0) }))
    }

    func stats(_ purchases: [(String, AlbumPurchase)], plays: [Int64: PlayTotal] = [:]) -> OwnershipStats {
        // SearchFixtures.now is 2026-09-21 (UTC).
        OwnershipStats(tracks: SearchFixtures.library, purchases: Dictionary(uniqueKeysWithValues: purchases),
                       playTotals: plays, now: SearchFixtures.now, calendar: calendar)
    }

    @Test func nothingOwned() {
        let s = stats([])
        #expect(s.libraryAlbumCount == 6 && s.ownedCount == 0 && s.totalSpent == 0)
        #expect(s.albums.isEmpty && s.timeline.isEmpty && s.averagePrice == nil && s.costPerPlay == nil)
    }

    @Test func totalsAndPrices() {
        let s = stats([
            purchase("OK Computer", "Radiohead", "2026-02-10", "20"),
            purchase("Kind of Blue", "Miles Davis", "2025-11-01", "10"),
            purchase("Please Please Me", "The Beatles", nil, "15"),
            purchase("Computer World", "Kraftwerk", "2026-03-01", nil),
            purchase("Not In Library", "Nobody", "2026-01-01", "99"),
        ], plays: [1: PlayTotal(plays: 3, listened: 800), 2: PlayTotal(plays: 1, listened: 260), 3: PlayTotal(plays: 5, listened: 2800)])
        #expect(s.ownedCount == 4)  // the album not in the library is left out
        #expect(s.ownedFraction == 4.0 / 6.0)
        #expect(s.pricedCount == 3 && s.datedCount == 3)
        #expect(s.totalSpent == 45)
        #expect(s.averagePrice == 15 && s.medianPrice == 15)
        #expect(s.mostExpensive?.album == "OK Computer" && s.cheapest?.album == "Kind of Blue")
        #expect(s.spentThisYear == 20 && s.boughtThisYear == 2)
        #expect(s.pricedPlays == 9)
        #expect(s.costPerPlay == 5)
        #expect(s.albums.map(\.album) == ["Computer World", "OK Computer", "Kind of Blue", "Please Please Me"])
        #expect(s.latestPurchase?.album == "Computer World" && s.firstPurchase?.album == "Kind of Blue")
        #expect(s.mostPlayed?.album == "Kind of Blue")
        // Kind of Blue: 10 / 5 plays = 2; OK Computer: 20 / 4 = 5.
        #expect(s.bestValue.map(\.album) == ["Kind of Blue", "OK Computer"])
        #expect(s.unplayed.map(\.album) == ["Computer World", "Please Please Me"])
        #expect(Set(s.missingDetails.map(\.album)) == ["Please Please Me", "Computer World"])
    }

    @Test func timelineByMonthWithGaps() {
        let s = stats([
            purchase("OK Computer", "Radiohead", "2026-02-10", "20"),
            purchase("Kind of Blue", "Miles Davis", "2025-11-01", "10"),
            purchase("Computer World", "Kraftwerk", "2026-02-20", "5"),
        ])
        #expect(s.granularity == .month)
        // November 2025 through September 2026 ("now"), empty months included.
        #expect(s.timeline.count == 11)
        #expect(s.timeline.first?.spent == 10)
        #expect(s.timeline.map(\.albums) == [1, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0])
        #expect(s.timeline.last?.cumulative == 35)
        #expect(s.busiestPeriod?.spent == 25)
        #expect(calendar.component(.month, from: s.busiestPeriod!.start) == 2)
    }

    @Test func timelineByYearForLongSpans() {
        let s = stats([
            purchase("OK Computer", "Radiohead", "1997-07-01", "18"),
            purchase("Kind of Blue", "Miles Davis", "2020-01-01", "10"),
        ])
        #expect(s.granularity == .year)
        #expect(s.timeline.count == 2026 - 1997 + 1)
        #expect(s.timeline.first.map { calendar.component(.year, from: $0.start) } == 1997)
    }

    @Test func breakdowns() {
        let s = stats([
            purchase("OK Computer", "Radiohead", nil, "20"),
            purchase("Kind of Blue", "Miles Davis", nil, "10"),
            purchase("Please Please Me", "The Beatles", nil, "8"),
            purchase("Hits 2020", "Various Artists", nil, nil),
        ])
        #expect(s.artists.map(\.name) == ["Radiohead", "Miles Davis", "The Beatles", "Various Artists"])
        #expect(s.decades.map(\.name) == ["1950s", "1960s", "1990s", "2020s"])
        #expect(s.genres.first { $0.name == "Rock" }.map { ($0.albums, $0.spent) } ?? (0, 0) == (2, 28))
        #expect(s.timeline.isEmpty)  // no dates
    }
}
