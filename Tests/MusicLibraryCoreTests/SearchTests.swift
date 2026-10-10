import Foundation
import Testing
@testable import MusicLibraryCore

enum SearchFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func track(_ id: Int64, _ title: String, artist: String, album: String, albumArtist: String = "", year: Int? = nil,
                      genre: String = "", duration: Double = 200, format: String = "flac", audio: AudioFormat? = nil,
                      addedDaysAgo: Double = 100, composer: String = "", mbid: String? = nil,
                      configure: (inout ExtendedMetadata) -> Void = { _ in }) -> Track {
        var ext = ExtendedMetadata()
        configure(&ext)
        return Track(id: id, path: "Music/\(artist)/\(album)/\(id).\(format)",
                     metadata: TrackMetadata(title: title, artist: artist, album: album, albumArtist: albumArtist, year: year,
                                             trackNo: Int(id), genre: genre, mbRecordingId: mbid, composer: composer, extended: ext),
                     duration: duration, format: format, sha256: "sha\(id)",
                     addedAt: now.addingTimeInterval(-addedDaysAgo * 86_400), audioFormat: audio)
    }

    static let flac16 = AudioFormat(codec: "flac", sampleRate: 44_100, bitDepth: 16, channels: 2)
    static let flac24 = AudioFormat(codec: "flac", sampleRate: 96_000, bitDepth: 24, channels: 2)
    static let mp3 = AudioFormat(codec: "mp3", sampleRate: 44_100, bitrate: 320_000, channels: 2)
    static let mp3Low = AudioFormat(codec: "mp3", sampleRate: 44_100, bitrate: 128_000, channels: 2)

    static let library: [Track] = [
        track(1, "Airbag", artist: "Radiohead", album: "OK Computer", year: 1997, genre: "Alternative Rock; Rock", duration: 284,
              audio: flac16, addedDaysAgo: 3, mbid: "rec-1") { $0.label = "Parlophone"; $0.releaseCountry = "GB" },
        track(2, "Karma Police", artist: "Radiohead", album: "OK Computer", year: 1997, genre: "Alternative Rock", duration: 264,
              audio: flac16, addedDaysAgo: 3, mbid: "rec-2") { $0.label = "Parlophone" },
        track(3, "So What", artist: "Miles Davis", album: "Kind of Blue", year: 1959, genre: "Jazz; Modal Jazz", duration: 562,
              audio: flac24, addedDaysAgo: 40, composer: "Miles Davis", mbid: "rec-3") {
            $0.label = "Columbia"
            $0.credits = [Credit(role: "instrument", name: "John Coltrane", attributes: ["tenor saxophone"], scope: .recording),
                          Credit(role: "producer", name: "Teo Macero", scope: .release)]
            $0.workTitle = "So What"
        },
        track(4, "Blue in Green", artist: "Miles Davis", album: "Kind of Blue", year: 1959, genre: "Jazz", duration: 337,
              audio: flac24, addedDaysAgo: 40, composer: "Bill Evans") {
            $0.credits = [Credit(role: "instrument", name: "Bill Evans", attributes: ["piano"], scope: .recording)]
        },
        track(5, "Love Me Do", artist: "The Beatles", album: "Please Please Me", year: 1963, genre: "Rock", duration: 140,
              format: "mp3", audio: mp3, addedDaysAgo: 400),
        track(6, "Computer Love", artist: "Kraftwerk", album: "Computer World", year: 1981, genre: "Electronic", duration: 435,
              format: "mp3", audio: mp3Low, addedDaysAgo: 400),
        track(7, "Mystery Track", artist: "Unknown", album: "", duration: 61, format: "wav", addedDaysAgo: 1),
        track(8, "Track From A Comp", artist: "Someone", album: "Hits 2020", albumArtist: "Various Artists", year: 2020,
              genre: "Pop", duration: 190, format: "mp3", audio: mp3, addedDaysAgo: 10) { $0.releaseSecondaryTypes = ["Compilation"] },
    ]

    static let index = SearchIndex(tracks: library, hasCover: { $0.album != "" && $0.artist != "Kraftwerk" })
}

@Suite struct SearchQueryParsingTests {
    let now = SearchFixtures.now

