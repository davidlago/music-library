import Foundation
import MusicLibraryGlance
import SQLite3
import Testing
@testable import MusicLibraryCore

/// A rehearsal of the collection migration on a COPY of a real library (`LegacyLibraryMigrationTests` does the same on
/// the committed fixtures). Opt-in: set `MUSICLIB_MIGRATION_REHEARSAL` to the path of a `library.sqlite` copy. The copy
/// is migrated in place (so it can then be opened by an older version, and migrated again); a path under `~/Music`
/// is refused. Only counts are printed, never titles or prices.
///
///     MUSICLIB_MIGRATION_REHEARSAL=/tmp/copy/library.sqlite swift test --filter MigrationRehearsalTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MUSICLIB_MIGRATION_REHEARSAL"] != nil))
struct MigrationRehearsalTests {
    typealias Legacy = LegacyLibraryMigrationTests

    /// The copy to migrate, or nil (with an issue recorded) when it's missing or under `~/Music`.
    static func target() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["MUSICLIB_MIGRATION_REHEARSAL"], !raw.isEmpty else { return nil }
        func real(_ path: String) -> String? {
            guard let p = realpath((path as NSString).expandingTildeInPath, nil) else { return nil }
            defer { free(p) }
            return String(cString: p)
        }
        guard let path = real(raw) else {
            Issue.record("MUSICLIB_MIGRATION_REHEARSAL: no file at the path given")
            return nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let music = real(home + "/Music") ?? (home + "/Music")
        for forbidden in Set([music, home + "/Music"]) where path == forbidden || path.hasPrefix(forbidden + "/") {
            Issue.record("Refusing to rehearse on a library under ~/Music: make a copy elsewhere (SQLite backup API) and pass that")
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// A copy of the database (and its WAL, if any) as `<new dir>/library.sqlite`, as it is now.
    static func snapshotCopy(of path: URL) throws -> URL {
        let dir = try TestSupport.tempDir()
        let dest = LibraryLocation.databaseURL(root: dir)
        try FileManager.default.copyItem(at: path, to: dest)
        let wal = URL(fileURLWithPath: path.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            try FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: dest.path + "-wal"))
        }
        return dest
    }

