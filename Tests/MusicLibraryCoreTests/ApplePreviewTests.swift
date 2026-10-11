import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct ApplePreviewTests {
    // MARK: Parsing

    @Test func lookupByBarcode() throws {
        let albums = try ApplePreviewParser.parseAlbums(try TestSupport.fixture("itunes_upc_okcomputer"))
        let album = try #require(albums.first)
        #expect(albums.count == 1)
        #expect(album.id == 1097861387 && album.title == "OK Computer" && album.artist == "Radiohead")
        #expect(album.trackCount == 12 && album.releaseYear == 1997 && !album.isClean)
        #expect(album.pageURL?.absoluteString == "https://music.apple.com/us/album/ok-computer/1097861387")
        #expect(album.tracks.count == 12 && album.previews.count == 12)
        let airbag = album.tracks[0]
        #expect(airbag.title == "Airbag" && airbag.disc == 1 && airbag.number == 1 && airbag.duration == 287.88)
        #expect(airbag.previewURL?.host == "audio-ssl.itunes.apple.com" && airbag.previewURL?.pathExtension == "m4a")
        #expect(airbag.pageURL?.absoluteString == "https://music.apple.com/us/album/airbag/1097861387?i=1097861769")
        #expect(album.tracks.map(\.number) == Array(1...12))
    }

    @Test func albumLookupWithTwoDiscs() throws {
        let album = try #require(try ApplePreviewParser.parseAlbums(try TestSupport.fixture("itunes_album_hamilton")).first)
        #expect(album.id == 1129446206 && album.tracks.count == 46)
        #expect(Set(album.tracks.map(\.disc)) == [1, 2])
        #expect(album.tracks.first?.title == "Alexander Hamilton")
        #expect(album.tracks.last?.disc == 2 && album.tracks.last?.number == 23)
    }

    @Test func searchResults() throws {
        let albums = try ApplePreviewParser.parseAlbums(try TestSupport.fixture("itunes_search_hamilton"))
        #expect(albums.count == 10 && albums.allSatisfy(\.tracks.isEmpty))
        let hamilton = try #require(albums.first)
        #expect(hamilton.title == "Hamilton: An American Musical (Original Broadway Cast Recording)" && hamilton.isClean)
    }

    @Test func untrustedURLsAreDropped() throws {
        let json = """
        {"results":[
          {"wrapperType":"collection","collectionId":1,"collectionName":"A","artistName":"B","collectionViewUrl":"javascript:alert(1)"},
          {"wrapperType":"track","kind":"song","collectionId":1,"trackId":2,"trackName":"S","artistName":"B","trackNumber":1,
           "previewUrl":"https://evil.example.com/a.m4a","trackViewUrl":"file:///etc/passwd"},
          {"wrapperType":"track","kind":"song","collectionId":1,"trackId":3,"trackName":"T","artistName":"B","trackNumber":2,
           "previewUrl":"http://audio-ssl.itunes.apple.com/a.m4a"},
          {"wrapperType":"track","kind":"song","collectionId":1,"trackId":4,"trackName":"U","artistName":"B","trackNumber":3,
           "previewUrl":"https://audio-ssl.itunes.apple.com.evil.com/a.m4a"},
          {"wrapperType":"track","kind":"music-video","collectionId":1,"trackId":5,"trackName":"V","artistName":"B"}
        ]}
        """
        let album = try #require(try ApplePreviewParser.parseAlbums(Data(json.utf8)).first)
        #expect(album.pageURL == nil && album.tracks.count == 3)
        #expect(album.tracks.allSatisfy { $0.previewURL == nil && $0.pageURL == nil })

        var cached = AppleAlbum(id: 1, title: "A", artist: "B", pageURL: URL(string: "https://example.com/x"),
                                tracks: [ApplePreviewTrack(id: 2, title: "S", artist: "B", number: 1,
                                                           previewURL: URL(string: "https://audio-ssl.itunes.apple.com/a.m4a"),
                                                           pageURL: URL(string: "file:///tmp/x"))])
        cached.validateURLs()
        #expect(cached.pageURL == nil && cached.tracks[0].pageURL == nil && cached.tracks[0].previewURL != nil)
    }

    @Test func albumIdsFromLinks() {
        func id(_ s: String) -> Int? { ApplePreviewParser.albumId(URL(string: s)!) }
        #expect(id("https://music.apple.com/us/album/ok-computer/1097861387") == 1097861387)
        #expect(id("https://music.apple.com/gb/album/1097861387") == 1097861387)
        #expect(id("https://itunes.apple.com/us/album/id1097861387") == 1097861387)
        #expect(id("https://music.apple.com/us/artist/radiohead/657515") == nil)
        #expect(id("https://music.apple.com.example.com/us/album/x/1") == nil)
        #expect(id("https://music.apple.com/us/album/x/99999999999999999999") == nil)
    }

    @Test func requestURLs() {
        let url = ApplePreviewClient.url("lookup", ["upc": "634904078164", "entity": "song"], country: "GB")
        #expect(url.absoluteString == "https://itunes.apple.com/lookup?entity=song&upc=634904078164&country=GB")
        let search = ApplePreviewClient.url("search", ["term": "Lin-Manuel Miranda Hamilton & co"], country: "US")
        #expect(search.absoluteString.contains("term=Lin-Manuel%20Miranda%20Hamilton%20%26%20co"))
    }

    // MARK: Matching

    @Test func choosesTheAlbumFromSearchResults() throws {
        let albums = try ApplePreviewParser.parseAlbums(try TestSupport.fixture("itunes_search_hamilton"))
        // As cataloged: "Hamilton: original Broadway cast recording" by "Miranda, Lin-Manuel, 1980-".
        let found = ApplePreviewMatcher.bestAlbum(albums, titles: ["Hamilton: original Broadway cast recording", "Hamilton"],
                                                  artists: ["Lin-Manuel Miranda"], trackCount: 46, year: 2015)
        #expect(found?.id == 1129446206)
        // Same title, other artist; other title, same artist.
        #expect(ApplePreviewMatcher.bestAlbum(albums, titles: ["Hamilton"], artists: ["Radiohead"]) == nil)
        #expect(ApplePreviewMatcher.bestAlbum(albums, titles: ["In the Heights"], artists: ["Lin-Manuel Miranda"]) == nil)
    }

    @Test func prefersExplicitAndExactTitles() {
        let clean = AppleAlbum(id: 1, title: "Album (Deluxe Edition)", artist: "Band", trackCount: 12, isClean: true)
        let explicit = AppleAlbum(id: 2, title: "Album (Deluxe Edition)", artist: "Band", trackCount: 12)
        let plain = AppleAlbum(id: 3, title: "Album", artist: "Band", trackCount: 10, isClean: true)
        #expect(ApplePreviewMatcher.bestAlbum([clean, explicit], titles: ["Album"], artists: ["Band"])?.id == 2)
        #expect(ApplePreviewMatcher.bestAlbum([clean, explicit, plain], titles: ["Album"], artists: ["The Band"])?.id == 3)
        // Numbered volumes aren't the same album.
        let two = AppleAlbum(id: 4, title: "Anthology 2", artist: "The Beatles")
        #expect(ApplePreviewMatcher.bestAlbum([two], titles: ["Anthology: 1"], artists: ["Beatles"]) == nil)
        // Compilations: no artist to compare, so "Various Artists" or the exact title.
        let comp = AppleAlbum(id: 5, title: "Now That's What I Call Music! 12", artist: "Various Artists")
        #expect(ApplePreviewMatcher.bestAlbum([comp], titles: ["Now that's what I call music! 12"], artists: [])?.id == 5)
    }

    @Test func linesSongsUp() throws {
        let album = try #require(try ApplePreviewParser.parseAlbums(try TestSupport.fixture("itunes_upc_okcomputer")).first)
        let songs = ["Airbag", "Paranoid Android", "Subterranean Homesick Alien", "Exit Music (for a film)", "Let Down",
                     "Karma Police", "Fitter Happier", "Electioneering", "Climbing Up the Walls", "No Surprises", "Lucky", "The Tourist"]
            .enumerated().map { ApplePreviewMatcher.Song(number: $0.offset + 1, title: $0.element) }
        let lined = ApplePreviewMatcher.lineUp(songs, with: album)
        #expect(lined.count == 12 && lined[3]?.title == "Exit Music (For a Film)")

        // A remaster's suffixes, a reordered song and an extra bonus track on Apple's side.
        var remaster = album
        remaster.tracks[0].title = "Airbag - Remastered"
        remaster.tracks.swapAt(1, 2)
        remaster.tracks.append(ApplePreviewTrack(id: 99, title: "Lift", artist: "Radiohead", number: 13,
                                                 previewURL: URL(string: "https://audio-ssl.itunes.apple.com/x.m4a")))
        let again = ApplePreviewMatcher.lineUp(songs, with: remaster)
        #expect(again[0]?.id == album.tracks[0].id && again[1]?.title == "Paranoid Android" && again[2]?.title == "Subterranean Homesick Alien")
        #expect(!again.values.contains { $0.id == 99 })

        // Untitled or differently titled songs fall back to their position when the disc has as many songs.
        let numbered = (1...12).map { ApplePreviewMatcher.Song(number: $0, title: "Track \($0)") }
        #expect(ApplePreviewMatcher.lineUp(numbered, with: album)[6]?.title == "Fitter Happier")
        #expect(ApplePreviewMatcher.lineUp(Array(numbered.prefix(11)), with: album).isEmpty)
    }

    // MARK: Finding

    /// Serves fixtures for the iTunes endpoints and records what was asked.
    final class FakeApple: @unchecked Sendable {
        var requests: [URL] = []
        let lock = NSLock()
        let responses: [(String, String)]
        init(_ responses: [(String, String)]) { self.responses = responses }

        func get(_ url: URL) throws -> Data {
            lock.withLock { requests.append(url) }
            for (needle, fixture) in responses where url.absoluteString.contains(needle) {
                return try TestSupport.fixture(fixture)
            }
            return Data(#"{"resultCount":0,"results":[]}"#.utf8)
        }

        var paths: [String] { lock.withLock { requests.map { "\($0.lastPathComponent)?\($0.query ?? "")" } } }
    }

    func finder(_ fake: FakeApple) -> ApplePreviewFinder {
        ApplePreviewFinder(client: ApplePreviewClient(minInterval: 0, get: { try fake.get($0) }))
    }

    @Test func findsByAppleMusicLink() async throws {
        let fake = FakeApple([("id=1097861387", "itunes_upc_okcomputer")])
        var details = CatalogAlbumDetails(workId: "w")
        var info = AlbumInfo(title: "OK Computer")
        info.links = [ArtistLink(kind: .appleMusic, url: URL(string: "https://music.apple.com/gb/album/ok-computer/1097861387")!)]
        details.album = info
        details.barcode = "634904078164"
        let found = try await finder(fake).previews(for: CatalogItem(id: "w", title: "OK computer"), details: details)
        #expect(found.match == .link && found.album?.id == 1097861387)
        #expect(fake.paths == ["lookup?entity=song&id=1097861387&limit=200&country=US"])
    }

    @Test func findsByBarcode() async throws {
        let fake = FakeApple([("upc=634904078164", "itunes_upc_okcomputer")])
        var details = CatalogAlbumDetails(workId: "w")
        details.barcode = "0724385522925"
        details.editions = [CatalogEdition(recordId: ".b1", upc: "00634904078164", statusText: "", availability: .unknown)]
        let found = try await finder(fake).previews(for: CatalogItem(id: "w", title: "OK computer", author: "Radiohead"), details: details)
        #expect(found.match == .barcode && found.album?.tracks.count == 12)
        #expect(fake.paths.map { $0.components(separatedBy: "&").first! } == ["lookup?entity=song", "lookup?entity=song"])
        #expect(fake.paths.last?.contains("upc=634904078164") == true)
    }

    @Test func fallsBackToSearch() async throws {
        let fake = FakeApple([("search?", "itunes_search_hamilton"), ("id=1129446206", "itunes_album_hamilton")])
        let item = CatalogItem(id: "w", title: "Hamilton", subtitle: "original Broadway cast recording", author: "Miranda, Lin-Manuel, 1980-", year: 2015)
        let found = try await finder(fake).previews(for: item, details: nil, upcs: ["075678668432"])
        #expect(found.match == .search && found.album?.id == 1129446206 && found.album?.tracks.count == 46)
        #expect(fake.paths.count == 3)
        #expect(fake.paths[1].contains("term=Lin-Manuel%20Miranda%20Hamilton"))

        let nothing = try await finder(FakeApple([])).previews(for: item, details: nil)
        #expect(!nothing.isMatched && nothing.match == nil)
    }

    @Test func cacheRoundTrip() throws {
        let db = try Database(path: ":memory:")
        let album = try #require(try ApplePreviewParser.parseAlbums(try TestSupport.fixture("itunes_upc_okcomputer")).first)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try db.saveCatalogPreviews(CatalogPreviews(workId: "w", album: album, match: .barcode, fetchedAt: date))
        try db.saveCatalogPreviews(CatalogPreviews(workId: "x", fetchedAt: date))
        let loaded = try db.catalogPreviews()
        #expect(loaded["w"]?.album == album && loaded["w"]?.match == .barcode && loaded["x"]?.isMatched == false)
        #expect(loaded["w"]?.isStale(now: date.addingTimeInterval(29 * 86_400)) == false)
        #expect(loaded["x"]?.isStale(now: date.addingTimeInterval(8 * 86_400)) == true)
    }
}