    @Test func tokenizesQuotesNegationAndFields() {
        let tokens = SearchTokenizer.tokenize(#"miles -live artist:"bill evans" "kind of" year:>1990 OR x"#)
        #expect(tokens.map(\.value) == ["miles", "live", "bill evans", "kind of", ">1990", "OR", "x"])
        #expect(tokens.map(\.negated) == [false, true, false, false, false, false, false])
        #expect(tokens.map(\.key) == [nil, nil, "artist", nil, "year", nil, nil])
        #expect(tokens[5].isOr)
    }

    @Test func groupsByOr() {
        let q = SearchQuery.parse("genre:jazz OR genre:rock year:1997", now: now)
        #expect(q.groups.count == 2)
        #expect(q.groups[1].count == 2)
        #expect(SearchQuery.parse("OR OR", now: now).isEmpty)
    }

    @Test func incompleteFiltersAreIgnoredWhileTyping() {
        #expect(SearchQuery.parse("genre:", now: now).isEmpty)
        #expect(SearchQuery.parse("-", now: now).isEmpty)
        #expect(SearchQuery.parse("artist:\"", now: now).isEmpty)
    }

    @Test func unknownKeysFallBackToText() {
        let q = SearchQuery.parse("re:stacks", now: now)
        #expect(q.groups == [[SearchQuery.Term(predicate: .text("re stacks"), negated: false)]])
    }

    @Test func reportsBadValues() {
        #expect(SearchQuery.parse("year:abc is:shiny decade:x", now: now).issues.count == 3)
    }

    @Test func numberRanges() {
        func range(_ s: String, _ f: SearchQuery.NumberField = .year) -> SearchQuery.NumberRange? { NumberParser.range(s, field: f, now: now) }
        #expect(range("1997")!.contains(1997) && !range("1997")!.contains(1998))
        #expect(range("1990-1999")!.contains(1999) && !range("1990-1999")!.contains(2000))
        #expect(range("1990..")!.contains(2024) && !range("1990..")!.contains(1989))
        #expect(range(">1990")!.contains(1991) && !range(">1990")!.contains(1990))
        #expect(range("<=1990")!.contains(1990) && !range("<=1990")!.contains(1991))
        // Durations: bare numbers are minutes; `=` covers the whole unit, comparisons are exact.
        #expect(range("5", .duration)!.contains(330) && !range("5", .duration)!.contains(360))
        #expect(range(">5m", .duration)!.contains(301))
        #expect(range("<3:30", .duration)!.contains(209) && !range("<3:30", .duration)!.contains(210))
        #expect(range("90s", .duration)!.contains(90))
        // Sample rates in kHz, bitrates in kbps.
        #expect(range("44.1", .sampleRate)!.contains(44_100))
        #expect(range("96", .sampleRate)!.contains(96_000) && !range("96", .sampleRate)!.contains(48_000))
        #expect(range(">=96", .sampleRate)!.contains(192_000))
        #expect(range("<256", .bitrate)!.contains(128_000) && !range("<256", .bitrate)!.contains(320_000))
        #expect(range("garbage") == nil)
    }

    @Test func decades() {
        #expect(NumberParser.decadeStart("90s", now: now) == 1990)
        #expect(NumberParser.decadeStart("1960s", now: now) == 1960)
        #expect(NumberParser.decadeStart("'00s", now: now) == 2000)
        #expect(NumberParser.decadeStart("20s", now: now) == 2020)
        #expect(NumberParser.decadeStart("x", now: now) == nil)
    }
}

@Suite struct SearchIndexTests {
    let index = SearchFixtures.index
    let now = SearchFixtures.now

    func ids(_ q: String) -> [Int64] { index.search(q, now: now, autocorrect: false).tracks.map(\.id) }
    func idSet(_ q: String) -> Set<Int64> { Set(ids(q)) }

    @Test func emptyQueryReturnsEverythingInOrder() {
        #expect(ids("") == SearchFixtures.library.map(\.id))
        #expect(ids("   ") == SearchFixtures.library.map(\.id))
    }

    @Test func freeTextMatchesAcrossFieldsCaseAndAccentInsensitive() {
        #expect(idSet("radiohead") == [1, 2])
        #expect(idSet("RADIOHEAD karma") == [2])
        #expect(idSet("coltrane") == [3])          // credits
        #expect(idSet("parlophone") == [1, 2])     // label
        #expect(idSet("modal") == [3])             // genre
        #expect(idSet("mîles dävis") == [3, 4])
        #expect(idSet("\"kind of blue\"") == [3, 4])
        #expect(idSet("\"blue kind\"").isEmpty)
    }

