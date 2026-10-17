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

    @Test func labelNumbersAreValidatedAndSaved() throws {
        #expect(AlbumPurchase(album: "A", artist: "B", labelNumber: 0).labelNumber == nil)
        #expect(AlbumPurchase(album: "A", artist: "B", labelNumber: -4).labelNumber == nil)
        #expect(AlbumPurchase(album: "A", artist: "B", labelNumber: AlbumPurchase.maxLabelNumber + 1).labelNumber == nil)
        var p = AlbumPurchase(album: "A", artist: "B", labelNumber: 7)
        #expect(p.labelNumber == 7)
        p.labelNumber = -1
        #expect(p.labelNumber == nil)

        let db = try Database(path: ":memory:")
        try db.saveAlbumPurchase(key: "k", AlbumPurchase(album: "A", artist: "B", labelNumber: 42))
        #expect(try db.albumPurchases()["k"]?.labelNumber == 42)
        try db.exec("UPDATE album_ownership SET label_number='forty' WHERE key='k'")
        #expect(try db.albumPurchases()["k"]?.labelNumber == nil)
    }

    @Test func downloadsHaveNoLabelAndTheFormatIsSaved() throws {
        #expect(AlbumPurchase(album: "A", artist: "B", format: .digital, labelNumber: 4).labelNumber == nil)
        var p = AlbumPurchase(album: "A", artist: "B", labelNumber: 4)
        p.format = .digital
        #expect(p.labelNumber == nil)
        p.labelNumber = 5
        #expect(p.labelNumber == nil)
        p.format = .cd
        p.labelNumber = 5
        #expect(p.labelNumber == 5)

        let db = try Database(path: ":memory:")
        try db.saveAlbumPurchase(key: "d", AlbumPurchase(album: "A", artist: "B", format: .digital, price: 9))
        try db.saveAlbumPurchase(key: "c", AlbumPurchase(album: "C", artist: "B", labelNumber: 2))
        #expect(try db.albumPurchases()["d"]?.format == .digital)
        #expect(try db.albumPurchases()["c"]?.format == .cd)
        // A CD is stored as NULL, like every purchase before formats; something unknown reads as a CD.
        #expect(try db.query("SELECT format FROM album_ownership WHERE key='c'") { $0.string(0) }.first == .some(nil))
        try db.exec("UPDATE album_ownership SET format='vinyl' WHERE key='d'")
        #expect(try db.albumPurchases()["d"]?.format == .cd)
    }

    @Test func ownershipMarks() {
        #expect(OwnershipMark(nil) == .borrowed)
        #expect(OwnershipMark(AlbumPurchase(album: "A", artist: "B", labelNumber: 3)) == .cd(label: 3))
        #expect(OwnershipMark(AlbumPurchase(album: "A", artist: "B")) == .cd(label: nil))
        #expect(OwnershipMark(AlbumPurchase(album: "A", artist: "B", format: .digital)) == .digital)
        #expect(OwnershipMark.cd(label: 3).labelNumber == 3 && OwnershipMark.digital.labelNumber == nil)
    }

    @Test func batchPricesSplitEvenlyToTheCent() {
        #expect(TrackPurchase.split(10, into: 3) == [Decimal(string: "3.34")!, Decimal(string: "3.33")!, Decimal(string: "3.33")!])
        #expect(TrackPurchase.split(Decimal(string: "9.99")!, into: 1) == [Decimal(string: "9.99")!])
        #expect(TrackPurchase.split(12, into: 12) == Array(repeating: Decimal(1), count: 12))
        #expect(TrackPurchase.split(Decimal(string: "0.02")!, into: 3) == [Decimal(string: "0.01")!, Decimal(string: "0.01")!, 0])
        #expect(TrackPurchase.split(Decimal(string: "1.005")!, into: 1) == [Decimal(string: "1.01")!])
        #expect(TrackPurchase.split(5, into: 0).isEmpty)
        #expect(TrackPurchase.split(-5, into: 2).isEmpty)
        #expect(TrackPurchase.split(Decimal(string: "9.99")!, into: 7).reduce(0, +) == Decimal(string: "9.99")!)
    }

    @Test func songPurchasesAreSavedAndGoWithTheTrack() throws {
        let db = try Database(path: ":memory:")
        let track = try db.insertTrack(Track(path: "Music/A/B/01 - C.flac", metadata: TrackMetadata(title: "C", artist: "A", album: "B"),
                                             duration: 60, format: "flac", sha256: "s"))
        let bought = TrackPurchase(purchasedOn: PurchaseDay(year: 2026, month: 10, day: 1), price: Decimal(string: "1.29"))
        try db.saveTrackPurchase(trackID: track.id, bought)
        #expect(try db.trackPurchases() == [track.id: bought])
        try db.exec("UPDATE track_purchases SET price='free', purchased_on='soon'")
        #expect(try db.trackPurchases() == [track.id: TrackPurchase()])
        try db.deleteTracks(ids: [track.id])
        #expect(try db.trackPurchases().isEmpty)
        #expect(TrackPurchase(price: -1).price == nil)
    }

    @Test func boughtSongsMakeAnAlbumADownload() {
        func track(_ id: Int64, _ album: String) -> Track {
            Track(id: id, path: "\(id)", metadata: TrackMetadata(title: "T\(id)", artist: "A", album: album), duration: 60, format: "flac", sha256: "\(id)")
        }
        let tracks = [track(1, "Songs"), track(2, "Songs"), track(3, "Songs"), track(4, "CD"), track(5, "Free")]
        let cd = AlbumPurchase(album: "CD", artist: "A", price: 12, labelNumber: 4)
        let records = [key("CD", "A"): cd]
        let songs: [Int64: TrackPurchase] = [
            1: TrackPurchase(purchasedOn: PurchaseDay(year: 2026, month: 5, day: 2), price: Decimal(string: "1.29")),
            2: TrackPurchase(purchasedOn: PurchaseDay(year: 2026, month: 3, day: 9), price: Decimal(string: "0.99")),
            4: TrackPurchase(price: 1),
            5: TrackPurchase(),
        ]
        let all = AlbumPurchase.including(songs: songs, tracks: tracks, in: records)
        #expect(all[key("Songs", "A")] == AlbumPurchase(album: "Songs", artist: "A", format: .digital,
                                                        purchasedOn: PurchaseDay(year: 2026, month: 3, day: 9), price: Decimal(string: "2.28")))
        #expect(all[key("CD", "A")] == cd, "an album you said you own keeps its own details")
        #expect(all[key("Free", "A")] == AlbumPurchase(album: "Free", artist: "A", format: .digital))
        #expect(AlbumPurchase.including(songs: [:], tracks: tracks, in: records) == records)
    }

    @Test func formatsSplitCDsDownloadsAndBorrowed() {
        func track(_ id: Int64, _ album: String) -> Track {
            Track(id: id, path: "\(id)", metadata: TrackMetadata(title: "T\(id)", artist: "A", album: album), duration: 100, format: "flac", sha256: "\(id)")
        }
        let tracks = [track(1, "CD1"), track(2, "CD2"), track(3, "Full"), track(4, "Part"), track(5, "Part"), track(6, "Borrowed")]
        let songs: [Int64: TrackPurchase] = [4: TrackPurchase(price: 1)]
        let records = [key("CD1", "A"): AlbumPurchase(album: "CD1", artist: "A", price: 10, labelNumber: 1),
                       key("CD2", "A"): AlbumPurchase(album: "CD2", artist: "A", price: 14),
                       key("Full", "A"): AlbumPurchase(album: "Full", artist: "A", format: .digital, price: 8)]
        let s = OwnershipStats(tracks: tracks, purchases: AlbumPurchase.including(songs: songs, tracks: tracks, in: records), songPurchases: songs)
        #expect(s.formats.map(\.format) == [.cd, .digital])
        let cd = s.formats[0], digital = s.formats[1]
        #expect(cd.albums == 2 && cd.spent == 24 && cd.labeled == 1 && cd.averagePrice == 12 && cd.partial == 0)
        #expect(digital.albums == 2 && digital.spent == 9 && digital.partial == 1 && digital.labeled == 0)
        #expect(s.borrowedCount == 1)
        #expect(s.albums.first { $0.album == "Part" }?.partial == true)
        #expect(s.albums.first { $0.album == "Full" }?.partial == false)
        #expect(OwnershipStats(tracks: tracks, purchases: [:]).formats.isEmpty)
    }

    @Test func nextLabelNumberFollowsTheHighest() {
        #expect(AlbumPurchase.nextLabelNumber(in: [:]) == 1)
        let purchases = [
            "a": AlbumPurchase(album: "A", artist: "X", labelNumber: 3),
            "b": AlbumPurchase(album: "B", artist: "X", labelNumber: 12),
            "c": AlbumPurchase(album: "C", artist: "X"),
            "d": AlbumPurchase(album: "D", artist: "X", labelNumber: 12),
        ]
        #expect(AlbumPurchase.nextLabelNumber(in: purchases) == 13)
        #expect(AlbumPurchase.nextLabelNumber(in: ["z": AlbumPurchase(album: "Z", artist: "X", labelNumber: AlbumPurchase.maxLabelNumber)])
                == AlbumPurchase.maxLabelNumber)
        #expect(AlbumPurchase.album(labeled: 12, in: purchases, excluding: "b")?.album == "D")
        #expect(AlbumPurchase.album(labeled: 3, in: purchases, excluding: "a") == nil)
        #expect(AlbumPurchase.album(labeled: 5, in: purchases, excluding: nil) == nil)
    }

    /// A library from before label numbers gets the column when opened, and a snapshot of one (read-only, so never
    /// migrated) reads without them.
    @Test func ownershipTableFromBeforeLabelNumbers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("library.sqlite").path
        do {
            let db = try Database(path: path)
            try db.exec("DROP TABLE album_ownership")
            try db.exec("""
            CREATE TABLE album_ownership(key TEXT PRIMARY KEY, album TEXT NOT NULL, artist TEXT NOT NULL,
                purchased_on TEXT, price TEXT, updated_at REAL NOT NULL)
            """)
            try db.exec("INSERT INTO album_ownership(key,album,artist,purchased_on,price,updated_at) VALUES('k','A','B','2020-01-02','5',0)")
            try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let snapshot = try Database(snapshotAt: path)
        #expect(try snapshot.albumPurchases()["k"] == AlbumPurchase(album: "A", artist: "B", purchasedOn: PurchaseDay(year: 2020, month: 1, day: 2), price: 5))

        let db = try Database(path: path)
        try db.saveAlbumPurchase(key: "k", AlbumPurchase(album: "A", artist: "B", labelNumber: 9))
        #expect(try db.albumPurchases()["k"]?.labelNumber == 9)
        try db.saveAlbumPurchase(key: "k", AlbumPurchase(album: "A", artist: "B", format: .digital))
        #expect(try db.albumPurchases()["k"]?.format == .digital)
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
