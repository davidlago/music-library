import Foundation
import Testing
@testable import MusicLibraryCore

/// Answers the Shop's Discogs searches from fixtures (real responses for Kind of Blue) and records what was asked.
private final class ShopSearchTransport: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var queries: [[String: String]] = []
    private(set) var paths: [String] = []
    /// Barcodes that have releases.
    var barcodes: Set<String> = []

    var transport: DiscogsCollectionClient.Transport {
        { [self] request in try self.answer(request) }
    }

    private func answer(_ request: URLRequest) throws -> (Data, Int) {
        let url = try #require(request.url)
        let items = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { a, _ in a })
        lock.withLock { queries.append(items); paths.append(url.path) }
        let empty = Data(#"{"pagination":{"page":1,"pages":1,"items":0},"results":[]}"#.utf8)
        switch url.path {
        case "/database/search":
            if let barcode = items["barcode"] {
                return (barcodes.contains(barcode) ? try TestSupport.fixture("discogs_search_kindofblue_vinyl") : empty, 200)
            }
            if items["type"] == "master" { return (try TestSupport.fixture("discogs_search_master_kindofblue"), 200) }
            if items["release_title"]?.lowercased() == "kind of blue" || items["q"]?.lowercased().contains("kind of blue") == true {
                return (try TestSupport.fixture("discogs_search_kindofblue_vinyl"), 200)
            }
            return (empty, 200)
        case "/masters/5460/versions":
            var text = String(decoding: try TestSupport.fixture("discogs_master_versions_5460_vinyl"), as: UTF8.self)
            text = text.replacingOccurrences(of: #""pages": 4"#, with: #""pages": 1"#).replacingOccurrences(of: #""pages":4"#, with: #""pages":1"#)
            return (Data(text.utf8), 200)
        default:
            return (Data(), 404)
        }
    }
}

@Suite struct CDShopDiscogsTests {
    // MARK: Results as albums

    @Test func releasesGroupedByMaster() throws {
        let found = try DiscogsParser.parseSearch(try TestSupport.fixture("discogs_search_kindofblue_vinyl"), medium: .vinyl)
        let albums = CDDiscogsSearch.albums(found, format: .vinyl)
        #expect(albums.count == 1)
        let album = try #require(albums.first)
        #expect(album.id == "discogs-master-5460" && album.discogsMasterID == 5460 && album.isDiscogs)
        #expect(album.releaseGroupId == nil)
        #expect(album.title == "Kind Of Blue" && album.artist == "Miles Davis")
        #expect(album.editionsLoaded && album.editions.count == 10)
        #expect(album.year == 1959)
        // Oldest first: the 1959 original, then the reissues.
        let first = try #require(album.editions.first)
        #expect(first.id == "discogs-2252871" && first.discogsReleaseID == 2252871 && first.discogsMasterID == 5460)
        #expect(first.musicBrainzID == nil)
        #expect(album.editions.map(\.date) == album.editions.map(\.date).sorted())
        let reissue = try #require(album.editions.first { $0.discogsReleaseID == 2772432 })
        #expect(reissue.country == "France" && reissue.label == "Columbia" && reissue.catalogNumber == "CS 8163")
        #expect(reissue.format == "Vinyl" && reissue.disambiguation == "LP, Album, Reissue, Stereo, 180 gram")
        // Only the format shopped for.
        #expect(CDDiscogsSearch.albums(found, format: .cd).isEmpty)
    }

    @Test func artistAloneListsTheirMasters() throws {
        let hits = try DiscogsMarketParser.hits(try TestSupport.fixture("discogs_search_master_kindofblue"))
        let albums = CDDiscogsSearch.albums(masters: hits, artist: "miles davis")
        #expect(albums.map(\.title) == ["Kind Of Blue", "All Blues / It Ain't Necessarily So", "Mode Study"])
        #expect(albums.map(\.kind) == ["Album", "", "Compilation"])
        #expect(albums.allSatisfy { !$0.editionsLoaded && $0.editions.isEmpty && $0.isDiscogs && $0.artist == "Miles Davis" })
        #expect(albums.first?.discogsMasterID == 5460 && albums.first?.year == 1959)
        // An artist none of them is by: everything found, rather than nothing.
        #expect(CDDiscogsSearch.albums(masters: hits, artist: "Nobody In Particular").count == hits.count)
    }

    // MARK: Searching

    @Test func albumAndArtistAreFieldSearches() async throws {
        let discogs = ShopSearchTransport()
        let guides = PriceGuides(token: nil, username: nil, currency: "USD", transport: discogs.transport)
        let albums = try await guides.shopAlbums(CDSearchQuery(album: "Kind of Blue", artist: "Miles Davis", format: .vinyl))
        #expect(albums.first?.discogsMasterID == 5460)
        let asked = try #require(discogs.queries.first)
        #expect(asked["type"] == "release" && asked["format"] == "Vinyl" && asked["per_page"] == "100")
        #expect(asked["release_title"] == "Kind of Blue" && asked["artist"] == "Miles Davis" && asked["q"] == nil)
        #expect(discogs.queries.count == 1)
    }

    @Test func freeTextWhenTheFieldsFindNothing() async throws {
        let discogs = ShopSearchTransport()
        let guides = PriceGuides(token: nil, username: nil, currency: "USD", transport: discogs.transport)
        let albums = try await guides.shopAlbums(CDSearchQuery(album: "Kind Of Blue (Remastered)", artist: "Miles Davis", format: .vinyl))
        #expect(albums.count == 1)
        #expect(discogs.queries.count == 2)
        #expect(discogs.queries.last?["q"] == "Miles Davis Kind Of Blue (Remastered)")
    }

