import Foundation
import MusicLibraryGlance
import Testing
@testable import MusicLibraryCore

@Suite struct GlanceTests {
    let now = SearchFixtures.now
    let tracks = SearchFixtures.library
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func play(_ id: Int64, daysAgo: Double, listened: Double = 200, counted: Bool = true) -> Play {
        Play(trackId: id, startedAt: now.addingTimeInterval(-daysAgo * 86_400), listened: listened, counted: counted)
    }

    var history: [Play] {
        [play(1, daysAgo: 0.1), play(1, daysAgo: 1), play(2, daysAgo: 1.2), play(3, daysAgo: 2, listened: 562),
         play(5, daysAgo: 20), play(5, daysAgo: 21, listened: 30, counted: false),
         // Played a lot long ago: a forgotten favorite.
         play(6, daysAgo: 200), play(6, daysAgo: 210), play(6, daysAgo: 220), play(6, daysAgo: 230)]
    }

    func build(playing: Glance.Playing? = nil, purchases: [String: AlbumPurchase] = [:]) -> (glance: Glance, covers: [String: Track]) {
        Glance.build(tracks: tracks, present: [1, 2, 5], plays: history, likedDates: [3: now, 99: now], purchases: purchases,
                     playTotals: [1: PlayTotal(plays: 2, listened: 400)], playing: playing, currencyCode: "EUR",
                     now: now, calendar: calendar)
    }

    @Test func libraryCounts() {
        let g = build().glance
        #expect(g.library.songs == 8)
        #expect(g.library.albums == 6)
        #expect(g.library.songsOnPhone == 3)
        #expect(g.library.albumsOnPhone == 2)
        // Likes for songs no longer in the library don't count.
        #expect(g.library.likedSongs == 1)
        #expect(g.library.recentlyAdded.first?.title == "Unknown Album")
        #expect(g.library.recentlyAdded.map(\.title).prefix(3) == ["Unknown Album", "OK Computer", "Hits 2020"])
        #expect(g.library.recentlyAdded.first { $0.title == "OK Computer" }?.playable == true)
        #expect(g.library.recentlyAdded.first { $0.title == "Kind of Blue" }?.playable == false)
        #expect(g.currencyCode == "EUR")
    }

    @Test func listening() {
        let g = build().glance
        #expect(g.week.days == 7 && g.month.days == 30)
        #expect(g.week.plays == 4)
        #expect(g.week.listened == 200 + 200 + 200 + 562)
        #expect(g.week.topSongs.first?.item.title == "Airbag")
        #expect(g.week.topSongs.first?.plays == 2)
        #expect(g.week.topSongs.first?.item.playable == true)
        #expect(g.week.topArtists.first?.item == "Radiohead")
        #expect(g.week.topAlbums.first?.item.title == "OK Computer")
        #expect(g.week.daily.count == 7)
        #expect(g.week.daily.reduce(0) { $0 + $1.listened } == g.week.listened)
        #expect(g.week.currentStreak == 3)
        #expect(g.month.plays == 5)
        #expect(g.month.daily.count == 30)
        #expect(g.month.topArtists.map(\.item).contains("The Beatles"))
        #expect(g.rediscover.map(\.item.title) == ["Computer Love"])
        #expect(g.rediscover.first?.plays == 4)
        #expect(g.rediscover.first?.lastPlayed == now.addingTimeInterval(-200 * 86_400))
    }