    @Test func rankingPrefersTitleThenArtistThenAlbum() {
        // "computer" is a title word for 6, an album word for 1/2 and 6.
        #expect(ids("computer").first == 6)
        #expect(ids("love").prefix(2) == [5, 6])  // "Love Me Do" starts with the word; "Computer Love" has it as a word
        #expect(ids("blue").first == 4)
    }

    @Test func fieldFilters() {
        #expect(idSet("artist:radiohead") == [1, 2])
        #expect(idSet("artist:various") == [8])  // album artist counts as artist
        #expect(idSet("album:blue") == [3, 4])
        #expect(idSet("title:blue") == [4])
        #expect(idSet("genre:jazz") == [3, 4])
        #expect(idSet("composer:evans") == [4])
        #expect(idSet("credit:macero") == [3])
        #expect(idSet("label:\"parlophone\"") == [1, 2])
        #expect(idSet("country:gb") == [1])
        #expect(idSet("format:mp3") == [5, 6, 8])
        #expect(idSet("work:\"so what\"") == [3])
    }

    @Test func numericFilters() {
        #expect(idSet("year:1959") == [3, 4])
        #expect(idSet("year:1960-1990") == [5, 6])
        #expect(idSet("decade:90s") == [1, 2])
        #expect(idSet("time:>7m") == [3, 6])
        #expect(idSet("time:<2:30") == [5, 7])
        #expect(idSet("bits:24") == [3, 4])
        #expect(idSet("rate:96") == [3, 4])
        #expect(idSet("bitrate:>=256") == [5, 8])
        #expect(idSet("added:7d") == [1, 2, 7])
        #expect(idSet("added:>1y") == [5, 6])
        #expect(idSet("track:1") == [1])
    }

    @Test func flagsAndPresence() {
        #expect(idSet("is:lossless") == [1, 2, 3, 4, 7])
        #expect(idSet("is:lossy") == [5, 6, 8])
        #expect(idSet("is:hires") == [3, 4])
        #expect(idSet("is:compilation") == [8])
        #expect(idSet("is:matched") == [1, 2, 3])
        #expect(idSet("is:unmatched") == [4, 5, 6, 7, 8])
        #expect(idSet("missing:year") == [7])
        #expect(idSet("missing:genre") == [7])
        #expect(idSet("has:credits") == [3, 4])
        #expect(idSet("missing:cover") == [6, 7])
        #expect(idSet("-missing:label") == [1, 2, 3])
    }

    @Test func negationAndOr() {
        #expect(idSet("genre:rock -radiohead") == [5])
        #expect(idSet("-is:lossy -missing:year") == [1, 2, 3, 4])
        #expect(idSet("artist:kraftwerk OR artist:beatles") == [5, 6])
        #expect(idSet("kraftwerk | beatles") == [5, 6])
    }

    @Test func hitsListAlbumsAndArtistsThatMatchedText() {
        let r = index.search("radiohead", now: now)
        #expect(r.artists.map(\.name) == ["Radiohead"])
        #expect(r.albums.map(\.album) == ["OK Computer"])
        #expect(r.albums.first?.trackCount == 2)
        // A title-only hit doesn't make the artist a hit.
        #expect(index.search("airbag", now: now).artists.isEmpty)
        // Filter-only queries list everything they contain.
        #expect(Set(index.search("genre:jazz", now: now).albums.map(\.album)) == ["Kind of Blue"])
        #expect(index.search("artist:davis", now: now).artists.first?.albumCount == 1)
    }

    @Test func spellingCorrection() {
        #expect(index.correction(for: "radiohed") == "radiohead")
        #expect(index.correction(for: "artist:kraftwrk -live") == "artist:kraftwerk -live")
        #expect(index.correction(for: "coltrnae year:1959") == "coltrane year:1959")
        #expect(index.correction(for: "radio") == nil)      // a substring of a real word
        #expect(index.correction(for: "zzzzzzzz") == nil)
        #expect(index.correction(for: "-liev") == nil)       // negated words are left alone

        let r = index.search("radiohed", now: now)
        #expect(r.correctedText == "radiohead")
        #expect(r.tracks.count == 2)
        #expect(index.search("radiohed", now: now, autocorrect: false).tracks.isEmpty)
    }

