import Foundation
import Testing
@testable import MusicLibraryCore

/// Answers Discogs API requests from fixtures (real responses for Kind of Blue: master 5460, its vinyl versions,
/// release 6276183; price suggestions and the collection follow Discogs' documented schemas).
final class PriceGuideTransport: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var paths: [String] = []
    var suggestions = true

    var transport: DiscogsCollectionClient.Transport {
        { [self] request in try self.answer(request) }
    }

    private func answer(_ request: URLRequest) throws -> (Data, Int) {
        let url = try #require(request.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? { items.first { $0.name == name }?.value }
        lock.withLock { paths.append(url.path + (query("page").map { "?page=\($0)" } ?? "")) }
        let parts = url.path.split(separator: "/").map(String.init)
        switch parts.first {
        case "masters" where parts.count == 2 && parts[1] == "5460":
            return (try TestSupport.fixture("discogs_master_5460"), 200)
        case "masters" where parts.count == 3 && parts[1] == "5460":
            // One page here; Discogs has four.
            if query("page") != "1" { return (Data(#"{"pagination":{"page":2,"pages":1},"versions":[]}"#.utf8), 200) }
            var text = String(decoding: try TestSupport.fixture("discogs_master_versions_5460_vinyl"), as: UTF8.self)
            text = text.replacingOccurrences(of: #""pages": 4"#, with: #""pages": 1"#).replacingOccurrences(of: #""pages":4"#, with: #""pages":1"#)
            return (Data(text.utf8), 200)
        case "releases" where parts.count == 2:
            #expect(query("curr_abbr") == "USD")
            // The one real release, answered under each ID asked for.
            let text = String(decoding: try TestSupport.fixture("discogs_release_6276183_usd"), as: UTF8.self)
            return (Data(text.replacingOccurrences(of: #""id":6276183"#, with: #""id":\#(parts[1])"#).utf8), 200)
        case "marketplace" where parts.count == 3 && parts[1] == "price_suggestions":
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Discogs token=") == true)
            return suggestions ? (try TestSupport.fixture("discogs_price_suggestions"), 200) : (Data(), 404)
        case "users" where url.path == "/users/example_user/collection/folders/0/releases":
            return (try TestSupport.fixture(query("page") == "2" ? "discogs_collection_page2" : "discogs_collection_page1"), 200)
        case "database":
            return (try TestSupport.fixture("discogs_search_master_kindofblue"), 200)
        default:
            return (Data(), 404)
        }
    }
}

@Suite struct DiscogsMarketParserTests {
    @Test func masterReleaseAndVersions() throws {
        let master = try DiscogsMarketParser.master(try TestSupport.fixture("discogs_master_5460"))
        #expect(master.id == 5460)
        #expect(master.title == "Kind Of Blue")
        #expect(master.artist == "Miles Davis")
        #expect(master.year == 1959)
        #expect(master.lowest == 0.35)
        #expect(master.forSale == 5492)
        #expect(master.thumbnail.map(DiscogsLink.isImageURL) == true)

        let release = try DiscogsMarketParser.release(try TestSupport.fixture("discogs_release_6276183_usd"), currency: "USD")
        #expect(release.masterID == 5460)
        #expect(release.edition.releaseID == 6276183)
        #expect(release.edition.lowest == Money(Decimal(string: "48.88")!, "USD"))
        #expect(release.edition.forSale == 11)
        #expect(release.edition.have == 2089)
        #expect(release.edition.want == 5351)
        #expect(release.edition.country == "US")
        #expect(release.edition.details.hasPrefix("US 1959 · Columbia"))

        let versions = try DiscogsMarketParser.versions(try TestSupport.fixture("discogs_master_versions_5460_vinyl"))
        #expect(versions.pages == 4)
        #expect(versions.versions.count == 100)
        let original = try #require(versions.versions.first { $0.candidate.releaseID == 2252871 })
        #expect(original.have == 4247)
        #expect(original.want == 6997)
        #expect(original.candidate.medium == .vinyl)
    }

    @Test func suggestionsBestConditionFirst() throws {
        let prices = try DiscogsMarketParser.suggestions(try TestSupport.fixture("discogs_price_suggestions"))
        #expect(prices.map(\.short) == ["M", "NM or M-", "VG+", "VG", "G+", "G", "F", "P"])
        #expect(prices[2].price == Money(Decimal(string: "60.25")!, "USD"))
        var edition = DiscogsPricedEdition(releaseID: 1, title: "", country: "", label: "", catalogNumber: "", format: "", roles: [], forSale: 0)
        edition.suggestions = prices
        #expect(edition.fairRange?.low == Money(Decimal(string: "35.12")!, "USD"))
        #expect(edition.fairRange?.high == Money(95, "USD"))
    }

    @Test func searchHits() throws {
        let hits = try DiscogsMarketParser.hits(try TestSupport.fixture("discogs_search_master_kindofblue"))
        let first = try #require(hits.first)
        #expect(first.masterID == 5460)
        #expect(first.releaseID == nil)
        #expect(first.artist == "Miles Davis")
        #expect(first.title == "Kind Of Blue")
        #expect(first.year == 1959)
        // Without a token Discogs gives no pictures.
        #expect(first.thumbnail == nil)
    }
}

@Suite struct PriceGuideTests {
    @Test func pricesTheEditionTheMostCollectedAndTheOriginal() async throws {
        let discogs = PriceGuideTransport()
        let guides = PriceGuides(token: String(repeating: "a", count: 40), username: "example_user", currency: "usd", transport: discogs.transport)
        let request = PriceGuideRequest(artist: "Miles Davis", album: "Kind of Blue", format: .vinyl, releaseID: 6276183)
        let guide = await guides.guide(for: request)

        #expect(guide.notes.isEmpty)
        #expect(guide.found)
        #expect(guide.masterID == 5460)
        #expect(guide.title == "Kind Of Blue")
        #expect(guide.versions == 100)
        #expect(guide.masterForSale == 5492)
        #expect(guide.editions.map(\.releaseID) == [6276183, 2252871, guide.editions.last!.releaseID])
        #expect(guide.editions[0].roles == [.identified])
        #expect(guide.editions[1].roles == [.mostCollected, .original])
        #expect(guide.editions.count == 3)
        #expect(guide.editions.allSatisfy { $0.suggestions.count == 8 })
        #expect(guide.headline?.releaseID == 6276183)
        #expect(guide.fairPrice?.source == "Discogs' suggestion, VG to NM")
        // The Discogs collection has a copy of another version (release 2772432, master 5460).
        #expect(guide.ownedOnDiscogs?.map(\.releaseID) == [2772432])
        #expect(guide.ownedOnDiscogs?.first?.sameEdition == false)
        #expect(guide.shoppingTarget.links.discogsMaster == 5460)
        #expect(guide.shoppingTarget.links.discogsRelease == 6276183)
        #expect(guide.shoppingTarget.format == .vinyl)
        let summary = guide.summary
        #expect(summary.contains("master 5460"))
        #expect(summary.contains("This edition: release 6276183"))
        #expect(summary.contains("Suggested: M $120.00, NM or M- $95.00, VG+ $60.25"))
        #expect(summary.contains("Their Discogs collection has 1 copy"))
    }

    @Test func withoutAnAccountOnlyPublicFigures() async throws {
        let discogs = PriceGuideTransport()
        let guides = PriceGuides(token: nil, username: "example_user", currency: "XYZ", transport: discogs.transport)
        #expect(guides.currency == "USD")
        let guide = await guides.guide(for: PriceGuideRequest(artist: "Miles Davis", album: "Kind of Blue", format: .vinyl, masterID: 5460))
        #expect(guide.ownedOnDiscogs == nil)
        #expect(guide.editions.allSatisfy { $0.suggestions.isEmpty })
        #expect(!discogs.paths.contains { $0.contains("price_suggestions") || $0.hasPrefix("/users") })
        #expect(guide.editions.first?.roles == [.mostCollected, .original])
    }

    @Test func missingSellerSettingsIsANoteNotAFailure() async throws {
        let discogs = PriceGuideTransport()
        discogs.suggestions = false
        let guides = PriceGuides(token: String(repeating: "a", count: 40), username: "example_user", currency: "USD", transport: discogs.transport)
        let guide = await guides.guide(for: PriceGuideRequest(artist: "Miles Davis", album: "Kind of Blue", format: .vinyl, masterID: 5460))
        #expect(guide.found)
        #expect(guide.notes.contains { $0.contains("seller settings") })
        // Asked once, not per edition.
        #expect(discogs.paths.filter { $0.contains("price_suggestions") }.count == 1)
    }

    @Test func nothingFound() async {
        let guides = PriceGuides(token: nil, username: nil, currency: "USD", transport: { _ in (Data(#"{"results":[]}"#.utf8), 200) })
        let guide = await guides.guide(for: PriceGuideRequest(artist: "Nobody", album: "Nothing", format: .cd))
        #expect(!guide.found)
        #expect(!guide.hasPrices)
        #expect(guide.summary.hasPrefix("Discogs has nothing matching “Nothing” by Nobody on CD."))
    }

    @Test func requestsKeepOnlyValidIDs() {
        let request = PriceGuideRequest(artist: "", album: "", barcode: "0 74646 49352 8", releaseID: 0, masterID: -3)
        #expect(request.releaseID == nil)
        #expect(request.masterID == nil)
        #expect(request.barcodeDigits == "074646493528")
        #expect(PriceGuideRequest(artist: "", album: "", barcode: "12").barcodeDigits == nil)
    }
}

@Suite struct EbayPriceTests {
    func listings() throws -> [EbayListing] {
        EbayPrices.parse(String(decoding: try TestSupport.fixture("ebay_listings_kindofblue_vinyl"), as: UTF8.self))
    }

    @Test func readsTheScriptsListings() throws {
        let all = try listings()
        #expect(all.count == 17)
        #expect(!all.contains { $0.title == "Shop on eBay" })
        let mono = try #require(all.first { $0.id == "364356363175" })
        #expect(mono.price == Money(Decimal(string: "26.94")!, "USD"))
        #expect(mono.isNew == true)
        #expect(mono.isAuction == false)
        #expect(all.first { $0.id == "366776814546" }?.isAuction == true)
        #expect(all.first { $0.id == "227604096956" }?.isNew == false)
        #expect(EbayPrices.parse("not json").isEmpty)
        #expect(EbayPrices.parse(#"{"items":[{"id":"../1","title":"x","price":"$1"}]}"#).isEmpty)
    }

    @Test func keepsTheAlbumAloneInTheFormat() throws {
        let matched = EbayPrices.matching(try listings(), album: "Kind of Blue", artist: "Miles Davis", format: .vinyl)
        let ids = Set(matched.map(\.id))
        #expect(!ids.contains("267763016356"))  // Sketches of Spain
        #expect(!ids.contains("840066551344"))  // …And Sketches Of Spain And 2 Louis Armstrong Records
        #expect(!ids.contains("127862048953"))  // Blue Train / Kind of Blue
        #expect(matched.count == 14)
        #expect(EbayPrices.matching(try listings(), album: "Kind of Blue", artist: "Miles Davis", format: .cd).isEmpty == false)
    }

    @Test func spreadsLeaveRunningAuctionsOut() throws {
        let matched = EbayPrices.matching(try listings(), album: "Kind of Blue", artist: "Miles Davis", format: .vinyl)
        let url = try #require(EbayPrices.url(for: PriceGuideRequest(artist: "Miles Davis", album: "Kind of Blue", format: .vinyl),
                                              artist: "Miles Davis", album: "Kind of Blue", sold: false))
        let summary = EbayPriceSummary(kind: .forSale, listings: matched, catalogNumber: "CL 1355", searchURL: url)
        #expect(summary.auctions == 5)
        #expect(summary.used?.count == 5)
        #expect(summary.used?.median == Money(Decimal(string: "35.99")!, "USD"))
        #expect(summary.used?.typicalLow == Money(Decimal(string: "29.99")!, "USD"))
        #expect(summary.used?.typicalHigh == Money(Decimal(string: "99.99")!, "USD"))
        #expect(summary.new?.count == 4)
        #expect(summary.edition?.count == 2)
        #expect(summary.summary.contains("Used: $29.99–$99.99 (median $35.99, 5 copies"))

        var guide = PriceGuide(request: PriceGuideRequest(artist: "Miles Davis", album: "Kind of Blue", format: .vinyl))
        guide.ebayForSale = summary
        #expect(guide.hasPrices)
        #expect(guide.fairPrice?.source == "eBay asking prices, 5 used for sale")
        let sold = EbayPriceSummary(kind: .sold, listings: matched, catalogNumber: "", searchURL: url)
        guide.ebaySold = sold
        #expect(guide.fairPrice?.source.hasPrefix("eBay sales") == true)
    }

    @Test func searchURLs() throws {
        let vinyl = PriceGuideRequest(artist: "Miles Davis", album: "Kind of Blue", format: .vinyl)
        let sold = try #require(EbayPrices.url(for: vinyl, artist: "Miles Davis", album: "Kind of Blue", sold: true))
        let items = URLComponents(url: sold, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "_sacat", value: "176985")))
        #expect(items.contains(URLQueryItem(name: "LH_Sold", value: "1")))
        #expect(items.contains(URLQueryItem(name: "_nkw", value: "Miles Davis Kind of Blue")))
        let any = PriceGuideRequest(artist: "Various Artists", album: "Pure Moods", format: .any)
        let url = try #require(EbayPrices.url(for: any, artist: any.artist, album: any.album, sold: false))
        #expect(url.absoluteString.contains("_sacat=11233"))
        #expect(url.absoluteString.contains("_nkw=Pure%20Moods"))
        #expect(!url.absoluteString.contains("LH_Sold"))
    }

    @Test func soldDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(EbayPrices.soldDate("Sold  Oct 12, 2026", now: now) != nil)
        #expect(EbayPrices.soldDate("Sold Oct 12, 2099", now: now) == nil)
        #expect(EbayPrices.soldDate("Located in United States", now: now) == nil)
    }

    @Test func spreadOfOne() throws {
        let one = try #require(PriceSpread([Money(10, "USD")]))
        #expect(one.median == Money(10, "USD"))
        #expect(PriceSpread([]) == nil)
        // Other currencies are left out.
        #expect(PriceSpread([Money(10, "USD"), Money(5, "EUR")])?.count == 1)
    }
}

@Suite struct RadioDJShoppingToolTests {
    @Test func priceGuideInput() throws {
        let ok = PriceGuideRequest.parse(.object(["album": .string(" Kind of Blue "), "artist": .string("Miles Davis"), "format": .string("Vinyl"),
                                                  "catalog_number": .string("CL 1355"), "year": .number(1959)]))
        let request = try ok.get()
        #expect(request.album == "Kind of Blue")
        #expect(request.format == .vinyl)
        #expect(request.catalogNumber == "CL 1355")
        #expect(request.year == 1959)
        #expect((try? PriceGuideRequest.parse(.object(["album": .string("X"), "artist": .string("Y"), "format": .string("cassette")])).get()) == nil)
        #expect((try? PriceGuideRequest.parse(.object(["album": .string(""), "artist": .string("Y"), "format": .string("cd")])).get()) == nil)
        #expect((try? PriceGuideRequest.parse(.string("x")).get()) == nil)
    }

    @Test func choicesInput() throws {
        let input: JSONValue = .object([
            "options": .array([
                .object(["album": .string("Kind of Blue"), "artist": .string("Miles Davis"), "year": .number(1959), "format": .string("vinyl"),
                         "note": .string("the mono original")]),
                .object(["album": .string("Kind of Blue (Legacy Edition)"), "artist": .string("Miles Davis")]),
            ]),
            "retake": .bool(true), "retake_hint": .string("the back cover"),
        ])
        let choices = try RadioDJChoices.parse(input).get()
        #expect(choices.options.count == 2)
        #expect(choices.options[0].answer == "It's *Kind of Blue* by Miles Davis (1959 · Vinyl · the mono original).")
        #expect(choices.options[1].format == .any)
        #expect(choices.retake)
        #expect(choices.retakeHint == "the back cover")
        #expect((try? RadioDJChoices.parse(.object(["options": .array([])])).get()) == nil)
        #expect((try? RadioDJChoices.parse(.object(["options": .array([]), "retake": .bool(true)])).get())?.retake == true)
        #expect((try? RadioDJChoices.parse(.object(["options": .array([.object(["artist": .string("X")])])])).get()) == nil)
    }

    @Test func ownership() {
        #expect(ShopOwnership.sameArtist("The Beatles", "Beatles"))
        #expect(ShopOwnership.sameArtist("Miles Davis", "The Miles Davis Quintet"))
        #expect(!ShopOwnership.sameArtist("Miles Davis", "John Coltrane"))
        #expect(ShopOwnership.sameArtist("", "Anyone"))
        let item = CollectionItem(id: "a", medium: .vinyl, album: "Kind Of Blue", artist: "Miles Davis",
                                  albumKey: SearchIndex.albumKey(album: "Kind Of Blue", artist: "Miles Davis"))
        let collection = MusicCollection(items: [item], songPurchases: [:], tracks: [])
        let owned = ShopOwnership.find(album: "Kind of Blue", artist: "miles davis", collection: collection, tracks: [])
        #expect(owned.copies.map(\.id) == ["a"])
        #expect(owned.lines == ["Owns it on vinyl"])
        #expect(ShopOwnership.find(album: "Milestones", artist: "Miles Davis", collection: collection, tracks: []).isEmpty)
    }

    @Test func discogsAccountRidesWithTheDJSettings() throws {
        let token = String(repeating: "b", count: 40)
        let settings = SyncRadioDJ(apiKey: nil, name: "Max", discogsToken: token, discogsUsername: "example_user")
        let decoded = try JSONDecoder().decode(SyncRadioDJ.self, from: try JSONEncoder().encode(settings))
        #expect(decoded == settings)
        // From an older Mac: no account. A bad token or username never gets in.
        let old = try JSONDecoder().decode(SyncRadioDJ.self, from: Data(#"{"name":"Max"}"#.utf8))
        #expect(old.discogsToken == nil && old.discogsUsername == nil)
        let bad = try JSONDecoder().decode(SyncRadioDJ.self, from: Data(#"{"name":"Max","discogsToken":"a b\nc","discogsUsername":"../x"}"#.utf8))
        #expect(bad.discogsToken == nil && bad.discogsUsername == nil)
    }
}

@MainActor @Suite struct RadioDJInStoreTests {
    func toolCall(_ name: String, _ json: String) -> [String] {
        let escaped = String(data: try! JSONEncoder().encode(json), encoding: .utf8)!
        return sse([
            #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"\#(name)","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":\#(escaped)}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}"#,
        ])
    }

    func idle(_ session: RadioDJSession, lines: Int) async throws {
        for _ in 0..<300 where session.isBusy || session.lines.count < lines { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<300 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func offersChoicesThenPricesThePick() async throws {
        let choices = #"{"options":[{"album":"Kind of Blue","artist":"Miles Davis","format":"vinyl"},{"album":"Milestones","artist":"Miles Davis"}],"retake":true,"retake_hint":"the back cover"}"#
        let price = #"{"album":"Kind of Blue","artist":"Miles Davis","format":"vinyl"}"#
        let transport = ScriptedClaudeTransport([
            .lines(toolCall("offer_choices", choices)), .lines(textReply("Which one is it?")),
            .lines(toolCall("price_guide", price)), .lines(textReply("A classic. Pay $20–$40.")),
        ])
        let guides = PriceGuides(token: nil, username: nil, currency: "USD", transport: { _ in (Data(#"{"results":[]}"#.utf8), 200) })
        let session = RadioDJSession(name: "Max", subject: RadioDJShopping.storeSubject, client: ClaudeClient(apiKey: "k", transport: transport),
                                     shopping: RadioDJShopping(guides: guides, inStore: true)) { _ in }
        var found: [PriceGuide] = []
        session.onPriceGuide = { guide, _ in found.append(guide) }
        session.start()
        #expect(session.suggestions.isEmpty)
        #expect(session.lines.first?.text.contains("crate digging") == true)

        session.send("", photos: [])  // nothing to send
        session.send("What's this one?")
        try await idle(session, lines: 3)
        #expect(session.error == nil)
        let offered = try #require(session.choices)
        #expect(offered.options.map(\.album) == ["Kind of Blue", "Milestones"])
        #expect(offered.retake)
        let first = try #require(transport.bodies.first)
        #expect(first["tools"]?.array?.compactMap { $0["name"]?.string }.suffix(2) == ["price_guide", "offer_choices"])
        let persona = first["system"]?.array?.first?["text"]?.string ?? ""
        #expect(persona.contains("out crate digging together"))
        #expect(persona.contains("bargain hunter"))
        #expect(!persona.contains("host of a radio show"))
        #expect(first["messages"]?.array?.first?["content"]?.array?.first?["text"]?.string?.hasPrefix("(The listener opened the Shop") == true)
        let result = transport.bodies[1]["messages"]?.array?.last?["content"]?.array?.first
        #expect(result?["content"]?.string?.hasPrefix("The choices are on the listener's screen") == true)

        session.send(offered.options[0].answer)
        #expect(session.choices == nil)
        try await idle(session, lines: 5)
        #expect(session.error == nil)
        #expect(session.lines.last?.priceGuides.count == 1)
        #expect(found.count == 1)
        let priced = transport.bodies[3]["messages"]?.array?.last?["content"]?.array?.first?["content"]?.string
        #expect(priced?.hasPrefix("Discogs has nothing matching “Kind of Blue” by Miles Davis on Vinyl.") == true)
    }

    @Test func outsideTheStoreNoChoices() async throws {
        let transport = ScriptedClaudeTransport([.lines(textReply("Hi."))])
        let guides = PriceGuides(token: nil, username: nil, currency: "USD")
        let session = RadioDJSession(name: "Max", subject: RadioDJSubject(kind: .artist, title: "X"),
                                     client: ClaudeClient(apiKey: "k", transport: transport),
                                     shopping: RadioDJShopping(guides: guides)) { _ in }
        session.start()
        session.send("Hi")
        try await idle(session, lines: 3)
        let names = transport.bodies.first?["tools"]?.array?.compactMap { $0["name"]?.string }
        #expect(names == ["web_search", "web_fetch", "price_guide"])
        let persona = transport.bodies.first?["system"]?.array?.first?["text"]?.string ?? ""
        #expect(persona.contains("host of a radio show"))
        #expect(persona.contains("price_guide"))
        #expect(!persona.contains("bargain hunter"))
    }
}
