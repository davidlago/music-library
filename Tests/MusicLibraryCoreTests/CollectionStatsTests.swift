import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct CollectionStatsTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    var now: Date { calendar.date(from: DateComponents(year: 2025, month: 8, day: 1, hour: 12))! }

    func day(_ y: Int, _ m: Int, _ d: Int) -> PurchaseDay { PurchaseDay(year: y, month: m, day: d)! }

    func track(_ id: Int64, album: String, artist: String, year: Int? = nil, genre: String = "", label: String = "",
               duration: Double = 200) -> Track {
        var m = TrackMetadata(title: "T\(id)", artist: artist, album: album, year: year, trackNo: Int(id), genre: genre)
        m.extended.label = label
        return Track(id: id, path: "Music/\(artist)/\(album)/\(id).flac", metadata: m, duration: duration, format: "flac",
                     sha256: "\(id)", addedAt: Date(timeIntervalSince1970: 0))
    }

    func item(_ id: String, _ medium: CollectionMedium, _ number: Int? = nil, album: String, artist: String,
              source: DigitalSource? = nil, created: Date = Date(timeIntervalSince1970: 1_600_000_000),
              configure: (inout CollectionItem) -> Void = { _ in }) -> CollectionItem {
        var i = CollectionItem(id: id, medium: medium, album: album, artist: artist, now: created)
        i.stickerNumber = number
        i.digitalSource = source
        configure(&i)
        return i
    }

    /// Album A on CD #1; album B on CD #3 and Vinyl #1 (one album, two copies); album C only in the library; songs of
    /// album D bought on their own; Blue Train on Vinyl #2 with no tracks; an unripped, unlabeled 3-CD box; and a
    /// second CD #3.
    var tracks: [Track] {
        [track(1, album: "A", artist: "Band", year: 1990, genre: "Rock", label: "Lab A"),
         track(2, album: "A", artist: "Band", year: 1990, genre: "Rock", label: "Lab A"),
         track(3, album: "B", artist: "Band", year: 1965, duration: 300),
         track(4, album: "C", artist: "Other"),
         track(5, album: "D", artist: "Singer", duration: 100),
         track(6, album: "D", artist: "Singer", duration: 100)]
    }

    var playTotals: [Int64: PlayTotal] {
        [1: PlayTotal(plays: 3, listened: 400), 2: PlayTotal(plays: 1, listened: 200), 3: PlayTotal(plays: 10, listened: 1800),
         4: PlayTotal(plays: 50, listened: 9000)]
    }

    var items: [CollectionItem] {
        [item("a-cd", .cd, 1, album: "A", artist: "Band", source: .rip) { $0.price = 12; $0.purchasedOn = day(2024, 1, 10) },
         item("b-vinyl", .vinyl, 1, album: "B", artist: "Band", source: .same) { $0.price = 25; $0.purchasedOn = day(2025, 6, 1) },
         item("b-cd", .cd, 3, album: "B", artist: "Band", source: .rip) { $0.price = 8; $0.purchasedOn = day(2023, 12, 1) },
         item("blue-train", .vinyl, 2, album: "Blue Train", artist: "John Coltrane", created: Date(timeIntervalSince1970: 1_000_000_000)) {
             $0.year = 1957; $0.recordLabel = "Blue Note"
         },
         item("box", .cd, album: "Box", artist: "Band") {
             $0.price = 40; $0.purchasedOn = day(2024, 5, 5); $0.discCount = 3; $0.trackCount = 30
         },
         item("dup", .cd, 3, album: "Dup", artist: "X", created: Date(timeIntervalSince1970: 1_750_000_000))]
    }

    var albumInfos: [String: AlbumInfo] {
        var info = AlbumInfo(title: "Blue Train")
        info.genres = ["jazz"]
        info.tracklist = [TracklistEntry(disc: 1, number: 1, title: "Blue Train", duration: 300, position: "A1"),
                          TracklistEntry(disc: 1, number: 2, title: "Moment's Notice", duration: 200, position: "A2")]
        return [SearchIndex.albumKey(album: "Blue Train", artist: "John Coltrane"): info]
    }

    var collection: MusicCollection {
        MusicCollection(items: items, songPurchases: [5: TrackPurchase(purchasedOn: day(2025, 7, 1), price: Decimal(string: "1.29"))],
                        tracks: tracks)
    }

    var stats: CollectionStats {
        CollectionStats(collection: collection, tracks: tracks, playTotals: playTotals, albumInfos: albumInfos, now: now, calendar: calendar)
    }

    let derived = CollectionItem.songsID(albumKey: SearchIndex.albumKey(album: "D", artist: "Singer"))

    @Test func countsIncludeTracklessItems() {
        let s = stats
        #expect(s.itemCount == 7 && s.physicalCount == 6)
        #expect(s.cdCount == 4 && s.vinylCount == 2 && s.downloadCount == 1 && s.otherCount == 0)
        // A, B, D, Blue Train, Box, Dup.
        #expect(s.albumsOwned == 6)
        #expect(s.libraryAlbumCount == 4 && s.notInCollection == 1)
        #expect(s.media.map(\.medium) == [.cd, .vinyl, .download])
        let cd = s.media[0], vinyl = s.media[1], download = s.media[2]
        #expect(cd.items == 4 && cd.digitized == 2 && cd.toDigitize == 2 && cd.labeled == 3 && cd.unlabeled == 1)
        #expect(cd.priced == 3 && cd.spent == 60 && cd.averagePrice == 20)
        #expect(vinyl.items == 2 && vinyl.otherCopy == 1 && vinyl.toDigitize == 1 && vinyl.labeled == 2)
        #expect(download.partial == 1 && download.labeled == 0 && download.unlabeled == 0 && download.spent == Decimal(string: "1.29"))
    }

    @Test func notInCollectionIsNeverNegative() {
        // More items than library albums: nothing in the library is unowned.
        let owned = CollectionStats(collection: collection, tracks: Array(tracks.prefix(3)), playTotals: [:], albumInfos: [:], now: now)
        #expect(owned.notInCollection == 0 && owned.libraryAlbumCount == 2 && owned.itemCount > owned.libraryAlbumCount)
        // An empty collection: every library album, and both series ready for #1.
        let empty = CollectionStats(collection: .empty, tracks: tracks, playTotals: [:], albumInfos: [:], now: now)
        #expect(empty.itemCount == 0 && empty.notInCollection == 4)
        #expect(empty.series.map(\.series) == [.cd, .vinyl] && empty.series.allSatisfy { $0.next == 1 && $0.highest == nil })
    }

    @Test func digitization() {
        let s = stats
        #expect(s.digitizedShare == 0.5)  // A, B (CD), B (vinyl, from the CD) of six physical items
        // Oldest bought first; undated ones by when they were added.
        #expect(s.toDigitize.map(\.id) == ["blue-train", "box", "dup"])
        #expect(s.toDigitizeCount == 3 && s.toRipCount == 2 && s.vinylToDigitizeCount == 1 && s.waitingForTurntable == 1)
    }

    @Test func seriesAreSeparate() {
        let s = stats
        let cd = s.series[0], vinyl = s.series[1]
        #expect(cd.series == .cd && cd.labeled == 3 && cd.unlabeled == 1 && cd.highest == 3 && cd.next == 4)
        #expect(cd.gaps == [2...2] && cd.gapCount == 1)
        #expect(cd.duplicates.keys.sorted() == [3] && Set(cd.duplicates[3] ?? []) == ["b-cd", "dup"])
        #expect(vinyl.series == .vinyl && vinyl.labeled == 2 && vinyl.unlabeled == 0 && vinyl.highest == 2 && vinyl.next == 3)
        #expect(vinyl.gaps.isEmpty && vinyl.duplicates.isEmpty)
        #expect(s.byLabel[.cd]?.map(\.item.stickerNumber) == [1, 3, 3])
        #expect(s.byLabel[.vinyl]?.map(\.id) == ["b-vinyl", "blue-train"])
    }

    @Test func gapsAreFolded() {
        let numbers = [1, 2, 5, 6, 7, 10, 11, 15]
        let list = numbers.map { item("cd\($0)", .cd, $0, album: "Album \($0)", artist: "A") }
        let s = CollectionStats(collection: MusicCollection(items: list, songPurchases: [:], tracks: []), tracks: [], playTotals: [:],
                                albumInfos: [:], now: now)
        #expect(s.series[0].gaps == [3...4, 8...9, 12...14] && s.series[0].gapCount == 7 && s.series[0].next == 16)
    }

    @Test func spending() throws {
        let s = stats
        // Each copy on its own, the songs bought on their own included.
        #expect(s.totalSpent == Decimal(string: "86.29") && s.pricedCount == 5 && s.datedCount == 5)
        #expect(s.medianPrice == 12 && s.averagePrice == Decimal(string: "86.29")! / 5)
        #expect(s.priciest?.id == "box" && s.cheapest?.id == derived)
        #expect(s.priciestList.map(\.id) == ["box", "b-vinyl", "a-cd", "b-cd", derived])
        #expect(s.boughtThisYear == 2 && s.spentThisYear == Decimal(string: "26.29"))
        // 20 months of purchases: monthly, from December 2023 to now.
        #expect(s.granularity == .month && s.timeline.count == 21)
        #expect(s.timeline.first?.start == day(2023, 12, 1) && s.timeline.last?.start == day(2025, 8, 1))
        #expect(s.timeline.last?.cumulative == s.totalSpent)
        let june = try #require(s.timeline.first { $0.start == day(2025, 6, 1) })
        #expect(june.items == 1 && june.spent == 25 && june.spentByMedium == ["vinyl": 25])
        #expect(s.timeline.first { $0.start == day(2025, 7, 1) }?.spentByMedium == ["download": Decimal(string: "1.29")!])

        // Spread over more than two years: yearly, undated items left out.
        var spread = items
        spread[0].purchasedOn = day(2015, 3, 1)
        let yearly = CollectionStats(collection: MusicCollection(items: spread, songPurchases: [:], tracks: tracks), tracks: tracks,
                                     playTotals: [:], albumInfos: [:], now: now, calendar: calendar)
        #expect(yearly.granularity == .year && yearly.timeline.map(\.start.year) == Array(2015...2025))
        #expect(yearly.timeline.reduce(0) { $0 + $1.items } == 4)
    }

    @Test func valueCountsPlaysOncePerAlbum() {
        let s = stats
        // A: $12 for 4 plays; B: $33 (both copies) for 10 plays, counted once; D has music but no plays.
        #expect(s.costPerPlay == Decimal(45) / Decimal(14))
        #expect(s.costPerHour == Decimal(45) / Decimal(2400.0 / 3600))
        #expect(s.bestValue.map(\.id) == ["a-cd", "b-cd"])
        #expect(s.bestValue.map(\.pricePerPlay) == [Decimal(3), Decimal(string: "3.3")])
        #expect(s.bestValue.map(\.plays) == [4, 10])
        // Albums with music and no plays; physical items with no music are To Digitize, not here.
        #expect(s.stillInWrapper.map(\.id) == [derived])
        // C's 50 plays aren't anyone's: it isn't in the collection.
        let withoutC = CollectionStats(collection: collection, tracks: tracks, playTotals: playTotals.filter { $0.key != 4 },
                                       albumInfos: albumInfos, now: now, calendar: calendar)
        #expect(withoutC.costPerPlay == s.costPerPlay)
    }

    @Test func needsDetails() {
        // No date or price (Blue Train, Dup), or physical with no label number (Box); the derived download can't be edited.
        #expect(Set(stats.needsDetails.map(\.id)) == ["blue-train", "box", "dup"])
    }

    @Test func breakdowns() {
        let s = stats
        #expect(s.artists.first?.name == "Band" && s.artists.first?.items == 4 && s.artists.first?.spent == 85)
        // Tracks' genres, else the album info's.
        #expect(s.genres.map(\.name) == ["Rock", "jazz"])
        // The item's year, else the tracks'.
        #expect(s.decades.map(\.name) == ["1950s", "1960s", "1990s"] && s.decades.map(\.items) == [1, 2, 1])
        // The item's record label, else the tracks' tag.
        #expect(s.recordLabels.map(\.name) == ["Lab A", "Blue Note"])
    }

    @Test func facts() {
        let s = stats
        #expect(s.oldestRelease?.id == "blue-train")
        #expect(s.newestAddition?.id == "dup")
        #expect(s.mostCopies?.item.id == "b-cd" && s.mostCopies?.copies == 2)
        #expect(s.biggestBox?.id == "box")
        // A, B and D's tracks, plus Blue Train's tracklist.
        #expect(s.runtime == 400 + 300 + 200 + 500)
        #expect(s.recentlyAdded.first?.id == derived && s.recentlyAdded.count == 7)
    }
}