    @Test func editDistance() {
        func d(_ a: String, _ b: String) -> Int { SearchIndex.editDistance(Array(a.utf8), Array(b.utf8), limit: 5) }
        #expect(d("radiohead", "radiohead") == 0)
        #expect(d("raidohead", "radiohead") == 1)  // transposition
        #expect(d("kitten", "sitting") == 3)
        #expect(SearchIndex.editDistance(Array("abcdef".utf8), Array("uvwxyz".utf8), limit: 2) == 3)
    }

    @Test func completions() {
        let keys = index.completions(for: "gen")
        #expect(keys.first?.replacement == "genre:")
        let genres = index.completions(for: "miles genre:ja")
        #expect(genres.first?.replacement == "miles genre:Jazz ")
        #expect(genres.contains { $0.label == "genre:Modal Jazz" && $0.replacement == "miles genre:\"Modal Jazz\" " })
        let artists = index.completions(for: "-radio")
        #expect(artists.contains { $0.replacement == "-artist:Radiohead " })
        #expect(index.completions(for: "is:h").first?.replacement == "is:hires ")
        #expect(index.completions(for: "decade:").map(\.label).prefix(2) == ["decade:1950s", "decade:1960s"])
        #expect(index.completions(for: "radiohead ").isEmpty)
        #expect(index.completions(for: "").isEmpty)
    }

    @Test func topValuesSplitMultiValueGenres() {
        let genres = index.topValues(.genre)
        #expect(genres.contains { $0.name == "Alternative Rock" && $0.count == 2 })
        #expect(index.decades.map(\.name) == ["1950s", "1960s", "1980s", "1990s", "2020s"])
    }

    /// Regression: MusicBrainz genres are community tags for the whole artist/release group (a Beatles song
    /// came back tagged Jazz, Trance and Classical), so they must not leak into `genre:` or free text.
    @Test func musicBrainzGenresOnlyMatchTheirOwnFilter() {
        let rockSong = SearchFixtures.track(50, "Come Together", artist: "The Beatles", album: "Abbey Road", genre: "Rock") {
            $0.mbGenres = ["Rock", "Pop Rock", "Jazz", "Trance", "Classical"]
        }
        let jazzSong = SearchFixtures.track(51, "Take Five", artist: "Dave Brubeck", album: "Time Out", genre: "Jazz")
        let index = SearchIndex(tracks: [rockSong, jazzSong])
        func ids(_ q: String) -> Set<Int64> { Set(index.search(q, autocorrect: false).tracks.map(\.id)) }
        #expect(ids("genre:jazz") == [51])
        #expect(ids("jazz") == [51])
        #expect(ids("genre:rock") == [50])
        #expect(ids("mbgenre:jazz") == [50])
        #expect(ids("tag:trance") == [50])
        #expect(ids("missing:genre").isEmpty)
        #expect(index.topValues(.genre).map(\.name).sorted() == ["Jazz", "Rock"])
        #expect(LibraryStats(tracks: [rockSong, jazzSong]).genres.map(\.name).sorted() == ["Jazz", "Rock"])
    }

    @Test func emptyIndex() {
        #expect(SearchIndex.empty.search("anything").tracks.isEmpty)
        #expect(SearchIndex.empty.completions(for: "art").first?.replacement == "artist:")
        #expect(SearchIndex.empty.correction(for: "anything") == nil)
    }
}

@Suite struct SmartPlaylistStorageTests {
    @Test func crudAndMigration() throws {
        let db = try Database(path: ":memory:")
        let p = try db.createSmartPlaylist(name: "Hi-Res Jazz", query: "genre:jazz is:hires")
        try db.createSmartPlaylist(name: "Added recently", query: "added:30d")
        #expect(try db.smartPlaylists().map(\.name) == ["Added recently", "Hi-Res Jazz"])
        try db.updateSmartPlaylist(id: p.id, name: "Jazz", query: "genre:jazz")
        #expect(try db.smartPlaylists().last?.query == "genre:jazz")
        try db.deleteSmartPlaylist(id: p.id)
        #expect(try db.smartPlaylists().count == 1)
    }
}
