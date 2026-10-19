import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct CollectionStoreTests {
    func key(_ album: String, _ artist: String = "Artist") -> String { SearchIndex.albumKey(album: album, artist: artist) }

    func item(_ id: String, _ medium: CollectionMedium, _ number: Int? = nil, album: String, artist: String = "Artist",
              price: Decimal? = nil, created: TimeInterval = 0) -> CollectionItem {
        var i = CollectionItem(id: id, medium: medium, album: album, artist: artist, now: Date(timeIntervalSince1970: created))
        i.stickerNumber = number
        i.price = price
        return i
    }

    /// A library as 1.20 left it: `album_ownership` rows and no collection table.
    func makeLegacyLibrary(at path: String, rows: [(key: String, album: String, artist: String, format: String?, label: Int?, price: String?, day: String?)]) throws {
        let db = try Database(path: path)
        try db.exec("DROP TABLE collection_items")
        try db.exec("DELETE FROM album_ownership")
        for (i, r) in rows.enumerated() {
            try db.exec("INSERT INTO album_ownership(key,album,artist,format,label_number,price,purchased_on,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                        [.text(r.key), .text(r.album), .text(r.artist), .text(r.format), .int(r.label), .text(r.price), .text(r.day),
                         .double(1000 + Double(i))])
        }
    }

    func ownershipRows(_ db: Database) throws -> [[String]] {
        try db.query("SELECT key, album, artist, IFNULL(format,'∅'), IFNULL(label_number,'∅'), IFNULL(price,'∅'), IFNULL(purchased_on,'∅'), updated_at FROM album_ownership ORDER BY key") { r in
            (0..<8).map { r.string(Int32($0)) ?? "∅" }
        }
    }

    var legacyRows: [(key: String, album: String, artist: String, format: String?, label: Int?, price: String?, day: String?)] {
        [(key("Blue"), "Blue", "Artist", nil, 12, "10", "2020-01-02"),
         (key("Bought"), "Bought", "Artist", "digital", nil, "9.99", nil),
         (key("Odd"), "Odd", "Artist", "vinyl", 3, nil, nil),
         (key("Twelve"), "Twelve", "Artist", nil, 12, nil, nil),
         (key("Orphan", "Gone"), "Orphan", "Gone", nil, nil, "abc", "yesterday")]
    }

    @Test func tableIsCreatedWithoutASchemaChange() throws {
        let db = try Database(path: ":memory:")
        #expect(try db.query("PRAGMA user_version") { $0.int(0) }.first == 14)
        #expect(Database.schemaVersion == 14)
        #expect(try db.columns(of: "collection_items") == Set(Database.collectionColumns))
        let indexes = try db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='collection_items'") { $0.string(0) ?? "" }
        #expect(Set(indexes).isSuperset(of: ["collection_items_album", "collection_items_sticker", "collection_items_release"]))
        let unique = try db.query("SELECT COUNT(*) FROM pragma_index_list('collection_items') WHERE \"unique\"=1 AND origin='c'") { $0.int(0) ?? 0 }
        #expect(unique.first == 0, "no UNIQUE index on labels")
        #expect(try db.collectionItems().hadTable)
    }

    @Test func migrationMakesItemsWithDeterministicIDsAndIsIdempotent() throws {
        let path = try TestSupport.tempDir().appendingPathComponent("library.sqlite").path
        try makeLegacyLibrary(at: path, rows: legacyRows)
        var db: Database? = try Database(path: path)
        let items = try #require(db).collectionItems().items
        let byKey = Dictionary(grouping: items, by: \.albumKey).mapValues { $0[0] }
        #expect(items.count == 5)
        for item in items { #expect(item.id == CollectionItem.legacyID(albumKey: item.albumKey)) }
        #expect(byKey[key("Blue")]?.medium == .cd && byKey[key("Blue")]?.stickerNumber == 12)
        #expect(byKey[key("Blue")]?.price == 10 && byKey[key("Blue")]?.purchasedOn == PurchaseDay(year: 2020, month: 1, day: 2))
        #expect(byKey[key("Blue")]?.createdAt == Date(timeIntervalSince1970: 1000) && byKey[key("Blue")]?.updatedAt == Date(timeIntervalSince1970: 1000))
        #expect(byKey[key("Bought")]?.medium == .download && byKey[key("Bought")]?.stickerNumber == nil)
        #expect(byKey[key("Odd")]?.medium == .cd && byKey[key("Odd")]?.stickerNumber == 3, "an unknown format reads as a CD, as old readers do")
        #expect(byKey[key("Twelve")]?.stickerNumber == 12, "a duplicate label is kept")
        let orphan = try #require(byKey[key("Orphan", "Gone")])
        #expect(orphan.album == "Orphan" && orphan.artist == "Gone" && orphan.price == nil && orphan.purchasedOn == nil && orphan.digitalSource == nil)
        #expect(MusicCollection(items: items, songPurchases: [:], tracks: []).duplicates(in: .cd)[12]?.count == 2)

        // The projection holds CDs and downloads only: the 'vinyl' row is rewritten as the CD it always read as.
        let projected = try ownershipRows(try #require(db))
        #expect(Set(try #require(db).query("SELECT DISTINCT IFNULL(format,'∅') FROM album_ownership") { $0.string(0) ?? "" }).isSubset(of: ["∅", "digital"]))
        #expect(projected.count == 5)

        // Reopening changes nothing.
        db = nil
        db = try Database(path: path)
        #expect(try #require(db).collectionItems().items == items)
        #expect(try ownershipRows(try #require(db)) == projected)
        db = nil
        db = try Database(path: path)
        #expect(try ownershipRows(try #require(db)) == projected)
    }

    @Test func copiesWithoutTheTableReadAsTheMigrationWould() throws {
        let dir = try TestSupport.tempDir()
        let old = dir.appendingPathComponent("old.sqlite").path, migrated = dir.appendingPathComponent("new.sqlite").path
        try makeLegacyLibrary(at: old, rows: legacyRows)
        try makeLegacyLibrary(at: migrated, rows: legacyRows)
        let snapshot = try Database(snapshotAt: old).collectionItems()
        #expect(!snapshot.hadTable && snapshot.unreadable == 0)
        let mac = try Database(path: migrated).collectionItems().items
        #expect(snapshot.items.sorted { $0.id < $1.id } == mac.sorted { $0.id < $1.id })
        #expect(try Database(snapshotAt: old).collectionCoverPaths().isEmpty)
    }

    @Test func projectionIsThePrimaryCopyOnlyCDsAndDownloads() throws {
        let db = try Database(path: ":memory:")
        var cheap = item("cheap", .cd, 5, album: "Two CDs", price: 10, created: 1)
        cheap.purchasedOn = PurchaseDay(year: 2001, month: 1, day: 1)
        try db.saveCollectionItems([
            cheap, item("dear", .cd, 7, album: "Two CDs", price: 20, created: 2),
            item("lp", .vinyl, 5, album: "Only Vinyl", price: 30),
            item("lp2", .vinyl, 8, album: "Both", price: 25), item("cd-both", .cd, album: "Both", price: 12),
            item("dl", .download, album: "Download", price: 7),
        ], at: Date(timeIntervalSince1970: 500))
        let owned = try db.albumPurchases()
        #expect(owned.keys.sorted() == [key("Both"), key("Download"), key("Two CDs")].sorted())
        #expect(owned[key("Two CDs")] == AlbumPurchase(album: "Two CDs", artist: "Artist", purchasedOn: PurchaseDay(year: 2001, month: 1, day: 1),
                                                       price: 10, labelNumber: 5), "the primary copy's own price, never a sum")
        #expect(owned[key("Both")] == AlbumPurchase(album: "Both", artist: "Artist", price: 12), "a record's number never appears")
        #expect(owned[key("Download")]?.format == .digital)
        let labels = try db.query("SELECT label_number FROM album_ownership WHERE label_number IS NOT NULL") { $0.int(0) ?? 0 }
        #expect(labels == [5])
        #expect(try db.query("SELECT updated_at FROM album_ownership WHERE key=?", [.text(key("Two CDs"))]) { $0.double(0) } == [500])

        // Deleting the primary copy hands the row to the next one; deleting the last removes it.
        try db.deleteCollectionItem(id: "cheap")
        #expect(try db.albumPurchases()[key("Two CDs")]?.labelNumber == 7)
        try db.deleteCollectionItem(id: "dear")
        #expect(try db.albumPurchases()[key("Two CDs")] == nil)
        // Changing the medium moves it out of the projection.
        var cd = try #require(try db.collectionItems().items.first { $0.id == "cd-both" })
        cd.medium = .vinyl
        try db.saveCollectionItem(cd)
        #expect(try db.albumPurchases()[key("Both")] == nil)
    }

    /// The exact SELECTs older phones (and Macs) read `album_ownership` with, on a projected library.
    @Test func olderReadersSeeTrueData() throws {
        let db = try Database(path: ":memory:")
        try db.saveCollectionItems([
            item("cd12", .cd, 12, album: "CD Twelve", price: 10), item("v12", .vinyl, 12, album: "Vinyl Twelve", price: 25),
            item("dl", .download, album: "Download", price: 8),
            item("v3", .vinyl, 3, album: "Both", price: 30), item("cd4", .cd, 4, album: "Both", price: 11),
            item("cassette", .download, album: "Tape"),
        ])
        try db.exec("UPDATE collection_items SET medium='cassette' WHERE id='cassette'")
        try db.projectLegacyOwnership(keys: nil)

        // 1.14–1.17
        let v117 = try db.query("SELECT key, album, artist, purchased_on, price FROM album_ownership") { r in
            (r.string(0) ?? "", AlbumPurchase(album: r.string(1) ?? "", artist: r.string(2) ?? "",
                                              purchasedOn: r.string(3).flatMap(PurchaseDay.init(string:)),
                                              price: AlbumPurchase.price(text: r.string(4))))
        }
        #expect(Set(v117.map(\.0)) == [key("CD Twelve"), key("Download"), key("Both")], "no record-only album, nothing of a newer medium")
        #expect(Dictionary(v117, uniquingKeysWith: { a, _ in a })[key("Both")]?.price == 11, "the CD's price, not the record's")

        // 1.18
        let label = try db.columns(of: "album_ownership").contains("label_number") ? "label_number" : "NULL"
        let v118 = try db.query("SELECT key, album, artist, purchased_on, price, \(label) FROM album_ownership") { r in
            (r.string(0) ?? "", AlbumPurchase(album: r.string(1) ?? "", artist: r.string(2) ?? "",
                                              purchasedOn: r.string(3).flatMap(PurchaseDay.init(string:)),
                                              price: AlbumPurchase.price(text: r.string(4)), labelNumber: r.int(5)))
        }
        let labels = Dictionary(v118, uniquingKeysWith: { a, _ in a }).mapValues(\.labelNumber)
        let expected: [String: Int?] = [key("CD Twelve"): 12, key("Download"): Int?.none, key("Both"): 4]
        #expect(labels == expected, "CD labels only; no vinyl numbers")

        // 1.19–1.20
        let columns = try db.columns(of: "album_ownership")
        let format = columns.contains("format") ? "format" : "NULL"
        let v120 = try db.query("SELECT key, album, artist, purchased_on, price, \(label), \(format) FROM album_ownership") { r in
            (r.string(0) ?? "", AlbumPurchase(album: r.string(1) ?? "", artist: r.string(2) ?? "",
                                              format: r.string(6).flatMap(AlbumPurchase.Format.init(rawValue:)) ?? .cd,
                                              purchasedOn: r.string(3).flatMap(PurchaseDay.init(string:)),
                                              price: AlbumPurchase.price(text: r.string(4)), labelNumber: r.int(5)))
        }
        let byKey = Dictionary(v120, uniquingKeysWith: { a, _ in a })
        #expect(byKey[key("CD Twelve")]?.format == .cd && byKey[key("Both")]?.format == .cd && byKey[key("Download")]?.format == .digital)
        #expect(Set(try db.query("SELECT DISTINCT IFNULL(format,'∅') FROM album_ownership") { $0.string(0) ?? "" }) == ["∅", "digital"])
    }

    @Test func olderMacEditsAreTakenInAndItsDeletesUndone() throws {
        let path = try TestSupport.tempDir().appendingPathComponent("library.sqlite").path
        var db: Database? = try Database(path: path)
        try #require(db).saveCollectionItems([item("cd", .cd, 5, album: "Blue", price: 10), item("lp", .vinyl, 2, album: "Red", price: 20)],
                                             at: Date(timeIntervalSince1970: 1000))
        // A 1.17 Mac (after a downgrade) reprices the CD and adds an album; it writes no label or format.
        try #require(db).exec("INSERT OR REPLACE INTO album_ownership(key,album,artist,purchased_on,price,updated_at) VALUES(?,?,?,?,?,?)",
                              [.text(key("Blue")), .text("Blue"), .text("Artist"), .text("2024-05-06"), .text("8"), .double(2000)])
        try #require(db).exec("INSERT OR REPLACE INTO album_ownership(key,album,artist,purchased_on,price,updated_at) VALUES(?,?,?,?,?,?)",
                              [.text(key("New")), .text("New"), .text("Artist"), .null, .text("5"), .double(2100)])
        // A 1.18 Mac reads labels: it sees the CD's, never the record's.
        #expect(try #require(db).albumPurchases()[key("Red")] == nil)
        db = nil
        db = try Database(path: path)
        var items = Dictionary(uniqueKeysWithValues: try #require(db).collectionItems().items.map { ($0.id, $0) })
        #expect(items["cd"]?.price == 8 && items["cd"]?.purchasedOn == PurchaseDay(year: 2024, month: 5, day: 6))
        #expect(items["cd"]?.stickerNumber == 5 && items["cd"]?.updatedAt == Date(timeIntervalSince1970: 2000), "the label stays")
        #expect(items[CollectionItem.legacyID(albumKey: key("New"))]?.price == 5)
        #expect(items["lp"]?.price == 20)
        #expect(try #require(db).albumPurchases()[key("Blue")]?.labelNumber == 5, "the projection writes the label back")

        // Its deletes aren't applied: the next projection writes the row again.
        try #require(db).exec("DELETE FROM album_ownership WHERE key=?", [.text(key("Blue"))])
        db = nil
        db = try Database(path: path)
        items = Dictionary(uniqueKeysWithValues: try #require(db).collectionItems().items.map { ($0.id, $0) })
        #expect(items["cd"] != nil)
        #expect(try #require(db).albumPurchases()[key("Blue")]?.price == 8)
    }

    @Test func malformedRowsAreNulledOrDroppedAndCounted() throws {
        let db = try Database(path: ":memory:")
        let columns = "id,medium,sticker,album,artist,album_key,year,mb_release_id,mb_release_group_id,barcode,catalog_number,record_label,country,format_detail,disc_count,track_count,purchased_on,price,notes,cover_file,digital_source,created_at,updated_at"
        func insert(_ values: [Bind]) throws {
            try db.exec("INSERT INTO collection_items(\(columns)) VALUES(\(values.map { _ in "?" }.joined(separator: ",")))", values)
        }
        func row(id: String, medium: String = "cd", sticker: Int? = 1, album: String = "A", artist: String = "B", key: String = "",
                 release: String? = nil, cover: String? = nil, notes: String? = nil, created: Double = 1) -> [Bind] {
            [.text(id), .text(medium), .int(sticker), .text(album), .text(artist), .text(key), .int(99), .text(release), .text("nope"),
             .text("12ab"), .text(String(repeating: "c", count: 201)), .text(" Blue Note "), .text("US"), .text("CD"), .int(0), .int(1000),
             .text("soon"), .text("-5"), .text(notes), .text(cover), .text("stolen"), .double(created), .double(created)]
        }
        try insert(row(id: "zero", sticker: 0, release: "6a5d8b5e-0000-4000-8000-000000000000", cover: "../x.jpg"))
        try insert(row(id: "huge", sticker: 10_000_000, cover: "/abs.jpg"))
        try insert(row(id: "dl", medium: "download", sticker: 5, cover: "Artist Images/x.jpg"))
        try insert(row(id: "UPPER", medium: "Vinyl", sticker: 7, cover: "upper-0000abcd.jpg", notes: String(repeating: "n", count: 1_000_000)))
        try insert(row(id: "tape", medium: "cassette", sticker: 3))
        try insert(row(id: "inf", created: .infinity))
        try insert(row(id: "bad/id"))
        try insert(row(id: String(repeating: "a", count: 65)))
        try insert(row(id: "nomedium", medium: ""))
        try insert(row(id: "badmedium", medium: "c d!"))
        try insert(row(id: "untitled", album: "  ", artist: ""))

        let read = try db.collectionItems()
        #expect(read.unreadable == 5)
        let items = Dictionary(uniqueKeysWithValues: read.items.map { ($0.id, $0) })
        #expect(items.keys.sorted() == ["dl", "huge", "inf", "tape", "upper", "zero"])
        #expect(items["zero"]?.stickerNumber == nil && items["huge"]?.stickerNumber == nil && items["dl"]?.stickerNumber == nil)
        #expect(items["upper"]?.medium == .vinyl && items["upper"]?.stickerNumber == 7)
        #expect(items["tape"]?.medium == .other("cassette") && items["tape"]?.stickerNumber == nil && items["tape"]?.isEditable == false)
        #expect(items["zero"]?.coverFile == nil && items["huge"]?.coverFile == nil && items["dl"]?.coverFile == nil)
        #expect(items["upper"]?.coverFile == "upper-0000abcd.jpg")
        #expect(items["zero"]?.releaseID == "6a5d8b5e-0000-4000-8000-000000000000" && items["huge"]?.releaseID == nil)
        let z = try #require(items["zero"])
        #expect(z.releaseGroupID == nil && z.year == nil && z.barcode == nil && z.catalogNumber == nil && z.recordLabel == "Blue Note")
        #expect(z.discCount == nil && z.trackCount == nil && z.purchasedOn == nil && z.price == nil && z.digitalSource == nil)
        #expect(z.albumKey == SearchIndex.albumKey(album: "A", artist: "B"), "an empty key is recomputed")
        #expect(items["upper"]?.notes == nil, "a 1 MB notes field reads as none")
        #expect(items["inf"]?.createdAt == Date(timeIntervalSince1970: 0))
        #expect(try db.collectionCoverPaths() == ["Music/Collection Covers/upper-0000abcd.jpg"])
    }

    @Test func columnsAddedLaterReadAsUnknownWhenMissing() throws {
        let path = try TestSupport.tempDir().appendingPathComponent("library.sqlite").path
        do {
            let db = try Database(path: path)
            try db.exec("DROP TABLE collection_items")
            try db.exec("CREATE TABLE collection_items(id TEXT PRIMARY KEY, medium TEXT NOT NULL, album TEXT NOT NULL, artist TEXT NOT NULL, album_key TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
            try db.exec("INSERT INTO collection_items VALUES('a','vinyl','Kind of Blue','Miles Davis','k',1,2)")
        }
        let read = try Database(snapshotAt: path).collectionItems()
        #expect(read.hadTable && read.items.count == 1)
        #expect(read.items[0].medium == .vinyl && read.items[0].stickerNumber == nil && read.items[0].albumKey == "k")
        #expect(read.items[0].updatedAt == Date(timeIntervalSince1970: 2))
    }

    @Test func savingRefusesWhatCantBeEditedHere() throws {
        let db = try Database(path: ":memory:")
        var derived = item("songs-1", .download, album: "A")
        derived.origin = .songs
        #expect(throws: CollectionError.self) { try db.saveCollectionItem(derived) }
        #expect(throws: CollectionError.self) { try db.saveCollectionItem(item("tape", .other("cassette"), album: "A")) }
        #expect(throws: CollectionError.self) { try db.saveCollectionItem(item("Bad ID", .cd, album: "A")) }
        #expect(throws: CollectionError.self) { try db.saveCollectionItem(item("x", .cd, album: "", artist: "")) }
        #expect(try db.collectionItems().items.isEmpty)

        // Duplicates are the editor's call, not the database's.
        try db.saveCollectionItems([item("a", .cd, 12, album: "A"), item("b", .cd, 12, album: "B")])
        #expect(try db.collectionItems().items.count == 2)
        var a = try #require(try db.collectionItems().items.first { $0.id == "a" })
        a.notes = "Signed"
        a.coverFile = "a-0000abcd.jpg"
        try db.saveCollectionItem(a, at: Date(timeIntervalSince1970: 77))
        let saved = try #require(try db.collectionItems().items.first { $0.id == "a" })
        #expect(saved.notes == "Signed" && saved.updatedAt == Date(timeIntervalSince1970: 77) && saved.createdAt == a.createdAt)
        #expect(try db.collectionCoverPaths() == ["Music/Collection Covers/a-0000abcd.jpg"])
    }

    @Test func savesKeepColumnsANewerVersionAdded() throws {
        let db = try Database(path: ":memory:")
        try db.exec("ALTER TABLE collection_items ADD COLUMN shelf TEXT")
        try db.saveCollectionItem(item("a", .cd, 1, album: "A"))
        try db.exec("UPDATE collection_items SET shelf='top' WHERE id='a'")
        var a = try #require(try db.collectionItems().items.first)
        a.price = 3
        try db.saveCollectionItem(a)
        #expect(try db.query("SELECT shelf FROM collection_items WHERE id='a'") { $0.string(0) } == ["top"])
    }

    @Test func rekeyingAndLinkerChangesFollowTheAlbum() throws {
        let db = try Database(path: ":memory:")
        try db.saveCollectionItems([item("cd", .cd, 1, album: "Old"), item("lp", .vinyl, 1, album: "Old")])
        try db.exec("INSERT INTO collection_items(id,medium,album,artist,album_key,created_at,updated_at) VALUES('tape','cassette','Old','Artist',?,0,0)",
                    [.text(key("Old"))])
        try db.rekeyCollection(from: key("Old"), to: key("New"), at: Date(timeIntervalSince1970: 9))
        let items = Dictionary(uniqueKeysWithValues: try db.collectionItems().items.map { ($0.id, $0) })
        #expect(items["cd"]?.albumKey == key("New") && items["lp"]?.albumKey == key("New"))
        #expect(items["cd"]?.album == "Old", "the item keeps its own title")
        #expect(items["tape"]?.albumKey == key("Old"), "items of a newer medium are read-only here")
        #expect(try db.albumPurchases()[key("Old")] == nil && db.albumPurchases()[key("New")]?.labelNumber == 1)

        try db.applyCollectionChanges([CollectionLinker.Change(id: "cd", albumKey: key("Other"), digitalSource: .rip),
                                       CollectionLinker.Change(id: "tape", digitalSource: .rip),
                                       CollectionLinker.Change(id: "missing", year: 2000)], at: Date(timeIntervalSince1970: 10))
        let after = Dictionary(uniqueKeysWithValues: try db.collectionItems().items.map { ($0.id, $0) })
        #expect(after["cd"]?.albumKey == key("Other") && after["cd"]?.digitalSource == .rip && after["cd"]?.updatedAt == Date(timeIntervalSince1970: 10))
        #expect(after["tape"]?.digitalSource == nil)
        #expect(try db.albumPurchases()[key("New")] == nil && db.albumPurchases()[key("Other")] != nil)
    }

    /// The app's ownership views still save through `saveAlbumPurchase` until they move to the collection.
    @Test func savingAnAlbumPurchaseEditsTheCollection() throws {
        let db = try Database(path: ":memory:")
        try db.saveCollectionItem(item("lp", .vinyl, 4, album: "A"))
        try db.saveAlbumPurchase(key: key("A"), AlbumPurchase(album: "A", artist: "Artist", price: 9, labelNumber: 3))
        var cds = try db.collectionItems().items.filter { $0.medium == .cd }
        #expect(cds.count == 1 && cds[0].stickerNumber == 3 && cds[0].price == 9 && cds[0].id == CollectionItem.legacyID(albumKey: key("A")))
        try db.saveAlbumPurchase(key: key("A"), AlbumPurchase(album: "A", artist: "Artist", format: .digital, price: 9))
        cds = try db.collectionItems().items.filter { $0.albumKey == key("A") && $0.medium != .vinyl }
        #expect(cds.count == 1 && cds[0].medium == .download && cds[0].stickerNumber == nil)
        try db.saveAlbumPurchase(key: key("A"), nil)
        #expect(try db.collectionItems().items.map(\.id) == ["lp"], "records are kept")
        #expect(try db.albumPurchases().isEmpty)
    }
}