    @Test func barcodeWrittenEitherWay() async throws {
        let discogs = ShopSearchTransport()
        discogs.barcodes = ["886976805715"]
        let guides = PriceGuides(token: nil, username: nil, currency: "USD", transport: discogs.transport)
        let albums = try await guides.shopAlbums(CDSearchQuery(code: "0886976805715", format: .vinyl))
        #expect(albums.first?.discogsMasterID == 5460)
        #expect(discogs.queries.compactMap { $0["barcode"] } == ["0886976805715", "886976805715"])
        #expect(discogs.queries.allSatisfy { $0["format"] == nil }, "the code says which release, whatever its format")
    }

    @Test func catalogNumberWithTheAlbum() async throws {
        let discogs = ShopSearchTransport()
        let guides = PriceGuides(token: nil, username: nil, currency: "USD", transport: discogs.transport)
        _ = try await guides.shopAlbums(CDSearchQuery(album: "Kind of Blue", code: "CS 8163", format: .vinyl))
        let asked = try #require(discogs.queries.first)
        #expect(asked["catno"] == "CS 8163" && asked["release_title"] == "Kind of Blue" && asked["artist"] == nil)
    }

    @Test func artistAloneThenAnAlbumsEditions() async throws {
        let discogs = ShopSearchTransport()
        let guides = PriceGuides(token: nil, username: nil, currency: "USD", transport: discogs.transport)
        let query = CDSearchQuery(artist: "Miles Davis", format: .vinyl)
        #expect(query.isArtistAlone)
        let albums = try await guides.shopAlbums(query)
        #expect(discogs.queries.first?["type"] == "master" && discogs.queries.first?["artist"] == "Miles Davis")
        let album = try #require(albums.first)
        #expect(album.discogsMasterID == 5460 && !album.editionsLoaded)

        let editions = try await guides.shopEditions(masterID: 5460, format: .vinyl, artist: album.artist)
        #expect(discogs.paths.last == "/masters/5460/versions")
        #expect(editions.count == 100)
        #expect(editions.allSatisfy { $0.discogsMasterID == 5460 && $0.discogsReleaseID != nil && $0.musicBrainzID == nil && $0.artist == "Miles Davis" })
        #expect(editions.allSatisfy { $0.thumbnail.map(DiscogsLink.isImageURL) == true })
        let coronet = try #require(editions.first { $0.discogsReleaseID == 4169354 })
        #expect(coronet.label == "Coronet" && coronet.country == "Australia" && coronet.date == "1959")
        #expect(coronet.format == "LP, Album, Mono" && coronet.catalogNumber.hasPrefix("KLP893"))
        #expect(editions.map(\.date) == editions.map(\.date).sorted())
    }

    @Test func barcodeVariants() {
        #expect(CDDiscogsSearch.otherBarcode("886976805715") == "0886976805715")
        #expect(CDDiscogsSearch.otherBarcode("0886976805715") == "886976805715")
        #expect(CDDiscogsSearch.otherBarcode("5099902987620") == nil)
        #expect(CDSearchQuery(album: "Kind of Blue").isArtistAlone == false)
        #expect(CDSearchQuery(artist: "Miles Davis", code: "CS 8163").isArtistAlone == false)
        #expect(CDSearchQuery().isArtistAlone == false)
    }

    // MARK: Shopping for what Discogs found

    @Test func anyEditionOfADiscogsAlbumShopsItsMaster() throws {
        var links = CDShopLinks()
        links.discogsMaster = 5460
        let target = CDShoppingTarget(album: "Kind Of Blue", artist: "Miles Davis", releaseGroupId: nil, edition: nil, links: links, format: .vinyl)
        #expect(!target.isByName)
        func value(_ name: String, in url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
        let discogs = try #require(CDShopURLs.requests(for: target).first { $0.shop == .discogs })
        #expect(discogs.kind == .album && value("master", in: discogs.url) == "5460" && value("formatName", in: discogs.url) == "Vinyl")
        // Keyword searches use the album's title, as for any album.
        let ebay = try #require(CDShopURLs.requests(for: target).first { $0.shop == .ebay && $0.kind == .keywords })
        #expect(value("_nkw", in: ebay.url) == "Miles Davis Kind Of Blue")
        #expect(CDShoppingTarget(byName: CDSearchQuery(album: "Kind Of Blue", artist: "Miles Davis")).isByName)
    }

    @Test func linksTheTargetCameWithAreKept() {
        let known = CDShopLinks(discogsRelease: 2252871, discogsMaster: 5460)
        let merged = known.merged(with: CDShopLinks(discogsRelease: 1, discogsMaster: 2, asin: "B000002ADT"))
        #expect(merged == CDShopLinks(discogsRelease: 2252871, discogsMaster: 5460, asin: "B000002ADT"))
    }

    @Test func djSummaryNamesTheSource() throws {
        let found = try DiscogsParser.parseSearch(try TestSupport.fixture("discogs_search_kindofblue_vinyl"), medium: .vinyl)
        let request = RadioDJShopRequest(album: "Kind of Blue", artist: "Miles Davis", format: .vinyl)
        let text = RadioDJShopRequest.summary(CDDiscogsSearch.albums(found, format: .vinyl), request: request, source: .discogs)
        #expect(text.contains("Discogs found 1 album:"))
        #expect(text.contains("10 Vinyl editions") && text.contains("editions from 1959 to 2021"))
        #expect(RadioDJShopRequest.summary([], request: request, source: .musicBrainz).contains("Discogs and MusicBrainz list no Vinyl editions"))
    }
}
