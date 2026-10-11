import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct ArtistInfoParsingTests {
    @Test func musicBrainzArtist() throws {
        let a = try ArtistInfoParser.parseArtist(try TestSupport.fixture("mb_artist_ellington_orch"))
        #expect(a.id == "c01557ad-d41e-4316-a285-605769e2ab3b")
        #expect(a.name == "Duke Ellington and His Orchestra")
        #expect(a.type == "Orchestra" && a.country == "US" && a.begin == "1927" && a.ended)
        #expect(a.genres.prefix(3).sorted() == ["big band", "jazz", "swing"])
        #expect(a.urls.contains { $0.0 == "wikidata" && $0.1.absoluteString.hasSuffix("Q1264385") })
    }

    @Test func linksAreClassifiedDedupedAndOrdered() throws {
        let a = try ArtistInfoParser.parseArtist(try TestSupport.fixture("mb_artist_domi"))
        let info = ArtistInfo.assemble(name: "DOMi & JD BECK", mb: a, wikidata: nil, wikipedia: nil, lastfm: nil)
        let kinds = info.links.map(\.kind)
        #expect(kinds.first == .official)
        #expect(kinds.contains(.spotify) && kinds.contains(.instagram) && kinds.contains(.youtube) && kinds.contains(.discogs))
        #expect(kinds.last == .musicbrainz)
        #expect(Set(kinds).count == kinds.count)                       // one link per kind
        #expect(!info.links.contains { $0.url.host?.contains("viaf") == true })  // catalogs are left out
    }

    @Test func classifyByHost() {
        func k(_ type: String, _ url: String) -> ArtistLink.Kind? { ArtistLink.classify(relationType: type, url: URL(string: url)!) }
        #expect(k("social network", "https://www.instagram.com/x") == .instagram)
        #expect(k("social network", "https://x.com/x") == .twitter)
        #expect(k("free streaming", "https://open.spotify.com/artist/1") == .spotify)
        #expect(k("streaming", "https://music.apple.com/us/artist/1") == .appleMusic)
        #expect(k("other databases", "https://d-nb.info/gnd/1") == nil)
        #expect(k("official homepage", "file:///Volumes/X/evil.app") == nil)
        #expect(k("social network", "x-apple-foo://instagram.com/x") == nil)
        #expect(k("wikipedia", "javascript:alert(1)") == nil)
    }

    @Test func onlyWebLinksAreAccepted() throws {
        #expect(URL(string: "https://example.com/x")!.isWebLink)
        #expect(URL(string: "HTTP://example.com")!.isWebLink)
        #expect(!URL(string: "file:///Applications/Calculator.app")!.isWebLink)
        #expect(!URL(string: "https:relative")!.isWebLink)
        #expect(URL(webLink: "smb://host/share") == nil)
        #expect(URL(webLink: "https://musicbrainz.org") != nil)

        let json = #"""
        {"id": "a1", "name": "Evil", "relations": [
          {"type": "official homepage", "url": {"resource": "file:///Volumes/X/evil.app"}},
          {"type": "bandcamp", "url": {"resource": "x-custom://run"}},
          {"type": "discogs", "url": {"resource": "https://www.discogs.com/artist/1"}}]}
        """#
        let a = try ArtistInfoParser.parseArtist(Data(json.utf8))
        #expect(a.urls.map(\.1.absoluteString) == ["https://www.discogs.com/artist/1"])
        let info = ArtistInfo.assemble(name: "Evil", mb: a, wikidata: nil, wikipedia: nil, lastfm: nil)
        #expect(info.links.allSatisfy(\.url.isWebLink))

        let wp = try ArtistInfoParser.parseWikipediaSummary(Data(#"{"extract": "x", "content_urls": {"desktop": {"page": "file:///etc/passwd"}}}"#.utf8))
        #expect(wp?.pageURL == nil)
        let lf = try ArtistInfoParser.parseLastFMArtist(Data(#"{"artist": {"url": "file:///etc/passwd"}}"#.utf8))
        #expect(lf?.url == nil)
    }

    @Test func wikidataAndWikipedia() throws {
        let wd = try ArtistInfoParser.parseWikidata(try TestSupport.fixture("wd_domi"))
        #expect(wd.enwikiTitle == "Domi and JD Beck")
        #expect(wd.imageFile == "Domi and JD Beck at History (cropped).jpg")
        let orch = try ArtistInfoParser.parseWikidata(try TestSupport.fixture("wd_ellington_orch"))
        #expect(orch.enwikiTitle == nil && orch.imageFile == "Duke Ellington Big Band.jpg")
        #expect(orch.description?.contains("jazz band") == true)

        let wp = try #require(try ArtistInfoParser.parseWikipediaSummary(try TestSupport.fixture("wp_summary_domi")))
        #expect(wp.extract.hasPrefix("Domi and JD Beck are a jazz duo"))
        #expect(wp.pageURL?.absoluteString == "https://en.wikipedia.org/wiki/Domi_and_JD_Beck")
        #expect(wp.imageFile == "Domi and JD Beck at History (cropped).jpg")
        #expect(try ArtistInfoParser.parseWikipediaSummary(Data(#"{"type":"disambiguation","extract":"x may refer to"}"#.utf8)) == nil)
    }

    @Test func commonsURLs() {
        #expect(ArtistInfoParser.commonsImageURL(file: "Duke Ellington Big Band.jpg")?.absoluteString
                == "https://commons.wikimedia.org/wiki/Special:FilePath/Duke_Ellington_Big_Band.jpg?width=800")
        #expect(ArtistInfoParser.commonsPageURL(file: "A (b).jpg")?.absoluteString == "https://commons.wikimedia.org/wiki/File:A_(b).jpg")
        #expect(ArtistInfoParser.wikipediaTitle(from: URL(string: "https://en.wikipedia.org/wiki/The_Beatles")!) == "The Beatles")
        #expect(ArtistInfoParser.wikipediaTitle(from: URL(string: "https://fr.wikipedia.org/wiki/X")!) == nil)
        #expect(InfoFetcher.summaryURL(title: "AC/DC")?.absoluteString == "https://en.wikipedia.org/api/rest_v1/page/summary/AC%2FDC")
    }

    @Test func lastfmBioIsCleaned() throws {
        let a = try #require(try ArtistInfoParser.parseLastFMArtist(try TestSupport.fixture("lastfm_artist_info")))
        #expect(a.bio == "Duke Ellington & His Orchestra was the big band led by Duke Ellington from 1923 until his death.")
        #expect(a.listeners == 312_045 && a.userPlaycount == 57)
    }

    @Test func bioFallsBackFromWikipediaToLastfmToWikidata() throws {
        let mb = try ArtistInfoParser.parseArtist(try TestSupport.fixture("mb_artist_ellington_orch"))
        let wd = try ArtistInfoParser.parseWikidata(try TestSupport.fixture("wd_ellington_orch"))
        let lf = try ArtistInfoParser.parseLastFMArtist(try TestSupport.fixture("lastfm_artist_info"))

        let withLastfm = ArtistInfo.assemble(name: "Duke Ellington & His Orchestra", mb: mb, wikidata: wd, wikipedia: nil, lastfm: lf)
        #expect(withLastfm.bioSource == "Last.fm")
        #expect(withLastfm.lastfmUserPlaycount == 57)
        #expect(withLastfm.imageURL?.absoluteString.contains("Duke_Ellington_Big_Band.jpg") == true)

        let noLastfm = ArtistInfo.assemble(name: "Duke Ellington & His Orchestra", mb: mb, wikidata: wd, wikipedia: nil, lastfm: nil)
        #expect(noLastfm.bioSource == "Wikidata")
        #expect(noLastfm.bio == "US musical group; jazz band led by Duke Ellington.")
        #expect(noLastfm.summary(locale: Locale(identifier: "en_US")) == "Orchestra · United States · From 1927")
        #expect(!noLastfm.notFound)

        let nothing = ArtistInfo.assemble(name: "Nobody", mb: nil, wikidata: nil, wikipedia: nil, lastfm: nil)
        #expect(nothing.notFound && nothing.bio == nil && nothing.links.isEmpty)
    }

    @Test func summaries() {
        var i = ArtistInfo(name: "x")
        i.type = "Group"; i.country = "US"; i.begin = "2018-03"
        #expect(i.summary(locale: Locale(identifier: "en_US")) == "Group · United States · 2018–present")
        i.type = "Person"; i.begin = "1899-04-29"; i.end = "1974-05-24"; i.ended = true
        #expect(i.summary(locale: Locale(identifier: "en_US")) == "Person · United States · 1899–1974")
    }
}

@Suite struct ArtistResolverTests {
    @Test func singleTaggedIdWins() {
        #expect(ArtistResolver.choose(name: "X", taggedIds: ["a", "a"], searchResults: []) == "a")
    }

    @Test func creditsOfSeveralPeopleUseAConfidentNameMatch() throws {
        let results = try ArtistInfoParser.parseArtistSearch(try TestSupport.fixture("mb_artist_search_rv"))
        #expect(ArtistResolver.choose(name: "Rachael & Vilray", taggedIds: ["aa4ec305", "32932c69"], searchResults: results)
                == "17883a96-8ae6-49c0-8e38-442ffd69cd67")
        #expect(ArtistResolver.choose(name: "Rachael and Vilray", taggedIds: [], searchResults: results) != nil)
        #expect(ArtistResolver.choose(name: "Someone Else", taggedIds: [], searchResults: results) == nil)
    }

    @Test func lowScoresAreRejected() {
        let weak = MBArtist(id: "w", name: "Beatles", type: nil, country: nil, begin: nil, end: nil, ended: false,
                            disambiguation: nil, genres: [], score: 60, urls: [])
        #expect(ArtistResolver.choose(name: "The Beatles", taggedIds: [], searchResults: [weak]) == nil)
        var strong = weak; strong.score = 100
        #expect(ArtistResolver.choose(name: "The Beatles", taggedIds: [], searchResults: [strong]) == "w")
    }
}

@Suite struct PlayHistoryTests {
    @Test func totalsAndCascade() throws {
        let db = try Database(path: ":memory:")
        let a = try db.insertTrack(SearchFixtures.library[0])
        let b = try db.insertTrack(SearchFixtures.library[1])
        let t0 = Date(timeIntervalSince1970: 1_000)
        try db.recordPlay(trackId: a.id, startedAt: t0, listened: 200, counted: true)
        try db.recordPlay(trackId: a.id, startedAt: t0.addingTimeInterval(500), listened: 20, counted: false)
        try db.recordPlay(trackId: b.id, startedAt: t0, listened: 130, counted: true)
        let totals = try db.playTotals()
        #expect(totals[a.id] == PlayTotal(plays: 1, listened: 220, lastPlayed: t0.addingTimeInterval(500)))
        #expect((totals[a.id]! + totals[b.id]!).plays == 2)
        try db.deleteTrack(id: a.id)
        #expect(try db.playTotals()[a.id] == nil)
    }

    @Test func artistInfoCache() throws {
        let db = try Database(path: ":memory:")
        var info = ArtistInfo(name: "DOMi & JD BECK")
        info.bio = "A duo."
        info.links = [ArtistLink(kind: .official, url: URL(string: "https://domiandjdbeck.com")!)]
        try db.saveArtistInfo(key: "domi & jd beck", info, imageFile: "abc.jpg")
        let loaded = try db.artistInfos()["domi & jd beck"]
        #expect(loaded?.info == info && loaded?.imageFile == "abc.jpg")
    }
}