    /// `snapshotCopy`, in rollback-journal mode: a read-only connection can't open a WAL database without its `-shm`
    /// file (which closing the last connection deletes), and the released readers open copies read-only. Only the
    /// header's journal-mode bytes change; every row, index and the user version stay as they were.
    static func readableCopy(of path: URL) throws -> URL {
        let dest = try snapshotCopy(of: path)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(dest.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        return dest
    }

    /// The raw rows of the database at `path` as they are now (read from a `readableCopy`).
    static func dump(_ path: URL) throws -> Legacy.Dump { try Legacy.dump(readableCopy(of: path).path) }

    @Test func rehearseTheMigration() throws {
        guard let path = Self.target() else { return }
        let now = Date()
        let calendar = Calendar.current
        var log: [String] = []

        // Before: raw rows, and what the released version read (from an untouched copy, read-only).
        let untouchedPath = try Self.readableCopy(of: path)
        let untouchedRoot = untouchedPath.deletingLastPathComponent()
        let before = try Self.dump(path)
        let wasMigrated = before.tables["collection_items"] != nil
        log.append("before: user_version=\(before.userVersion) tables=\(before.tables.count) collection_items=\(wasMigrated ? "present" : "absent")")
        #expect(before.userVersion == 14)
        let old = try Database(snapshotAt: untouchedPath.path)
        let oldReads = (try Legacy.read117(old), try Legacy.read118(old), try Legacy.read120(old))
        let oldAlbums = try old.albumPurchases()
        let oldSongs = try old.trackPurchases()
        let oldTracks = try old.fetchAllTracks()
        let playTotals = try old.playTotals()
        let plays = try old.plays()
        let liked = try old.likedTrackDates()
        let legacy = LegacyOwnership.including(songs: oldSongs, tracks: oldTracks, in: oldAlbums)
        let ownershipRows = try #require(before.tables["album_ownership"]).namedRows
        log.append("before: album_ownership=\(ownershipRows.count) track_purchases=\(oldSongs.count) tracks=\(oldTracks.count) plays=\(plays.count)")

        // 1. Migrate: every row of every table that existed is unchanged.
        _ = try Database(path: path.path)
        let after = try Self.dump(path)
        #expect(after.userVersion == 14, "no schema version change")
        for (name, oldTable) in before.tables.sorted(by: { $0.key < $1.key }) {
            guard let new = after.tables[name] else { Issue.record("table \(name) is gone"); continue }
            #expect(Array(new.columns.prefix(oldTable.columns.count)) == oldTable.columns, "\(name) keeps its columns in order")
            let added = Set(new.columns.dropFirst(oldTable.columns.count))
            #expect(added.isSubset(of: Legacy.allowedNewColumns[name] ?? []), "\(name) gained \(added)")
            #expect(Set(new.rows.keys) == Set(oldTable.rows.keys), "\(name): no row deleted, replaced or added")
            var changed = 0
            for (rowid, values) in oldTable.rows {
                guard let newValues = new.rows[rowid] else { continue }
                if Array(newValues.prefix(values.count)) != values || !newValues.dropFirst(values.count).allSatisfy({ $0 == .null }) {
                    changed += 1
                }
            }
            #expect(changed == 0, "\(name): \(changed) rows changed")
            log.append("table \(name): rows \(oldTable.rows.count) -> \(new.rows.count), changed \(changed)")
        }
        for (name, sql) in before.schema { #expect(after.schema[name] == sql, "index \(name)") }
        let created = Set(after.tables.keys).subtracting(before.tables.keys)
        #expect(created.isSubset(of: ["collection_items", "discogs_sync", "rip_checks", "track_purchases"]), "created \(created)")
        for name in created where name != "collection_items" { #expect(after.tables[name]?.rows.isEmpty == true, "\(name)") }

        // 2. Every ownership row is an item with the same values, stored with the same bytes.
        let db = try Database(path: path.path)
        let read = try db.collectionItems()
        #expect(read.hadTable && read.unreadable == 0)
        let stored = read.items
        if !wasMigrated { #expect(stored.count == ownershipRows.count, "one item per album_ownership row, nothing else") }
        let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        let storedRows = try #require(after.tables["collection_items"])
        let storedByID = Dictionary(uniqueKeysWithValues: storedRows.namedRows.map { ($0["id"]?.text ?? "", $0) })
        var matched = 0
        for (n, row) in ownershipRows.enumerated() {
            let key = try #require(row["key"]?.text)
            let id = CollectionItem.legacyID(albumKey: key)
            guard let item = byID[id], let s = storedByID[id] else { Issue.record("row \(n): no item with the legacy id"); continue }
            let digital = row["format"]?.text == "digital"
            let ok = item.medium == (digital ? .download : .cd) && item.origin == .stored && item.isEditable
                && item.album == row["album"]?.text && item.artist == row["artist"]?.text && item.albumKey == key
                && item.stickerNumber == row["label_number"]?.int.map(Int.init)
                && item.purchasedOn?.string == row["purchased_on"]?.text
                && AlbumPurchase.priceText(item.price) == row["price"]?.text
                && item.updatedAt == Date(timeIntervalSince1970: row["updated_at"]?.double ?? .nan)
                && s["album"] == row["album"] && s["artist"] == row["artist"] && s["album_key"] == row["key"]
                && s["purchased_on"] == row["purchased_on"] && s["price"] == row["price"]
                && s["sticker"] == (row["label_number"] ?? .null) && s["medium"] == .text(digital ? "download" : "cd")
                && s["updated_at"] == row["updated_at"]
            #expect(ok, "row \(n): the item holds the row's values")
            if !wasMigrated {
                #expect(s["created_at"] == row["updated_at"] && item.digitalSource == nil && item.releaseID == nil
                        && item.notes == nil && item.coverFile == nil, "row \(n): nothing invented")
            }
            if ok { matched += 1 }
        }
        log.append("ownership rows matched by items: \(matched)/\(ownershipRows.count)")

        // 3. Song purchases make derived downloads (and stay as they were).
        let tracks = try db.fetchAllTracks()
        let songs = try db.trackPurchases()
        #expect(songs == oldSongs)
        #expect(tracks == oldTracks)
        let collection = MusicCollection(items: stored, songPurchases: songs, tracks: tracks)
        let storedDownloads = Set(stored.filter { $0.medium == .download }.map(\.albumKey))
        var expectedDerived: [String: (price: Decimal?, day: PurchaseDay?, songs: Int)] = [:]
        for t in tracks {
            guard let song = songs[t.id] else { continue }
            let key = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
            guard !storedDownloads.contains(key) else { continue }
            var e = expectedDerived[key] ?? (nil, nil, 0)
            if let p = song.price { e.price = (e.price ?? 0) + p }
            if let d = song.purchasedOn { e.day = min(e.day ?? d, d) }
            e.songs += 1
            expectedDerived[key] = e
        }
        let derived = collection.items.filter { $0.origin == .songs }
        #expect(derived.count == expectedDerived.count)
        for d in derived {
            let e = expectedDerived[d.albumKey]
            #expect(d.id == CollectionItem.songsID(albumKey: d.albumKey) && d.medium == .download && !d.isEditable)
            #expect(d.price == e?.price && d.purchasedOn == e?.day, "a derived download carries its songs' total and first day")
        }
        let songsNextToCD = derived.filter { oldAlbums[$0.albumKey] != nil }
        log.append("song purchases: \(songs.count) songs -> \(derived.count) derived downloads (\(songsNextToCD.count) next to an owned album)")
        #expect(try db.collectionItems().items.allSatisfy { $0.origin == .stored }, "derived downloads are never stored")
        #expect(LegacyOwnership.purchases(of: collection) == legacy, "the old owned albums, as the collection projects them")

        // 4. Reopening changes nothing.
        let first = try Self.dump(path)
        _ = try Database(path: path.path)
        let second = try Self.dump(path)
        #expect(second == first, "reopening is idempotent")
        #expect(try Database(path: path.path).collectionItems().items == stored)

        // 5. What older versions read from album_ownership is unchanged.
        #expect(try Legacy.read117(db) == oldReads.0, "1.14–1.17")
        #expect(try Legacy.read118(db) == oldReads.1, "1.18")
        #expect(try Legacy.read120(db) == oldReads.2, "1.19–1.20")
        #expect(try db.albumPurchases() == oldAlbums)

        // 6. A phone reading the untouched copy sees the same collection (ids and values) as the Mac after migrating.
        let phone = try LibrarySnapshot(root: untouchedRoot, isPresent: { _ in false })
        #expect(phone.labelUnreadable == 0)
        #expect(LegacyOwnership.purchases(of: phone.collection) == legacy)
        #expect(phone.collection.items.map(\.id) == collection.items.map(\.id))
        #expect(phone.collection.items == collection.items)
        let syncedDir = try Self.readableCopy(of: path).deletingLastPathComponent()
        let synced = try LibrarySnapshot(root: syncedDir, isPresent: { _ in false })
        #expect(synced.collection.items == collection.items && LegacyOwnership.purchases(of: synced.collection) == legacy)

        // 7. Labels: the CDs keep their numbers, in the CD series.
        let cdRows = ownershipRows.filter { $0["format"]?.text != "digital" }
        let oldLabels = cdRows.compactMap { $0["label_number"]?.int.map(Int.init) }.sorted()
        let cds = collection.items.filter { $0.origin == .stored && $0.medium == .cd }
        let cdLabels = cds.compactMap { $0.sticker?.series == .cd ? $0.stickerNumber : nil }.sorted()
        if !wasMigrated { #expect(cds.count == cdRows.count) }
        #expect(cdLabels == oldLabels, "the CDs' label numbers, in the CD series")
        let oldDuplicates = Dictionary(grouping: oldLabels, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(collection.duplicates(in: .cd).keys.sorted() == oldDuplicates)
        #expect(collection.nextNumber(in: .cd) == (oldLabels.max() ?? 0) + 1)
        let vinyl = collection.items.filter { $0.medium == .vinyl }
        if vinyl.isEmpty { #expect(collection.nextNumber(in: .vinyl) == 1) }
        let range = oldLabels.isEmpty ? "none" : "\(oldLabels.first!)...\(oldLabels.last!)"
        log.append("CDs: \(cds.count) items, labels \(range) (\(cdLabels.count) labeled, \(Set(cdLabels).count) distinct), "
                   + "duplicates \(collection.duplicates(in: .cd).count), next CD \(collection.nextNumber(in: .cd)), "
                   + "next vinyl \(collection.nextNumber(in: .vinyl))")

        // 8. Every item whose album has songs in the library shows its music.
        var withMusic = 0, trackless = 0
        for item in collection.items {
            let hasTracks = item.origin == .songs || !collection.libraryTracks(item).isEmpty
            #expect(collection.digitalState(item).hasMusic == hasTracks, "an item shows its music exactly when it has some")
            if collection.digitalState(item).hasMusic { withMusic += 1 }
            if !hasTracks { trackless += 1 }
        }
        log.append("digital state: \(withMusic)/\(collection.items.count) items show their music, \(trackless) without tracks")

        // 9. Insights: the collection's totals are the old ones plus exactly what the old stats left out (owned
        // albums with no songs in the library, and songs bought next to an owned album), so nothing filed is lost.
        let oldStats = LegacyOwnership.Totals(tracks: tracks, purchases: legacy, now: now, calendar: calendar)
        let newStats = CollectionStats(collection: collection, tracks: tracks, playTotals: playTotals, albumInfos: [:],
                                       now: now, calendar: calendar)
        let trackKeys = Set(tracks.map { SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist) })
        let thisYear = calendar.component(.year, from: now)
        let leftOut = collection.items.filter { item in
            item.origin == .stored ? !trackKeys.contains(item.albumKey) : oldAlbums[item.albumKey] != nil
        }
        let leftOutSpend = leftOut.reduce(Decimal(0)) { $0 + ($1.price ?? 0) }
        let leftOutThisYear = leftOut.filter { $0.purchasedOn?.year == thisYear }
        let tracklessKeys = Set(leftOut.filter { $0.origin == .stored }.map(\.albumKey))
        let enteredSpend = stored.reduce(Decimal(0)) { $0 + ($1.price ?? 0) } + derived.reduce(Decimal(0)) { $0 + ($1.price ?? 0) }
        if !wasMigrated {
            let rowSpend = ownershipRows.reduce(Decimal(0)) { $0 + (AlbumPurchase.price(text: $1["price"]?.text) ?? 0) }
            let songSpend = tracks.reduce(Decimal(0)) { t, track in
                t + (storedDownloads.contains(SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist))
                     ? 0 : songs[track.id]?.price ?? 0)
            }
            #expect(enteredSpend == rowSpend + songSpend, "every price entered is counted once")
        }
        #expect(newStats.totalSpent == enteredSpend)
        #expect(newStats.totalSpent == oldStats.totalSpent + leftOutSpend)
        #expect(newStats.albumsOwned == oldStats.ownedCount + tracklessKeys.count)
        #expect(newStats.libraryAlbumCount == oldStats.libraryAlbumCount)
        #expect(newStats.notInCollection == oldStats.borrowedCount)
        #expect(newStats.spentThisYear == oldStats.spentThisYear + leftOutThisYear.reduce(Decimal(0)) { $0 + ($1.price ?? 0) })
        #expect(newStats.boughtThisYear == oldStats.boughtThisYear + leftOutThisYear.count)
        log.append("stats: owned old \(oldStats.ownedCount) new \(newStats.albumsOwned) (+\(tracklessKeys.count) trackless); "
                   + "spend new == old + \(leftOut.count) items left out by the old stats: "
                   + "\(newStats.totalSpent == oldStats.totalSpent + leftOutSpend); library albums \(newStats.libraryAlbumCount)")

        // 10. Glance: the same Owned counts; spending as the stats. (1.20's `Glance.build(purchases:)` filled
        // `owned` with its OwnershipStats totals, `oldStats` here, and `library` without looking at ownership.)
        let present = Set(tracks.map(\.id))
        let oldGlance = (owned: oldStats,
                         library: Glance.build(tracks: tracks, present: present, plays: plays, likedDates: liked, collection: .empty,
                                               playTotals: playTotals, playing: nil, currencyCode: "USD", now: now,
                                               calendar: calendar).glance.library)
        let newGlance = Glance.build(tracks: tracks, present: present, plays: plays, likedDates: liked, collection: collection,
                                     playTotals: playTotals, playing: nil, currencyCode: "USD", now: now, calendar: calendar).glance
        #expect(newGlance.owned.ownedCount == oldGlance.owned.ownedCount)
        #expect(newGlance.owned.libraryAlbumCount == oldGlance.owned.libraryAlbumCount)
        #expect(newGlance.owned.totalSpent == oldGlance.owned.totalSpent + leftOutSpend)
        #expect(newGlance.owned.spentThisYear == oldGlance.owned.spentThisYear + leftOutThisYear.reduce(Decimal(0)) { $0 + ($1.price ?? 0) })
        #expect(newGlance.owned.boughtThisYear == oldGlance.owned.boughtThisYear + leftOutThisYear.count)
        #expect(newGlance.library == oldGlance.library)
        #expect(newGlance.collection?.cds == cds.count && newGlance.collection?.nextCD == collection.nextNumber(in: .cd))
        log.append("glance: owned \(oldGlance.owned.ownedCount) -> \(newGlance.owned.ownedCount), library albums "
                   + "\(newGlance.owned.libraryAlbumCount), spend equal after left-out items: "
                   + "\(newGlance.owned.totalSpent == oldGlance.owned.totalSpent + leftOutSpend)")

        print(log.map { "REHEARSAL \($0)" }.joined(separator: "\n"))
    }
}
