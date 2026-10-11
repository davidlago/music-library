import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct ArtistPhotoParsingTests {
    @Test func deezerSearchSkipsArtistsWithoutPictures() throws {
        let artists = try ArtistPhotoParser.parseDeezerSearch(try TestSupport.fixture("deezer_search_domi"))
        // The second "DOMi & JD BECK" has the empty-hash placeholder picture.
        #expect(artists.map(\.id) == [165408677])
        let a = try #require(artists.first)
        #expect(a.name == "DOMi & JD BECK" && a.fans == 8502 && a.albums == 4)
        #expect(a.pictureXL.absoluteString.hasSuffix("/885de3d24754c7cd5710cf46d5589ccb/1000x1000-000000-80-0-0.jpg"))
        #expect(a.pictureMedium.host == "cdn-images.dzcdn.net")
        #expect(a.link?.absoluteString == "https://www.deezer.com/artist/165408677")
    }

    @Test func deezerArtistLookup() throws {
        let a = try #require(try ArtistPhotoParser.parseDeezerArtist(try TestSupport.fixture("deezer_artist_domi")))
        #expect(a.id == 165408677 && a.pictureXL.absoluteString.contains("1000x1000"))
        // Unknown IDs come back as 200 with an error object.
        #expect(try ArtistPhotoParser.parseDeezerArtist(Data(#"{"error":{"type":"DataException","message":"no data","code":800}}"#.utf8)) == nil)
        #expect(throws: NetworkError.self) {
            try ArtistPhotoParser.parseDeezerSearch(Data(#"{"error":{"type":"Exception","message":"Quota limit exceeded","code":4}}"#.utf8))
        }
    }

    @Test func deezerArtistIdFromLinks() {
        func id(_ s: String) -> Int? { ArtistPhotoParser.deezerArtistId(from: URL(string: s)!) }
        #expect(id("https://www.deezer.com/artist/165408677") == 165408677)
        #expect(id("https://www.deezer.com/en/artist/27") == 27)
        #expect(id("https://www.deezer.com/album/27") == nil)
        #expect(id("https://evil.example/artist/27") == nil)
        #expect(id("deezer://www.deezer.com/artist/27") == nil)
    }

    @Test func wikipediaArticleImagesArePhotosOnly() throws {
        let images = try ArtistPhotoParser.parseWikimediaImages(try TestSupport.fixture("wp_images_radiohead"))
        let titles = images.map(\.title)
        #expect(titles.contains("File:Thom Yorke 1998.jpg"))
        #expect(titles.contains("File:The Smile 30 January 2022 - 2.png"))
        #expect(!titles.contains { $0.hasSuffix(".svg") || $0.hasSuffix(".ogg") })   // logos, icons, sound clips
        #expect(images.allSatisfy { min($0.width, $0.height) >= 200 && ArtistPhotoParser.isPhotoURL($0.thumbnailURL) })
        let yorke = try #require(images.first { $0.title == "File:Thom Yorke 1998.jpg" })
        #expect(yorke.width == 573 && yorke.height == 590)
        #expect(yorke.pageURL?.host == "commons.wikimedia.org")
    }

    @Test func commonsSearchKeepsTheRanking() throws {
        let images = try ArtistPhotoParser.parseWikimediaImages(try TestSupport.fixture("commons_search_domi"))
        #expect(images.map(\.title) == ["File:Domi and JD Beck at History (cropped).jpg", "File:Domi and JD Beck at History.jpg",
                                        "File:WHO ASKED album cover.jpg"])
        let c = ArtistPhotoCandidate(wikimedia: images[0], source: .commons, api: ArtistPhotoParser.commonsAPI)
        #expect(c.id == "wm:File:Domi and JD Beck at History (cropped).jpg")
        #expect(c.title == "Domi and JD Beck at History (cropped)" && c.detail == "Wikimedia Commons · 2485 × 1865")
        #expect(c.credit == "Wikimedia Commons")
    }

    @Test func onlyHttpsImagesFromKnownHostsAreDownloaded() throws {
        func ok(_ s: String) -> Bool { ArtistPhotoParser.isPhotoURL(URL(string: s)!) }
        #expect(ok("https://cdn-images.dzcdn.net/images/artist/x/1000x1000.jpg"))
        #expect(ok("https://upload.wikimedia.org/wikipedia/commons/c/c6/x.jpg"))
        #expect(!ok("http://upload.wikimedia.org/x.jpg"))
        #expect(!ok("https://evilwikimedia.org/x.jpg"))
        #expect(!ok("file:///etc/passwd"))
        let json = #"""
        {"query": {"pages": [
          {"title": "File:A.jpg", "imageinfo": [{"mime": "image/jpeg", "width": 800, "height": 800, "thumburl": "https://example.com/a.jpg"}]},
          {"title": "File:B.jpg", "imageinfo": [{"mime": "image/jpeg", "width": 800, "height": 800, "thumburl": "file:///etc/passwd"}]}]}}
        """#
        #expect(try ArtistPhotoParser.parseWikimediaImages(Data(json.utf8)).isEmpty)
        let deezer = #"{"data": [{"id": 1, "name": "X", "picture_medium": "https://example.com/a.jpg", "picture_xl": "https://example.com/b.jpg"}]}"#
        #expect(try ArtistPhotoParser.parseDeezerSearch(Data(deezer.utf8)).isEmpty)
    }

    @Test func fileURLsOnlyForKnownAPIs() throws {
        let url = try #require(ArtistPhotoParser.wikimediaFileURL(api: ArtistPhotoParser.commonsAPI, file: "File:A & B.jpg", width: 1200))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "titles", value: "File:A & B.jpg")))
        #expect(items.contains(URLQueryItem(name: "iiurlwidth", value: "1200")))
        #expect(ArtistPhotoParser.wikimediaFileURL(api: URL(string: "https://evil.example/w/api.php")!, file: "File:A.jpg", width: 1200) == nil)
    }

    @Test func choiceFileNamesMustStayInTheFolder() {
        #expect(ArtistPhotoChoice.isSafeFileName("0a1b2c-1234abcd.jpg"))
        for bad in ["", "..", ".hidden.jpg", "../x.jpg", "a/b.jpg", "/etc/passwd", "a\\b.jpg"] {
            #expect(!ArtistPhotoChoice.isSafeFileName(bad))
        }
    }

    @Test func chosenPhotosAreSavedApartFromArtistInfo() throws {
        let db = try Database(path: ":memory:")
        try db.saveArtistInfo(key: "domi & jd beck", ArtistInfo(name: "DOMi & JD BECK"), imageFile: "auto.jpg")
        let choice = ArtistPhotoChoice(file: "abc-1234.jpg", credit: "Deezer", creditURL: URL(string: "https://www.deezer.com/artist/165408677"))
        try db.saveArtistPhoto(key: "domi & jd beck", choice)
        #expect(try db.artistPhotos() == ["domi & jd beck": choice])
        // Updating the downloaded info leaves the choice alone.
        try db.saveArtistInfo(key: "domi & jd beck", ArtistInfo(name: "DOMi & JD BECK"), imageFile: "auto.jpg")
        #expect(try db.artistPhotos()["domi & jd beck"] == choice)
        try db.saveArtistPhoto(key: "domi & jd beck", nil)
        #expect(try db.artistPhotos().isEmpty)
        #expect(try db.artistInfos()["domi & jd beck"]?.imageFile == "auto.jpg")
    }

    @Test func untrustedPhotoRowsAreSanitized() throws {
        let db = try Database(path: ":memory:")
        try db.exec("INSERT INTO artist_photos(key,file,credit,credit_url,updated_at) VALUES('a','../../evil.jpg',NULL,NULL,0)")
        try db.exec("INSERT INTO artist_photos(key,file,credit,credit_url,updated_at) VALUES('b','ok.jpg','X','file:///Applications/Calculator.app',0)")
        let photos = try db.artistPhotos()
        #expect(photos["a"] == nil)
        #expect(photos["b"] == ArtistPhotoChoice(file: "ok.jpg", credit: "X", creditURL: nil))
    }
}

@Suite struct ArtistPhotoFinderTests {
    /// Serves fixtures by URL; anything else is a 404.
    static func finder(_ routes: [String: String], seen: Recorder? = nil) -> ArtistPhotoFinder {
        ArtistPhotoFinder { url in
            await seen?.add(url)
            for (needle, fixture) in routes where url.absoluteString.contains(needle) {
                return try TestSupport.fixture(fixture)
            }
            return nil
        }
    }

    actor Recorder {
        var urls: [URL] = []
        func add(_ url: URL) { urls.append(url) }
    }

    @Test func linkedPhotosComeFromTheArtistsLinks() async throws {
        let mb = try ArtistInfoParser.parseArtist(try TestSupport.fixture("mb_artist_domi"))
        let wp = try ArtistInfoParser.parseWikipediaSummary(try TestSupport.fixture("wp_summary_domi"))
        let info = ArtistInfo.assemble(name: "DOMi & JD BECK", mb: mb, wikidata: nil, wikipedia: wp, lastfm: nil)
        let finder = Self.finder(["api.deezer.com/artist/165408677": "deezer_artist_domi",
                                  "en.wikipedia.org/w/api.php": "wp_images_radiohead"])
        let found = await finder.linked(info)
        #expect(found.first?.id == "deezer:165408677")
        #expect(found.first?.detail.hasPrefix("Deezer (linked on MusicBrainz)") == true)
        #expect(found.dropFirst().allSatisfy { $0.source == .wikipedia && $0.wikiAPI == ArtistPhotoParser.wikipediaAPI })
        #expect(found.count > 5)
    }

    @Test func articleLeadPhotoComesFirst() async throws {
        var info = ArtistInfo(name: "Radiohead")
        info.links = [ArtistLink(kind: .wikipedia, url: URL(string: "https://en.wikipedia.org/wiki/Radiohead")!)]
        info.imageCreditURL = ArtistInfoParser.commonsPageURL(file: "Radiohead New Jersey 2012.jpg")
        let found = await Self.finder(["en.wikipedia.org/w/api.php": "wp_images_radiohead"]).linked(info)
        #expect(found.first?.wikiFile == "File:Radiohead New Jersey 2012.jpg")
    }

    @Test func searchCombinesDeezerAndCommons() async throws {
        let finder = Self.finder(["api.deezer.com/search/artist": "deezer_search_domi",
                                  "commons.wikimedia.org/w/api.php": "commons_search_domi"])
        let found = try await finder.search("DOMi & JD BECK")
        #expect(found.map(\.source) == [.deezer, .commons, .commons, .commons])
        #expect(try await finder.search("   ").isEmpty)
    }

    @Test func searchFailsOnlyWhenBothSourcesFail() async throws {
        let half = ArtistPhotoFinder { url in
            if url.host == "api.deezer.com" { throw NetworkError.http(503, url.absoluteString) }
            return try TestSupport.fixture("commons_search_domi")
        }
        #expect(try await half.search("Domi").count == 3)
        let down = ArtistPhotoFinder { url in throw NetworkError.http(503, url.absoluteString) }
        await #expect(throws: NetworkError.self) { try await down.search("Domi") }
    }

    @Test func wikimediaPhotosAreResolvedToALargeRendition() async throws {
        let images = try ArtistPhotoParser.parseWikimediaImages(try TestSupport.fixture("commons_search_domi"))
        let c = ArtistPhotoCandidate(wikimedia: images[0], source: .commons, api: ArtistPhotoParser.commonsAPI)
        let recorder = Recorder()
        let finder = ArtistPhotoFinder { url in
            await recorder.add(url)
            if url.host == "commons.wikimedia.org" { return try TestSupport.fixture("commons_search_domi") }
            return Data("jpeg".utf8)
        }
        #expect(try await finder.image(for: c) == Data("jpeg".utf8))
        let urls = await recorder.urls
        #expect(urls.count == 2)
        #expect(urls[0].query?.contains("iiurlwidth=1200") == true)
        #expect(ArtistPhotoParser.isPhotoURL(urls[1]))
    }
}
