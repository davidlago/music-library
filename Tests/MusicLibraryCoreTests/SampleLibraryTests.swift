import Foundation
import Testing
@testable import MusicLibraryCore

/// The iPhone app's sample library (`scripts/make-sample-library.sh`), as the app opens it: read-only, in place.
@Suite struct SampleLibraryTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("iOS/MusicLibraryMobile/SampleLibrary.bundle", isDirectory: true)

    @Test func opensWithEverySongCoverAndPhoto() throws {
        let s = try LibrarySnapshot(root: Self.root, datesRelativeToNow: true)
        #expect(s.tracks.count >= 30)
        #expect(s.presentIDs.count == s.tracks.count)
        #expect(s.albums.allSatisfy { a in s.coverURL(album: a).map { FileManager.default.fileExists(atPath: $0.path) } == true })
        #expect(s.artists.allSatisfy { a in s.artistImageURL(a.name).map { FileManager.default.fileExists(atPath: $0.path) } == true })
        #expect(s.artists.allSatisfy { s.artistInfo($0.name)?.bio != nil })
        #expect(!s.playlists.isEmpty && !s.likedDates.isEmpty && !LegacyOwnership.purchases(of: s.collection).isEmpty)
        #expect(s.libraryID != nil)
        // Its history reaches today, however long ago it was made.
        let last = try #require(s.plays.last?.startedAt)
        #expect(Date().timeIntervalSince(last) < 86_400)
        #expect(s.collaborations.people.count > s.artists.count)
    }

    /// Labeled CDs (ripped from CD #1 on, two not ripped yet) and records (two never digitized, one needle-dropped,
    /// one of an album also on CD), and a download.
    @Test func hasACollectionInBothSeries() throws {
        let s = try LibrarySnapshot(root: Self.root, datesRelativeToNow: true)
        let c = s.collection
        #expect(c.unreadable == 0)
        for series in StickerSeries.allCases {
            let numbers = c.items.compactMap { $0.sticker?.series == series ? $0.sticker?.number : nil }.sorted()
            #expect(numbers.first == 1 && numbers == Array(1...numbers.count))
            #expect(c.duplicates(in: series).isEmpty)
        }
        let cd1 = try #require(Sticker(series: .cd, number: 1)), vinyl3 = try #require(Sticker(series: .vinyl, number: 3))
        #expect(c.items(at: cd1).count == 1 && c.items(at: cd1).allSatisfy { c.digitalState($0).hasMusic })
        #expect(c.items(number: 1).count == 2)

        let vinyl = c.items(in: .vinyl)
        let undigitized = vinyl.filter { c.digitalState($0) == .none }
        #expect(undigitized.compactMap(\.sticker?.number).sorted() == [1, 2])
        let ripped = try #require(c.items(at: vinyl3).first)
        #expect(ripped.digitalSource == .rip && c.digitalState(ripped).hasMusic)
        #expect(c.items(in: .cds).filter { c.digitalState($0) == .none }.count == 2)
        #expect(c.items(in: .downloads).contains { $0.origin == .stored })
        #expect(Set(c.items.map(\.albumKey)).contains { key in Set(c.copies(albumKey: key).map(\.medium)).isSuperset(of: [.cd, .vinyl]) })

        // Every item without songs has a cover of its own, in the bundle, and a track list.
        for item in c.items where c.libraryTracks(item).isEmpty {
            let file = try #require(item.coverFile)
            #expect(s.coverURL(item: item) == CollectionCovers.url(file, root: Self.root))
            #expect(s.coverURL(item: item).map { FileManager.default.fileExists(atPath: $0.path) } == true)
            #expect(s.albumInfos[item.albumKey]?.tracklist.isEmpty == false)
        }
        #expect(vinyl.contains { item in s.albumInfos[item.albumKey]?.tracklist.contains { $0.position == "A1" } == true })
    }

    /// Older phones read `album_ownership`: only CDs (with their own labels) and downloads, never a record.
    @Test func legacyOwnershipHasNoVinyl() throws {
        let db = try Database(snapshotAt: LibraryLocation.databaseURL(root: Self.root).path)
        let collection = try db.collectionItems()
        #expect(collection.hadTable)
        let rows = try db.legacyOwnershipRows()
        let vinylOnly = Set(collection.items.map(\.albumKey))
            .filter { key in collection.items.filter { $0.albumKey == key }.allSatisfy { $0.medium == .vinyl } }
        #expect(!vinylOnly.isEmpty && rows.allSatisfy { !vinylOnly.contains($0.key) })
        for row in rows {
            let primary = try #require(CollectionLegacy.primary(collection.items, albumKey: row.key))
            #expect(primary.medium == .cd || primary.medium == .download)
            #expect(row.purchase.labelNumber == (primary.medium == .cd ? primary.stickerNumber : nil))
            #expect(row.purchase.format == (primary.medium == .download ? .digital : .cd))
        }
        #expect(rows.count == Set(collection.items.filter { $0.medium == .cd || $0.medium == .download }.map(\.albumKey)).count)
    }

    /// A WAL database can't be opened read-only inside an app bundle.
    @Test func databaseIsNotInWALMode() throws {
        let header = try FileHandle(forReadingFrom: LibraryLocation.databaseURL(root: Self.root)).read(upToCount: 20) ?? Data()
        #expect(header.count == 20 && header[18] == 1 && header[19] == 1)
    }

    @Test func shiftsHistoryByWholeDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(LibrarySnapshot.dayShift(latest: now.addingTimeInterval(-3.5 * 86_400), now: now) == 3 * 86_400)
        #expect(LibrarySnapshot.dayShift(latest: now.addingTimeInterval(-3600), now: now) == 0)
        #expect(LibrarySnapshot.dayShift(latest: now.addingTimeInterval(3600), now: now) == 0)
        #expect(LibrarySnapshot.dayShift(latest: nil, now: now) == 0)
    }
}
