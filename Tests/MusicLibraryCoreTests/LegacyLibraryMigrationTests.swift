import Foundation
import SQLite3
import Testing
@testable import MusicLibraryCore

/// Libraries made by the released code of each version (1.14–1.20: their own `Database`, `migrate()` and API; see
/// `Fixtures/legacy-libraries`) opened by this one. Nothing anyone filed may be lost or changed: every table's rows
/// are compared raw, before and after, and the collection made from `album_ownership` is checked row by row.
@Suite struct LegacyLibraryMigrationTests {
    /// What each fixture was made to hold (labels from 1.18, formats and song purchases from 1.19).
    struct Fixture: Sendable, CustomTestStringConvertible {
        struct Songs: Sendable {
            var album: String
            var artist: String
            var price: Decimal?
            var day: String
            var songs: Int
            /// The album is also owned as a stored CD.
            var nextToCD: Bool
        }

        var version: String
        var ownership: Int
        /// (album, artist) of the albums sharing label 7.
        var duplicateSeven: [(String, String)] = []
        /// (album, artist) of an owned album with no tracks; its label, when the version had labels.
        var orphan: (String, String)
        var orphanLabel: Int?
        /// (album, artist) of an owned album the version could tell was a download.
        var download: (String, String)?
        /// (album, artist) of a CD owned without a label, in versions with labels.
        var unlabeled: (String, String)?
        var songs: [Songs] = []
        /// Tables the version had (beyond those every version has).
        var tables: Set<String>

        var testDescription: String { version }
        var hasLabels: Bool { orphanLabel != nil }
    }

    static let baseTables: Set<String> = [
        "tracks", "playlists", "playlist_tracks", "smart_playlists", "plays", "artist_info", "album_info", "catalog_info",
        "catalog_items", "catalog_previews", "album_ownership", "liked_tracks", "artist_photos", "library_meta", "sync_events",
    ]

    static let fixtures: [Fixture] = [
        Fixture(version: "v1.14.0", ownership: 9, orphan: ("Time Out", "The Dave Brubeck Quartet"), tables: baseTables),
        Fixture(version: "v1.15.0", ownership: 6, orphan: ("Abbey Road", "The Beatles"), tables: baseTables),
        Fixture(version: "v1.16.0", ownership: 9, orphan: ("Blue Train", "John Coltrane"), tables: baseTables),
        Fixture(version: "v1.17.0", ownership: 9, orphan: ("The Dark Side of the Moon", "Pink Floyd"),
                tables: baseTables.union(["rip_checks"])),
        Fixture(version: "v1.18.0", ownership: 9, duplicateSeven: [("Jazz Moods", "Various Artists"), ("OK Computer", "Radiohead")],
                orphan: ("Monk's Dream", "Thelonious Monk"), orphanLabel: 9, unlabeled: ("Homogenic", "Björk"),
                tables: baseTables.union(["rip_checks"])),
        Fixture(version: "v1.19.0", ownership: 9, duplicateSeven: [("OK Computer", "Radiohead"), ("Homogenic", "Björk")],
                orphan: ("Abbey Road", "The Beatles"), orphanLabel: 9, download: ("Discovery", "Daft Punk"),
                unlabeled: ("Pastel Blues", "Nina Simone"),
                songs: [Fixture.Songs(album: "OK Computer", artist: "Radiohead", price: Decimal(string: "2.58"), day: "2018-01-01", songs: 2, nextToCD: true),
                        Fixture.Songs(album: "Mezzanine", artist: "Massive Attack", price: 2, day: "2022-02-02", songs: 3, nextToCD: false)],
                tables: baseTables.union(["rip_checks", "track_purchases"])),
        Fixture(version: "v1.20.0", ownership: 9, duplicateSeven: [("Abbey Road", "The Beatles"), ("Rumours", "Fleetwood Mac")],
                orphan: ("Hounds of Love", "Kate Bush"), orphanLabel: 9, download: ("In Rainbows", "Radiohead"),
                unlabeled: ("OK Computer", "Radiohead"),
                songs: [Fixture.Songs(album: "Time Out", artist: "The Dave Brubeck Quartet", price: Decimal(string: "1.29"), day: "2012-06-01",
                                      songs: 2, nextToCD: true),
                        Fixture.Songs(album: "Blue Train", artist: "John Coltrane", price: Decimal(string: "2.99"), day: "2023-11-01",
                                      songs: 2, nextToCD: false)],
                tables: baseTables.union(["rip_checks", "track_purchases"])),
    ]

