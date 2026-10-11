import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct LibraryStatsTests {
    let now = SearchFixtures.now
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func stats(_ tracks: [Track] = SearchFixtures.library) -> LibraryStats {
        LibraryStats(tracks: tracks, now: now, calendar: calendar, hasCover: { $0.artist != "Kraftwerk" && !$0.album.isEmpty },
                     fileSize: { $0.id == 1 ? 30_000_000 : nil })
    }

    @Test func emptyLibrary() {
        let s = LibraryStats(tracks: [], now: now)
        #expect(s.trackCount == 0 && s.albumCount == 0 && s.artistCount == 0)
        #expect(s.years.isEmpty && s.genres.isEmpty && s.growth.isEmpty && s.lengthBuckets.isEmpty)
        #expect(s.longestTrack == nil && s.medianYear == nil)
        #expect(s.averageTrackLength == 0)
    }

    @Test func totals() {
        let s = stats()
        #expect(s.trackCount == 8)
        #expect(s.albumCount == 6)
        #expect(s.artistCount == 6)
        #expect(s.totalDuration == SearchFixtures.library.reduce(0) { $0 + $1.duration })
        #expect(s.losslessCount == 5)
        #expect(s.totalBytes > 30_000_000)
        #expect(s.bytesAreEstimated)
    }

    @Test func timeline() {
        let s = stats()
        #expect(s.years.map(\.year) == [1959, 1963, 1981, 1997, 2020])
        #expect(s.decades.map(\.year) == [1950, 1960, 1980, 1990, 2020])
        #expect(s.busiestYear?.year == 1959)  // ties go to the earlier year
        #expect(s.medianYear == 1981)
        #expect(s.oldestAlbum?.album == "Kind of Blue")
        #expect(s.newestAlbum?.album == "Hits 2020")
        #expect(s.longestAlbum?.album == "Kind of Blue")
    }

    @Test func rankingsAndGenres() {
        let s = stats()
        #expect(s.genres.first?.count == 2)
        #expect(s.genres.contains { $0.name == "Modal Jazz" && $0.count == 1 })
        #expect(s.artistsByTracks.prefix(2).map(\.name) == ["Miles Davis", "Radiohead"])
        #expect(s.artistsByDuration.first?.name == "Miles Davis")
        #expect(s.labels.first?.name == "Parlophone")
        #expect(s.people.map(\.name).contains("John Coltrane"))
        #expect(s.people.first { $0.name == "John Coltrane" }?.roles == ["tenor saxophone"])
        #expect(s.longestTrack?.title == "So What")
        #expect(s.shortestTrack?.title == "Mystery Track")
    }

    @Test func titleWordsNeedToRecur() {
        let s = stats()
        // "computer", "love", "blue"... only words in 2+ titles count, and stop words never do.
        #expect(s.titleWords.map(\.name) == ["love"])
    }

    @Test func audioQuality() {
        let s = stats()
        let tiers = Dictionary(uniqueKeysWithValues: s.qualityTiers.map { ($0.tier, $0.count) })
        #expect(tiers[.hiRes] == 2)
        #expect(tiers[.cd] == 3)   // 2 FLAC 16/44.1 + the WAV with unknown details
        #expect(tiers[.lossyHigh] == 2)
        #expect(tiers[.lossy] == 1)
        #expect(tiers[.unknown] == nil)
        #expect(s.sampleRates.map(\.name) == ["44.1 kHz", "96 kHz"])
        #expect(s.bitDepths.map(\.name) == ["16-bit", "24-bit"])
        #expect(s.codecs.map(\.name).first == "FLAC")
    }

    @Test func lengthHistogramAdaptsToData() {
        let s = stats()
        #expect(s.lengthBuckets.reduce(0) { $0 + $1.count } == 8)
        #expect(s.lengthBuckets.first?.lowerMinute == 0)
        #expect(s.lengthBuckets.last?.upperMinute == nil)
        #expect(s.lengthBuckets.first { $0.lowerMinute == 4 }?.count == 2)  // 4:24 and 4:44

        // A long-form collection gets more buckets but never more than 21.
        let long = (0..<50).map { SearchFixtures.track(Int64($0), "T\($0)", artist: "A", album: "B", duration: Double($0) * 120) }
        let ls = LibraryStats(tracks: long, now: now)
        #expect(ls.lengthBuckets.count <= 21)
        #expect(ls.lengthBuckets.last?.label == "20+")
    }

    @Test func growthGranularityFollowsSpan() {
        let s = stats()
        #expect(s.growthGranularity == .week)  // 400 days of history
        #expect(s.growth.last?.total == 8)
        #expect(s.growth.map(\.total) == s.growth.map(\.total).sorted())
        #expect(s.addedLast30Days == 4)

        let fresh = SearchFixtures.library.map { t -> Track in var t = t; t.addedAt = now; return t }
        let fs = LibraryStats(tracks: fresh, now: now, calendar: calendar)
        #expect(fs.growthGranularity == .day)
        #expect(fs.growth.count == 1)

        let old = (0..<10).map { SearchFixtures.track(Int64($0), "T", artist: "A", album: "B", addedDaysAgo: Double($0) * 400) }
        #expect(LibraryStats(tracks: old, now: now, calendar: calendar).growthGranularity == .month)
    }

    @Test func coverage() {
        let s = stats()
        let c = Dictionary(uniqueKeysWithValues: s.coverage.map { ($0.field, $0.present) })
        #expect(c[.year] == 7)
        #expect(c[.mbid] == 3)
        #expect(c[.cover] == 6)
        #expect(c[.credits] == 2)
        #expect(c[.label] == 3)
    }

    @Test func folding() {
        let items = (1...10).map { LibraryStats.Count(name: "g\($0)", count: 11 - $0) }
        let f = LibraryStats.folded(items, top: 5)
        #expect(f.count == 6)
        #expect(f.last?.name == "Other" && f.last?.count == 15)
        #expect(LibraryStats.folded(Array(items.prefix(6)), top: 5).count == 6)  // never fold a single item
    }

    @Test func bucketQueriesSelectTheBucket() {
        let s = stats()
        let index = SearchFixtures.index
        for b in s.lengthBuckets {
            #expect(index.search(b.query, now: now, autocorrect: false).tracks.count == b.count, "bucket \(b.label)")
        }
        for t in s.qualityTiers {
            guard let q = t.tier.query else { continue }
            #expect(index.search(q, now: now, autocorrect: false).tracks.count == t.count, "tier \(t.tier.rawValue)")
        }
    }
}

