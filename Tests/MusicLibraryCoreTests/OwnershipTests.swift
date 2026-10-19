import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct AlbumOwnershipTests {
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
        #expect(try db.legacyOwnershipRows().first { $0.key == "d" }?.purchase.format == .cd, "and so it does for the collection")
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
        var item = CollectionItem(id: "cd", medium: .cd, album: "CD", artist: "A", now: Date(timeIntervalSince1970: 0))
        item.price = 12
        item.stickerNumber = 4
        let all = LegacyOwnership.purchases(of: MusicCollection(items: [item], songPurchases: songs, tracks: tracks))
        #expect(all == LegacyOwnership.including(songs: songs, tracks: tracks, in: records), "the downloads 1.20 derived")
        #expect(all[key("Songs", "A")] == AlbumPurchase(album: "Songs", artist: "A", format: .digital,
                                                        purchasedOn: PurchaseDay(year: 2026, month: 3, day: 9), price: Decimal(string: "2.28")))
        #expect(all[key("CD", "A")] == cd, "an album you said you own keeps its own details")
        #expect(all[key("Free", "A")] == AlbumPurchase(album: "Free", artist: "A", format: .digital))
        #expect(LegacyOwnership.purchases(of: MusicCollection(items: [item], songPurchases: [:], tracks: tracks)) == records)
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
        // The phone reconciles it into the collection as a CD.
        let items = CollectionLegacy.reconcile(items: try snapshot.collectionItems().items, legacy: try snapshot.legacyOwnershipRows()).items
        #expect(items.map(\.medium) == [.cd] && items.first?.price == 5 && items.first?.id == CollectionItem.legacyID(albumKey: "k"))

        let db = try Database(path: path)
        try db.saveAlbumPurchase(key: "k", AlbumPurchase(album: "A", artist: "B", labelNumber: 9))
        #expect(try db.albumPurchases()["k"]?.labelNumber == 9)
        try db.saveAlbumPurchase(key: "k", AlbumPurchase(album: "A", artist: "B", format: .digital))
        #expect(try db.albumPurchases()["k"]?.format == .digital)
    }

    func key(_ album: String, _ artist: String) -> String { SearchIndex.albumKey(album: album, artist: artist) }
}