    /// Columns migration may add to a table that existed, and what every pre-existing row must hold in them. Nothing
    /// else may differ. Both are the ones 1.18 and 1.19 themselves added on open (`ALTER TABLE … ADD COLUMN`), and
    /// NULL is what those versions read as "no label" and "a CD", exactly what the older rows meant.
    static let allowedNewColumns: [String: Set<String>] = ["album_ownership": ["label_number", "format"]]

    // MARK: Raw reading (plain SQLite, independent of `Database`)

    enum Value: Hashable, CustomStringConvertible {
        case null, int(Int64), real(UInt64), text(String), blob(Data)

        var description: String {
            switch self {
            case .null: "NULL"
            case .int(let v): "\(v)"
            case .real(let bits): "\(Double(bitPattern: bits))r"
            case .text(let s): "'\(s.replacingOccurrences(of: "\u{1}", with: "\\x01"))'"
            case .blob(let d): "x'\(d.map { String(format: "%02x", $0) }.joined())'"
            }
        }
        var text: String? { if case .text(let s) = self { s } else { nil } }
        var int: Int64? { if case .int(let v) = self { v } else { nil } }
        var double: Double? {
            switch self {
            case .real(let b): Double(bitPattern: b)
            case .int(let v): Double(v)
            default: nil
            }
        }
    }

    struct Table: Equatable {
        var columns: [String]
        /// Rows by rowid, every column (rowid is stable unless a row is deleted or replaced).
        var rows: [Int64: [Value]]

        func row(_ rowid: Int64) -> [String: Value] { Dictionary(uniqueKeysWithValues: zip(columns, rows[rowid] ?? [])) }
        var namedRows: [[String: Value]] { rows.keys.sorted().map(row) }
    }

    struct Dump: Equatable {
        var userVersion: Int64
        var tables: [String: Table]
        /// Index and trigger definitions by name.
        var schema: [String: String]
    }

