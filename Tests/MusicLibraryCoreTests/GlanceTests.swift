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

// MARK: Collection

extension GlanceTests {
    static let okKey = SearchIndex.albumKey(album: "OK Computer", artist: "Radiohead")
    static let blueKey = SearchIndex.albumKey(album: "Kind of Blue", artist: "Miles Davis")

    func day(_ y: Int, _ m: Int, _ d: Int) -> PurchaseDay { PurchaseDay(year: y, month: m, day: d)! }

    func copy(_ id: String, _ medium: CollectionMedium, _ number: Int? = nil, album: String, artist: String, day: PurchaseDay? = nil,
              price: Decimal? = nil, cover: String? = nil) -> CollectionItem {
        var i = CollectionItem(id: id, medium: medium, album: album, artist: artist, now: Date(timeIntervalSince1970: 0))
        i.stickerNumber = number
        i.purchasedOn = day
        i.price = price
        i.coverFile = cover
        return i
    }

    /// OK Computer on CD and vinyl, Kind of Blue on vinyl only, two trackless items and songs bought of Computer World.
    var collection: MusicCollection {
        MusicCollection(items: [
            copy("ok-cd", .cd, 3, album: "OK Computer", artist: "Radiohead", day: day(2026, 9, 1), price: 12.5),
            copy("ok-lp", .vinyl, 1, album: "OK Computer", artist: "Radiohead", day: day(2025, 1, 10), price: 30),
            copy("blue-lp", .vinyl, 4, album: "Kind of Blue", artist: "Miles Davis", day: day(2026, 3, 1), price: 25),
            copy("ril-lp", .vinyl, 2, album: "Remain in Light", artist: "Talking Heads", day: day(2026, 9, 10), price: 20,
                 cover: "ril-lp-0000abcd.jpg"),
            copy("train-cd", .cd, 4, album: "Blue Train", artist: "John Coltrane", price: 10),
            copy("dup-cd", .cd, 4, album: "Giant Steps", artist: "John Coltrane"),
        ], songPurchases: [6: TrackPurchase(purchasedOn: day(2026, 2, 2), price: Decimal(string: "1.29"))], tracks: tracks)
    }

    func build(collection: MusicCollection) -> (glance: Glance, covers: [String: GlanceCoverSource]) {
        Glance.build(tracks: tracks, present: [1, 2, 5], plays: history, likedDates: [3: now], collection: collection,
                     playTotals: [1: PlayTotal(plays: 2, listened: 400), 3: PlayTotal(plays: 5, listened: 900)], playing: nil,
                     currencyCode: "USD", now: now, calendar: calendar)
    }

    @Test func ownedKeepsItsMeaningWithACollection() {
        let g = build(collection: collection).glance
        // Library albums with songs only, one per album: the trackless records and CDs aren't counted.
        #expect(g.owned.ownedCount == 3)
        #expect(g.owned.libraryAlbumCount == 6)
        #expect(g.owned.ownedCount <= g.owned.libraryAlbumCount)
        #expect(g.owned.recent.map(\.album.title) == ["OK Computer", "Kind of Blue", "Computer World"])
        // OK Computer's latest dated copy: the CD, with its own price (never a sum of copies).
        let ok = try! #require(g.owned.recent.first)
        #expect(ok.itemID == "ok-cd" && ok.id == "ok-cd")
        #expect(ok.purchasedOn == "2026-09-01" && ok.price == 12.5 && ok.plays == 2)
        #expect(g.owned.recent[1].plays == 5)
        #expect(g.owned.recent[2].itemID == CollectionItem.songsID(albumKey: SearchIndex.albumKey(album: "Computer World", artist: "Kraftwerk")))
        // Spending covers every copy, trackless ones included.
        #expect(g.owned.totalSpent == 12.5 + 30 + 25 + 20 + 10 + Decimal(string: "1.29")!)
        #expect(g.owned.boughtThisYear == 4)
        #expect(g.owned.spentThisYear == 12.5 + 25 + 20 + Decimal(string: "1.29")!)
    }

