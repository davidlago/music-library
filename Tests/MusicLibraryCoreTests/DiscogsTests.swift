import Foundation
import Testing
@testable import MusicLibraryCore

/// Answers Discogs API requests from fixtures, without the network: release 2772432 and 8961614, a barcode search
/// with the Rick Astley one, a `q` search for "kind of blue" with the vinyl one, anything else with no results.
final class DiscogsStub: URLProtocol, @unchecked Sendable {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
        func all() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    static let log = Log()

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscogsStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.log.append(url)
        let items = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { a, _ in a })
        var body = Data(#"{"pagination":{"items":0},"results":[]}"#.utf8)
        var status = 200
        switch url.path {
        case "/releases/2772432": body = (try? TestSupport.fixture("discogs_release_kindofblue")) ?? body
        case "/releases/8961614": body = (try? TestSupport.fixture("discogs_release_wall")) ?? body
        case "/releases/429": status = 429
        case "/database/search":
            if items["barcode"] != nil { body = (try? TestSupport.fixture("discogs_search_barcode_astley")) ?? body }
            if items["q"]?.lowercased().contains("kind of blue") == true { body = (try? TestSupport.fixture("discogs_search_kindofblue_vinyl")) ?? body }
        default: status = 404
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct DiscogsTests {
    // MARK: Search results

    @Test func vinylSearchResults() throws {
        let editions = try DiscogsParser.parseSearch(try TestSupport.fixture("discogs_search_kindofblue_vinyl"), medium: .vinyl)
        #expect(editions.count == 10)
        let first = try #require(editions.first)
        #expect(first.id == "discogs-2772432")
        #expect(first.discogsReleaseID == 2772432 && first.discogsMasterID == 5460)
        #expect(first.isDiscogs && first.groupKey == "discogs-master-5460")
        #expect(first.title == "Kind Of Blue" && first.artist == "Miles Davis")
        #expect(first.releaseGroupTitle == "Kind Of Blue")
        #expect(first.date == "2010" && first.year == 2010 && first.country == "France")
        #expect(first.recordLabel == "Columbia", "only the first label: the rest are other companies")
        #expect(first.catalogNumber == "CS 8163")
        #expect(first.medium == .vinyl && first.formatDetail == "Vinyl" && first.discCount == 1)
        #expect(first.formatNotes == "LP, Album, Reissue, Stereo, 180 gram")
        #expect(first.barcode == "", "runout matrix codes aren't barcodes")
        #expect(editions[1].barcode == "886976805715")
        #expect(first.thumbnail == nil, "no pictures without an account")
        #expect(MBID.validated(first.id) == nil)
        #expect(Set(editions.map(\.groupKey)).count < editions.count, "versions of one master group together")
    }

    @Test func barcodeSearchKeepsEveryFormatPreferringTheMedium() throws {
        let all = try DiscogsParser.parseSearch(try TestSupport.fixture("discogs_search_barcode_astley"))
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { $0.artist == "Rick Astley" && $0.title == "Never Gonna Give You Up" })
        #expect(all[0].barcode == "5012394144777")
        #expect(all.contains { $0.barcode == "5012394144777" && $0.id != all[0].id }, "spaced barcodes read as digits")
        let cdFirst = CollectionEditionParser.preferring(.cd, all)
        #expect(Set(cdFirst.map(\.id)) == Set(all.map(\.id)))
    }

    // MARK: Releases

    @Test func singleRecordRelease() throws {
        let r = try DiscogsParser.parseRelease(try TestSupport.fixture("discogs_release_kindofblue"))
        #expect(r.id == 2772432 && r.title == "Kind Of Blue" && r.artist == "Miles Davis")
        #expect(r.year == 2010 && r.labels.first == "Columbia" && r.catalogNumbers.first == "CS 8163")
        #expect(r.media == ["Vinyl"])
        #expect(r.tracks.map(\.title) == ["So What", "Freddie Freeloader", "Blue In Green", "All Blues", "Flamenco Sketches"])
        #expect(r.tracks.map(\.numberLabel) == ["A1", "A2", "A3", "B1", "B2"])
        #expect(r.tracks.map(\.trackNo) == [1, 2, 3, 4, 5])
        #expect(r.tracks.allSatisfy { $0.discNo == 1 && $0.trackTotal == 5 && $0.recordingId.isEmpty && $0.artist == "Miles Davis" })
        #expect(r.tracks[0].durationSeconds == 536)
        #expect(!r.images.isEmpty && r.images.allSatisfy(DiscogsLink.isImageURL))
        #expect(r.thumbnail.map(DiscogsLink.isImageURL) == true)
        #expect(r.webURL?.absoluteString == "https://www.discogs.com/release/2772432")

        let e = r.edition
        #expect(e.id == "discogs-2772432" && e.discogsReleaseID == 2772432 && e.discogsMasterID == 5460)
        #expect(e.trackCount == 5 && e.discCount == 1 && e.medium == .vinyl)

        let info = r.releaseInfo
        #expect(info.id.isEmpty && info.releaseGroupId == nil, "no MusicBrainz IDs")
        #expect(info.album == "Kind Of Blue" && info.albumArtist == "Miles Davis" && info.discTotal == 1)
        var m = TrackMetadata()
        info.apply(info.tracks[3], to: &m)
        #expect(m.title == "All Blues" && m.trackNo == 4 && m.discNo == 1 && m.album == "Kind Of Blue")
        #expect(m.mbReleaseId == nil && m.mbRecordingId == nil)
        #expect(m.extended.trackNumberLabel == "B1")
        #expect(m.extended.catalogNumber == "CS 8163")
    }

    @Test func doubleRecordSidesGoTwoToADisc() throws {
        let r = try DiscogsParser.parseRelease(try TestSupport.fixture("discogs_release_wall"))
        #expect(r.media == ["Vinyl", "Vinyl"])
        #expect(r.edition.formatDetail == "2×Vinyl" && r.edition.discCount == 2 && r.edition.trackCount == 26)
        #expect(r.barcode == "5099902988313")
        #expect(r.catalogNumbers == ["PFRLP11"], "the barcode a label entry lists as its catalog number is left out")
        #expect(r.genres == ["Rock", "Prog Rock", "Classic Rock", "Art Rock"])
        let first = r.tracks.filter { $0.discNo == 1 }, second = r.tracks.filter { $0.discNo == 2 }
        #expect(first.count == 13 && second.count == 13)
        #expect(first.first?.numberLabel == "A1" && first.last?.numberLabel == "B7" && first.last?.trackNo == 13)
        #expect(second.first?.numberLabel == "C1" && second.first?.trackNo == 1 && second.first?.title == "Hey You")
        #expect(second.allSatisfy { $0.trackTotal == 13 })
        #expect(r.releaseInfo.discTotal == 2)
        #expect(r.releaseInfo.releaseGenres.first?.name == "Rock")
    }

    @Test func tracklistShapes() throws {
        func tracks(_ json: String, media: [String] = ["CD"]) throws -> [ReleaseTrack] {
            let list = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
            return DiscogsParser.tracks(list, media: media, artist: "Band")
        }
        // Headings are left out; movements with their own positions are songs.
        let work = try tracks("""
        [{"type_":"heading","position":"","title":"Side One"},
         {"type_":"index","position":"","title":"Suite","sub_tracks":[{"type_":"track","position":"A1a","title":"Dawn","duration":"2:00"},
                                                                      {"type_":"track","position":"A1b","title":"Dusk","duration":"3:00"}]},
         {"type_":"index","position":"B1","title":"Medley","sub_tracks":[{"type_":"track","position":"","title":"One"},{"type_":"track","position":"","title":"Two"}]},
         {"type_":"track","position":"B2","title":"Last","duration":"1:02:03","artists":[{"name":"Guest (3)","anv":"","join":"&"},{"name":"Friend*","anv":"","join":""}]}]
        """, media: ["12\" Vinyl"])
        #expect(work.map(\.title) == ["Suite: Dawn", "Suite: Dusk", "Medley", "Last"])
        #expect(work.map(\.numberLabel) == ["A1a", "A1b", "B1", "B2"])
        #expect(work.map(\.trackNo) == [1, 2, 3, 4])
        #expect(work[3].durationSeconds == 3723 && work[3].artist == "Guest & Friend" && work[0].artist == "Band")
        #expect(work.allSatisfy { $0.mediaFormat == "12\" Vinyl" })

        // "2-1" names the disc; numbers starting over start the next one.
        let named = try tracks(#"[{"position":"1-1","title":"a"},{"position":"1-2","title":"b"},{"position":"2-1","title":"c"}]"#, media: ["CD", "CD"])
        #expect(named.map(\.discNo) == [1, 1, 2] && named.map(\.trackNo) == [1, 2, 1])
        #expect(named.map(\.numberLabel) == ["1-1", "1-2", "2-1"])
        let restarted = try tracks(#"[{"position":"1","title":"a"},{"position":"2","title":"b"},{"position":"1","title":"c"}]"#, media: ["CD", "CD"])
        #expect(restarted.map(\.discNo) == [1, 1, 2] && restarted.allSatisfy { $0.numberLabel.isEmpty })
        // A single record keeps every side on one disc.
        let single = try tracks(#"[{"position":"A","title":"a"},{"position":"B","title":"b"}]"#, media: ["7\" Vinyl"])
        #expect(single.map(\.discNo) == [1, 1] && single.map(\.numberLabel) == ["A", "B"])
    }

    @Test func fields() {
        #expect(DiscogsParser.clean("Nirvana (2)") == "Nirvana")
        #expect(DiscogsParser.clean("Miles Davis*") == "Miles Davis")
        #expect(DiscogsParser.clean("Blink-182") == "Blink-182")
        #expect(DiscogsParser.date("1959-00-00") == "1959" && DiscogsParser.date("1987-07-00") == "1987-07")
        #expect(DiscogsParser.date("2016-08-26") == "2016-08-26" && DiscogsParser.date("") == "")
        #expect(DiscogsParser.duration("3:32") == 212 && DiscogsParser.duration("") == nil && DiscogsParser.duration("x:10") == nil)
        #expect(DiscogsParser.media([["name": "Box Set", "qty": "1"], ["name": "Vinyl", "qty": "3", "descriptions": ["12\"", "LP"]],
                                     ["name": "CD", "qty": "1"]]) == ["12\" Vinyl", "12\" Vinyl", "12\" Vinyl", "CD"])
        #expect(DiscogsParser.barcode(["XSM 47326", "8 88751 11921 5", "888751119215"]) == "888751119215")
        #expect(DiscogsParser.credit([["name": "Simon", "anv": "", "join": ","], ["name": "Garfunkel (2)", "anv": "Art", "join": ""]]) == "Simon, Art")
    }

    @Test func links() {
        #expect(DiscogsLink.releaseID(in: "https://www.discogs.com/release/2772432-Miles-Davis-Kind-Of-Blue") == 2772432)
        #expect(DiscogsLink.releaseID(in: " https://www.discogs.com/es/release/8961614-Pink-Floyd-The-Wall?ev=rr ") == 8961614)
        #expect(DiscogsLink.releaseID(in: "discogs.com/release/123") == 123)
        #expect(DiscogsLink.releaseID(in: "[r2772432]") == 2772432)
        #expect(DiscogsLink.releaseID(in: "https://www.discogs.com/master/5460-Miles-Davis-Kind-Of-Blue") == nil)
        #expect(DiscogsLink.releaseID(in: "https://evil.example/discogs.com/release/1") == nil)
        #expect(DiscogsLink.releaseID(in: "https://discogs.com.evil.example/release/1") == nil)
        #expect(DiscogsLink.releaseID(in: "miles davis kind of blue") == nil)
        #expect(DiscogsLink.releaseID(in: "discogs.com/release/0") == nil)
        #expect(DiscogsLink.isImageURL(URL(string: "https://i.discogs.com/a.jpeg")!))
        #expect(!DiscogsLink.isImageURL(URL(string: "http://i.discogs.com/a.jpeg")!))
        #expect(!DiscogsLink.isImageURL(URL(string: "https://example.com/a.jpeg")!))
    }

    // MARK: Client

    @Test func clientSearches() async throws {
        let client = DiscogsClient(session: DiscogsStub.session)
        let before = DiscogsStub.log.all().count
        func requests() -> [URLComponents] { DiscogsStub.log.all().dropFirst(before).compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) } }

        let pasted = try await client.searchEditions(CollectionReleaseQuery(text: "https://www.discogs.com/release/8961614-Pink-Floyd-The-Wall", medium: .vinyl))
        #expect(pasted.map(\.id) == ["discogs-8961614"] && pasted[0].trackCount == 26)

        let words = try await client.searchEditions(CollectionReleaseQuery(text: "Miles Davis Kind of Blue", medium: .vinyl))
        #expect(words.count == 10)
        let wordsQuery = try #require(requests().last?.queryItems)
        #expect(wordsQuery.contains(.init(name: "format", value: "Vinyl")) && wordsQuery.contains(.init(name: "type", value: "release")))

        let code = try await client.searchEditions(CollectionReleaseQuery(text: "5 012394 144777", medium: .vinyl))
        #expect(code.first?.barcode == "5012394144777")
        let codeQuery = try #require(requests().last?.queryItems)
        #expect(codeQuery.contains(.init(name: "barcode", value: "5012394144777")) && !codeQuery.contains { $0.name == "format" })

        // Words that find nothing are tried as a catalog number.
        let none = try await client.searchEditions(CollectionReleaseQuery(text: "CL 1355", medium: .cd))
        #expect(none.isEmpty)
        let last = requests().suffix(2).map { $0.queryItems ?? [] }
        #expect(last.first?.contains(.init(name: "q", value: "CL 1355")) == true)
        #expect(last.last?.contains(.init(name: "catno", value: "CL 1355")) == true && last.last?.contains(.init(name: "format", value: "CD")) == true)

        await #expect(throws: DiscogsError.busy) { try await client.release(id: 429) }
    }

    @Test func clientStaysUnderTheLimit() async throws {
        let client = DiscogsClient(session: DiscogsStub.session, window: 2, period: 0.4)
        let start = Date()
        for _ in 0..<3 { _ = try await client.release(id: 2772432) }
        #expect(Date().timeIntervalSince(start) >= 0.35, "the third request waits for the first to leave the window")
    }

    // MARK: Items and album info

    @Test func draftKeepsTheDiscogsRelease() throws {
        let r = try DiscogsParser.parseRelease(try TestSupport.fixture("discogs_release_wall"))
        let item = CollectionDraft.item(from: r.edition, medium: .vinyl, sticker: 4)
        #expect(item.discogsReleaseID == 8961614 && item.releaseID == nil && item.releaseGroupID == nil)
        #expect(item.album == "The Wall" && item.artist == "Pink Floyd" && item.year == 2016)
        #expect(item.barcode == "5099902988313" && item.discCount == 2 && item.trackCount == 26 && item.formatDetail == "2×Vinyl")
        #expect(item.stickerNumber == 4)
    }

    @Test func storeKeepsTheDiscogsRelease() throws {
        let path = try TestSupport.tempDir().appendingPathComponent("library.sqlite").path
        // A library 1.27 made: no discogs_release_id column.
        var db: Database? = try Database(path: path)
        try db?.exec("ALTER TABLE collection_items DROP COLUMN discogs_release_id")
        try db?.exec("INSERT INTO collection_items(id,medium,sticker,album,artist,album_key,created_at,updated_at) VALUES('old','vinyl',1,'Old','Artist','k',1,1)")
        db = nil

        db = try Database(path: path)
        let reopened = try #require(db)
        #expect(try reopened.columns(of: "collection_items").contains("discogs_release_id"))
        #expect(try reopened.collectionItems().items.map(\.id) == ["old"])
        var found = CollectionItem(id: "found", medium: .vinyl, album: "The Wall", artist: "Pink Floyd")
        found.discogsReleaseID = 8961614
        try reopened.saveCollectionItem(found)
        #expect(try reopened.collectionItems().items.first { $0.id == "found" }?.discogsReleaseID == 8961614)

        // An older version's upsert names only its own columns and keeps the release.
        try reopened.exec("INSERT INTO collection_items(id,medium,album,artist,album_key,created_at,updated_at) VALUES('found','vinyl','The Wall','Pink Floyd','k',1,2) ON CONFLICT(id) DO UPDATE SET album=excluded.album, updated_at=excluded.updated_at")
        #expect(try reopened.collectionItems().items.first { $0.id == "found" }?.discogsReleaseID == 8961614)

        // A bad value reads as none.
        try reopened.exec("UPDATE collection_items SET discogs_release_id=-5 WHERE id='found'")
        #expect(try reopened.collectionItems().items.first { $0.id == "found" }?.discogsReleaseID == nil)
    }

    @Test func albumInfoTakesTheDiscogsTrackList() throws {
        let r = try DiscogsParser.parseRelease(try TestSupport.fixture("discogs_release_kindofblue"))
        let info = AlbumInfo.assemble(title: "Kind Of Blue", releaseGroup: nil, release: r.releaseInfo, wikidata: nil,
                                      wikipedia: nil, lastfm: nil, discogs: r)
        #expect(info.tracklist.map(\.displayPosition) == ["A1", "A2", "A3", "B1", "B2"])
        #expect(info.tracklist.allSatisfy { $0.recordingId.isEmpty && $0.disc == 1 })
        #expect(info.links.contains { $0.kind == .discogs && $0.url.absoluteString == "https://www.discogs.com/release/2772432" })
        #expect(info.genres == ["Jazz", "Modal"])
        #expect(!info.notFound)
    }

    @Test func fetcherReadsDiscogsWithoutAMusicBrainzRelease() async throws {
        let fetcher = InfoFetcher(musicBrainz: MusicBrainzClient(session: ReleaseSearchStub.session, minInterval: 0),
                                  discogs: DiscogsClient(session: DiscogsStub.session), get: { _ in nil })
        let info = try await fetcher.fetchAlbum(title: "The Wall", artist: "Pink Floyd", releaseGroupId: nil, releaseId: nil,
                                                discogsReleaseId: 8961614)
        #expect(info.tracklist.count == 26 && info.tracklist.last?.displayPosition == "D7" && info.tracklist.last?.disc == 2)
    }
}
