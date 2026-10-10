import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct AlbumInfoTests {
    @Test func releaseGroupWithNoisyGenresAndReviews() throws {
        let rg = try ArtistInfoParser.parseReleaseGroup(try TestSupport.fixture("mb_rg_abbey"))
        #expect(rg.title == "Abbey Road" && rg.primaryType == "Album" && rg.firstReleaseDate == "1969-09-26")
        // 23 community genres, most with 1–4 votes; only the well-supported ones survive.
        #expect(rg.genres == ["rock", "pop rock", "pop"])
        #expect(rg.rating == 4.6 && rg.ratingVotes == 71)

        let info = AlbumInfo.assemble(title: "Abbey Road (Super Deluxe Edition)", releaseGroup: rg, release: nil,
                                      wikidata: nil, wikipedia: nil, lastfm: nil)
        #expect(info.title == "Abbey Road")
        #expect(info.reviews.map(\.title) == ["BBC Music"])
        let kinds = info.links.map(\.kind)
        #expect(kinds.contains(.allmusic) && kinds.contains(.discogs) && kinds.contains(.rateyourmusic) && kinds.contains(.genius))
        #expect(kinds.contains(.lastfm) && kinds.last == .musicbrainz)
        #expect(kinds.firstIndex(of: .review)! < kinds.firstIndex(of: .discogs)!)
        #expect(!info.links.contains { $0.url.host?.contains("musik-sammler") == true })
    }

    @Test func unratedReleaseGroup() throws {
        let rg = try ArtistInfoParser.parseReleaseGroup(try TestSupport.fixture("mb_rg_thunder"))
        let info = AlbumInfo.assemble(title: "Such Sweet Thunder", releaseGroup: rg, release: nil, wikidata: nil, wikipedia: nil, lastfm: nil)
        #expect(info.rating == nil && info.ratingVotes == 0)
        #expect(info.genres == ["jazz"])
        #expect(info.firstReleaseYear == 1957)
    }

    @Test func descriptionFallbacks() throws {
        let rg = try ArtistInfoParser.parseReleaseGroup(try TestSupport.fixture("mb_rg_thunder"))
        let wp = try ArtistInfoParser.parseWikipediaSummary(try TestSupport.fixture("wp_summary_thunder"))
        let lf = try ArtistInfoParser.parseLastFMAlbum(try TestSupport.fixture("lastfm_album_info"))
        let wd = try ArtistInfoParser.parseWikidata(try TestSupport.fixture("wd_album_abbey"))

        let a = AlbumInfo.assemble(title: "x", releaseGroup: rg, release: nil, wikidata: nil, wikipedia: wp, lastfm: lf)
        #expect(a.descriptionSource == "Wikipedia" && a.description?.hasPrefix("Such Sweet Thunder is a Duke Ellington album") == true)
        #expect(a.lastfmUserPlaycount == 12)

        let b = AlbumInfo.assemble(title: "x", releaseGroup: rg, release: nil, wikidata: nil, wikipedia: nil, lastfm: lf)
        #expect(b.descriptionSource == "Last.fm" && b.description == "Such Sweet Thunder is a 1957 suite by Duke Ellington and Billy Strayhorn.")

        let c = AlbumInfo.assemble(title: "x", releaseGroup: nil, release: nil, wikidata: wd, wikipedia: nil, lastfm: nil)
        #expect(c.description == "1969 studio album by the Beatles." && c.descriptionSource == "Wikidata")
        #expect(c.notFound)
        #expect(wd.enwikiTitle == "Abbey Road")
    }

    @Test func reviewPublications() {
        func p(_ s: String) -> String { ArtistLink.publication(for: URL(string: s)!) }
        #expect(p("https://www.bbc.co.uk/music/reviews/cwvr") == "BBC Music")
        #expect(p("https://pitchfork.com/reviews/albums/x") == "Pitchfork")
        #expect(p("https://www.someblog.co.uk/review") == "Someblog")
        #expect(p("https://reviews.example.com/x") == "Example")
    }

    @Test func typeLabels() {
        var i = AlbumInfo(title: "x")
        #expect(i.typeLabel == nil)
        i.primaryType = "Album"
        #expect(i.typeLabel == "Album")
        i.secondaryTypes = ["Live"]
        #expect(i.typeLabel == "Live Album")
        i.primaryType = "EP"
        #expect(i.typeLabel == "Live EP")
    }

    @Test func tracklistMergesLibraryAndMissingTracks() throws {
        let release = try MusicBrainzParser.parseRelease(try TestSupport.fixture("mb_release_okcomputer"))
        let info = AlbumInfo.assemble(title: "OK Computer", releaseGroup: nil, release: release, wikidata: nil, wikipedia: nil, lastfm: nil)
        #expect(info.tracklist.count == release.tracks.count)
        let first = try #require(info.tracklist.first)

        // One track matched by recording ID, one by position, one the release doesn't list.
        var byRecording = SearchFixtures.track(1, "Airbag (tagged differently)", artist: "Radiohead", album: "OK Computer", mbid: first.recordingId)
        byRecording.metadata.trackNo = 99
        let second = info.tracklist[1]
        var byPosition = SearchFixtures.track(2, second.title, artist: "Radiohead", album: "OK Computer")
        byPosition.metadata.discNo = second.disc
        byPosition.metadata.trackNo = second.number
        var bonus = SearchFixtures.track(3, "Bonus", artist: "Radiohead", album: "OK Computer")
        bonus.metadata.trackNo = 50

        let rows = AlbumTracklist.merge(library: [bonus, byPosition, byRecording], tracklist: info.tracklist)
        #expect(rows.count == info.tracklist.count + 1)
        guard case .owned(let t0, _) = rows[0], case .owned(let t1, _) = rows[1], case .owned(let last, nil) = rows.last! else {
            Issue.record("unexpected rows \(rows)"); return
        }
        #expect(t0.id == 1 && t1.id == 2 && last.id == 3)
        #expect(rows.dropFirst(2).dropLast().allSatisfy { if case .missing = $0 { true } else { false } })

        #expect(AlbumTracklist.merge(library: [bonus], tracklist: []).count == 1)
    }

    @Test func cacheRoundTrip() throws {
        let db = try Database(path: ":memory:")
        var info = AlbumInfo(title: "Abbey Road")
        info.rating = 4.6; info.ratingVotes = 71
        var review = ArtistLink(kind: .review, url: URL(string: "https://www.bbc.co.uk/music/reviews/cwvr")!)
        review.label = "BBC Music"
        info.links = [review]
        info.tracklist = [TracklistEntry(disc: 1, number: 1, title: "Come Together", duration: 259)]
        try db.saveAlbumInfo(key: "the beatles\u{1}abbey road", info)
        #expect(try db.albumInfos()["the beatles\u{1}abbey road"] == info)
    }
}
