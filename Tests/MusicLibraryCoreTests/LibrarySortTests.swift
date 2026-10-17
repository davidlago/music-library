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
}