    @Test func ownedAlbums() {
        let ok = SearchIndex.albumKey(album: "OK Computer", artist: "Radiohead")
        let blue = SearchIndex.albumKey(album: "Kind of Blue", artist: "Miles Davis")
        let comp = SearchIndex.albumKey(album: "Computer World", artist: "Kraftwerk")
        let g = build(purchases: [
            ok: AlbumPurchase(album: "OK Computer", artist: "Radiohead", purchasedOn: PurchaseDay(year: 2026, month: 9, day: 1), price: 12.5),
            blue: AlbumPurchase(album: "Kind of Blue", artist: "Miles Davis", purchasedOn: PurchaseDay(year: 1999, month: 2, day: 3), price: 9),
            comp: AlbumPurchase(album: "Computer World", artist: "Kraftwerk"),
        ]).glance
        #expect(g.owned.ownedCount == 3)
        #expect(g.owned.libraryAlbumCount == 6)
        #expect(g.owned.boughtThisYear == 1)
        #expect(g.owned.spentThisYear == 12.5)
        #expect(g.owned.totalSpent == 21.5)
        // Dated purchases only, latest first.
        #expect(g.owned.recent.map(\.album.title) == ["OK Computer", "Kind of Blue"])
        #expect(g.owned.recent.first?.purchasedOn == "2026-09-01")
        #expect(g.owned.recent.first?.plays == 2)
        let day = g.owned.recent.first?.purchaseDate(calendar: calendar)
        #expect(day.map { calendar.component(.day, from: $0) } == 1)
    }

    @Test func nowPlaying() {
        let g = build(playing: Glance.Playing(track: tracks[2], isPlaying: true, position: 60, duration: 562, next: tracks[3])).glance
        let p = try! #require(g.nowPlaying)
        #expect(p.song.title == "So What")
        #expect(p.liked)
        #expect(!p.song.playable)
        #expect(p.next?.title == "Blue in Green")
        #expect(p.startDate == now.addingTimeInterval(-60))
        #expect(p.position(at: now.addingTimeInterval(10)) == 70)
        #expect(p.position(at: now.addingTimeInterval(10_000)) == 562)
        var paused = p
        paused.isPlaying = false
        #expect(paused.position(at: now.addingTimeInterval(10)) == 60)
    }

    @Test func nowPlayingAlone() {
        let playing = Glance.Playing(track: tracks[2], isPlaying: true, position: 60, duration: 562, next: tracks[0])
        let full = build(playing: playing).glance.nowPlaying
        let (alone, covers) = Glance.nowPlaying(playing, present: [1, 2, 5], likedDates: [3: now], now: now)
        #expect(alone == full)
        #expect(Set(covers.keys) == Set([alone?.song.cover, alone?.next?.cover].compactMap { $0 }))
        #expect(Glance.nowPlaying(nil, present: [], likedDates: [:]).nowPlaying == nil)
    }

    @Test func coversAreTheAlbumsShown() {
        let (g, covers) = build(playing: Glance.Playing(track: tracks[5], isPlaying: false, position: 0, duration: 435))
        #expect(Set(covers.keys) == g.coverNames)
        let name = Glance.coverName(albumKey: SearchIndex.albumKey(album: "OK Computer", artist: "Radiohead"))
        #expect(covers[name]?.id == 1)  // the album's first track
        #expect(g.nowPlaying?.song.cover == Glance.coverName(albumKey: SearchIndex.albumKey(album: "Computer World", artist: "Kraftwerk")))
    }

    @Test func coverNames() {
        let name = Glance.coverName(albumKey: "radiohead\u{1}ok computer")
        #expect(name == Glance.coverName(albumKey: "radiohead\u{1}ok computer"))
        #expect(name != Glance.coverName(albumKey: "radiohead\u{1}kid a"))
        #expect(Glance.isCoverName(name))
        for bad in ["../glance.json", "c.jpg", "cABC.jpg", "c12/34.jpg", "glance.json", "c0123456789abcdef0.jpg"] {
            #expect(!Glance.isCoverName(bad))
        }
        let store = GlanceStore(directory: URL(fileURLWithPath: "/tmp/x"))
        #expect(store.coverURL("../../etc/passwd") == nil)
    }

