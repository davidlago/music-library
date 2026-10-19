import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct LibrarySortTests {
    func track(_ id: Int64, _ title: String, artist: String = "A", album: String = "X", composer: String = "", year: Int? = nil,
               duration: Double = 200, format: String = "flac", added: TimeInterval = 0) -> Track {
        Track(id: id, path: "Music/\(id).\(format)",
              metadata: TrackMetadata(title: title, artist: artist, album: album, year: year, composer: composer),
              duration: duration, format: format, sha256: "\(id)", addedAt: Date(timeIntervalSince1970: added))
    }

    func ids(_ tracks: [Track]) -> [Int64] { tracks.map(\.id) }

    @Test func songsSortNaturallyAndKeepTiesInLibraryOrder() {
        let tracks = [track(1, "Song 10", artist: "beta"), track(2, "song 2", artist: "Alpha"), track(3, "Ärger", artist: "beta"),
                      track(4, "", artist: "alpha")]
        #expect(ids(SongSort.title.sorted(tracks, ascending: true)) == [3, 2, 1, 4])
        #expect(ids(SongSort.title.sorted(tracks, ascending: false)) == [1, 2, 3, 4])
        // Case doesn't split an artist, and the library's order holds within one.
        #expect(ids(SongSort.artist.sorted(tracks, ascending: true)) == [2, 4, 1, 3])
        #expect(ids(SongSort.artist.sorted(tracks, ascending: false)) == [1, 3, 2, 4])
    }

    @Test func missingValuesGoLastEitherWay() {
        let tracks = [track(1, "a"), track(2, "b", composer: "Bach", year: 1990), track(3, "c", composer: "Arvo", year: 2001),
                      track(4, "d", year: 0)]
        #expect(ids(SongSort.composer.sorted(tracks, ascending: true)) == [3, 2, 1, 4])
        #expect(ids(SongSort.composer.sorted(tracks, ascending: false)) == [2, 3, 1, 4])
        #expect(ids(SongSort.year.sorted(tracks, ascending: true)) == [2, 3, 1, 4])
        #expect(ids(SongSort.year.sorted(tracks, ascending: false)) == [3, 2, 1, 4])
    }

    @Test func songsByTimeFormatAndDateAdded() {
        let tracks = [track(1, "a", duration: 300, format: "mp3", added: 50), track(2, "b", duration: 100, format: "flac", added: 200),
                      track(3, "c", duration: 200, format: "m4a", added: 100)]
        #expect(ids(SongSort.duration.sorted(tracks, ascending: true)) == [2, 3, 1])
        #expect(ids(SongSort.format.sorted(tracks, ascending: true)) == [2, 3, 1])
        #expect(SongSort.added.defaultAscending == false)
        #expect(ids(SongSort.added.sorted(tracks, ascending: SongSort.added.defaultAscending)) == [2, 3, 1])
    }

    @Test func albumOrders() {
        let albums = [AlbumSummary(album: "Zeta", artist: "A", year: 1990, trackCount: 1, firstTrackPath: "a"),
                      AlbumSummary(album: "", artist: "B", year: nil, trackCount: 1, firstTrackPath: "b"),
                      AlbumSummary(album: "alpha", artist: "C", year: 2005, trackCount: 1, firstTrackPath: "c")]
        func key(_ i: Int) -> String { SearchIndex.albumKey(album: albums[i].album, artist: albums[i].artist) }
        func order(_ sort: AlbumSort, added: [String: Date] = [:], plays: [String: PlayTotal] = [:]) -> [String] {
            sort.sorted(albums, added: added, plays: plays).map(\.firstTrackPath)
        }
        #expect(order(.artist) == ["a", "b", "c"])
        #expect(order(.title) == ["c", "a", "b"])
        #expect(order(.year) == ["c", "a", "b"])
        #expect(order(.added, added: [key(0): Date(timeIntervalSince1970: 10), key(2): Date(timeIntervalSince1970: 20)]) == ["c", "a", "b"])
        #expect(order(.mostPlayed, plays: [key(1): PlayTotal(plays: 3, listened: 100), key(2): PlayTotal(plays: 3, listened: 900)])
                == ["c", "b", "a"])
        #expect(order(.recent, plays: [key(0): PlayTotal(plays: 1, lastPlayed: Date(timeIntervalSince1970: 5))]) == ["a", "b", "c"])
    }

    @Test func albumAddedDatesUseTheNewestSong() {
        let tracks = [track(1, "a", album: "X", added: 100), track(2, "b", album: "X", added: 300), track(3, "c", album: "Y", added: 50)]
        let added = AlbumSort.addedDates(tracks)
        #expect(added[SearchIndex.albumKey(album: "X", artist: "A")] == Date(timeIntervalSince1970: 300))
        #expect(added[SearchIndex.albumKey(album: "Y", artist: "A")] == Date(timeIntervalSince1970: 50))
    }

    @Test func collectionOrders() {
        func item(_ id: String, _ medium: CollectionMedium, _ number: Int? = nil, album: String = "", artist: String = "",
                  year: Int? = nil, bought: PurchaseDay? = nil, price: Decimal? = nil, added: TimeInterval = 0) -> CollectionItem {
            var i = CollectionItem(id: id, medium: medium, album: album, artist: artist, now: Date(timeIntervalSince1970: added))
            i.stickerNumber = number
            i.year = year
            i.purchasedOn = bought
            i.price = price
            return i
        }
        let items = [
            item("v2", .vinyl, 2, album: "Blue", artist: "Joni", year: 1971, bought: PurchaseDay(year: 2020, month: 1, day: 1), price: 30, added: 5),
            item("u1", .cd, album: "Zed", artist: "Beta", added: 9),
            item("c10", .cd, 10, album: "Abbey", artist: "Beatles", year: 1969, price: 12, added: 1),
            item("dl", .download, album: "", artist: "", bought: PurchaseDay(year: 2024, month: 5, day: 1), added: 3),
            item("c2", .cd, 2, album: "Kind", artist: "Miles", year: 1959, bought: PurchaseDay(year: 2020, month: 1, day: 1), price: 12, added: 7),
            item("u0", .vinyl, album: "Alpha", artist: "Beta", added: 2),
        ]
        func order(_ sort: CollectionSort) -> [String] { sort.sorted(items).map(\.id) }
        #expect(order(.sticker) == ["c2", "c10", "v2", "u0", "u1", "dl"], "CDs, then records, by number; unlabeled by artist and title")
        #expect(order(.artist) == ["c10", "u1", "u0", "v2", "c2", "dl"])
        #expect(order(.title) == ["c10", "u0", "v2", "c2", "u1", "dl"])
        #expect(order(.year) == ["v2", "c10", "c2", "u1", "dl", "u0"], "newest first, undated last in their order")
        #expect(order(.bought) == ["dl", "v2", "c2", "u1", "c10", "u0"])
        #expect(order(.price) == ["v2", "c10", "c2", "u1", "dl", "u0"], "ties keep their order")
        #expect(order(.added) == ["u1", "c2", "v2", "dl", "u0", "c10"])
        #expect(CollectionSort.sticker.title == "Label")
    }
}