@Suite struct ListeningStatsTests {
    // Monday, 14:13 UTC.
    let now = SearchFixtures.now
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        c.locale = Locale(identifier: "en_US")
        return c
    }

    func play(_ id: Int64, _ daysAgo: Double, listened: Double = 200, counted: Bool = true) -> Play {
        Play(trackId: id, startedAt: now.addingTimeInterval(-daysAgo * 86_400), listened: listened, counted: counted)
    }

    var history: [Play] {
        [
            play(1, 0.1, listened: 284), play(1, 0.05, listened: 284),        // Airbag twice today
            play(3, 1, listened: 562), play(3, 2, listened: 562),             // So What yesterday and the day before
            play(5, 0.99, listened: 10, counted: false), play(5, 3, listened: 5, counted: false),  // Love Me Do skipped
            play(6, 200), play(6, 201), play(6, 202),                         // Computer Love, long ago
            play(8, 20),
            play(999, 1),                                                      // a deleted track
        ]
    }

    func stats(_ period: ListeningStats.Period, _ plays: [Play]? = nil) -> ListeningStats {
        ListeningStats(plays: plays ?? history, tracks: SearchFixtures.library, period: period, now: now, calendar: calendar)
    }

    @Test func noHistory() {
        let s = stats(.month, [])
        #expect(!s.hasHistory)
        #expect(s.listens == 0 && s.listened == 0 && s.songs.byPlays.isEmpty)
        #expect(s.neverPlayed == 8)
    }

    @Test func periodTotals() {
        let s = stats(.week)
        #expect(s.listens == 6 && s.plays == 4 && s.skipped == 2)
        #expect(s.listened == 284 * 2 + 562 * 2 + 15)
        #expect(s.dayCount == 7 && s.activeDays == 3)
        #expect(s.previousListened == 0)
        #expect(s.songs.total == 2)
        #expect(s.libraryPlayed == 2.0 / 8.0)
        #expect(s.activity.count == 7 && s.granularity == .day)
        #expect(s.activity.reduce(0) { $0 + $1.listened } == s.listened)
    }

    @Test func rankings() {
        let s = stats(.week)
        // Equal plays rank by listening time.
        #expect(s.songs.byPlays.map(\.name) == ["So What", "Airbag"])
        #expect(s.artists.byPlays.map(\.name) == ["Miles Davis", "Radiohead"])
        // Skipped-only songs show up by time but not by plays.
        #expect(s.artists.byTime.map(\.name).contains("The Beatles"))
        #expect(s.albums.byPlays.first?.name == "Kind of Blue" && s.albums.byPlays.first?.subtitle == "Miles Davis")
        #expect(s.genres.byPlays.first?.name == "Jazz")
        #expect(s.mostSkipped.map(\.name) == ["Love Me Do"])
        #expect(Set(s.newArtists.byPlays.map(\.name)) == ["Miles Davis", "Radiohead"])
    }

    @Test func historyFacts() {
        let s = stats(.week)
        #expect(s.currentStreak == 3 && s.longestStreak == 3)
        #expect(s.forgotten.map(\.name) == ["Computer Love"])
        #expect(s.forgotten.first?.plays == 3)
        #expect(s.neverPlayed == 4)
        #expect(s.firstSong?.name == "Computer Love")
        #expect(s.onRepeat?.song.name == "Airbag" && s.onRepeat?.plays == 2)
        #expect(s.biggestDay?.listened == 572)
        #expect(s.longestSession?.listened == 572 && s.longestSession?.songs == 2)
    }

    @Test func clockFollowsCalendar() {
        let s = stats(.week)
        #expect(s.weekdaySymbols.first == "Mon")
        #expect(s.clock[0][11] == 284 && s.clock[0][13] == 284)  // today's two plays
        #expect(s.peakWeekday == 6)  // Sunday: So What + the skip
        #expect(s.hourTotals.reduce(0, +) == s.listened)
    }

    @Test func allTime() {
        let s = stats(.all)
        #expect(s.listens == 10)
        #expect(s.previousListened == nil)
        #expect(s.newArtists.total == 0)
        #expect(s.granularity == .week)  // 200 days
        #expect(s.dayCount == 203)
        #expect(abs(s.eras.reduce(0) { $0 + $1.listening } - 1) < 1e-9)
        #expect(abs(s.eras.reduce(0) { $0 + $1.library } - 1) < 1e-9)
        #expect(s.eras.first { $0.decade == 1980 }?.listening == 600 / s.listened)
        #expect(stats(.year).granularity == .week)
        // A day of history still charts a week.
        let today = stats(.all, [play(1, 0.1)])
        #expect(today.dayCount == 1 && today.activity.count == 7)
    }

    @Test func playsRoundTripThroughDatabase() throws {
        let db = try Database(path: ":memory:")
        let a = try db.insertTrack(SearchFixtures.library[0])
        try db.recordPlay(trackId: a.id, startedAt: now, listened: 20, counted: false)
        try db.recordPlay(trackId: a.id, startedAt: now.addingTimeInterval(-60), listened: 200, counted: true)
        #expect(try db.plays() == [Play(trackId: a.id, startedAt: now.addingTimeInterval(-60), listened: 200, counted: true),
                                   Play(trackId: a.id, startedAt: now, listened: 20, counted: false)])
    }
}