    @Test func collectionSummary() throws {
        let (g, covers) = build(collection: collection)
        let c = try #require(g.collection)
        #expect(c.items == 7 && c.cds == 3 && c.vinyl == 3 && c.downloads == 1)
        // Kind of Blue's record has its music from elsewhere; Remain in Light has none.
        #expect(c.toRip == 2 && c.vinylToDigitize == 1)
        #expect(c.nextCD == 5 && c.nextVinyl == 5)
        let recent = try #require(c.recent)
        #expect(recent.count == 7)
        #expect(recent.map(\.id).prefix(5) == ["ril-lp", "ok-cd", "blue-lp",
                                                CollectionItem.songsID(albumKey: SearchIndex.albumKey(album: "Computer World", artist: "Kraftwerk")),
                                                "ok-lp"])
        #expect(c.toRipList?.map(\.id) == ["dup-cd", "train-cd"])

        let ril = recent[0], ok = recent[1]
        #expect(ril.medium == "vinyl" && ril.sticker == 2 && ril.stickerText == "Vinyl #2")
        #expect(ril.digitized == false && ril.playable == false && ril.purchasedOn == "2026-09-10" && ril.price == 20)
        #expect(ok.stickerText == "CD #3" && ok.digitized == true && ok.playable == true && ok.albumKey == Self.okKey)
        #expect(recent.allSatisfy { $0.addedOn.map { $0.count == 10 } ?? false })  // "Added …" without a purchase day
        #expect(ok.cover == Glance.coverName(albumKey: Self.okKey))
        #expect(c.toRipList?.first?.cover == nil)  // trackless, no cover of its own

        // Its own cover comes from its file; the album's from a track.
        let rilCover = try #require(ril.cover)
        #expect(Glance.isCoverName(rilCover) && rilCover != Glance.coverName(albumKey: ril.albumKey))
        #expect(covers[rilCover] == .file(relativePath: "Music/Collection Covers/ril-lp-0000abcd.jpg"))
        #expect(covers[Glance.coverName(albumKey: Self.okKey)] == .track(tracks[0]))
        #expect(Set(covers.keys) == g.coverNames)
        #expect(g.coverNames.contains(rilCover))

        // A new cover file is a new thumbnail name.
        var items = collection.items.filter { $0.origin == .stored }
        items[items.firstIndex { $0.id == "ril-lp" }!].coverFile = "ril-lp-0000beef.jpg"
        let changed = build(collection: MusicCollection(items: items, songPurchases: [:], tracks: tracks)).glance
        #expect(changed.collection?.recent?.first?.cover != rilCover)
    }

    @Test func purchasesOverloadIsUnchanged() {
        let (g, covers) = build(purchases: [Self.okKey: AlbumPurchase(album: "OK Computer", artist: "Radiohead",
                                                                      purchasedOn: day(2026, 9, 1), price: 12.5)])
        #expect(g.collection == nil)
        #expect(g.owned.ownedCount == 1 && g.owned.recent.first?.itemID == nil && g.owned.recent.first?.id == Self.okKey)
        #expect(Set(covers.keys) == g.coverNames)
    }

    @Test func olderPayloadsDecode() throws {
        let g = build(collection: collection).glance
        // As a phone before the collection writes it: no `collection`, no `itemID`.
        var json = try #require(try JSONSerialization.jsonObject(with: GlanceStore.encode(g)) as? [String: Any])
        #expect(json["collection"] != nil)
        json["collection"] = nil
        var owned = try #require(json["owned"] as? [String: Any])
        owned["recent"] = (owned["recent"] as? [[String: Any]])?.map { var p = $0; p["itemID"] = nil; return p }
        json["owned"] = owned
        let old = try #require(GlanceStore.decode(try JSONSerialization.data(withJSONObject: json)))
        #expect(old.collection == nil)
        #expect(old.owned.recent.first?.id == Self.okKey)
        #expect(old.owned.ownedCount == g.owned.ownedCount)
    }

    @Test func newerPayloadsWithMoreKeysDecode() throws {
        let g = build(collection: collection).glance
        var json = try #require(try JSONSerialization.jsonObject(with: GlanceStore.encode(g)) as? [String: Any])
        json["somethingNew"] = ["a": 1]
        var c = try #require(json["collection"] as? [String: Any])
        c["shelves"] = 3
        c["recent"] = (c["recent"] as? [[String: Any]])?.enumerated().map { i, item in
            var item = item
            item["condition"] = "mint"
            if i == 0 { item["medium"] = "cassette" }
            return item
        }
        json["collection"] = c
        let back = try #require(GlanceStore.decode(try JSONSerialization.data(withJSONObject: json)))
        // (JSONSerialization turns prices into doubles, so they're not compared here.)
        #expect(back.owned.recent.map(\.id) == g.owned.recent.map(\.id) && back.owned.ownedCount == g.owned.ownedCount)
        let first = try #require(back.collection?.recent?.first)
        #expect(first.medium == "cassette" && first.stickerText == "2")
        #expect(back.collection?.recent?.dropFirst().map(\.id) == g.collection?.recent?.dropFirst().map(\.id))
        #expect(back.collection?.nextVinyl == 5)
        #expect(GlanceStore.decode(try GlanceStore.encode(g)) == g)
    }

    // MARK: Shelf

    @Test func shelfIndex() throws {
        let (shelf, covers) = Glance.shelf(collection: collection, now: now)
        #expect(shelf.version == GlanceShelf.currentVersion)
        // Labeled items only (not the download), CDs then records, by number.
        #expect(shelf.entries.map { "\($0.s)\($0.n)" } == ["cd3", "cd4", "cd4", "vinyl1", "vinyl2", "vinyl4"])
        #expect(shelf.entries(series: "cd", number: 4).map(\.i) == ["dup-cd", "train-cd"])
        #expect(shelf.entries(series: "vinyl", number: 3).isEmpty)
        let n = shelf.neighbors(series: "vinyl", number: 3)
        #expect(n.previous?.i == "ril-lp" && n.next?.i == "blue-lp")
        #expect(shelf.neighbors(series: "cd", number: 3).previous == nil)
        #expect(shelf.neighbors(series: "cd", number: 3).next?.n == 4)
        let ok = try #require(shelf.entries(series: "cd", number: 3).first)
        #expect(ok.t == "OK Computer" && ok.a == "Radiohead" && ok.d == true && ok.stickerText == "CD #3")
        #expect(shelf.entries(series: "vinyl", number: 2).first?.d == false)
        #expect(shelf.coverNames == Set(covers.keys))
        #expect(shelf.coverNames.count == 3)  // OK Computer (both copies share it), Kind of Blue, Remain in Light's own

        let store = GlanceStore(directory: try TestSupport.tempDir().appendingPathComponent("Glance"))
        #expect(store.readShelf() == nil)
        try store.writeShelf(shelf)
        #expect(store.shelfURL.lastPathComponent == "shelf.json")
        #expect(store.readShelf() == shelf)

        // The hash follows the entries, not the clock.
        #expect(Glance.shelf(collection: collection, now: now.addingTimeInterval(60)).shelf.contentHash == shelf.contentHash)
        var other = shelf
        other.entries[0].d = false
        #expect(other.contentHash != shelf.contentHash)
        #expect(shelf.contentHash.count == 16)
    }

    @Test func shelfTitlesAreCut() {
        let long = String(repeating: "x", count: 500)
        let shelf = Glance.shelf(collection: MusicCollection(items: [copy("a", .cd, 1, album: long, artist: long)], songPurchases: [:], tracks: [])).shelf
        #expect(shelf.entries.first?.t.count == GlanceShelf.maxText && shelf.entries.first?.a.count == GlanceShelf.maxText)
        #expect(shelf.entries.first?.c == nil)
    }

    @Test func shelfFromTheOtherDeviceIsChecked() throws {
        let good = GlanceShelf.Entry(id: "a", series: "cd", number: 1, title: "A", artist: "B", cover: Glance.coverName(albumKey: "k"))
        func encoded(_ entries: [GlanceShelf.Entry], version: Int = GlanceShelf.currentVersion) throws -> Data {
            var s = GlanceShelf(generatedAt: now, entries: entries)
            s.version = version
            return try GlanceStore.encodeShelf(s)
        }
        #expect(GlanceStore.decodeShelf(try encoded([good]))?.entries == [good])
        #expect(GlanceStore.decodeShelf(try encoded([good], version: 2)) == nil)
        #expect(GlanceStore.decodeShelf(Data("{}".utf8)) == nil)
        #expect(GlanceStore.decodeShelf(Data(repeating: 0x20, count: GlanceShelf.maxBytes + 1)) == nil)
        let many = (1...(GlanceShelf.maxEntries + 1)).map { GlanceShelf.Entry(id: "i\($0)", series: "cd", number: $0, title: "", artist: "") }
        #expect(GlanceStore.decodeShelf(try encoded(many)) == nil)

        var badCover = good; badCover.i = "b"; badCover.c = "../../glance.json"
        var badSeries = good; badSeries.i = "c"; badSeries.s = "tape"
        var badNumber = good; badNumber.i = "d"; badNumber.n = 0
        var badID = good; badID.i = "../X"
        var noCover = good; noCover.i = "e"; noCover.c = nil; noCover.s = "vinyl"
        let back = try #require(GlanceStore.decodeShelf(try encoded([noCover, badCover, badSeries, badNumber, badID, good])))
        #expect(back.entries.map(\.i) == ["a", "e"])  // put back in shelf order too

        let store = GlanceStore(directory: try TestSupport.tempDir())
        #expect(throws: (any Error).self) {
            try store.writeShelf(GlanceShelf(generatedAt: now, entries: (1...20_000).map {
                GlanceShelf.Entry(id: "item-\($0)", series: "cd", number: $0, title: String(repeating: "é", count: 80), artist: "")
            }))
        }
    }

    @Test func shelfCoversLookedUpStayWhenPruning() throws {
        let store = GlanceStore(directory: try TestSupport.tempDir().appendingPathComponent("Glance"))
        let names = (0..<45).map { Glance.coverName(albumKey: "shelf\($0)") }
        for name in names {
            try store.saveCover(Data([1]), name: name)
            store.rememberShelfCover(name)
        }
        store.rememberShelfCover("../evil.jpg")
        #expect(store.shelfCovers.count == GlanceStore.shelfCoverLimit)
        #expect(store.shelfCovers.first == names.last)
        let summary = Glance.coverName(albumKey: "summary")
        try store.saveCover(Data([2]), name: summary)
        store.pruneCovers(keeping: [summary])
        #expect(store.hasCover(summary))
        #expect(names.suffix(40).allSatisfy(store.hasCover))
        #expect(!names.prefix(5).contains(where: store.hasCover))
        // Looking one up again keeps it at the front.
        store.rememberShelfCover(names[10])
        #expect(store.shelfCovers.first == names[10] && store.shelfCovers.count == GlanceStore.shelfCoverLimit)
    }

    @Test func itemLinks() {
        let link = GlanceLink.item(id: "3f2a-item")
        #expect(link == .album(key: "item:3f2a-item"))
        #expect(GlanceLink(url: link.url) == link)
        #expect(GlanceLink(url: link.url)?.itemID == "3f2a-item")
        for other: GlanceLink in [.nowPlaying, .library, .insights(.owned), .album(key: Self.okKey), .album(key: "item:")] {
            #expect(other.itemID == nil)
            #expect(GlanceLink(url: other.url) == other)
        }
        #expect(GlanceLink.insights(.owned).url.absoluteString == "musiclibrary://insights?pane=owned")
        #expect(GlanceLink.album(key: "a").url.absoluteString == "musiclibrary://album?key=a")
    }

    @Test func stickerText() {
        #expect(GlanceFormat.sticker(medium: "cd", number: 12) == "CD #12")
        #expect(GlanceFormat.sticker(medium: "Vinyl", number: 12) == "Vinyl #12")
        #expect(GlanceFormat.sticker(medium: "cassette", number: 12) == "12")
        #expect(Glance.Collection.Item(id: "a", albumKey: "k", title: "T", artist: "A", medium: "cd").stickerText == nil)
    }
}