    @Test func storeRoundTripAndPrune() throws {
        let dir = try TestSupport.tempDir()
        let store = GlanceStore(directory: dir.appendingPathComponent("Glance"))
        #expect(store.read() == nil)
        let (g, _) = build(purchases: [SearchIndex.albumKey(album: "OK Computer", artist: "Radiohead"):
                                        AlbumPurchase(album: "OK Computer", artist: "Radiohead", purchasedOn: PurchaseDay(year: 2026, month: 1, day: 2), price: Decimal(string: "12.99"))])
        try store.write(g)
        let back = try #require(store.read())
        #expect(back == g)
        #expect(back.owned.recent.first?.price == Decimal(string: "12.99"))

        let keep = Glance.coverName(albumKey: "a"), drop = Glance.coverName(albumKey: "b")
        try store.saveCover(Data([1]), name: keep)
        try store.saveCover(Data([2]), name: drop)
        #expect(throws: (any Error).self) { try store.saveCover(Data([3]), name: "../x.jpg") }
        store.pruneCovers(keeping: [keep])
        #expect(store.hasCover(keep) && !store.hasCover(drop))
        #expect(store.read() != nil)  // the summary itself is never pruned
    }

    @Test func rejectsOtherVersionsAndJunk() throws {
        var g = Glance.empty(at: now)
        #expect(GlanceStore.decode(try GlanceStore.encode(g)) == g)
        g.version = Glance.currentVersion + 1
        #expect(GlanceStore.decode(try GlanceStore.encode(g)) == nil)
        #expect(GlanceStore.decode(Data("{}".utf8)) == nil)
    }

    @Test func sameContentIgnoresTheClock() {
        let a = build(playing: Glance.Playing(track: tracks[0], isPlaying: true, position: 10, duration: 284)).glance
        var b = a
        b.generatedAt = now.addingTimeInterval(30)
        b.nowPlaying?.updatedAt = now.addingTimeInterval(30)
        b.nowPlaying?.position = 40
        #expect(a.sameContent(as: b))
        b.nowPlaying?.position = 100  // a seek
        #expect(!a.sameContent(as: b))
        var c = a
        c.nowPlaying?.isPlaying = false
        #expect(!a.sameContent(as: c))
    }

    @Test func links() {
        let links: [GlanceLink] = [.nowPlaying, .library, .insights(.owned), .album(key: "miles davis\u{1}kind of blue & more")]
        for link in links { #expect(GlanceLink(url: link.url) == link) }
        #expect(GlanceLink(url: URL(string: "musiclibrary://insights")!) == .insights(.listening))
        #expect(GlanceLink(url: URL(string: "musiclibrary://album")!) == nil)
        #expect(GlanceLink(url: URL(string: "https://example.com/album?key=x")!) == nil)
        #expect(GlanceLink(url: URL(string: "musiclibrary://elsewhere")!) == nil)
    }

    @Test func commandsRoundTrip() {
        let commands: [GlanceCommand] = [.playPause, .next, .previous, .toggleLike, .playAlbum(key: "a\u{1}b"), .playSong(id: 42), .shuffleLiked, .shuffleAll]
        for c in commands {
            #expect(GlanceMessage.decode(GlanceCommand.self, from: GlanceMessage.encode(c)) == c)
        }
        #expect(GlanceMessage.decode(GlanceCommand.self, from: "playPause") == nil)
    }

    @Test func formatting() {
        #expect(GlanceFormat.listened(0) == "0m")
        #expect(GlanceFormat.listened(42) == "42s")
        #expect(GlanceFormat.listened(35 * 60 + 10) == "35m")
        #expect(GlanceFormat.listened(4 * 3600 + 12 * 60) == "4h 12m")
        #expect(GlanceFormat.listened(3 * 3600) == "3h")
        #expect(GlanceFormat.listened(150 * 3600 + 60) == "150h")
        #expect(GlanceFormat.change(0.123) == "+12%")
        #expect(GlanceFormat.change(-0.3) == "−30%")
        #expect(GlanceFormat.count(1, "album") == "1 album")
        #expect(GlanceFormat.count(1200, "album") == "\(1200.formatted()) albums")
    }
}
