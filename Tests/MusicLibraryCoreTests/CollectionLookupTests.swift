import Foundation
import Testing
@testable import MusicLibraryCore

/// Answers MusicBrainz release searches from fixtures, without the network: a barcode search with the Hamilton
/// barcode fixture, a catalog number search with the vinyl one, anything else with no releases.
final class ReleaseSearchStub: URLProtocol, @unchecked Sendable {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var queries: [String] = []
        func append(_ q: String) { lock.lock(); queries.append(q); lock.unlock() }
        func matching(_ marker: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return queries.filter { $0.lowercased().contains(marker.lowercased()) }
        }
    }

    static let log = Log()

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseSearchStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
        Self.log.append(query)
        var body = Data(#"{"releases":[]}"#.utf8)
        if query.hasPrefix("barcode:") { body = (try? TestSupport.fixture("mb_barcode_hamilton")) ?? body }
        if query.hasPrefix("catno:") { body = (try? TestSupport.fixture("mb_release_search_vinyl")) ?? body }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct CollectionLookupTests {
    let vinylFormats = #"format:("Vinyl" OR "12\" Vinyl" OR "10\" Vinyl" OR "7\" Vinyl")"#
    let kindOfBlue = "d6a1f166-8a02-4608-849b-9d623912c3e5"

    @Test func luceneQueries() {
        let vinyl = CollectionReleaseQuery(text: "Kind of Blue  Miles", medium: .vinyl)
        #expect(vinyl.barcode == nil)
        #expect(vinyl.luceneQuery() == "((release:kind* OR artist:kind*) AND (release:blue* OR artist:blue*) AND (release:miles* OR artist:miles*)) AND " + vinylFormats)
        #expect(vinyl.luceneQuery(loose: true) == "((release:kind* OR artist:kind*) OR (release:blue* OR artist:blue*) OR (release:miles* OR artist:miles*)) AND " + vinylFormats)
        #expect(CollectionReleaseQuery(text: "Radiohead", medium: .cd).luceneQuery()
                == #"(release:radiohead* OR artist:radiohead*) AND format:("CD" OR "Enhanced CD" OR "HDCD" OR "SHM\-CD" OR "Blu\-spec CD" OR "Hybrid SACD" OR "SACD")"#)
        // A download is usually of a release listed as a CD: no format filter.
        #expect(CollectionReleaseQuery(text: "AC/DC", medium: .download).luceneQuery() == "((release:ac* OR artist:ac*) AND (release:dc* OR artist:dc*))")
        #expect(CollectionReleaseQuery(text: "The The", medium: .download).luceneQuery() == "((release:the* OR artist:the*) AND (release:the* OR artist:the*))")
        #expect(CollectionReleaseQuery(text: " ", medium: .vinyl).luceneQuery().isEmpty && CollectionReleaseQuery(text: " ", medium: .cd).isEmpty)
        // Barcodes, with and without a leading zero, whatever the medium.
        let code = CollectionReleaseQuery(text: "0 886976 389413", medium: .vinyl)
        #expect(code.barcode == "0886976389413")
        #expect(code.luceneQuery() == "barcode:(0886976389413 OR 886976389413)")
        #expect(CollectionReleaseQuery(text: "724385522925", medium: .cd).luceneQuery() == "barcode:(724385522925 OR 0724385522925)")
        #expect(CollectionReleaseQuery(text: "1234567", medium: .cd).barcode == nil)
        // Catalog numbers, tried last.
        #expect(CollectionReleaseQuery(text: "MOVLP019", medium: .vinyl).catalogNumberQuery() == #"catno:"MOVLP019" AND "# + vinylFormats)
        #expect(CollectionReleaseQuery(text: "CL 1355", medium: .download).catalogNumberQuery() == #"catno:"CL 1355""#)
        #expect(CollectionReleaseQuery(text: "kind of blue", medium: .vinyl).catalogNumberQuery() == nil)
        #expect(CollectionReleaseQuery(text: "724385522925", medium: .cd).catalogNumberQuery() == nil)
    }

    @Test func mediaFromMusicBrainzFormats() {
        #expect(CollectionMedium(musicBrainzFormats: ["Vinyl", "Vinyl"]) == .vinyl)
        #expect(CollectionMedium(musicBrainzFormats: ["12\" Vinyl"]) == .vinyl && CollectionMedium(musicBrainzFormats: ["10\""]) == .vinyl)
        #expect(CollectionMedium(musicBrainzFormats: ["CD", "DVD-Video"]) == .cd)
        #expect(CollectionMedium(musicBrainzFormats: ["Digital Media"]) == .download)
        #expect(CollectionMedium(musicBrainzFormats: ["Cassette"]) == nil && CollectionMedium(musicBrainzFormats: []) == nil)
        let summary = MBReleaseSummary(id: kindOfBlue, title: "Kind of Blue", artist: "Miles Davis", formats: ["12\" Vinyl"], trackCount: 5)
        #expect(summary.isVinyl && !summary.isCD && summary.medium == .vinyl)
        let cd = MBReleaseSummary(id: kindOfBlue, title: "Kind of Blue", artist: "Miles Davis", formats: ["CD"], trackCount: 5)
        #expect(!cd.isVinyl && cd.medium == .cd)
    }

    @Test func vinylReleaseSearch() throws {
        let data = try TestSupport.fixture("mb_release_search_vinyl")
        let editions = try CollectionEditionParser.parseSearch(data, medium: .vinyl)
        let e = try #require(editions.first)
        #expect(editions.count == 1)
        #expect(e.id == kindOfBlue && e.title == "Kind of Blue" && e.artist == "Miles Davis")
        #expect(e.date == "2010-05" && e.year == 2010 && e.country == "NL" && e.status == "Official")
        #expect(e.recordLabel == "Music on Vinyl" && e.catalogNumber == "MOVLP019" && e.barcode == "0886976389413")
        #expect(e.formatDetail == "2×Vinyl" && e.discCount == 2 && e.trackCount == 7 && e.medium == .vinyl)
        #expect(e.releaseGroupId == "8e8a594f-2175-38c7-a871-abb68ec363e7" && e.releaseGroupTitle == "Kind of Blue" && e.groupKey == e.releaseGroupId)
        // Not a CD, but any release does for a download.
        #expect(try CollectionEditionParser.parseSearch(data, medium: .cd).isEmpty)
        #expect(try CollectionEditionParser.parseSearch(data, medium: .download).count == 1)
        #expect(try CollectionEditionParser.parseSearch(data).count == 1)
    }

    @Test func barcodeFixtures() throws {
        let ok = try CollectionEditionParser.parseSearch(try TestSupport.fixture("mb_cd_barcode_okcomputer"), medium: .cd)
        #expect(ok.count == 10 && ok.allSatisfy { $0.medium == .cd && $0.barcode == "724385522925" && $0.formatDetail == "CD" })
        #expect(ok.first?.recordLabel == "Capitol Records" && ok.first?.catalogNumber == "CDP 7243 8 55229 2 5")
        #expect(try CollectionEditionParser.parseSearch(try TestSupport.fixture("mb_cd_barcode_okcomputer"), medium: .vinyl).isEmpty)
        let hamilton = try CollectionEditionParser.parseSearch(try TestSupport.fixture("mb_barcode_hamilton"))
        #expect(hamilton.count == 2 && hamilton.allSatisfy { $0.formatDetail == "2×CD" && $0.discCount == 2 && $0.trackCount == 46 })
        // Found by barcode while adding vinyl, the CD still shows, after any vinyl.
        let vinyl = try CollectionEditionParser.parseSearch(try TestSupport.fixture("mb_release_search_vinyl"))
        #expect(CollectionEditionParser.preferring(.vinyl, hamilton + vinyl).map(\.medium) == [.vinyl, .cd, .cd])
        #expect(CollectionEditionParser.preferring(.download, hamilton + vinyl).map(\.medium) == [.cd, .cd, .vinyl])
    }

    @Test func searchesRetryLooserThenAsACatalogNumber() async throws {
        let client = MusicBrainzClient(session: ReleaseSearchStub.session, minInterval: 0)
        let found = try await client.searchEditions(CollectionReleaseQuery(text: "MOVLP019", medium: .vinyl))
        #expect(found.map(\.id) == [kindOfBlue])
        let asked = ReleaseSearchStub.log.matching("movlp019")
        #expect(asked == [CollectionReleaseQuery(text: "MOVLP019", medium: .vinyl).luceneQuery(),
                          CollectionReleaseQuery(text: "MOVLP019", medium: .vinyl).luceneQuery(loose: true),
                          #"catno:"MOVLP019" AND "# + vinylFormats])

        // A barcode is one lookup, whatever the medium.
        let byCode = try await client.searchEditions(CollectionReleaseQuery(text: "0 75678 66843 2", medium: .vinyl))
        #expect(byCode.count == 2 && byCode.allSatisfy { $0.medium == .cd })
        #expect(ReleaseSearchStub.log.matching("075678668432").count == 1)
    }

    // MARK: Drafts

    @Test func draftFromAnEdition() throws {
        let edition = try #require(try CollectionEditionParser.parseSearch(try TestSupport.fixture("mb_release_search_vinyl")).first)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let item = CollectionDraft.item(from: edition, medium: .vinyl, sticker: 12, now: now)
        #expect(item.medium == .vinyl && item.sticker == Sticker(series: .vinyl, number: 12) && item.origin == .stored && item.isEditable)
        #expect(item.album == "Kind of Blue" && item.artist == "Miles Davis")
        #expect(item.albumKey == SearchIndex.albumKey(album: "Kind of Blue", artist: "Miles Davis"))
        #expect(item.year == 2010 && item.releaseID == kindOfBlue && item.releaseGroupID == edition.releaseGroupId)
        #expect(item.barcode == "0886976389413" && item.catalogNumber == "MOVLP019" && item.recordLabel == "Music on Vinyl")
        #expect(item.country == "NL" && item.formatDetail == "2×Vinyl" && item.discCount == 2 && item.trackCount == 7)
        #expect(item.purchasedOn == PurchaseDay(now) && item.price == nil && item.digitalSource == nil && item.coverFile == nil)
        #expect(item.createdAt == now && CollectionItem.isValidID(item.id))
        // A download has no label number.
        #expect(CollectionDraft.item(from: edition, medium: .download, sticker: 12, now: now).stickerNumber == nil)
        var blank = edition
        blank.barcode = "12"; blank.date = ""; blank.discCount = 0; blank.recordLabel = String(repeating: "x", count: 500)
        let sparse = CollectionDraft.item(from: blank, medium: .vinyl, sticker: nil, now: now)
        #expect(sparse.barcode == nil && sparse.year == nil && sparse.discCount == nil && sparse.recordLabel?.count == 200)
    }

    @Test func draftFromALibraryAlbum() {
        let release = "11111111-1111-1111-1111-111111111111", group = "33333333-3333-3333-3333-333333333333"
        let tracks: [Track] = (1...3).map { n in
            var m = TrackMetadata(title: "T\(n)", artist: "Miles Davis", album: "Kind of Blue", year: 1959, trackNo: n, trackTotal: 5,
                                  discNo: 1, discTotal: 1, mbReleaseId: release)
            m.extended.mbReleaseGroupId = group
            m.extended.label = "Columbia"; m.extended.catalogNumber = "CK 64935"; m.extended.barcode = "074646493528"
            m.extended.mediaFormat = "CD"; m.extended.releaseCountry = "US"
            return Track(id: Int64(n), path: "Music/Miles Davis/Kind of Blue/\(n).flac", metadata: m, duration: 300, format: "flac", sha256: "\(n)")
        }
        let album = AlbumSummary(album: "Kind of Blue", artist: "Miles Davis", year: 1959, trackCount: 3, firstTrackPath: tracks[0].path)
        let cd = CollectionDraft.item(album: album, tracks: tracks, medium: .cd, sticker: 213)
        #expect(cd.albumKey == SearchIndex.albumKey(album: "Kind of Blue", artist: "Miles Davis") && cd.stickerNumber == 213)
        #expect(cd.releaseID == release && cd.releaseGroupID == group && cd.year == 1959 && cd.recordLabel == "Columbia")
        #expect(cd.barcode == "074646493528" && cd.catalogNumber == "CK 64935" && cd.country == "US" && cd.formatDetail == "CD")
        #expect(cd.discCount == 1 && cd.trackCount == 5 && cd.digitalSource == .rip && cd.coverFile == nil && cd.purchasedOn == nil)
        // A record of the album the tracks were ripped from a CD of: the same music, not that CD's codes.
        let vinyl = CollectionDraft.item(album: album, tracks: tracks, medium: .vinyl, sticker: 49)
        #expect(vinyl.digitalSource == .same && vinyl.stickerNumber == 49 && vinyl.releaseGroupID == group && vinyl.recordLabel == "Columbia")
        #expect(vinyl.releaseID == nil && vinyl.barcode == nil && vinyl.catalogNumber == nil && vinyl.formatDetail == nil && vinyl.trackCount == nil)
        #expect(CollectionDraft.item(album: album, tracks: tracks, medium: .download, sticker: 3).digitalSource == .download)
        #expect(CollectionDraft.item(album: album, tracks: tracks, medium: .download, sticker: 3).stickerNumber == nil)
        #expect(CollectionDraft.item(album: album, tracks: [], medium: .cd, sticker: nil).digitalSource == nil)
    }
}
