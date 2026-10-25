import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct CDShoppingTests {
    static let okComputer = CDEdition(
        id: "6a09041b-0f79-3278-88d9-0552dd28d37f", title: "OK Computer", artist: "Radiohead", date: "1997-07-01",
        country: "US", label: "Capitol Records", catalogNumber: "CDP 7243 8 55229 2 5", barcode: "724385522925",
        releaseGroupId: "b1392450-e666-3926-a536-22c65f834433", releaseGroupTitle: "OK Computer", releaseType: "Album")

    static func target(edition: CDEdition? = okComputer) -> CDShoppingTarget {
        CDShoppingTarget(album: "OK Computer", artist: "Radiohead", releaseGroupId: okComputer.releaseGroupId, edition: edition,
                         links: CDShopLinks(discogsRelease: 105704, discogsMaster: 21491, asin: "B000002UJQ"))
    }

    static func offers(_ fixture: String, _ shop: CDShop, _ kind: CDShopRequest.Kind) throws -> [CDOffer] {
        CDShopParser.parse(try TestSupport.html(fixture), request: CDShopRequest(shop: shop, url: shop.home, kind: kind))
    }

    // MARK: Finding the edition

    @Test func searchQuery() {
        #expect(CDSearchQuery(album: "OK Computer", artist: "Radiohead").luceneQuery
                == "(release:ok* AND release:computer*) AND artist:radiohead* AND format:CD")
        // A few words of each, in any order, also as the start of a longer word.
        let partial = CDSearchQuery(album: "green riv", artist: "Creed Revival")
        #expect(partial.luceneQuery == "(release:green* AND release:riv*) AND (artist:creed* AND artist:revival*) AND format:CD")
        #expect(partial.luceneQuery(loose: true) == "(release:green* OR release:riv*) AND (artist:creed* OR artist:revival*) AND format:CD")
        #expect(CDSearchQuery(album: #"Best Of "The Live Sessions""#).luceneQuery
                == "(release:best* AND release:live* AND release:sessions*) AND format:CD")
        #expect(CDSearchQuery(album: "The The").luceneQuery == "(release:the* AND release:the*) AND format:CD")
        #expect(CDSearchQuery(artist: "AC/DC").artistQuery == "(artist:ac* AND artist:dc*)")
        let barcode = CDSearchQuery(code: "7 24385 52292 5")
        #expect(barcode.barcode == "724385522925")
        #expect(barcode.luceneQuery == "barcode:(724385522925 OR 0724385522925)")
        #expect(CDSearchQuery(code: "0724385522925").luceneQuery == "barcode:(0724385522925 OR 724385522925)")
        #expect(CDSearchQuery(code: "CDP 7243 8 55229 2 5").barcode == nil)
        #expect(CDSearchQuery(album: "Sgt. Pepper's", code: "TOCP-50201").luceneQuery == #"catno:"TOCP\-50201" AND (release:sgt* AND release:pepper's*) AND format:CD"#)
        #expect(CDSearchQuery(album: " ").isEmpty)
    }

    @Test func editionsFromSearch() throws {
        let editions = try CDEditionParser.parseSearch(try TestSupport.fixture("mb_cd_search_okcomputer"))
        #expect(editions.count == 27)
        #expect(editions.allSatisfy { CDEditionParser.isCD($0.format) })
        let first = try #require(editions.first)
        #expect(first.country == "JP" && first.barcode == "4988006729254" && first.catalogNumber == "TOCP-50201" && first.label == "EMI")
        #expect(first.trackCount == 12 && first.format == "CD" && first.releaseType == "Album")
        let albums = CDEditionParser.albums(editions)
        #expect(albums.count == 1)
        let album = try #require(albums.first)
        #expect(album.title == "OK Computer" && album.year == 1997 && album.editions.count == 27)
        #expect(album.editions.first?.year == 1997 && album.editions.last?.date.isEmpty == true)

        let byBarcode = try CDEditionParser.parseSearch(try TestSupport.fixture("mb_cd_barcode_okcomputer"))
        #expect(byBarcode.first?.id == Self.okComputer.id && byBarcode.first?.catalogNumber == Self.okComputer.catalogNumber)
    }

    @Test func editionsOfOtherMediaOnlyWhenAsked() throws {
        let vinyl = try TestSupport.fixture("mb_release_search_vinyl")
        // A CD search keeps only CDs; a record search only records.
        #expect(try CDEditionParser.parseSearch(vinyl).isEmpty)
        let records = try CDEditionParser.parseSearch(vinyl, medium: .vinyl)
        #expect(records.map(\.id) == ["d6a1f166-8a02-4608-849b-9d623912c3e5"] && records.first?.format == "2×Vinyl")
        // And CDs are the same whether asked for or not.
        let cds = try TestSupport.fixture("mb_cd_search_okcomputer")
        #expect(try CDEditionParser.parseSearch(cds, medium: .cd) == CDEditionParser.parseSearch(cds))
        #expect(try CDEditionParser.parseSearch(cds, medium: .vinyl).isEmpty)
        #expect(CDEditionParser.isFormat("12\" Vinyl", of: .vinyl) && !CDEditionParser.isFormat("CD", of: .vinyl))
        #expect(CDEditionParser.isFormat("Hybrid SACD", of: .cd) && !CDEditionParser.isFormat("VCD", of: .cd))
        #expect(CDEditionParser.isFormat("Digital Media", of: .download) && !CDEditionParser.isFormat("CD", of: .other("cd")))
    }

    @Test func artistDiscography() throws {
        let artists = try CDDiscographyParser.parseArtists(try TestSupport.fixture("mb_artist_search_creedence"))
        #expect(artists.first?.name == "Creedence Clearwater Revival" && artists.first?.score == 100 && artists.count == 10)
        let ccr = try #require(artists.first)
        let page = try CDDiscographyParser.parseAlbums(try TestSupport.fixture("mb_rg_browse_ccr"), artist: ccr.name)
        #expect(page.total == 169 && page.albums.count == 100 && page.albums.allSatisfy { !$0.editionsLoaded && $0.artist == ccr.name })
        let sorted = CDDiscographyParser.sorted(page.albums)
        // The studio albums first, oldest first; then the compilations.
        #expect(sorted.prefix(7).map(\.title) == ["Creedence Clearwater Revival", "Bayou Country", "Green River", "Willy and the Poor Boys",
                                                   "Cosmo’s Factory", "Pendulum", "Mardi Gras"])
        #expect(sorted[0].kind == "Album" && sorted[0].year == 1968 && sorted[7].kind == "Compilation")

        let editions = try CDEditionParser.parseSearch(try TestSupport.fixture("mb_cd_editions_greenriver"))
        #expect(editions.count == 21 && editions.allSatisfy { $0.releaseGroupTitle == "Green River" })
    }

    @Test func vinylSearches() {
        #expect(CDSearchQuery(album: "OK Computer", artist: "Radiohead", format: .vinyl).luceneQuery
                == "(release:ok* AND release:computer*) AND artist:radiohead* AND format:*vinyl")
        // "vinyl" and "LP" typed into the album aren't title words.
        #expect(CDSearchQuery(album: "Rumours LP vinyl", format: .vinyl).luceneQuery == "release:rumours* AND format:*vinyl")
        // A barcode is the edition, whatever the format.
        #expect(CDSearchQuery(code: "075992731325", format: .vinyl).luceneQuery == "barcode:(075992731325 OR 0075992731325)")
        #expect(CDShoppingTarget(byName: CDSearchQuery(album: "Rumours", artist: "Fleetwood Mac", format: .vinyl)).format == .vinyl)
        #expect(ShopFormat(medium: .vinyl) == .vinyl && ShopFormat(medium: .cd) == .cd && ShopFormat(medium: .download) == nil)
    }

    @Test func formatSummaries() {
        #expect(CDEditionParser.formatSummary(["CD", "CD"]) == "2×CD")
        #expect(CDEditionParser.formatSummary(["CD", "DVD-Video"]) == "CD + DVD-Video")
        #expect(CDEditionParser.isCD("Enhanced CD") && CDEditionParser.isCD("SHM-CD") && !CDEditionParser.isCD("12\" Vinyl"))
        #expect(!CDEditionParser.isCD("VCD") && !CDEditionParser.isCD("DVD-Video"))
    }

    @Test func storeLinksFromMusicBrainz() throws {
        let release = try CDShopLinks.parse(try TestSupport.fixture("mb_release_urls_okcomputer"))
        #expect(release.discogsRelease == 105704 && release.asin == "B000002UJQ" && release.discogsMaster == nil)
        let group = try CDShopLinks.parse(try TestSupport.fixture("mb_rg_urls_okcomputer"))
        #expect(group.discogsMaster == 21491 && group.discogsRelease == nil)

        let untrusted = """
        {"relations":[
          {"type":"discogs","url":{"resource":"https://www.discogs.com.evil.com/release/1"}},
          {"type":"discogs","url":{"resource":"javascript:alert(1)"}},
          {"type":"amazon asin","url":{"resource":"https://www.amazon.com/gp/product/../../x"}},
          {"type":"discogs","url":{"resource":"https://www.discogs.com/master/7"}}
        ]}
        """
        let links = try CDShopLinks.parse(Data(untrusted.utf8))
        #expect(links.discogsRelease == nil && links.asin == nil && links.discogsMaster == 7)
    }

    // MARK: Stores

    @Test func requestsForAnEdition() {
        let requests = CDShopURLs.requests(for: Self.target())
        #expect(requests.map(\.shop) == [.discogs, .ebay, .ebay, .cdandlp, .alibris])
        #expect(requests[0].kind == .edition
                && requests[0].url.absoluteString == "https://www.discogs.com/shop/list?release=105704&ships_to=US&sort=price&sortOrder=ascending")
        #expect(requests[1].kind == .edition && requests[1].url.absoluteString.contains("_nkw=724385522925&_sacat=176984"))
        #expect(requests[2].kind == .keywords && requests[2].url.absoluteString.contains("_nkw=Radiohead%20OK%20Computer"))

        let any = CDShopURLs.requests(for: Self.target(edition: nil))
        #expect(any.first?.kind == .album && any.first?.url.absoluteString.contains("master=21491&formatName=CD") == true)
        #expect(!any.contains { $0.shop == .ebay && $0.kind == .edition })
        #expect(CDShopURLs.browse(.amazon, for: Self.target())?.absoluteString == "https://www.amazon.com/dp/B000002UJQ")
        #expect(CDShopURLs.browse(.walmart, for: Self.target())?.absoluteString == "https://www.walmart.com/search?q=724385522925")
    }

    @Test func requestsForARecord() {
        var target = Self.target(edition: nil)
        target.format = .vinyl
        let requests = CDShopURLs.requests(for: target)
        #expect(requests.allSatisfy { $0.format == .vinyl })
        #expect(requests.first?.kind == .album && requests.first?.url.absoluteString.contains("master=21491&formatName=Vinyl") == true)
        #expect(requests.contains { $0.shop == .ebay && $0.url.absoluteString.contains("_sacat=176985") })
        #expect(!requests.contains { $0.url.absoluteString.contains("176984") })
        #expect(CDShopURLs.browse(.amazon, for: target)?.absoluteString == "https://www.amazon.com/s?k=Radiohead%20OK%20Computer%20vinyl&i=popular")
        #expect(CDShopURLs.browse(.discogs, for: target)?.absoluteString.contains("master_id=21491&format=Vinyl") == true)
        // The edition's barcode needs no "vinyl".
        var edition = Self.target()
        edition.format = .vinyl
        #expect(CDShopURLs.browse(.walmart, for: edition)?.absoluteString == "https://www.walmart.com/search?q=724385522925")
    }

    @Test func discogsListings() throws {
        let offers = try Self.offers("shop_discogs_release_okcomputer", .discogs, .edition)
        #expect(offers.count == 25 && offers.allSatisfy { $0.match == .edition && $0.url.host == "www.discogs.com" })
        let first = try #require(offers.first)
        #expect(first.id == "discogs-4290744288" && first.title == "Radiohead – OK Computer (CD)")
        #expect(first.edition == "Album · 1997 · Europe · Parlophone 7243 8 55229 2 5, Parlophone CDNODATA 02")
        #expect(first.price == Money(3, "EUR") && first.shipping == Money(16, "EUR") && first.quotedTotal == Money(Decimal(string: "21.35")!, "USD"))
        #expect(first.conditionText == "Very Good / sleeve Very Good +" && first.condition == .used)
        #expect(first.seller == "SiSiMusic" && first.sellerRating == "100%" && first.shipsFrom == "Netherlands")
        #expect(first.url.absoluteString == "https://www.discogs.com/shop/item/4290744288" && first.imageURL?.host == "i.discogs.com")
        #expect(offers.contains { $0.price == Money(80, "SEK") })

        let master = try Self.offers("shop_discogs_master_okcomputer", .discogs, .album)
        #expect(master.count == 25 && master.first?.edition == "Album · 1997 · US · Capitol Records CDP 7243 8 55229 2 5")
        #expect(master.first?.quotedTotal == Money(Decimal(string: "6.87")!, "USD"))
    }

    @Test func eBayListings() throws {
        let offers = try Self.offers("shop_ebay_upc_okcomputer", .ebay, .edition)
        #expect(offers.count == 56 && Set(offers.map(\.id)).count == 56)
        let first = try #require(offers.first)
        #expect(first.id == "ebay-254672441635" && first.title == "OK Computer - Audio CD By RADIOHEAD - GOOD")
        #expect(first.price == Money(Decimal(string: "11.88")!, "USD") && first.shipping == Money(0, "USD"))
        #expect(first.condition == .used && first.conditionText == "Pre-Owned" && first.saleFormat == "Buy It Now")
        #expect(first.seller == "second.sale" && first.shipsFrom == "United States")
        #expect(first.url.absoluteString == "https://www.ebay.com/itm/254672441635" && first.imageURL?.host == "i.ebayimg.com")
        #expect(offers.contains { $0.shipping == Money(Decimal(string: "7")!, "USD") || $0.shippingNote == "estimate" })

        let search = try Self.offers("shop_ebay_search_okcomputer", .ebay, .keywords)
        #expect(search.count == 58 && search.allSatisfy { $0.match == .possible && $0.title != "Shop on eBay" })
    }

    @Test func cdAndLPListings() throws {
        let offers = try Self.offers("shop_cdandlp_okcomputer", .cdandlp, .keywords)
        #expect(offers.count == 27 && offers.allSatisfy { $0.title.hasSuffix("(CD)") || $0.title.hasSuffix("(CD x 2)") })
        let first = try #require(offers.first)
        #expect(first.id == "cdandlp-r1001840369" && first.price == Money(Decimal(string: "17.21")!, "EUR"))
        #expect(first.edition == "Europe · 2016" && first.condition == .new && first.seller == "gsmtools" && first.shipsFrom == "Czech Republic")
        #expect(offers.contains { $0.edition == "Parlophone · 7243 8 55229 2 5 · Europe · 1997" })
    }

    @Test func recordsFromStoresThatSellBoth() throws {
        let cdandlp = CDShopParser.parse(try TestSupport.html("shop_cdandlp_okcomputer"),
                                         request: CDShopRequest(shop: .cdandlp, url: CDShop.cdandlp.home, kind: .keywords, format: .vinyl))
        #expect(cdandlp.count == 21 && cdandlp.allSatisfy { $0.title.hasSuffix("(LP)") || $0.title.hasSuffix("(LP x 2)") })
        #expect(CDShopParser.isCDandLP("12''", .vinyl) && CDShopParser.isCDandLP("Maxi 45 T", .vinyl))
        #expect(!CDShopParser.isCDandLP("CD x 2", .vinyl) && !CDShopParser.isCDandLP("Poster / Display", .vinyl))
        let alibris = CDShopParser.parse(try TestSupport.html("shop_alibris_okcomputer"),
                                         request: CDShopRequest(shop: .alibris, url: CDShop.alibris.home, kind: .keywords, format: .vinyl))
        // "[LP]", "[2 LP]"; Alibris calls their recommended copies CDs, which isn't shown.
        #expect(alibris.count == 4 && alibris.allSatisfy { $0.title.contains("LP]") && $0.notes.isEmpty })
    }

    @Test func otherFormatsInTitles() {
        #expect(ShopFormat.cd.isOtherFormat("Radiohead OK Computer Vinyl LP"))
        #expect(!ShopFormat.cd.isOtherFormat("Radiohead OK Computer CD + DVD"))
        #expect(ShopFormat.vinyl.isOtherFormat("OK Computer - Audio CD By RADIOHEAD - GOOD"))
        #expect(ShopFormat.vinyl.isOtherFormat("Radiohead OK Computer cassette tape"))
        #expect(!ShopFormat.vinyl.isOtherFormat("Radiohead OK Computer 2xLP 12\" Vinyl + CD"))
        #expect(!ShopFormat.vinyl.isOtherFormat("RADIOHEAD OK Computer LP Parlophone NODATA 02"))
        #expect(!ShopFormat.vinyl.isOtherFormat("Radiohead - OK Computer (Capitol Records)"))
    }

    @Test func alibrisWorks() throws {
        let offers = try Self.offers("shop_alibris_okcomputer", .alibris, .keywords)
        #expect(!offers.contains { $0.title.contains("[LP]") })
        let first = try #require(offers.first)
        #expect(first.title == "Radiohead – OK Computer (1997)" && first.price == Money(Decimal(string: "10.98")!, "USD"))
        #expect(first.saleFormat == "from" && first.url.host == "www.alibris.com")
        #expect(offers.contains { $0.id == "alibris-402085133-new" && $0.condition == .new && $0.price == Money(Decimal(string: "19.37")!, "USD") })
    }

    @Test func untrustedListingLinksAreDropped() {
        let html = """
        <article class="msr-listing-card"><a href="https://evil.example.com/shop/item/1">x</a><span class="msr-listing-card-price">$1.00</span></article>
        <article class="msr-listing-card"><a href="javascript:alert(1)/shop/item/2">x</a><span class="msr-listing-card-price">$1.00</span></article>
        <article class="msr-listing-card"><a href="/shop/item/3">x</a><span class="msr-listing-card-price">$1.00</span></article>
        """
        let offers = CDShopParser.parse(html, request: CDShopRequest(shop: .discogs, url: CDShop.discogs.home, kind: .edition))
        #expect(offers.map(\.id) == ["discogs-3"])
        #expect(!CDShop.ebay.owns(URL(string: "http://www.ebay.com/itm/1")!) && !CDShop.ebay.owns(URL(string: "https://ebay.com.evil.net/")!))
    }

    // MARK: Prices

    @Test func money() {
        #expect(Money.parse("$22.59") == Money(Decimal(string: "22.59")!, "USD"))
        #expect(Money.parse("US $5.00") == Money(5, "USD"))
        #expect(Money.parse("17.21 €") == Money(Decimal(string: "17.21")!, "EUR"))
        #expect(Money.parse("+ £7.49 shipping") == Money(Decimal(string: "7.49")!, "GBP"))
        #expect(Money.parse("$10.98 to $15.00") == Money(Decimal(string: "10.98")!, "USD"))
        #expect(Money.parse("SEK\u{a0}80.00") == Money(80, "SEK"))
        #expect(Money.parse("C $1,234.50") == Money(Decimal(string: "1234.5")!, "CAD"))
        #expect(Money.parse("12.00", defaultCurrency: "EUR") == Money(12, "EUR"))
        #expect(Money.parse("12.00") == nil && Money.parse("Free") == nil)
    }

    @Test func exchangeRates() throws {
        let rates = try ExchangeRates.parse(try TestSupport.fixture("frankfurter_usd"))
        #expect(rates.perDollar["EUR"] != nil && !rates.date.isEmpty)
        let fixed = ExchangeRates(perDollar: ["EUR": Decimal(string: "0.8")!])
        #expect(fixed.dollars(Money(8, "EUR")) == 10 && fixed.dollars(Money(3, "USD")) == 3 && fixed.dollars(Money(1, "XYZ")) == nil)

        let stats = try DiscogsMarketStats.parse(try TestSupport.fixture("discogs_stats_105704"))
        #expect(stats.forSale == 19 && stats.lowest == Money(Decimal(string: "1.39")!, "USD"))
    }

    // MARK: Matching

    @Test func filteringAndOrder() throws {
        let rates = ExchangeRates(perDollar: ["EUR": Decimal(string: "0.9")!, "GBP": Decimal(string: "0.75")!, "SEK": 10])
        let target = Self.target()
        let raw = try Self.offers("shop_ebay_upc_okcomputer", .ebay, .edition)
            + Self.offers("shop_ebay_search_okcomputer", .ebay, .keywords)
            + Self.offers("shop_cdandlp_okcomputer", .cdandlp, .keywords)
            + Self.offers("shop_alibris_okcomputer", .alibris, .keywords)
        let offers = CDOfferMatcher.filter(raw, for: target, rates: rates)
        #expect(Set(offers.map(\.id)).count == offers.count)
        #expect(!offers.contains { $0.title.lowercased().contains(" lot") })
        #expect(!offers.contains { $0.shop == .alibris && $0.title.contains("Vitamin String Quartet") })
        // CDandLP's listing of this edition's catalog number counts as this edition.
        #expect(offers.contains { $0.shop == .cdandlp && $0.match == .edition && $0.edition.contains("7243 8 55229 2 5") })
        // Best matches first, cheapest first within them.
        #expect(offers.map(\.match) == offers.map(\.match).sorted(by: >))
        let editionTotals = offers.filter { $0.match == .edition }.compactMap { $0.totalDollars(rates) }
        #expect(editionTotals == editionTotals.sorted())

        let anyEdition = CDOfferMatcher.filter(raw, for: Self.target(edition: nil), rates: rates)
        #expect(!anyEdition.contains { $0.match == .edition })

        // Shopping for the record drops the CD listings eBay's keyword search found.
        var record = Self.target(edition: nil)
        record.format = .vinyl
        let records = CDOfferMatcher.filter(raw.filter { $0.shop == .ebay && $0.match == .possible }, for: record, rates: rates)
        #expect(records.count < offers.filter { $0.shop == .ebay && $0.match == .possible }.count)
        #expect(!records.contains { ShopFormat.vinyl.isOtherFormat($0.title) })
    }

    @Test func shoppingByName() {
        let target = CDShoppingTarget(byName: CDSearchQuery(album: #"Best Of “The Live Sessions” from Oslo Concert House"#,
                                                            artist: "Maria Mena", code: "0123456789012"))
        #expect(target.isByName && target.album == "Best Of The Live Sessions from Oslo Concert House" && target.barcode == "0123456789012")
        let requests = CDShopURLs.requests(for: target)
        #expect(!requests.contains { $0.shop == .discogs } && requests.contains { $0.shop == .ebay && $0.kind == .edition })
        #expect(requests.contains { $0.shop == .ebay && $0.kind == .keywords && $0.url.absoluteString.hasSuffix("_nkw=Maria%20Mena&_sacat=176984") })
        // A typed title needs only half its words in a listing.
        let url = URL(string: "https://www.ebay.com/itm/1")!
        let offers = [CDOffer(id: "a", shop: .ebay, title: "Mena, Maria Perspective- Best Of The Live Sessions From Osl (UK IMPORT) CD NEW", price: Money(20, "USD"), url: url, match: .possible),
                      CDOffer(id: "b", shop: .ebay, title: "Maria Mena - Growing Pains CD", price: Money(5, "USD"), url: url, match: .possible)]
        #expect(CDOfferMatcher.filter(offers, for: target, rates: ExchangeRates()).map(\.id) == ["a"])
    }

    @Test func truncatedTitles() {
        let title = "Mena, Maria Perspective- Best Of The Live Sessions From Osl (UK IMPORT) CD NEW"
        #expect(CDOfferMatcher.names(title, album: "Oslo"))
        #expect(CDOfferMatcher.names(title, album: "Perspective"))
        #expect(!CDOfferMatcher.names("Maria Mena Live Os", album: "Oslo"))
        #expect(!CDOfferMatcher.names("Maria Mena Growing Pains", album: "Oslo Concert"))
    }

    @Test func wordMatching() {
        #expect(CDOfferMatcher.names("RADIOHEAD - OK Computer [CD]", album: "OK Computer"))
        #expect(!CDOfferMatcher.names("Radiohead - Kid A", album: "OK Computer"))
        #expect(CDOfferMatcher.names("Beatles Abbey Road", album: "The Abbey Road"))
        #expect(CDOfferMatcher.mentions("Capitol CDP 7243 8 55229 2 5 US 1997", edition: Self.okComputer))
        #expect(!CDOfferMatcher.mentions("Parlophone 55229-2 Canada", edition: Self.okComputer))
    }
}