    static func dump(_ path: String) throws -> Dump {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        func rows(_ sql: String) throws -> [[Value]] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DatabaseError.sql(message: String(cString: sqlite3_errmsg(db)), statement: sql)
            }
            defer { sqlite3_finalize(stmt) }
            var out: [[Value]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append((0..<sqlite3_column_count(stmt)).map { i in
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: .real(sqlite3_column_double(stmt, i).bitPattern)
                    case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(stmt, i)))
                    case SQLITE_BLOB: .blob(Data(bytes: sqlite3_column_blob(stmt, i), count: Int(sqlite3_column_bytes(stmt, i))))
                    default: .null
                    }
                })
            }
            return out
        }
        let version = try rows("PRAGMA user_version").first?.first?.int ?? 0
        var tables: [String: Table] = [:]
        for name in try rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").compactMap({ $0[0].text }) {
            let columns = try rows("SELECT name FROM pragma_table_info('\(name)') ORDER BY cid").compactMap { $0[0].text }
            var byRowid: [Int64: [Value]] = [:]
            for r in try rows("SELECT rowid, * FROM \"\(name)\"") { byRowid[r[0].int!] = Array(r.dropFirst()) }
            tables[name] = Table(columns: columns, rows: byRowid)
        }
        var schema: [String: String] = [:]
        for r in try rows("SELECT name, IFNULL(sql,'') FROM sqlite_master WHERE type IN ('index','trigger')") {
            schema[r[0].text ?? ""] = r[1].text
        }
        return Dump(userVersion: version, tables: tables, schema: schema)
    }

    /// A copy of the fixture as `<dir>/library.sqlite`.
    static func copy(_ fixture: Fixture) throws -> URL {
        let source = try #require(Bundle.module.url(forResource: fixture.version, withExtension: "sqlite",
                                                    subdirectory: "Fixtures/legacy-libraries"))
        let dir = try TestSupport.tempDir()
        let path = LibraryLocation.databaseURL(root: dir)
        try FileManager.default.copyItem(at: source, to: path)
        return path
    }

    /// Opens the library with this version (the migration runs) and closes it again.
    static func openAndClose(_ path: URL) throws {
        _ = try Database(path: path.path)
    }

    // MARK: Readers of earlier versions (the exact SELECTs, as in `CollectionStoreTests.olderReadersSeeTrueData`)

    static func read117(_ db: Database) throws -> [String: AlbumPurchase] {
        let rows = try db.query("SELECT key, album, artist, purchased_on, price FROM album_ownership") { r in
            (r.string(0) ?? "", AlbumPurchase(album: r.string(1) ?? "", artist: r.string(2) ?? "",
                                              purchasedOn: r.string(3).flatMap(PurchaseDay.init(string:)),
                                              price: AlbumPurchase.price(text: r.string(4))))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    static func read118(_ db: Database) throws -> [String: AlbumPurchase] {
        let label = try db.columns(of: "album_ownership").contains("label_number") ? "label_number" : "NULL"
        let rows = try db.query("SELECT key, album, artist, purchased_on, price, \(label) FROM album_ownership") { r in
            (r.string(0) ?? "", AlbumPurchase(album: r.string(1) ?? "", artist: r.string(2) ?? "",
                                              purchasedOn: r.string(3).flatMap(PurchaseDay.init(string:)),
                                              price: AlbumPurchase.price(text: r.string(4)), labelNumber: r.int(5)))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    static func read120(_ db: Database) throws -> [String: AlbumPurchase] {
        let columns = try db.columns(of: "album_ownership")
        let label = columns.contains("label_number") ? "label_number" : "NULL"
        let format = columns.contains("format") ? "format" : "NULL"
        let rows = try db.query("SELECT key, album, artist, purchased_on, price, \(label), \(format) FROM album_ownership") { r in
            (r.string(0) ?? "", AlbumPurchase(album: r.string(1) ?? "", artist: r.string(2) ?? "",
                                              format: r.string(6).flatMap(AlbumPurchase.Format.init(rawValue:)) ?? .cd,
                                              purchasedOn: r.string(3).flatMap(PurchaseDay.init(string:)),
                                              price: AlbumPurchase.price(text: r.string(4)), labelNumber: r.int(5)))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    static func key(_ pair: (String, String)) -> String { SearchIndex.albumKey(album: pair.0, artist: pair.1) }

    // MARK: Tests

    /// Every row of every table that existed is the same after the migration, column by column and by rowid (so no
    /// row was deleted or rewritten either); the only additions are the allow-listed columns, NULL in every old row,
    /// and tables this version creates.
    @Test(arguments: fixtures)
    func everyFiledRowSurvivesUnchanged(_ fixture: Fixture) throws {
        let path = try Self.copy(fixture)
        let before = try Self.dump(path.path)
        #expect(before.userVersion == 14)
        #expect(Set(before.tables.keys) == fixture.tables, "the fixture holds the tables \(fixture.version) made")
        #expect(before.tables["album_ownership"]?.rows.count == fixture.ownership)

        try Self.openAndClose(path)
        let after = try Self.dump(path.path)
        #expect(after.userVersion == 14, "no schema version change: older phones refuse a newer schema")

        for (name, old) in before.tables.sorted(by: { $0.key < $1.key }) {
            guard let new = try? #require(after.tables[name], "table \(name) is kept") else { continue }
            #expect(Array(new.columns.prefix(old.columns.count)) == old.columns, "\(name) keeps its columns in order")
            let added = Set(new.columns.dropFirst(old.columns.count))
            #expect(added.isSubset(of: Self.allowedNewColumns[name] ?? []), "\(name) gained \(added)")
            #expect(Set(new.rows.keys) == Set(old.rows.keys), "\(name): no row deleted, replaced or added")
            for (rowid, values) in old.rows.sorted(by: { $0.key < $1.key }) {
                guard let newValues = new.rows[rowid] else { continue }
                #expect(Array(newValues.prefix(values.count)) == values, "\(name) row \(rowid) is byte-identical")
                #expect(newValues.dropFirst(values.count).allSatisfy { $0 == .null }, "\(name) row \(rowid): added columns are NULL")
            }
        }
        // Indexes and triggers that existed are kept as they were.
        for (name, sql) in before.schema { #expect(after.schema[name] == sql, "index \(name)") }
        let created = Set(after.tables.keys).subtracting(before.tables.keys)
        #expect(created.isSubset(of: ["collection_items", "rip_checks", "track_purchases"]), "created \(created)")
        #expect(after.tables["collection_items"] != nil)
        // Tables made now start empty, apart from the collection.
        for name in created where name != "collection_items" { #expect(after.tables[name]?.rows.isEmpty == true, "\(name)") }
    }

    /// Each `album_ownership` row became exactly one CD or download with the row's own values and the deterministic
    /// legacy id; labels (duplicates and orphans included) survive; songs bought make derived downloads.
    @Test(arguments: fixtures)
    func ownershipBecomesTheCollection(_ fixture: Fixture) throws {
        let path = try Self.copy(fixture)
        let before = try Self.dump(path.path)
        let db = try Database(path: path.path)
        let read = try db.collectionItems()
        #expect(read.hadTable && read.unreadable == 0)
        let items = read.items
        let rows = try #require(before.tables["album_ownership"]).namedRows
        #expect(items.count == rows.count, "one item per album_ownership row, nothing else")
        #expect(Set(items.map(\.id)).count == items.count)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        let stored = try #require(try Self.dump(path.path).tables["collection_items"])
        let storedByID = Dictionary(uniqueKeysWithValues: stored.namedRows.map { ($0["id"]?.text ?? "", $0) })

        for row in rows {
            let key = try #require(row["key"]?.text)
            let album = row["album"]?.text, artist = row["artist"]?.text
            #expect(key == SearchIndex.albumKey(album: album ?? "", artist: artist ?? ""), "fixture keys are the app's")
            let id = CollectionItem.legacyID(albumKey: key)
            guard let item = try? #require(byID[id], "\(album ?? "?"): an item with the legacy id") else { continue }
            let digital = row["format"]?.text == "digital"
            #expect(item.medium == (digital ? .download : .cd), "\(album ?? ""): NULL format is a CD, 'digital' a download")
            #expect(item.origin == .stored && item.isEditable)
            #expect(item.album == album && item.artist == artist && item.albumKey == key)
            #expect(item.stickerNumber == row["label_number"]?.int.map(Int.init), "\(album ?? ""): the label number")
            #expect(item.purchasedOn?.string == row["purchased_on"]?.text, "\(album ?? ""): the purchase day")
            #expect(AlbumPurchase.priceText(item.price) == row["price"]?.text, "\(album ?? ""): the price text")
            let updated = try #require(row["updated_at"]?.double)
            #expect(item.createdAt == Date(timeIntervalSince1970: updated) && item.updatedAt == Date(timeIntervalSince1970: updated))
            #expect(item.digitalSource == nil && item.releaseID == nil && item.notes == nil && item.coverFile == nil)

            // As stored: the same bytes as the row.
            let s = try #require(storedByID[id])
            #expect(s["album"] == row["album"] && s["artist"] == row["artist"] && s["album_key"] == row["key"])
            #expect(s["purchased_on"] == row["purchased_on"] && s["price"] == row["price"])
            #expect(s["sticker"] == (row["label_number"] ?? .null))
            #expect(s["medium"] == .text(digital ? "download" : "cd"))
            #expect(s["created_at"] == row["updated_at"] && s["updated_at"] == row["updated_at"])
        }

        // The cases each fixture was made to hold.
        let byKey = Dictionary(grouping: items, by: \.albumKey)
        if fixture.hasLabels {
            #expect(fixture.duplicateSeven.count == 2)
            for pair in fixture.duplicateSeven {
                #expect(byKey[Self.key(pair)]?.map(\.stickerNumber) == [7], "\(pair.0) keeps label 7")
            }
            let collection = MusicCollection(items: items, songPurchases: [:], tracks: [])
            #expect(collection.duplicates(in: .cd)[7]?.count == 2, "both CDs labeled 7 are kept, as a duplicate")
            if let unlabeled = fixture.unlabeled {
                #expect(byKey[Self.key(unlabeled)]?.map(\.stickerNumber) == [nil] && byKey[Self.key(unlabeled)]?.first?.medium == .cd)
            }
        } else {
            #expect(items.allSatisfy { $0.medium == .cd && $0.stickerNumber == nil }, "before 1.18 nothing had a label or a format")
        }
        let tracks = try db.fetchAllTracks()
        let trackKeys = Set(tracks.map { SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist) })
        let orphanKey = Self.key(fixture.orphan)
        #expect(!trackKeys.contains(orphanKey), "the orphan has no tracks")
        #expect(byKey[orphanKey]?.count == 1 && byKey[orphanKey]?.first?.stickerNumber == fixture.orphanLabel,
                "an album owned without tracks survives with its label")
        if let download = fixture.download {
            #expect(byKey[Self.key(download)]?.map(\.medium) == [.download] && byKey[Self.key(download)]?.first?.stickerNumber == nil)
        }

        // Songs bought on their own: a derived download per album, the songs' prices summed, next to a CD too.
        let songPurchases = try db.trackPurchases()
        #expect(songPurchases.count == fixture.songs.reduce(0) { $0 + $1.songs })
        let collection = MusicCollection(items: items, songPurchases: songPurchases, tracks: tracks)
        let derived = collection.items.filter { $0.origin == .songs }
        #expect(derived.count == fixture.songs.count)
        for songs in fixture.songs {
            let key = SearchIndex.albumKey(album: songs.album, artist: songs.artist)
            let d = try #require(derived.first { $0.albumKey == key }, "\(songs.album): a download made of its songs")
            #expect(d.id == CollectionItem.songsID(albumKey: key) && d.medium == .download && !d.isEditable)
            #expect(d.price == songs.price && d.purchasedOn?.string == songs.day)
            #expect(collection.items.contains { $0.origin == .stored && $0.albumKey == key && $0.medium == .cd } == songs.nextToCD)
        }
        #expect(try db.collectionItems().items.allSatisfy { $0.origin == .stored }, "derived downloads are never stored")
    }

    /// Reopening (a second migration) changes nothing anywhere, the collection included.
    @Test(arguments: fixtures)
    func reopeningChangesNothing(_ fixture: Fixture) throws {
        let path = try Self.copy(fixture)
        try Self.openAndClose(path)
        let first = try Self.dump(path.path)
        let items = try Database(path: path.path).collectionItems().items
        let second = try Self.dump(path.path)
        try Self.openAndClose(path)
        let third = try Self.dump(path.path)
        #expect(first.userVersion == 14 && second.userVersion == 14 && third.userVersion == 14)
        #expect(second == first)
        #expect(third == first)
        #expect(try Database(path: path.path).collectionItems().items == items)
    }

    /// What 1.14–1.17, 1.18 and 1.19–1.20 read from `album_ownership` (synced or exported copies, a downgraded Mac) is
    /// the same after the migration as before.
    @Test(arguments: fixtures)
    func olderReadersSeeTheSameOwnership(_ fixture: Fixture) throws {
        let path = try Self.copy(fixture)
        let old = try Database(snapshotAt: path.path)
        let before = (try Self.read117(old), try Self.read118(old), try Self.read120(old))
        #expect(before.0.count == fixture.ownership)
        let db = try Database(path: path.path)
        #expect(try Self.read117(db) == before.0, "1.14–1.17")
        #expect(try Self.read118(db) == before.1, "1.18")
        #expect(try Self.read120(db) == before.2, "1.19–1.20")
        #expect(try db.albumPurchases() == before.2)
    }

    /// A phone reading an older Mac's copy as it is (no migration, read-only) sees the same collection, with the same
    /// ids, as the Mac after migrating, and the same owned albums as before the collection.
    @Test(arguments: fixtures)
    func phoneReadingAnOlderCopyAgreesWithTheMac(_ fixture: Fixture) throws {
        let path = try Self.copy(fixture)
        let root = path.deletingLastPathComponent()
        let untouched = try Self.dump(path.path)

        // What 1.20 showed as owned: `albumPurchases()` plus downloads made of bought songs.
        let old = try Database(snapshotAt: path.path)
        let tracks = try old.fetchAllTracks()
        let songs = try old.trackPurchases()
        let legacy = AlbumPurchase.including(songs: songs, tracks: tracks, in: try old.albumPurchases())

        let phone = try LibrarySnapshot(root: root, isPresent: { _ in false })
        #expect(try Self.dump(path.path) == untouched, "reading a snapshot writes nothing")
        #expect(phone.labelUnreadable == 0)
        #expect(phone.purchases == legacy, "legacyPurchases equals the old albumPurchases() + including")

        let macCopy = try TestSupport.tempDir()
        try FileManager.default.copyItem(at: path, to: LibraryLocation.databaseURL(root: macCopy))
        let mac = try Database(path: LibraryLocation.databaseURL(root: macCopy).path)
        let macItems = try mac.collectionItems().items
        let macCollection = MusicCollection(items: macItems, songPurchases: try mac.trackPurchases(), tracks: try mac.fetchAllTracks())
        #expect(phone.collection.items.map(\.id) == macCollection.items.map(\.id))
        #expect(phone.collection.items == macCollection.items, "the same items, ids and values")
        #expect(macCollection.legacyPurchases == legacy)

        // And reading the migrated copy (a sync or export from this version) agrees too.
        let synced = try LibrarySnapshot(root: macCopy, isPresent: { _ in false })
        #expect(synced.collection.items == macCollection.items)
        #expect(synced.purchases == legacy)
    }
}

/// A library this version migrated, then edited by an older Mac (a downgrade, or a second Mac sharing the library) and
/// opened by this version again: what the older Mac filed is what the collection holds. The older Macs' writes are
/// the exact statements their `saveAlbumPurchase` runs, on a plain SQLite connection.
@Suite struct DowngradeRoundTripTests {
    enum OlderMac: String, CaseIterable, Sendable {
        case v117 = "1.14–1.17", v118 = "1.18", v120 = "1.19–1.20"

        func save(_ path: URL, key: String, _ p: AlbumPurchase?, at time: Double) throws {
            let price = AlbumPurchase.priceText(p?.price), day = p?.purchasedOn?.string
            guard let p else { return try Self.exec(path, "DELETE FROM album_ownership WHERE key=?", [.text(key)]) }
            switch self {
            case .v117:
                try Self.exec(path, "INSERT OR REPLACE INTO album_ownership(key,album,artist,purchased_on,price,updated_at) VALUES(?,?,?,?,?,?)",
                              [.text(key), .text(p.album), .text(p.artist), .text(day), .text(price), .double(time)])
            case .v118:
                try Self.exec(path, "INSERT OR REPLACE INTO album_ownership(key,album,artist,purchased_on,price,label_number,updated_at) VALUES(?,?,?,?,?,?,?)",
                              [.text(key), .text(p.album), .text(p.artist), .text(day), .text(price), .int(p.labelNumber), .double(time)])
            case .v120:
                try Self.exec(path, "INSERT OR REPLACE INTO album_ownership(key,album,artist,format,purchased_on,price,label_number,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                              [.text(key), .text(p.album), .text(p.artist), .text(p.format == .cd ? nil : p.format.rawValue), .text(day),
                               .text(price), .int(p.labelNumber), .double(time)])
            }
        }

        static func exec(_ path: URL, _ sql: String, _ binds: [Bind]) throws {
            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            guard sqlite3_open(path.path, &db) == SQLITE_OK, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.sql(message: String(cString: sqlite3_errmsg(db)), statement: sql)
            }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, b) in binds.enumerated() {
                switch b {
                case .null: sqlite3_bind_null(stmt, Int32(i + 1))
                case .int(let v): sqlite3_bind_int64(stmt, Int32(i + 1), v)
                case .double(let v): sqlite3_bind_double(stmt, Int32(i + 1), v)
                case .text(let v): sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient)
                }
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.sql(message: String(cString: sqlite3_errmsg(db)), statement: sql) }
        }
    }

    static let fixture = LegacyLibraryMigrationTests.fixtures.first { $0.version == "v1.20.0" }!
    static func key(_ pair: (String, String)) -> String { LegacyLibraryMigrationTests.key(pair) }
    /// "Hounds of Love", owned without tracks, label 9; "In Rainbows", a download; "OK Computer", a CD without a label.
    static let labeled = key(fixture.orphan), download = key(fixture.download!), unlabeled = key(fixture.unlabeled!)

    /// A copy of the 1.20 library, migrated by this version.
    static func migrated() throws -> URL {
        let path = try LegacyLibraryMigrationTests.copy(fixture)
        try LegacyLibraryMigrationTests.openAndClose(path)
        return path
    }

    static func primary(_ db: Database, _ key: String) throws -> CollectionItem? {
        CollectionLegacy.primary(try db.collectionItems().items, albumKey: key)
    }

    /// The row an older Mac starts from: what it reads (its own `albumPurchases`) for the key.
    static func owned(_ path: URL, _ key: String) throws -> AlbumPurchase {
        try #require(try LegacyLibraryMigrationTests.read120(Database(snapshotAt: path.path))[key])
    }

    /// Reopening with this version: the phone, reading the edited copy in memory, agrees with the Mac, and a second
    /// open changes nothing.
    static func reopen(_ path: URL) throws -> Database {
        let phone = try LibrarySnapshot(root: path.deletingLastPathComponent(), isPresent: { _ in false })
        try LegacyLibraryMigrationTests.openAndClose(path)
        let first = try LegacyLibraryMigrationTests.dump(path.path)
        let db = try Database(path: path.path)
        #expect(try LegacyLibraryMigrationTests.dump(path.path) == first, "a second open changes nothing")
        let mac = MusicCollection(items: try db.collectionItems().items, songPurchases: try db.trackPurchases(), tracks: try db.fetchAllTracks())
        #expect(phone.collection.items == mac.items, "the phone agrees")
        return db
    }

    @Test func aLabelClearedOnAnOlderMacStaysCleared() throws {
        for mac in [OlderMac.v118, .v120] {
            let path = try Self.migrated()
            var p = try Self.owned(path, Self.labeled)
            #expect(p.labelNumber == 9)
            p.labelNumber = nil
            try mac.save(path, key: Self.labeled, p, at: 2_000_000_000)
            let db = try Self.reopen(path)
            #expect(try Self.primary(db, Self.labeled)?.stickerNumber == nil, "\(mac.rawValue)")
            #expect(try db.albumPurchases()[Self.labeled]?.labelNumber == nil, "\(mac.rawValue)")
        }
    }

    @Test func aDownloadMadeACDOnAnOlderMacStaysACD() throws {
        let path = try Self.migrated()
        var p = try Self.owned(path, Self.download)
        #expect(p.format == .digital)
        p.format = .cd
        try OlderMac.v120.save(path, key: Self.download, p, at: 2_000_000_000)
        let db = try Self.reopen(path)
        #expect(try Self.primary(db, Self.download)?.medium == .cd)
        #expect(try db.albumPurchases()[Self.download]?.format == .cd)
    }

    /// 1.20 makes you clear a number before it's given to another CD: the cleared one doesn't come back as a duplicate.
    @Test func aLabelMovedOnAnOlderMacIsNotDuplicated() throws {
        let path = try Self.migrated()
        var from = try Self.owned(path, Self.labeled), to = try Self.owned(path, Self.unlabeled)
        #expect(to.labelNumber == nil)
        from.labelNumber = nil
        to.labelNumber = 9
        try OlderMac.v120.save(path, key: Self.labeled, from, at: 2_000_000_000)
        try OlderMac.v120.save(path, key: Self.unlabeled, to, at: 2_000_000_001)
        let db = try Self.reopen(path)
        #expect(try Self.primary(db, Self.labeled)?.stickerNumber == nil && Self.primary(db, Self.unlabeled)?.stickerNumber == 9)
        let collection = MusicCollection(items: try db.collectionItems().items, songPurchases: [:], tracks: [])
        #expect(collection.duplicates(in: .cd)[9] == nil)
        #expect(try db.albumPurchases().values.filter { $0.labelNumber == 9 }.count == 1)
    }

    /// Apps that never wrote a column can't clear it: their edits keep the label, and a download stays one.
    @Test func editsFromAppsThatDontWriteAColumnKeepIt() throws {
        for mac in [OlderMac.v117, .v118] {
            let path = try Self.migrated()
            var cd = try Self.owned(path, Self.labeled), dl = try Self.owned(path, Self.download)
            cd.price = 3
            dl.price = 4
            dl.format = .cd  // what an app before 1.19 thinks every album is
            if mac == .v117 { cd.labelNumber = nil }  // it reads no labels
            try mac.save(path, key: Self.labeled, cd, at: 2_000_000_000)
            try mac.save(path, key: Self.download, dl, at: 2_000_000_000)
            // What older readers see meanwhile is what that app wrote: no stand-in values.
            let old = try Database(snapshotAt: path.path)
            #expect(try LegacyLibraryMigrationTests.read118(old)[Self.labeled]?.labelNumber == (mac == .v117 ? nil : 9))
            #expect(try LegacyLibraryMigrationTests.read120(old)[Self.download]?.format == .cd)

            let db = try Self.reopen(path)
            let c = try #require(try Self.primary(db, Self.labeled)), d = try #require(try Self.primary(db, Self.download))
            #expect(c.price == 3 && c.stickerNumber == 9, "\(mac.rawValue)")
            #expect(d.price == 4 && d.medium == .download, "\(mac.rawValue)")
            #expect(c.updatedAt == Date(timeIntervalSince1970: 2_000_000_000))
            #expect(try db.albumPurchases()[Self.download]?.format == .digital)
            #expect(Set(try db.query("SELECT DISTINCT IFNULL(format,'∅') FROM album_ownership") { $0.string(0) ?? "" }).isSubset(of: ["∅", "digital"]))
        }
    }

    /// The copy's time came from a device whose clock is ahead: an older Mac's later edit, with an earlier time, is
    /// still taken in.
    @Test func anOlderMacsEditWithAnEarlierClockIsTakenIn() throws {
        let path = try Self.migrated()
        do {
            let db = try Database(path: path.path)
            var item = try #require(try Self.primary(db, Self.labeled))
            item.price = 50
            try db.saveCollectionItem(item, at: Date(timeIntervalSince1970: 3_000_000_000))
        }
        var p = try Self.owned(path, Self.labeled)
        p.price = 5
        try OlderMac.v120.save(path, key: Self.labeled, p, at: 2_000_000_000)
        let db = try Self.reopen(path)
        #expect(try Self.primary(db, Self.labeled)?.price == 5)
    }

    /// Marking the table keeps every row (and rowid), and a version that never wrote it (no table yet) reads the same.
    @Test func markingKeepsTheRowsAndOnlyOnce() throws {
        let path = try LegacyLibraryMigrationTests.copy(Self.fixture)
        let before = try #require(try LegacyLibraryMigrationTests.dump(path.path).tables["album_ownership"])
        try LegacyLibraryMigrationTests.openAndClose(path)
        let db = try Database(path: path.path)
        #expect(try db.hasLegacyWriterMarks())
        let after = try #require(try LegacyLibraryMigrationTests.dump(path.path).tables["album_ownership"])
        #expect(after == before)
        #expect(try db.legacyOwnershipRows().allSatisfy { $0.writer == .current })
        let unmarked = try Database(snapshotAt: try LegacyLibraryMigrationTests.copy(Self.fixture).path)
        #expect(try unmarked.legacyOwnershipRows().allSatisfy { $0.writer == .unknown })
    }

    /// An owned album with neither an album nor an artist tag keeps its empty title: nothing is made up.
    @Test func anUntitledOwnedAlbumKeepsItsEmptyTitle() throws {
        let path = try LegacyLibraryMigrationTests.copy(Self.fixture)
        let blank = SearchIndex.albumKey(album: "", artist: "")
        try OlderMac.v120.save(path, key: blank, AlbumPurchase(album: "", artist: "", purchasedOn: PurchaseDay(year: 2020, month: 1, day: 2),
                                                               price: Decimal(string: "9.99"), labelNumber: 11), at: 1_600_000_000)
        let before = try #require(try LegacyLibraryMigrationTests.dump(path.path).tables["album_ownership"])
        let phone = try LibrarySnapshot(root: path.deletingLastPathComponent(), isPresent: { _ in false })
        try LegacyLibraryMigrationTests.openAndClose(path)
        #expect(try LegacyLibraryMigrationTests.dump(path.path).tables["album_ownership"] == before, "the row is unchanged")
        let db = try Self.reopen(path)
        let item = try #require(try Self.primary(db, blank))
        #expect(item.id == CollectionItem.legacyID(albumKey: blank) && item.album.isEmpty && item.artist.isEmpty && item.stickerNumber == 11)
        #expect(phone.collection.items.first { $0.albumKey == blank } == item)
        // It can still be edited.
        var edited = item
        edited.price = 5
        try db.saveCollectionItem(edited)
        #expect(try Self.primary(db, blank)?.price == 5 && db.albumPurchases()[blank]?.album == "")
    }
}
