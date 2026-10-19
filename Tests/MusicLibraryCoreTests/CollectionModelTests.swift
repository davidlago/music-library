import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct CollectionModelTests {
    let releaseA = "11111111-1111-1111-1111-111111111111"
    let releaseB = "22222222-2222-2222-2222-222222222222"
    let groupA = "33333333-3333-3333-3333-333333333333"

    func item(_ id: String, _ medium: CollectionMedium, _ number: Int? = nil, album: String = "Album", artist: String = "Artist",
              key: String? = nil, source: DigitalSource? = nil, created: TimeInterval = 0) -> CollectionItem {
        var i = CollectionItem(id: id, medium: medium, album: album, artist: artist, albumKey: key, now: Date(timeIntervalSince1970: created))
        i.stickerNumber = number
        i.digitalSource = source
        return i
    }

    func track(_ id: Int64, album: String = "Album", artist: String = "Artist", release: String? = nil, group: String = "",
               year: Int? = nil, trackNo: Int? = nil, trackTotal: Int? = nil) -> Track {
        var m = TrackMetadata(title: "T\(id)", artist: artist, album: album, year: year, trackNo: trackNo ?? Int(id), trackTotal: trackTotal,
                              mbReleaseId: release)
        m.extended.mbReleaseGroupId = group
        return Track(id: id, path: "Music/\(artist)/\(album)/\(id).flac", metadata: m, duration: 100, format: "flac", sha256: "\(id)",
                     addedAt: Date(timeIntervalSince1970: Double(id)))
    }

    // MARK: Labels

    /// Songs imported as a record's digital copy put what they cost on it only where it has nothing of its own, and
    /// say so only when it went there (else each song keeps its own purchase, so nothing typed is lost).
    @Test func songsPurchaseGoesOnTheItemOnlyWhereItHasNone() {
        let day = PurchaseDay(year: 2025, month: 3, day: 1)!, other = PurchaseDay(year: 2020, month: 1, day: 1)!
        var dated = item("v4", .vinyl, 4)
        dated.purchasedOn = other
        // A date but no price: the price goes there, its date stays.
        let onDated = dated.takeSongsPurchase(price: 25, day: day)
        #expect(onDated && dated.price == 25 && dated.purchasedOn == other)
        // A price already: nothing replaced, and the songs keep theirs.
        var priced = item("v5", .vinyl, 5)
        priced.price = 30
        let onPriced = priced.takeSongsPurchase(price: 25, day: day)
        #expect(!onPriced && priced.price == 30 && priced.purchasedOn == day)
        // Blank: both go there.
        var blank = item("v6", .vinyl, 6)
        let onBlank = blank.takeSongsPurchase(price: 25, day: day)
        #expect(onBlank && blank.price == 25 && blank.purchasedOn == day)
        // No price typed: on the item when its date is the songs' (or was blank), not when it's another.
        var noPrice = item("v7", .vinyl, 7)
        noPrice.purchasedOn = other
        let otherDay = noPrice.takeSongsPurchase(price: nil, day: day)
        let sameDay = noPrice.takeSongsPurchase(price: nil, day: other)
        let noDay = noPrice.takeSongsPurchase(price: nil, day: nil)
        #expect(!otherDay && noPrice.purchasedOn == other && sameDay && noDay)
    }

    @Test func stickersParseInEveryForm() {
        for (text, number) in [("12", 12), ("#12", 12), (" # 12 ", 12), ("9999999", 9_999_999)] {
            let p = Sticker.parse(text)
            #expect(p?.series == nil && p?.number == number, "\(text)")
        }
        for text in ["cd12", "cd 12", "CD #12", "cd#12", "Cd # 12"] {
            let p = Sticker.parse(text)
            #expect(p?.series == .cd && p?.number == 12, "\(text)")
        }
        for text in ["vinyl 12", "vinyl#12", "v12", "lp12", "lp #12", "record 12", "Vinyl #12", "V 12"] {
            let p = Sticker.parse(text)
            #expect(p?.series == .vinyl && p?.number == 12, "\(text)")
        }
        for bad in ["", "0", "#0", "cd", "12a", "cd-12", "10000000", "12345678", "dvd 12", "#", "1 2", "-3", "vinylx12", "cd 12 13"] {
            #expect(Sticker.parse(bad) == nil, "\(bad)")
        }
    }

    /// Find by Label's number field: a phone set to Arabic-Indic numerals types those digits, which `Int(String)` can't
    /// read, so the field showed nothing.
    @Test func typedNumbersReadDigitsInAnyScript() {
        for (text, number) in [("12", 12), ("١٢", 12), ("１２", 12), ("۱۲", 12), ("12١", 121), ("#1 2", 12), ("0012", 12),
                               ("12345678", 1_234_567)] {
            #expect(Sticker.typedNumber(text) == number, "\(text)")
        }
        for none in ["", "#", "abc", "½", "Ⅻ"] {
            #expect(Sticker.typedNumber(none) == nil, "\(none)")
        }
        #expect(Sticker.typedNumber("0") == 0)
    }

    @Test func stickersAlwaysShowTheirSeries() throws {
        let cd = try #require(Sticker(series: .cd, number: 12))
        let vinyl = try #require(Sticker(series: .vinyl, number: 12))
        #expect(cd.text == "CD #12" && vinyl.text == "Vinyl #12")
        #expect(cd.spoken == "CD label 12" && vinyl.spoken == "Vinyl label 12")
        #expect(cd.token == "sticker:cd12" && vinyl.token == "sticker:vinyl12")
        #expect(cd != vinyl && cd < vinyl)
        #expect(Sticker.parse(vinyl.text)?.series == .vinyl && Sticker.parse(cd.text)?.series == .cd)
        #expect(Sticker(series: .cd, number: 0) == nil && Sticker(series: .cd, number: Sticker.maxNumber + 1) == nil)
        #expect(Sticker.maxNumber == 9_999_999)
    }

    @Test func mediaRoundTripAndUnknownOnesReadAsOther() {
        for m in CollectionMedium.known { #expect(CollectionMedium(rawValue: m.rawValue) == m) }
        #expect(CollectionMedium(rawValue: " Vinyl ") == .vinyl)
        #expect(CollectionMedium(rawValue: "cassette") == .other("cassette"))
        #expect(CollectionMedium(rawValue: "cassette")?.rawValue == "cassette")
        for bad in ["", "   ", "8-track!", "a/b", String(repeating: "x", count: 25), "café"] {
            #expect(CollectionMedium(rawValue: bad) == nil, "\(bad)")
        }
        #expect(CollectionMedium.cd.series == .cd && CollectionMedium.vinyl.series == .vinyl)
        #expect(CollectionMedium.download.series == nil && CollectionMedium.other("x").series == nil)
        #expect(CollectionMedium.other("x").isPhysical && !CollectionMedium.download.isPhysical)
        #expect([CollectionMedium.download, .other("x"), .vinyl, .cd].sorted() == [.cd, .vinyl, .other("x"), .download])
        #expect(StickerSeries.cd.medium == .cd && StickerSeries.vinyl.name == "Vinyl")
    }

    @Test func mediaFromMusicBrainzFormats() {
        #expect(CollectionMedium(musicBrainzFormats: ["12\" Vinyl", "12\" Vinyl"]) == .vinyl)
        #expect(CollectionMedium(musicBrainzFormats: ["7\""]) == .vinyl)
        #expect(CollectionMedium(musicBrainzFormats: ["CD", "12\" Vinyl"]) == .vinyl)
        for cd in ["CD", "SACD", "Hybrid SACD", "HDCD", "SHM-CD", "Blu-spec CD", "Enhanced CD", "CD-R"] {
            #expect(CollectionMedium(musicBrainzFormats: [cd]) == .cd, "\(cd)")
        }
        #expect(CollectionMedium(musicBrainzFormats: ["Digital Media"]) == .download)
        #expect(CollectionMedium(musicBrainzFormats: ["Cassette"]) == nil)
        #expect(CollectionMedium(musicBrainzFormats: []) == nil)
    }

    @Test func itemsKeepLabelsWithinTheirSeries() {
        var i = item("a", .cd, 12)
        #expect(i.sticker == Sticker(series: .cd, number: 12))
        i.stickerNumber = 0
        #expect(i.stickerNumber == nil)
        i.stickerNumber = 12
        i.medium = .cd
        #expect(i.stickerNumber == 12)
        i.medium = .vinyl
        #expect(i.stickerNumber == nil, "another series clears the number")
        i.stickerNumber = 5
        i.medium = .download
        #expect(i.stickerNumber == nil)
        i.stickerNumber = 5
        #expect(i.stickerNumber == nil, "downloads have no label")
        i.price = -1
        #expect(i.price == nil)
        #expect(item("x", .other("cassette")).isEditable == false)
        var derived = item("d", .download)
        derived.origin = .songs
        #expect(!derived.isEditable && item("s", .vinyl).isEditable)
        #expect(CollectionItem(medium: .cd, album: "Kind of Blue", artist: "Miles Davis").albumKey
                == SearchIndex.albumKey(album: "Kind of Blue", artist: "Miles Davis"))
        #expect(CollectionItem.isValidID(CollectionItem.newID()))
    }

    @Test func legacyIDsAreDeterministic() {
        let key = SearchIndex.albumKey(album: "Kind of Blue", artist: "Miles Davis")
        let id = CollectionItem.legacyID(albumKey: key)
        #expect(id == CollectionItem.legacyID(albumKey: key))
        #expect(id.hasPrefix("own-") && id.count == 20 && CollectionItem.isValidID(id))
        #expect(CollectionItem.songsID(albumKey: key) == "songs-" + id.dropFirst(4))
        #expect(id != CollectionItem.legacyID(albumKey: key + "x"))
        // FNV-1a 64 test vectors.
        #expect(CollectionItem.fnv1a64Hex("") == "cbf29ce484222325")
        #expect(CollectionItem.fnv1a64Hex("a") == "af63dc4c8601ec8c")
    }

    // MARK: Series

    /// A label at the maximum (a typo older versions accepted) doesn't make the next number one that's taken.
    @Test func nextNumberAtTheMaximumIsTheFirstFree() {
        let max = Sticker.maxNumber
        let c = MusicCollection(items: [item("top", .cd, max), item("one", .cd, 1), item("two", .cd, 2)], songPurchases: [:], tracks: [])
        #expect(c.nextNumber(in: .cd) == 3)
        #expect(c.nextNumber(in: .cd, pending: [3]) == 4)
        #expect(c.nextNumber(in: .vinyl) == 1)
        let alone = MusicCollection(items: [item("top", .cd, max)], songPurchases: [:], tracks: [])
        #expect(alone.nextNumber(in: .cd) == 1 && alone.taken(Sticker(series: .cd, number: 1)!, excluding: nil) == nil)
    }

    /// A phone reconciles in memory on every load: an item made for a key whose legacy id is taken keeps its id.
    @Test func reconcileGivesTheSameIDEveryTime() {
        let key = SearchIndex.albumKey(album: "Album", artist: "Artist")
        // The migrated CD was changed to vinyl; then an older Mac marked the album owned again.
        let vinyl = item(CollectionItem.legacyID(albumKey: key), .vinyl, 4, key: key)
        let row = CollectionLegacy.Row(key: key, purchase: AlbumPurchase(album: "Album", artist: "Artist", price: 5),
                                       updatedAt: Date(timeIntervalSince1970: 100))
        let first = CollectionLegacy.reconcile(items: [vinyl], legacy: [row]).changed
        let second = CollectionLegacy.reconcile(items: [vinyl], legacy: [row]).changed
        #expect(first.count == 1 && first.map(\.id) == second.map(\.id))
        #expect(first.first?.id == CollectionItem.legacyID(albumKey: key + "#2") && first.first?.medium == .cd)
        let third = item(CollectionItem.legacyID(albumKey: key + "#2"), .vinyl, 5, key: key)
        #expect(CollectionLegacy.reconcile(items: [vinyl, third], legacy: [row]).changed.first?.id == CollectionItem.legacyID(albumKey: key + "#3"))
    }

    @Test func seriesAreNumberedApart() {
        let c = MusicCollection(items: [item("c12", .cd, 12, album: "Blue"), item("v12", .vinyl, 12, album: "Rumours"),
                                        item("c3", .cd, 3), item("v1", .vinyl, 1), item("c12b", .cd, 12, album: "Dup")],
                                songPurchases: [:], tracks: [])
        #expect(c.nextNumber(in: .cd) == 13)
        #expect(c.nextNumber(in: .vinyl) == 13)
        #expect(c.nextNumber(in: .cd, pending: [20, -1]) == 21)
        #expect(MusicCollection.empty.nextNumber(in: .vinyl) == 1)
        let cd12 = Sticker(series: .cd, number: 12)!, vinyl12 = Sticker(series: .vinyl, number: 12)!
        #expect(c.items(at: vinyl12).map(\.id) == ["v12"])
        #expect(c.items(at: cd12).map(\.id).sorted() == ["c12", "c12b"])
        #expect(c.items(number: 12).map(\.id).sorted() == ["c12", "c12b", "v12"])
        #expect(c.items(number: 12).last?.id == "v12", "CDs first")
        #expect(c.taken(vinyl12, excluding: "v12") == nil)
        #expect(c.taken(vinyl12, excluding: nil)?.id == "v12")
        #expect(c.taken(cd12, excluding: "c12")?.id == "c12b")
        #expect(c.duplicates(in: .cd).keys.sorted() == [12] && c.duplicates(in: .cd)[12]?.count == 2)
        #expect(c.duplicates(in: .vinyl).isEmpty)
        #expect(c.gaps(in: .cd) == [1...2, 4...11])
        #expect(c.firstGap(in: .cd) == 1)
        #expect(c.gaps(in: .vinyl) == [2...11])
        #expect(MusicCollection(items: [item("a", .cd, 1), item("b", .cd, 2)], songPurchases: [:], tracks: []).firstGap(in: .cd) == nil)
    }

    @Test func neighborsOnTheShelf() {
        let c = MusicCollection(items: [item("c1", .cd, 1), item("c5", .cd, 5), item("c9", .cd, 9), item("v4", .vinyl, 4),
                                        item("u", .cd)], songPurchases: [:], tracks: [])
        var n = c.neighbors(of: Sticker(series: .cd, number: 5)!)
        #expect(n.previous?.id == "c1" && n.next?.id == "c9")
        n = c.neighbors(of: Sticker(series: .cd, number: 4)!)
        #expect(n.previous?.id == "c1" && n.next?.id == "c5", "a free number still has neighbors, in its own series")
        n = c.neighbors(of: Sticker(series: .cd, number: 1)!)
        #expect(n.previous == nil && n.next?.id == "c5")
        n = c.neighbors(of: Sticker(series: .vinyl, number: 4)!)
        #expect(n.previous == nil && n.next == nil)
    }

    // MARK: Digital state

    @Test func everyDigitalState() {
        let key = SearchIndex.albumKey(album: "Album", artist: "Artist")
        let tracks = [track(1), track(2)]
        var partialCD = item("p", .cd, source: .rip)
        partialCD.trackCount = 5
        let items = [item("rip", .cd, 1, source: .rip), item("dl", .download, source: .download), partialCD,
                     item("same", .vinyl, source: .same), item("cdNil", .cd), item("dlNil", .download),
                     item("vNil", .vinyl), item("oNil", .other("cassette"))]
        let c = MusicCollection(items: items, songPurchases: [:], tracks: tracks)
        func state(_ id: String) -> DigitalState? { c.item(id: id).map(c.digitalState) }
        #expect(state("rip") == .digitized(tracks: 2))
        #expect(state("dl") == .digitized(tracks: 2))
        #expect(state("p") == .partial(have: 2, of: 5))
        #expect(state("same") == .otherCopy(tracks: 2, from: "rip"))
        #expect(state("cdNil") == .digitized(tracks: 2))
        #expect(state("dlNil") == .digitized(tracks: 2))
        #expect(state("vNil") == .otherCopy(tracks: 2, from: "rip"))
        #expect(state("oNil") == .otherCopy(tracks: 2, from: "rip"))
        #expect(c.libraryTracks(items[0]).map(\.id) == [1, 2])

        let empty = MusicCollection(items: [item("linked", .cd, source: .rip, created: 1), item("never", .vinyl)], songPurchases: [:], tracks: [])
        #expect(empty.digitalState(empty.item(id: "linked")!) == .missing)
        #expect(empty.digitalState(empty.item(id: "never")!) == .none)
        #expect(DigitalState.missing.needsDigitizing && DigitalState.none.needsDigitizing && !DigitalState.none.hasMusic)
        #expect(DigitalState.otherCopy(tracks: 1, from: nil).hasMusic && !DigitalState.partial(have: 1, of: 2).needsDigitizing)
        #expect(c.copies(albumKey: key).count == items.count)
        // A record whose music came from elsewhere, with nothing to point at.
        let alone = MusicCollection(items: [item("v", .vinyl, source: .same)], songPurchases: [:], tracks: tracks)
        #expect(alone.digitalState(alone.items[0]) == .otherCopy(tracks: 2, from: nil))
    }

    @Test func boughtSongsMakeADownloadNextToACD() throws {
        let key = SearchIndex.albumKey(album: "Album", artist: "Artist")
        let tracks = (1...4).map { track(Int64($0), trackTotal: 10) }
        let songs: [Int64: TrackPurchase] = [
            1: TrackPurchase(purchasedOn: PurchaseDay(year: 2026, month: 5, day: 2), price: Decimal(string: "1.29")),
            2: TrackPurchase(purchasedOn: PurchaseDay(year: 2026, month: 3, day: 9), price: Decimal(string: "0.99")),
        ]
        let c = MusicCollection(items: [item("cd", .cd, 7, source: .rip)], songPurchases: songs, tracks: tracks)
        #expect(c.items.count == 2)
        let derived = try #require(c.item(id: CollectionItem.songsID(albumKey: key)))
        #expect(derived.origin == .songs && !derived.isEditable && derived.medium == .download && derived.digitalSource == .download)
        #expect(derived.price == Decimal(string: "2.28"))
        #expect(derived.purchasedOn == PurchaseDay(year: 2026, month: 3, day: 9))
        #expect(derived.trackCount == 10)
        #expect(c.digitalState(derived) == .partial(have: 2, of: 10))
        #expect(c.copies(albumKey: key).map(\.id) == ["cd", derived.id])
        #expect(c.mark(albumKey: key) == .cd(number: 7, digitized: true, more: 1))
        #expect(c.mark(item: derived) == .download(partial: true, more: 1))

        // A stored album download replaces it; songs without a price make a free one.
        let stored = MusicCollection(items: [item("dl", .download)], songPurchases: songs, tracks: tracks)
        #expect(stored.items.map(\.id) == ["dl"])
        let free = MusicCollection(items: [], songPurchases: [3: TrackPurchase()], tracks: tracks)
        #expect(free.items.count == 1 && free.items[0].price == nil)
        #expect(LegacyOwnership.purchases(of: free)[key] == AlbumPurchase(album: "Album", artist: "Artist", format: .digital))
    }

    @Test func marksPreferTheLowestCDThenRecordsThenDownloads() {
        let key = SearchIndex.albumKey(album: "Album", artist: "Artist")
        let tracks = [track(1)]
        func mark(_ items: [CollectionItem]) -> CopyMark {
            MusicCollection(items: items, songPurchases: [:], tracks: tracks).mark(albumKey: key)
        }
        let all = [item("dl", .download), item("o", .other("cassette")), item("v", .vinyl), item("v9", .vinyl, 9),
                   item("cd", .cd), item("cd8", .cd, 8), item("cd3", .cd, 3)]
        let c = MusicCollection(items: all, songPurchases: [:], tracks: tracks)
        #expect(c.copies(albumKey: key).map(\.id) == ["cd3", "cd8", "cd", "v9", "v", "o", "dl"])
        #expect(mark(all) == .cd(number: 3, digitized: true, more: 6))
        #expect(mark([item("cd", .cd), item("v9", .vinyl, 9)]) == .cd(number: nil, digitized: true, more: 1))
        #expect(mark([item("v", .vinyl), item("v9", .vinyl, 9), item("dl", .download)]) == .vinyl(number: 9, digitized: true, more: 2))
        #expect(mark([item("o", .other("x")), item("dl", .download)]) == .other(more: 1))
        #expect(mark([item("dl", .download)]) == .download(partial: false, more: 0))
        #expect(mark([]) == .notInCollection)
        #expect(MusicCollection(items: [item("v", .vinyl, 2)], songPurchases: [:], tracks: []).mark(albumKey: key)
                == .vinyl(number: 2, digitized: false, more: 0))
        #expect(CopyMark.vinyl(number: 2, digitized: false, more: 0).sticker == Sticker(series: .vinyl, number: 2))
        #expect(CopyMark.download(partial: false, more: 0).sticker == nil)
    }

    // MARK: Lookups

    @Test func matchesPutUndigitizedItemsFirst() {
        let key = SearchIndex.albumKey(album: "Album", artist: "Artist")
        var byRelease = item("rel", .cd, 1, album: "Other", key: "elsewhere", source: .rip, created: 1)
        byRelease.releaseID = releaseA
        var byGroup = item("grp", .cd, 2, album: "G", key: "g", created: 2)
        byGroup.releaseGroupID = groupA
        var byBarcode = item("bar", .cd, 3, album: "B", key: "b", created: 3)
        byBarcode.barcode = "0602547000000"
        let byKey = item("key", .cd, 4, created: 4)
        let vinyl = item("vin", .vinyl, 1, created: 5)
        let c = MusicCollection(items: [byRelease, byGroup, byBarcode, byKey, vinyl], songPurchases: [:], tracks: [])
        // None has a digital copy: the closest match first.
        let found = c.matches(releaseID: releaseA.uppercased(), releaseGroupID: groupA, albumKey: key, barcode: "602547000000", medium: .cd)
        #expect(found.map(\.id) == ["rel", "bar", "key", "grp"])
        #expect(c.matches(releaseID: nil, releaseGroupID: nil, albumKey: key, barcode: nil, medium: nil).map(\.id) == ["key", "vin"])
        #expect(c.matches(releaseID: nil, releaseGroupID: nil, albumKey: key, barcode: nil, medium: .vinyl).map(\.id) == ["vin"])
        #expect(c.matches(releaseID: nil, releaseGroupID: nil, albumKey: nil, barcode: nil, medium: nil).isEmpty)

        // "key" is ripped (its album has tracks), "other" isn't: the one still to rip comes first.
        var other = item("other", .cd, 9, key: "nothing", created: 9)
        other.releaseID = releaseB
        let mixed = MusicCollection(items: [byKey, other], songPurchases: [:], tracks: [track(1)])
        #expect(mixed.matches(releaseID: releaseB, releaseGroupID: nil, albumKey: key, barcode: nil, medium: .cd).map(\.id) == ["other", "key"])
    }

    @Test func syncItemsAreTheLinkedAlbumsInScope() {
        let tracks = [track(1, album: "Ripped"), track(2, album: "Needle"), track(3, album: "Bought")]
        let items = [item("cd", .cd, 1, album: "Ripped", source: .rip), item("unripped", .cd, 2, album: "Never"),
                     item("lp", .vinyl, 1, album: "Needle", source: .rip), item("dl", .download, album: "Bought"),
                     item("cd2", .cd, 3, album: "Ripped", source: .rip)]
        let c = MusicCollection(items: items, songPurchases: [:], tracks: tracks)
        #expect(c.syncItems(.off).isEmpty)
        #expect(c.syncItems(.cds) == [.album(album: "Ripped", artist: "Artist")])
        #expect(c.syncItems(.vinyl) == [.album(album: "Needle", artist: "Artist")])
        #expect(Set(c.syncItems(.all)) == [.album(album: "Ripped", artist: "Artist"), .album(album: "Needle", artist: "Artist"),
                                           .album(album: "Bought", artist: "Artist")])
        #expect(c.syncItems(.all).count == 3)
    }

    @Test func scopesCountsArtistsAndCovers() {
        let tracks = [track(1, album: "Ripped")]
        var covered = item("lp", .vinyl, 1, album: "Trackless", artist: "beta")
        covered.coverFile = "lp-0000abcd.jpg"
        let items = [item("cd", .cd, 1, album: "Ripped", source: .rip), item("unripped", .cd, 2, album: "Never", artist: "Beta"),
                     covered, item("dl", .download, album: "Gone", source: .download)]
        let c = MusicCollection(items: items, songPurchases: [:], tracks: tracks)
        #expect(c.count(.all) == 3, "the Shelf is the physical collection: no downloads")
        #expect(c.items(in: .all).map(\.id).sorted() == ["cd", "lp", "unripped"])
        #expect(c.count(.cds) == 2 && c.count(.vinyl) == 1 && c.count(.downloads) == 1)
        #expect(c.items(in: .toDigitize).map(\.id).sorted() == ["lp", "unripped"], "a download with no tracks isn't waiting")
        #expect(c.count(.toDigitize) == 2)
        #expect(c.artists == ["Artist", "Beta"])
        #expect(c.items(artist: "BETA").map(\.id).sorted() == ["lp", "unripped"])
        #expect(c.coverPath(c.item(id: "lp")!) == "Music/Collection Covers/lp-0000abcd.jpg")
        #expect(c.coverPath(c.item(id: "cd")!) == "Music/Artist/Ripped/cover.jpg")
        #expect(c.coverPath(c.item(id: "unripped")!) == nil)
        #expect(CollectionScope.toDigitize.query == "own:physical ripped:no" && CollectionScope.all.title == "Shelf")
        #expect(CollectionScope.all.query == "own:physical")
        #expect(CollectionSyncScope.all.title == "Everything I own that's digitized")
    }

    @Test func olderVersionsSeeThePrimaryCDsAndDownloads() {
        var cd = item("cd", .cd, 4, album: "A")
        cd.price = 10
        var cd2 = item("cd2", .cd, 9, album: "A")
        cd2.price = 15
        let c = MusicCollection(items: [cd, cd2, item("lp", .vinyl, 1, album: "B"), item("dl", .download, album: "C")],
                                songPurchases: [:], tracks: [])
        let p = LegacyOwnership.purchases(of: c)
        #expect(p.count == 2, "records aren't owned for older call sites")
        #expect(p[SearchIndex.albumKey(album: "A", artist: "Artist")] == AlbumPurchase(album: "A", artist: "Artist", price: 10, labelNumber: 4))
        #expect(p[SearchIndex.albumKey(album: "C", artist: "Artist")]?.format == .digital)
    }

    // MARK: Linking

    @Test func linkerBackfillsAndInfersTheSource() {
        let tracks = [track(1, release: releaseA, group: groupA, year: 1959), track(2, release: releaseA, group: groupA, year: 1959),
                      track(3, release: releaseB, year: 1997)]
        var known = item("known", .cd, 2, source: .rip)
        known.releaseID = releaseB
        known.year = 2000
        let items = [item("cd", .cd, 1), item("lp", .vinyl, 1), item("dl", .download), known,
                     item("none", .cd, 3, album: "Unripped"), item("new", .other("cassette"))]
        let changes = Dictionary(uniqueKeysWithValues: CollectionLinker.changes(items: items, tracks: tracks).map { ($0.id, $0) })
        #expect(changes["cd"] == CollectionLinker.Change(id: "cd", releaseID: releaseA, releaseGroupID: groupA, year: 1959, digitalSource: .rip))
        // The record's music is the CD's: it takes the release group, never the CD's release.
        #expect(changes["lp"] == CollectionLinker.Change(id: "lp", releaseGroupID: groupA, year: 1959, digitalSource: .same))
        #expect(changes["dl"]?.digitalSource == .download)
        #expect(changes["known"] == CollectionLinker.Change(id: "known", releaseGroupID: groupA), "set fields are kept")
        #expect(changes["none"] == nil && changes["new"] == nil)
        // Applying them settles it.
        let applied = items.map { i in changes[i.id].map { $0.applied(to: i) } ?? i }
        #expect(CollectionLinker.changes(items: applied, tracks: tracks).isEmpty)
    }

    @Test func linkerRelinksOnlyByExactRelease() {
        // The album was retagged elsewhere: its release now lives under one other key.
        var moved = item("moved", .cd, 1, album: "Old Name", source: .rip)
        moved.releaseID = releaseA
        var ambiguous = item("amb", .cd, 2, album: "Gone", source: .rip)
        ambiguous.releaseID = releaseB
        var neverLinked = item("never", .cd, 3, album: "Never")
        neverLinked.releaseID = releaseA
        var groupOnly = item("group", .cd, 4, album: "Group", source: .rip)
        groupOnly.releaseGroupID = groupA
        let tracks = [track(1, album: "New Name", release: releaseA, group: groupA),
                      track(2, album: "Copy 1", release: releaseB), track(3, album: "Copy 2", release: releaseB)]
        let changes = Dictionary(uniqueKeysWithValues: CollectionLinker.changes(items: [moved, ambiguous, neverLinked, groupOnly], tracks: tracks)
            .map { ($0.id, $0) })
        #expect(changes["moved"]?.albumKey == SearchIndex.albumKey(album: "New Name", artist: "Artist"))
        #expect(changes["moved"]?.releaseGroupID == groupA, "backfilled from the new key")
        #expect(changes["amb"] == nil, "a release on two keys stays unlinked")
        #expect(changes["never"] == nil, "only items that lost their tracks are relinked")
        #expect(changes["group"] == nil, "release groups are never linked automatically")
    }

    @Test func linkSuggestionsGoByReleaseThenGroupThenName() {
        var target = item("t", .vinyl, 1, album: "Rumours (Deluxe Edition)", artist: "Fleetwood Mac", key: "x")
        target.releaseID = releaseA
        target.releaseGroupID = groupA
        let tracks = [track(1, album: "Rumours", artist: "Fleetwood Mac", group: groupA),
                      track(2, album: "Rumours Live", artist: "Fleetwood Mac", release: releaseA),
                      track(3, album: "Rumours", artist: "Someone Else"), track(4, album: "Tusk", artist: "Fleetwood Mac")]
        let albums = [
            AlbumSummary(album: "Rumours", artist: "Someone Else", year: nil, trackCount: 1, firstTrackPath: ""),
            AlbumSummary(album: "Rumours", artist: "Fleetwood Mac", year: nil, trackCount: 1, firstTrackPath: ""),
            AlbumSummary(album: "Tusk", artist: "Fleetwood Mac", year: nil, trackCount: 1, firstTrackPath: ""),
            AlbumSummary(album: "Rumours Live", artist: "Fleetwood Mac", year: nil, trackCount: 1, firstTrackPath: ""),
        ]
        #expect(CollectionLinker.suggestions(for: target, albums: albums, tracks: tracks).map(\.album) == ["Rumours Live", "Rumours"])
        target.releaseID = nil
        target.releaseGroupID = nil
        #expect(CollectionLinker.suggestions(for: target, albums: albums, tracks: tracks).map(\.album) == ["Rumours"])
    }

    // MARK: Covers

    @Test func coverNamesAreChecked() throws {
        #expect(CollectionCovers.isFileName("own-0123456789abcdef-0000abcd.jpg"))
        for bad in ["", ".jpg", "-x.jpg", "../x.jpg", "x/y.jpg", "/abs.jpg", "X.jpg", "x.png", "x.jpg.png", "x .jpg",
                    String(repeating: "a", count: 81) + ".jpg", "Artist Images/x.jpg"] {
            #expect(!CollectionCovers.isFileName(bad), "\(bad)")
            #expect(CollectionCovers.path(bad) == nil)
        }
        #expect(CollectionCovers.path("a.jpg") == "Music/Collection Covers/a.jpg")

        let root = try TestSupport.tempDir()
        let name = try CollectionCovers.write(Data([0xFF, 0xD8, 0xFF]), itemID: "item-1", root: root)
        #expect(name.hasPrefix("item-1-") && CollectionCovers.isFileName(name))
        let url = try #require(CollectionCovers.url(name, root: root))
        #expect(try Data(contentsOf: url) == Data([0xFF, 0xD8, 0xFF]))
        #expect(url.path.hasSuffix("Music/Collection Covers/\(name)"))
        let again = try CollectionCovers.write(Data([1]), itemID: "item-1", root: root)
        #expect(again != name, "a new name on each change")
        #expect(throws: CollectionError.self) { try CollectionCovers.write(Data(), itemID: "../x", root: root) }

        let album = root.appendingPathComponent("Music/A/B (2000)")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data([9, 9]).write(to: album.appendingPathComponent("cover.jpg"))
        let adopted = try CollectionCovers.adopt(albumCover: album.appendingPathComponent("cover.jpg"), itemID: "item-2", root: root)
        #expect(try Data(contentsOf: try #require(CollectionCovers.url(adopted, root: root))) == Data([9, 9]))
    }

    @Test func coversDontFollowSymlinksOutOfTheLibrary() throws {
        let root = try TestSupport.tempDir()
        let outside = try TestSupport.tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Music"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(CollectionCovers.folder), withDestinationURL: outside)
        #expect(CollectionCovers.url("a.jpg", root: root) == nil)
        #expect(throws: CollectionError.self) { try CollectionCovers.write(Data([1]), itemID: "a", root: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    // MARK: Legacy

    @Test func primaryCopyAndProjection() {
        var cd9 = item("cd9", .cd, 9, created: 1)
        cd9.price = 20
        var cd2 = item("cd2", .cd, 2, created: 5)
        cd2.price = 12
        cd2.purchasedOn = PurchaseDay(year: 2001, month: 1, day: 1)
        let dl = item("dl", .download, created: 0)
        let lp = item("lp", .vinyl, 1, album: "Vinyl Only")
        var derived = item("songs", .download, album: "Songs")
        derived.origin = .songs
        let key = SearchIndex.albumKey(album: "Album", artist: "Artist")
        #expect(CollectionLegacy.primary([dl, cd9, cd2, lp], albumKey: key)?.id == "cd2")
        #expect(CollectionLegacy.primary([dl, item("u", .cd, created: 9)], albumKey: key)?.id == "u")
        #expect(CollectionLegacy.primary([dl, item("a", .download, created: 0)], albumKey: key)?.id == "a", "ties: earliest, then lowest id")
        let projection = CollectionLegacy.projection(items: [cd9, cd2, dl, lp, derived])
        #expect(projection.count == 1, "no records, no derived downloads")
        #expect(projection[key]?.purchase == AlbumPurchase(album: "Album", artist: "Artist", purchasedOn: PurchaseDay(year: 2001, month: 1, day: 1),
                                                          price: 12, labelNumber: 2), "the primary copy's own price, never a sum")
        #expect(projection[key]?.updatedAt == cd2.updatedAt)
        #expect(CollectionLegacy.projection(items: [dl])[key]?.purchase.format == .digital)
    }

    @Test func reconcileTakesInOlderEditsAndNeverDeletes() {
        let key = SearchIndex.albumKey(album: "Album", artist: "Artist")
        var cd = item("cd", .cd, 5, created: 100)
        cd.price = 10
        let projected = CollectionLegacy.Row(key: key, purchase: AlbumPurchase(album: " Album", artist: "Artist", price: 10, labelNumber: 5),
                                             updatedAt: Date(timeIntervalSince1970: 100.0005))
        #expect(CollectionLegacy.reconcile(items: [cd], legacy: [projected]).changed.isEmpty, "the projection: nothing to take in")
        // An older Mac whose clock is behind: its edit is older than the copy's, and still taken in.
        let behind = CollectionLegacy.Row(key: key, purchase: AlbumPurchase(album: "Album", artist: "Artist", price: 1, labelNumber: 5),
                                          updatedAt: Date(timeIntervalSince1970: 50))
        #expect(CollectionLegacy.reconcile(items: [cd], legacy: [behind]).items.map(\.price) == [1])
        // The same values written by an app before 1.19 are still its edit (its time is taken in).
        var marked = projected
        marked.writer = .noFormat
        #expect(CollectionLegacy.reconcile(items: [cd], legacy: [marked]).changed.map(\.updatedAt) == [Date(timeIntervalSince1970: 100.0005)])

        // A 1.17 Mac edited the price: no label or format in its row.
        let edited = CollectionLegacy.Row(key: key, purchase: AlbumPurchase(album: "Album", artist: "Artist", price: 8), updatedAt: Date(timeIntervalSince1970: 200),
                                          writer: .noLabel)
        var r = CollectionLegacy.reconcile(items: [cd], legacy: [edited])
        #expect(r.changed.map(\.id) == ["cd"])
        #expect(r.items[0].price == 8 && r.items[0].stickerNumber == 5 && r.items[0].updatedAt == Date(timeIntervalSince1970: 200))
        // A 1.19 Mac made it a download; a 1.18 Mac relabeled it.
        r = CollectionLegacy.reconcile(items: [cd], legacy: [CollectionLegacy.Row(key: key, purchase: AlbumPurchase(album: "Album", artist: "Artist", format: .digital),
                                                                                  updatedAt: Date(timeIntervalSince1970: 200))])
        #expect(r.items[0].medium == .download && r.items[0].stickerNumber == nil)
        r = CollectionLegacy.reconcile(items: [cd], legacy: [CollectionLegacy.Row(key: key, purchase: AlbumPurchase(album: "Album", artist: "Artist", labelNumber: 6),
                                                                                  updatedAt: Date(timeIntervalSince1970: 200), writer: .noFormat)])
        #expect(r.items[0].stickerNumber == 6)
        // A download edited by a Mac that writes no format stays a download.
        let dl = item("dl", .download, created: 100)
        r = CollectionLegacy.reconcile(items: [dl], legacy: [edited])
        #expect(r.items[0].medium == .download && r.items[0].price == 8)

        // No CD or download for the key (a record doesn't count): one is made, with the deterministic id.
        let lp = item("lp", .vinyl, 1)
        r = CollectionLegacy.reconcile(items: [lp], legacy: [edited])
        #expect(r.items.count == 2 && r.changed.map(\.id) == [CollectionItem.legacyID(albumKey: key)])
        #expect(r.changed[0].medium == .cd && r.changed[0].createdAt == Date(timeIntervalSince1970: 200))
        // Nothing in the rows: nothing removed.
        #expect(CollectionLegacy.reconcile(items: [cd, lp], legacy: []).items == [cd, lp])
        // The legacy id taken by an item on another key (changed to vinyl): a new id.
        let taken = item(CollectionItem.legacyID(albumKey: key), .vinyl, 1)
        r = CollectionLegacy.reconcile(items: [taken], legacy: [edited])
        #expect(r.changed.count == 1 && r.changed[0].id != taken.id && CollectionItem.isValidID(r.changed[0].id))
    }

    /// An older app's NULL label or format is a clear only from an app that wrote the column (`Writer`).
    @Test func reconcileFollowsWhatTheWriterKnew() {
        let key = SearchIndex.albumKey(album: "Album", artist: "Artist")
        let cd = item("cd", .cd, 5, created: 100), dl = item("dl", .download, created: 100)
        func reconciled(_ item: CollectionItem, _ writer: CollectionLegacy.Writer, label: Int? = nil) -> CollectionItem {
            let row = CollectionLegacy.Row(key: key, purchase: AlbumPurchase(album: "Album", artist: "Artist", labelNumber: label),
                                           updatedAt: Date(timeIntervalSince1970: 200), writer: writer)
            return CollectionLegacy.reconcile(items: [item], legacy: [row]).items[0]
        }
        // 1.19 and later write both: a NULL label is cleared, a NULL format is a CD.
        #expect(reconciled(cd, .current).medium == .cd && reconciled(cd, .current).stickerNumber == nil, "the label was cleared")
        #expect(reconciled(dl, .current).medium == .cd, "a download made a CD without a label")
        // 1.18 writes the label, not the format.
        #expect(reconciled(cd, .noFormat).stickerNumber == nil, "the label was cleared")
        #expect(reconciled(dl, .noFormat).medium == .download, "it can't say a download")
        #expect(reconciled(dl, .noFormat, label: 3).medium == .cd && reconciled(dl, .noFormat, label: 3).stickerNumber == 3)
        // 1.14–1.17 write neither, and a row from an unmarked table may be from any of them.
        for writer in [CollectionLegacy.Writer.noLabel, .unknown] {
            #expect(reconciled(cd, writer).stickerNumber == 5 && reconciled(dl, writer).medium == .download, "\(writer)")
        }
        #expect(reconciled(cd, .unknown, label: 6).stickerNumber == 6 && reconciled(dl, .unknown, label: 6).medium == .cd)
    }
}
