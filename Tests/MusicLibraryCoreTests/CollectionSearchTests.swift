import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct CollectionSearchTests {
    let now = SearchFixtures.now
    let index = SearchFixtures.index
    let tracks = SearchFixtures.library

    func item(_ id: String, _ medium: CollectionMedium, _ number: Int? = nil, album: String, artist: String,
              source: DigitalSource? = nil, configure: (inout CollectionItem) -> Void = { _ in }) -> CollectionItem {
        var i = CollectionItem(id: id, medium: medium, album: album, artist: artist, now: Date(timeIntervalSince1970: 0))
        i.stickerNumber = number
        i.digitalSource = source
        configure(&i)
        return i
    }

    /// OK Computer on CD #1 (partly ripped), Kind of Blue on CD #12 and Vinyl #12, Blue Train on Vinyl #13 (no tracks),
    /// Computer World as a download, an unlabeled Please Please Me CD and CD #2 whose rip is gone.
    var items: [CollectionItem] {
        [
            item("cd1", .cd, 1, album: "OK Computer", artist: "Radiohead", source: .rip) {
                $0.trackCount = 12; $0.price = 15; $0.purchasedOn = PurchaseDay(year: 2024, month: 3, day: 1)
                $0.barcode = "724385522925"; $0.catalogNumber = "CDP 7243 8 55229 2 5"; $0.recordLabel = "Capitol"
            },
            item("cd12", .cd, 12, album: "Kind of Blue", artist: "Miles Davis", source: .rip) {
                $0.price = 10; $0.purchasedOn = PurchaseDay(now.addingTimeInterval(-10 * 86_400))
            },
            item("v12", .vinyl, 12, album: "Kind of Blue", artist: "Miles Davis", source: .same) {
                $0.price = 30; $0.year = 1959; $0.recordLabel = "Columbia"; $0.catalogNumber = "CL 1355"
                $0.purchasedOn = PurchaseDay(year: 2021, month: 6, day: 5)
            },
            item("v13", .vinyl, 13, album: "Blue Train", artist: "John Coltrane") { $0.year = 1957; $0.recordLabel = "Blue Note" },
            item("dl", .download, album: "Computer World", artist: "Kraftwerk"),
            item("ppm", .cd, album: "Please Please Me", artist: "The Beatles") { $0.price = 0 },
            item("cd2", .cd, 2, album: "Lost Album", artist: "Nobody", source: .rip) { $0.price = 12 },
        ]
    }

    var albumInfos: [String: AlbumInfo] {
        var info = AlbumInfo(title: "Blue Train")
        info.genres = ["hard bop"]
        info.tracklist = [TracklistEntry(disc: 1, number: 1, title: "Blue Train", artist: "John Coltrane", duration: 643, position: "A1"),
                          TracklistEntry(disc: 1, number: 2, title: "Moment's Notice", artist: "John Coltrane", duration: 550, position: "A2")]
        return [SearchIndex.albumKey(album: "Blue Train", artist: "John Coltrane"): info]
    }

    var collection: MusicCollection { MusicCollection(items: items, songPurchases: [:], tracks: tracks) }
    var collectionIndex: CollectionIndex { CollectionIndex(collection: collection, tracks: tracks, albumInfos: albumInfos) }

    func ids(_ text: String) -> [String] { collectionIndex.search(text, now: now).map(\.id) }
    func run(_ text: String, autocorrect: Bool = true) -> LibrarySearch.Results {
        LibrarySearch.run(text, index: index, collectionIndex: collectionIndex, collection: collection, now: now, autocorrect: autocorrect)
    }
    func trackIDs(_ text: String) -> [Int64] { run(text).library.tracks.map(\.id) }

    // MARK: Parsing

    @Test func everyKeyAndAlias() {
        func kinds(_ text: String) -> [CollectionSearchQuery.Filter.Kind] {
            CollectionSearchQuery.parse(text, now: now).filters.map(\.kind)
        }
        for text in ["own:vinyl", "medium:vinyl", "media:vinyl", "own:lp", "own:record", "OWN:Vinyl"] {
            #expect(kinds(text) == [.own(.medium(.vinyl))], "\(text)")
        }
        #expect(kinds("own:cd") == [.own(.medium(.cd))])
        #expect(kinds("own:download") == kinds("own:dl") && kinds("own:dl") == [.own(.medium(.download))])
        #expect(kinds("own:physical own:any own:none") == [.own(.physical), .own(.any), .own(.none)])
        #expect(kinds("own:cassette") == [.own(.medium(.other("cassette")))])
        for (value, wanted) in [("yes", CollectionSearchQuery.Digitized.yes), ("no", .no), ("partial", .partial),
                                ("missing", .missing), ("other", .other)] {
            #expect(kinds("ripped:\(value)") == [.ripped(wanted)] && kinds("digitized:\(value)") == [.ripped(wanted)])
        }
        let twelve = SearchQuery.NumberRange(lower: 12, upper: 13, upperInclusive: false)
        #expect(kinds("sticker:12") == [.sticker(series: nil, range: twelve)])
        #expect(kinds("labelno:cd12") == [.sticker(series: .cd, range: twelve)])
        #expect(kinds("shelf:vinyl12") == [.sticker(series: .vinyl, range: twelve)])
        #expect(kinds("sticker:cd") == [.sticker(series: .cd, range: nil)] && kinds("sticker:vinyl") == [.sticker(series: .vinyl, range: nil)])
        #expect(kinds("sticker:lp>300") == [.sticker(series: .vinyl, range: .init(lower: 301))])
        #expect(kinds("sticker:none") == [.unlabeled])
        #expect(kinds("bought:none") == [.bought(.none)] && kinds("purchased:2024") == kinds("bought:2024"))
        #expect(kinds("bought:2020-2022") == [.bought(.year(.init(lower: 2020, upper: 2023, upperInclusive: false)))])
        #expect(kinds("bought:<90d") == [.bought(.age(.init(lower: 0, upper: 90)))])
        #expect(kinds("paid:>20") == [.paid(.init(lower: 20, lowerInclusive: false))] && kinds("price:>20") == kinds("paid:>20"))
        #expect(kinds("paid:0") == [.paid(.init(lower: 0, upper: 0))] && kinds("paid:none") == [.paid(nil)])
        #expect(kinds("paid:10-15") == [.paid(.init(lower: 10, upper: 15))] && kinds("paid:$9.99") == [.paid(.init(lower: 9.99, upper: 9.99))])
        #expect(kinds("copies:>1") == [.copies(.init(lower: 2))])
        #expect(kinds("barcode:0724385522925") == [.barcode("724385522925")])
        #expect(kinds("catno:\"CL 1355\"") == [.catalogNumber("cl1355")])
        // Negation, values still being typed, and values that don't read.
        let negated = CollectionSearchQuery.parse("-own:vinyl jazz", now: now)
        #expect(negated.filters == [.init(kind: .own(.medium(.vinyl)), negated: true)] && negated.base == SearchQuery.parse("jazz", now: now))
        #expect(CollectionSearchQuery.parse("own: jazz", now: now).filters.isEmpty)
        let bad = CollectionSearchQuery.parse("ripped:maybe paid:lots sticker:x", now: now)
        #expect(bad.filters.isEmpty && bad.issues.count == 3 && bad.base.isEmpty)
        // None of the keys are library filters.
        for key in CollectionSearchQuery.keyNames.keys { #expect(SearchFilterKey.lookup(key) == nil, "\(key)") }
    }

    @Test func labelShorthandInBothSeries() {
        let twelve = SearchQuery.NumberRange(lower: 12, upper: 12)
        #expect(CollectionSearchQuery.parse("#12", now: now).filters.map(\.kind) == [.sticker(series: nil, range: twelve)])
        for text in ["vinyl#12", "lp#12", "v#12", "record#12"] {
            #expect(CollectionSearchQuery.parse(text, now: now).filters.map(\.kind) == [.sticker(series: .vinyl, range: twelve)], "\(text)")
        }
        #expect(CollectionSearchQuery.parse("cd#12", now: now).filters.map(\.kind) == [.sticker(series: .cd, range: twelve)])
        // Without "#" (or quoted) it's text.
        for text in ["12", "cd12", "\"#12\""] { #expect(CollectionSearchQuery.parse(text, now: now).filters.isEmpty, "\(text)") }
        #expect(ids("#12") == ["cd12", "v12"])
        #expect(ids("vinyl#12") == ["v12"] && ids("cd#12") == ["cd12"] && ids("-#12 own:physical sticker:any") == ["cd1", "cd2", "v13"])
    }

    @Test func labelForms() {
        #expect(CollectionSearchQuery.labelForm("#12")! == (nil, 12))
        #expect(CollectionSearchQuery.labelForm("142")! == (nil, 142))
        #expect(CollectionSearchQuery.labelForm("cd 12")! == (.cd, 12))
        #expect(CollectionSearchQuery.labelForm(" Vinyl 12 ")! == (.vinyl, 12))
        #expect(CollectionSearchQuery.labelForm("v12")! == (.vinyl, 12))
        for text in ["kind of blue", "12345678", "cd 12 jazz", "", "own:cd"] {
            #expect(CollectionSearchQuery.labelForm(text) == nil, "\(text)")
        }
    }

    @Test func canonicalTextForSmartPlaylists() {
        #expect(CollectionSearchQuery.canonical("#12 -vinyl#3 jazz lp#4 cd#5") == "sticker:12 -sticker:vinyl3 jazz sticker:vinyl4 sticker:cd5")
        #expect(CollectionSearchQuery.canonical("artist:\"#1 band\" \"#12\" own:vinyl 12") == "artist:\"#1 band\" \"#12\" own:vinyl 12")
        // The saved form means the same.
        #expect(ids(CollectionSearchQuery.canonical("vinyl#12 OR #13")) == ids("vinyl#12 OR #13"))
    }

    // MARK: Existing queries are unchanged

    static let corpus = [
        "", "radiohead", "label:\"blue note\"", "label:parlophone", "format:flac", "is:hires", "is:lossy", "missing:label",
        "has:cover", "year:1990-1999", "year:>=2000", "-genre:jazz", "decade:60s", "time:>5m", "added:<30d", "bits:24 rate:>=96",
        "radiohead OR kraftwerk", "artist:miles OR artist:radiohead -is:lossy", "credit:\"john coltrane\"", "is:compilation",
        "1999", "21", "computer", "\"kind of\"", "re: foo", "kraftwrek", "is:bogus", "-", "genre:rock OR genre:jazz -format:mp3",
        "missing:year", "albumartist:\"various artists\"", "composer:evans", "is:matched", "-is:unmatched year:1959",
        "#41", "#9 dream",
    ]

    @Test func existingQueriesGiveIdenticalResults() {
        for text in Self.corpus {
            // "#41" is a label in search boxes, but not for songs or saved playlists.
            let parsed = CollectionSearchQuery.parse(text, now: now, shorthand: false)
            #expect(parsed.base == SearchQuery.parse(text, now: now) && parsed.filters.isEmpty, "\(text)")
            let old = index.search(text, now: now), new = run(text).library
            #expect(new.tracks.map(\.id) == old.tracks.map(\.id), "\(text)")
            #expect(new.albums == old.albums && new.artists == old.artists, "\(text)")
            #expect(new.correctedText == old.correctedText && new.issues == old.issues, "\(text)")
            // Smart playlists without collection keys.
            let playlist = LibrarySearch.tracks(matching: text, index: index, collectionIndex: collectionIndex, collection: collection, now: now)
            #expect(playlist.map(\.id) == index.tracks(matching: SearchQuery.parse(text, now: now), now: now).map(\.id), "\(text)")
        }
    }

    /// Songs titled with a "#": in saved smart playlists and in the songs a search finds, the shorthand stays text;
    /// it still picks the items.
    @Test func hashTitlesStayText() {
        var library = tracks
        library.append(SearchFixtures.track(41, "#41", artist: "Dave Matthews Band", album: "Crash"))
        library.append(SearchFixtures.track(42, "#9 Dream", artist: "John Lennon", album: "Walls and Bridges"))
        let index = SearchIndex(tracks: library)
        let collection = MusicCollection(items: items, songPurchases: [:], tracks: library)
        let collectionIndex = CollectionIndex(collection: collection, tracks: library, albumInfos: albumInfos)
        for (text, id) in [("#41", Int64(41)), ("#9 dream", Int64(42)), ("#12", nil)] {
            let plain = index.tracks(matching: SearchQuery.parse(text, now: now), now: now).map(\.id)
            #expect(id.map { plain == [$0] } ?? true, "\(text)")
            let playlist = LibrarySearch.tracks(matching: text, index: index, collectionIndex: collectionIndex, collection: collection, now: now)
            #expect(playlist.map(\.id) == plain, "\(text)")
            let results = LibrarySearch.run(text, index: index, collectionIndex: collectionIndex, collection: collection, now: now)
            #expect(results.library.tracks.map(\.id) == index.search(text, now: now).tracks.map(\.id), "\(text)")
        }
        let label = LibrarySearch.run("#12", index: index, collectionIndex: collectionIndex, collection: collection, now: now)
        #expect(label.items.map(\.id).sorted() == ["cd12", "v12"] && label.labelHits.map(\.id).sorted() == ["cd12", "v12"])
        // A saved playlist with the canonical form is a label filter.
        let saved = LibrarySearch.tracks(matching: CollectionSearchQuery.canonical("#12"), index: index, collectionIndex: collectionIndex,
                                         collection: collection, now: now)
        #expect(!saved.isEmpty && saved.allSatisfy { $0.album == "Kind of Blue" })
        #expect(CollectionSearchQuery.parse("#12", now: now, shorthand: false).filters.isEmpty)
    }

    @Test func bareNumbersStayTextWithLabelHitsAlongside() {
        var library = tracks
        library.append(SearchFixtures.track(9, "1999", artist: "Prince", album: "1999", year: 1982))
        let index = SearchIndex(tracks: library)
        var all = items
        all.append(item("cd1999", .cd, 1999, album: "Pet Sounds", artist: "The Beach Boys"))
        let collection = MusicCollection(items: all, songPurchases: [:], tracks: library)
        let collectionIndex = CollectionIndex(collection: collection, tracks: library, albumInfos: [:])
        let results = LibrarySearch.run("1999", index: index, collectionIndex: collectionIndex, collection: collection, now: now)
        #expect(results.library.tracks.map(\.id) == index.search("1999", now: now).tracks.map(\.id))
        #expect(results.library.tracks.map(\.id) == [9])
        #expect(results.labelHits.map(\.id) == ["cd1999"])
        #expect(run("12").labelHits.map(\.id) == ["cd12", "v12"])
        #expect(run("vinyl 12").labelHits.map(\.id) == ["v12"] && run("cd 13").labelHits.isEmpty)
        #expect(run("kind of blue").labelHits.isEmpty)
    }

    // MARK: Items

    @Test func textMatchesItemsTheirInfoAndTheirTracks() {
        #expect(ids("coltrane") == ["v13", "cd12", "v12"])  // Blue Train by name; Kind of Blue through a track's credits
        #expect(ids("\"moment's notice\"") == ["v13"])
        #expect(ids("title:\"moment's notice\"") == ["v13"])
        #expect(ids("genre:\"hard bop\"") == ["v13"])
        #expect(ids("genre:jazz") == ["cd12", "v12"])
        // An item's record label wins over its tracks' tag.
        #expect(ids("label:\"blue note\"") == ["v13"])
        #expect(ids("label:columbia") == ["cd12", "v12"])
        #expect(ids("label:capitol") == ["cd1"] && ids("label:parlophone").isEmpty)
        // Its year, else its tracks'.
        #expect(ids("year:1957") == ["v13"])
        #expect(ids("decade:50s") == ["cd12", "v12", "v13"])
        // Track-only terms hold when any linked track does.
        #expect(ids("format:flac") == ["cd1", "cd12", "v12"])
        #expect(ids("is:hires") == ["cd12", "v12"])
        #expect(ids("-is:hires") == ["cd1", "dl", "ppm"])
        #expect(ids("time:>9m") == ["cd12", "v12"])
        // Release fields as text, barcodes included.
        #expect(ids("cl 1355") == ["v12"] && ids("724385522925") == ["cd1"])
        #expect(ids("-artist:miles own:physical") == ["cd1", "cd2", "v13", "ppm"])
        #expect(collectionIndex.search("", now: now).count == items.count)
        // Reusing the library's index gives the same answers, and knows the covers.
        let shared = CollectionIndex(collection: collection, tracks: tracks, albumInfos: albumInfos, index: index)
        for text in ["coltrane", "format:flac", "-is:hires", "decade:50s", "label:columbia", "own:vinyl genre:jazz"] {
            #expect(shared.search(text, now: now).map(\.id) == ids(text), "\(text)")
        }
        #expect(shared.search("has:cover", now: now).map(\.id) == ["cd1", "cd12", "v12", "ppm"])
    }

    /// How You Own It: each part of a medium's bar opens a Shelf listing exactly the items it counts (a partial copy
    /// isn't in Digitized; a missing rip is counted once in To digitize).
    @Test func ownershipBarPartsOpenWhatTheyCount() {
        let stats = CollectionStats(collection: collection, tracks: tracks, playTotals: [:], albumInfos: albumInfos, now: now)
        #expect(!stats.media.isEmpty)
        for share in stats.media {
            for part in CollectionStats.MediumShare.Part.allCases {
                #expect(ids(share.query(part)).count == share.count(part), "\(share.medium) \(part)")
            }
        }
        let cd = stats.media.first { $0.medium == .cd }
        #expect(cd?.count(.digitized) == 2 && cd?.count(.partial) == 1 && cd?.count(.toDigitize) == 1)
    }

    @Test func collectionFilters() {
        #expect(ids("own:vinyl") == ["v12", "v13"])
        #expect(ids("own:cd") == ["cd1", "cd2", "cd12", "ppm"])
        #expect(ids("own:download") == ["dl"] && ids("own:physical").count == 6 && ids("own:any").count == 7)
        #expect(ids("own:none").isEmpty && ids("-own:none").count == 7)
        #expect(ids("-own:vinyl") == ["cd1", "cd2", "cd12", "dl", "ppm"])
        #expect(ids("ripped:yes") == ["cd1", "cd12", "dl", "ppm"])
        #expect(ids("ripped:no") == ["cd2", "v13"])
        #expect(ids("ripped:partial") == ["cd1"] && ids("ripped:missing") == ["cd2"] && ids("ripped:other") == ["v12"])
        #expect(ids("own:physical ripped:no") == collection.items(in: .toDigitize).map(\.id))
        #expect(ids("sticker:12") == ["cd12", "v12"] && ids("sticker:cd") == ["cd1", "cd2", "cd12"])
        #expect(ids("sticker:vinyl10-20") == ["v12", "v13"] && ids("sticker:lp>12") == ["v13"] && ids("sticker:>=12") == ["cd12", "v12", "v13"])
        #expect(ids("sticker:none") == ["ppm"])
        #expect(ids("bought:2024") == ["cd1"] && ids("bought:2020-2022") == ["v12"] && ids("bought:<90d") == ["cd12"])
        #expect(ids("bought:none") == ["cd2", "v13", "dl", "ppm"])
        #expect(ids("paid:>20") == ["v12"] && ids("paid:10-15") == ["cd1", "cd2", "cd12"] && ids("paid:0") == ["ppm"])
        #expect(ids("paid:none") == ["v13", "dl"])
        #expect(ids("copies:>1") == ["cd12", "v12"] && ids("copies:1").count == 5)
        #expect(ids("barcode:0724385522925") == ["cd1"] && ids("barcode:\"7 24385 52292 5\"") == ["cd1"])
        #expect(ids("catno:\"cl 1355\"") == ["v12"] && ids("catno:cl1355") == ["v12"] && ids("catno:55229") == ["cd1"])
        // Filters apply across the whole query, OR groups included.
        #expect(ids("own:vinyl radiohead OR coltrane") == ["v13", "v12"])
    }

    @Test func tracksAreLimitedToTheMatchingItemsAlbums() {
        #expect(trackIDs("own:vinyl") == [3, 4])
        #expect(trackIDs("own:vinyl genre:jazz") == [3, 4])
        #expect(trackIDs("own:cd") == [1, 2, 3, 4, 5])
        #expect(trackIDs("own:cd radiohead") == [1, 2])
        #expect(trackIDs("ripped:no").isEmpty)
        #expect(run("ripped:no").items.map(\.id) == ["cd2", "v13"])
        // own:none: the albums with no copy.
        #expect(trackIDs("own:none") == [7, 8])
        #expect(trackIDs("-own:none") == [1, 2, 3, 4, 5, 6])
        #expect(trackIDs("own:none own:cd").isEmpty)
        // Albums and artists for a query of filters alone are those of the songs.
        let vinyl = run("own:vinyl").library
        #expect(vinyl.albums.map(\.album) == ["Kind of Blue"] && vinyl.artists.map(\.name) == ["Miles Davis"])
        // Smart playlists with collection keys.
        #expect(LibrarySearch.tracks(matching: "own:vinyl", index: index, collectionIndex: collectionIndex, collection: collection, now: now)
            .map(\.id) == [3, 4])
        // The results also carry the items; an empty query has none.
        #expect(run("kind of blue").items.map(\.id) == ["cd12", "v12"])
        #expect(run("").items.isEmpty && run("").library.tracks.count == tracks.count)
    }

    @Test func spellingCorrectionKeepsCollectionTerms() {
        let results = run("own:cd radiohed").library
        #expect(results.correctedText == "own:cd radiohead" && results.tracks.map(\.id) == [1, 2])
        #expect(run("own:cd radiohed", autocorrect: false).library.tracks.isEmpty)
        #expect(run("own:vinyl paid:lots").library.issues == ["Can't read “lots” as a value for paid:"])
    }

    @Test func olderReadersSeeTextThatMatchesNothing() {
        // A phone before the collection parses a saved query with only the library's language.
        let old = SearchQuery.parse("own:vinyl", now: now)
        #expect(old.issues.isEmpty && old.groups == [[.init(predicate: .text("own vinyl"), negated: false)]])
        #expect(index.tracks(matching: old, now: now).isEmpty)
        for text in ["ripped:no", "sticker:cd12", "bought:2024", "paid:>20", "copies:>1", "barcode:123456789012", "catno:cl1355"] {
            #expect(index.tracks(matching: SearchQuery.parse(text, now: now), now: now).isEmpty, "\(text)")
        }
        // Negated, it matches everything there.
        #expect(index.tracks(matching: SearchQuery.parse("-own:vinyl", now: now), now: now).count == tracks.count)
    }

    @Test func completions() {
        #expect(collectionIndex.completions(for: "own:v").map(\.label) == ["own:vinyl"])
        #expect(collectionIndex.completions(for: "own:v").first?.detail == "2 items")
        #expect(collectionIndex.completions(for: "jazz own:v").first?.replacement == "jazz own:vinyl ")
        #expect(collectionIndex.completions(for: "rip").map(\.label) == ["ripped:"])
        #expect(collectionIndex.completions(for: "ripped:").map(\.label) == ["ripped:yes", "ripped:no", "ripped:partial", "ripped:missing", "ripped:other"])
        #expect(collectionIndex.completions(for: "artist:x").isEmpty && collectionIndex.completions(for: "own ").isEmpty)
    }

    @Test func snapshotSmartPlaylistsGoThroughTheCollection() throws {
        let (root, db, _) = try TestSupport.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try db.createSmartPlaylist(name: "Vinyl", query: "own:vinyl")
        _ = try db.createSmartPlaylist(name: "Everything", query: "")
        try db.saveCollectionItem(item("v1", .vinyl, 1, album: "Nothing Here", artist: "Nobody"))
        let snapshot = try LibrarySnapshot(root: root, isPresent: { _ in true })
        #expect(snapshot.collectionIndex.count == 1)
        for p in snapshot.smartPlaylists {
            #expect(snapshot.tracks(smartPlaylist: p).isEmpty)
        }
    }
}
