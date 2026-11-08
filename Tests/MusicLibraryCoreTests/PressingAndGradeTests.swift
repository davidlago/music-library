import Foundation
import Testing
@testable import MusicLibraryCore

/// A copy's pressing (runouts) and condition (grades): stored per item, read from Discogs, valued by, searched and
/// sent to Discogs.
@Suite struct PressingAndGradeTests {
    // MARK: Grades

    @Test func gradesReadTheirCodesAndDiscogsNames() {
        #expect(CollectionGrade(rawValue: "VG+") == .veryGoodPlus)
        #expect(CollectionGrade(rawValue: " nm ") == .nearMint && CollectionGrade(rawValue: "m-") == .nearMint)
        #expect(CollectionGrade(rawValue: "excellent") == nil)
        #expect(CollectionGrade(discogsName: "Very Good Plus (VG+)") == .veryGoodPlus)
        #expect(CollectionGrade(discogsName: "Near Mint (NM or M-)") == .nearMint)
        #expect(CollectionGrade(discogsName: "No Cover") == .noCover)
        // The same strings Discogs' price suggestions use, best first.
        #expect(CollectionGrade.media.map(\.discogsName) == DiscogsConditionPrice.order)
        #expect(CollectionGrade.mint < .veryGood && CollectionGrade.veryGoodPlus < .veryGood)
        for g in CollectionGrade.allCases { #expect(CollectionGrade(rawValue: g.rawValue) == g) }
    }

    @Test func gradesAndRunoutsAreCopyFieldsOnly() {
        var item = CollectionItem(medium: .vinyl, album: "Kind of Blue", artist: "Miles Davis")
        item.runouts = "  XSM 47326\nXSM 47327  "
        item.mediaGrade = .noCover  // not a media grade
        item.sleeveGrade = .generic
        let n = item.normalized()
        #expect(n.runouts == "XSM 47326\nXSM 47327" && n.mediaGrade == nil && n.sleeveGrade == .generic)
        var download = item
        download.medium = .download
        download.mediaGrade = .nearMint
        let d = download.normalized()
        #expect(d.runouts == nil && d.mediaGrade == nil && d.sleeveGrade == nil)
        item.runouts = String(repeating: "A", count: CollectionItem.maxRunouts + 50)
        #expect(item.normalized().runouts?.count == CollectionItem.maxRunouts)
    }

    // MARK: Storage

    @Test func columnsAreAddedOnOpenAndKeptByOlderVersions() throws {
        let path = try TestSupport.tempDir().appendingPathComponent("library.sqlite").path
        // A library 1.34 made: none of the new columns.
        var db: Database? = try Database(path: path)
        for column in ["runouts", "media_grade", "sleeve_grade"] {
            try db?.exec("ALTER TABLE collection_items DROP COLUMN \(column)")
        }
        try db?.exec("INSERT INTO collection_items(id,medium,sticker,album,artist,album_key,created_at,updated_at) VALUES('old','vinyl',1,'Old','Artist','k',1,1)")
        db = nil

        db = try Database(path: path)
        let reopened = try #require(db)
        let columns = try reopened.columns(of: "collection_items")
        #expect(columns.isSuperset(of: ["runouts", "media_grade", "sleeve_grade"]))
        #expect(try reopened.query("PRAGMA user_version") { $0.int(0) ?? 0 }.first == 14)
        let old = try #require(try reopened.collectionItems().items.first)
        #expect(old.runouts == nil && old.mediaGrade == nil && old.sleeveGrade == nil)

        var copy = CollectionItem(id: "graded", medium: .vinyl, album: "Kind of Blue", artist: "Miles Davis")
        copy.runouts = "XSM 47326 (Side A)\nXSM 47327 (Side B)"
        copy.mediaGrade = .veryGoodPlus
        copy.sleeveGrade = .veryGood
        try reopened.saveCollectionItem(copy)
        let read = try #require(try reopened.collectionItems().items.first { $0.id == "graded" })
        #expect(read.runouts == copy.runouts && read.mediaGrade == .veryGoodPlus && read.sleeveGrade == .veryGood)

        // An older version's upsert names only its own columns and keeps them.
        try reopened.exec("INSERT INTO collection_items(id,medium,album,artist,album_key,created_at,updated_at) VALUES('graded','vinyl','Kind of Blue','Miles Davis','k',1,2) ON CONFLICT(id) DO UPDATE SET album=excluded.album, updated_at=excluded.updated_at")
        let kept = try #require(try reopened.collectionItems().items.first { $0.id == "graded" })
        #expect(kept.runouts == copy.runouts && kept.mediaGrade == .veryGoodPlus && kept.sleeveGrade == .veryGood)

        // Values that don't read are unknown: a grade from nowhere, a sleeve-only grade as the media's, runouts too long.
        try reopened.exec("UPDATE collection_items SET media_grade='excellent', sleeve_grade='no-cover' WHERE id='graded'")
        let odd = try #require(try reopened.collectionItems().items.first { $0.id == "graded" })
        #expect(odd.mediaGrade == nil && odd.sleeveGrade == .noCover)
        try reopened.exec("UPDATE collection_items SET media_grade='generic', runouts=? WHERE id='graded'",
                          [.text(String(repeating: "x", count: CollectionItem.maxRunouts + 1))])
        let bad = try #require(try reopened.collectionItems().items.first { $0.id == "graded" })
        #expect(bad.mediaGrade == nil && bad.runouts == nil)
    }

    @Test func snapshotsWithoutTheColumnsReadThem() throws {
        let path = try TestSupport.tempDir().appendingPathComponent("library.sqlite").path
        var db: Database? = try Database(path: path)
        for column in ["runouts", "media_grade", "sleeve_grade"] {
            try db?.exec("ALTER TABLE collection_items DROP COLUMN \(column)")
        }
        try db?.exec("INSERT INTO collection_items(id,medium,album,artist,album_key,created_at,updated_at) VALUES('old','cd','Old','Artist','k',1,1)")
        db = nil
        // A phone opens a synced copy read-only, without migrating it.
        let snapshot = try Database(snapshotAt: path)
        let item = try #require(try snapshot.collectionItems().items.first)
        #expect(item.id == "old" && item.mediaGrade == nil && item.runouts == nil)
    }

    // MARK: Discogs identifiers

    @Test func releaseListsItsRunoutsFirstAndThePlant() throws {
        let blue = try DiscogsParser.parseRelease(try TestSupport.fixture("discogs_release_kindofblue"))
        #expect(blue.runouts.map(\.value) == ["XSM 47326", "XSM 47327", "85700 1A 01-MILES DAVIS A", "85700 1B 01-MILES DAVIS A"])
        #expect(blue.runouts.first?.description == "Side A [label]")
        #expect(blue.identifiers.last?.type == "Depósito Legal")
        #expect(blue.pressedBy == ["Record Industry"])

        let wall = try DiscogsParser.parseRelease(try TestSupport.fixture("discogs_release_wall"))
        #expect(wall.identifiers.first?.isRunout == true)
        // Barcodes come after the runouts, before the rest.
        let types = wall.identifiers.map(\.type)
        let firstOther = types.firstIndex { $0 != "Matrix / Runout" && $0 != "Barcode" } ?? types.count
        #expect(types.prefix(firstOther).allSatisfy { $0 == "Matrix / Runout" || $0 == "Barcode" })
        #expect(types.lastIndex(of: "Matrix / Runout")! < types.firstIndex(of: "Barcode")!)
        #expect(wall.barcode == "5099902988313")
    }

    @Test func identifiersAreCappedAndCleaned() {
        let raw: [[String: Any]] = [
            ["type": " Matrix / Runout ", "value": " A1 ", "description": "Side A"],
            ["type": "Barcode", "value": ""],
            ["type": "Other", "value": String(repeating: "x", count: 400)],
        ] + (0..<100).map { ["type": "Matrix / Runout", "value": "R\($0)"] }
        let parsed = DiscogsParser.identifiers(raw)
        #expect(parsed.count == DiscogsIdentifier.maxCount)
        #expect(parsed.first == DiscogsIdentifier(type: "Matrix / Runout", value: "A1", description: "Side A"))
        #expect(!parsed.contains { $0.value.isEmpty || $0.value.count > DiscogsIdentifier.maxLength })
    }

    // MARK: Values

    func edition(_ id: Int, roles: [DiscogsPricedEdition.Role], lowest: Decimal? = nil,
                 suggestions: [(String, Decimal)] = []) -> DiscogsPricedEdition {
        var e = DiscogsPricedEdition(releaseID: id, title: "Kind of Blue", year: 1959, country: "US", label: "Columbia",
                                     catalogNumber: "CL 1355", format: "LP, Album, Mono", roles: roles,
                                     lowest: lowest.map { Money($0, "USD") }, forSale: 3, have: nil, want: nil, rating: nil, ratingCount: nil)
        e.suggestions = suggestions.map { DiscogsConditionPrice(condition: $0.0, price: Money($0.1, "USD")) }
        return e
    }

    var guide: PriceGuide {
        var g = PriceGuide(request: PriceGuideRequest(artist: "Miles Davis", album: "Kind of Blue", format: .vinyl))
        g.masterID = 5460
        g.editions = [
            edition(1, roles: [.identified], lowest: 30,
                    suggestions: [("Mint (M)", 90), ("Near Mint (NM or M-)", 60), ("Very Good Plus (VG+)", 40), ("Very Good (VG)", 25)]),
            edition(2, roles: [.mostCollected], lowest: 12,
                    suggestions: [("Near Mint (NM or M-)", 30), ("Very Good Plus (VG+)", 20), ("Very Good (VG)", 14)]),
        ]
        // eBay's sales would lead the fair price.
        let sold = [100, 110, 120].map { EbayListing(id: "\($0)", title: "Kind of Blue LP", price: Money(Decimal($0), "USD"), isNew: false, isAuction: false, soldOn: nil) }
        g.ebaySold = EbayPriceSummary(kind: .sold, listings: sold, catalogNumber: "", searchURL: URL(string: "https://www.ebay.com")!)
        return g
    }

    @Test func aCopyIsValuedAtItsPressingAndGrade() throws {
        let graded = try #require(guide.copyEstimate(grade: .veryGoodPlus))
        #expect(graded.low == Money(40, "USD") && graded.high == Money(40, "USD"))
        #expect(graded.source.contains("this pressing") && graded.source.contains("VG+"))
        // Ungraded: Very Good to Near Mint of its own pressing, not eBay's sales.
        #expect(guide.fairPrice?.source.contains("eBay") == true)
        let plain = try #require(guide.copyEstimate(grade: nil))
        #expect(plain.low == Money(25, "USD") && plain.high == Money(60, "USD"))
        // A grade Discogs gave no price for falls back to the range.
        #expect(guide.copyEstimate(grade: .poor)?.low == Money(25, "USD"))
        // Not identified: the most common pressing.
        var unknown = guide
        unknown.editions[0].roles = [.original]
        #expect(unknown.copyEstimate(grade: .veryGoodPlus)?.low == Money(20, "USD"))
        #expect(unknown.copyEstimate(grade: .veryGoodPlus)?.source.contains("most common") == true)
        // No suggestions (no token): the cheapest copy of the pressing.
        var noToken = guide
        noToken.editions = noToken.editions.map { var e = $0; e.suggestions = []; return e }
        #expect(noToken.copyEstimate(grade: .veryGoodPlus)?.low == Money(30, "USD"))
        // With what the pressing sold for on Discogs, its low to high, before the cheapest copy for sale.
        var sold = noToken
        sold.editions[0].sales = DiscogsSalesHistory(releaseID: 1, low: Money(6, "USD"), median: Money(10, "USD"), high: Money(35, "USD"))
        let sales = try #require(sold.copyEstimate(grade: .veryGoodPlus))
        #expect(sales.low == Money(6, "USD") && sales.high == Money(35, "USD") && sales.median == Money(10, "USD"))
        #expect(sales.source == "Discogs sales of this pressing, any condition")
        // Its value's estimate is the median, not the middle of the range.
        #expect(CollectionValue(itemID: "v1", guide: sold, grade: .veryGoodPlus).estimate == Money(10, "USD"))
        // Never eBay: with no Discogs price, no value, though eBay's sales would lead the fair price.
        var ebayOnly = guide
        ebayOnly.editions = []
        #expect(ebayOnly.fairPrice?.source.contains("eBay") == true)
        #expect(ebayOnly.copyEstimate(grade: .nearMint) == nil)
        var nothingListed = noToken
        nothingListed.editions = nothingListed.editions.map { var e = $0; e.lowest = nil; return e }
        #expect(nothingListed.copyEstimate(grade: nil) == nil)
        let unpriced = CollectionValue(itemID: "v1", guide: nothingListed)
        #expect(unpriced.found && unpriced.low == nil)
        ebayOnly.masterID = nil
        #expect(!CollectionValue(itemID: "v1", guide: ebayOnly).found)
    }

    @Test func discogsSalesReadFromTheReleasePage() throws {
        func sales(_ id: Int) throws -> DiscogsSalesHistory? {
            DiscogsSalesHistory.parse(String(decoding: try TestSupport.fixture("discogs_sales_\(id)"), as: UTF8.self), releaseID: id)
        }
        // The Köln Concert, US Pitman pressing: none for sale, Low $6.00, Median $10.00, High $34.99 on the page.
        let koln = try #require(try sales(29241412))
        #expect(koln.low == Money(6, "USD") && koln.median == Money(10, "USD") && koln.high == Money(Decimal(string: "34.99")!, "USD"))
        #expect(koln.lastSold == ISO8601DateFormatter().date(from: "2026-09-23T00:27:23Z"))
        let chronicle = try #require(try sales(2775493))
        #expect(chronicle.low == Money(1, "USD") && chronicle.median == Money(Decimal(string: "2.9")!, "USD") && chronicle.high == Money(10, "USD"))
        // Another release's page, a page without its data, nonsense.
        let text = String(decoding: try TestSupport.fixture("discogs_sales_29241412"), as: UTF8.self)
        #expect(DiscogsSalesHistory.parse(text, releaseID: 2775493) == nil)
        #expect(DiscogsSalesHistory.parse("", releaseID: 1) == nil)
        #expect(DiscogsSalesHistory.parse(#"{"releases":[{"discogsId":1,"statistics":null}]}"#, releaseID: 1) == nil)
        let upsideDown = #"{"releases":[{"discogsId":1,"statistics":{"min":{"amount":9,"currency":"USD"},"median":{"amount":5,"currency":"USD"},"max":{"amount":10,"currency":"USD"}}}]}"#
        #expect(DiscogsSalesHistory.parse(upsideDown, releaseID: 1) == nil)
        #expect(DiscogsSalesHistory.url(releaseID: 29241412)?.absoluteString == "https://www.discogs.com/release/29241412")
    }

    @Test func salesAreReadOnlyWhenDiscogsSuggestsNoPrice() async throws {
        let page = String(decoding: try TestSupport.fixture("discogs_sales_29241412"), as: UTF8.self)
        let reads = PageReads()
        let guides = PriceGuides(token: nil, username: nil, currency: "USD",
                                 discogsPages: DiscogsPageReader(sales: { url in
                                     await reads.add(url)
                                     return page
                                 }))
        var g = PriceGuide(request: PriceGuideRequest(artist: "Keith Jarrett", album: "The Köln Concert"))
        g.editions = [DiscogsPricedEdition(releaseID: 29241412, title: "The Köln Concert", country: "US", label: "ECM Records",
                                           catalogNumber: "ECM 1064/65", format: "LP", roles: [.identified], forSale: 0)]
        let read = await guides.withSales(g)
        #expect(read.editions[0].sales?.median == Money(10, "USD"))
        #expect(await reads.urls == [URL(string: "https://www.discogs.com/release/29241412")!])
        // Discogs' suggestions already price it: no page read.
        g.editions[0].suggestions = [DiscogsConditionPrice(condition: "Very Good Plus (VG+)", price: Money(20, "USD"))]
        _ = await guides.withSales(g)
        #expect(await reads.urls.count == 1)
    }

    @Test func valueRemembersItsGradeAndMethod() {
        var item = CollectionItem(id: "v1", medium: .vinyl, album: "Kind of Blue", artist: "Miles Davis")
        item.mediaGrade = .veryGoodPlus
        let value = CollectionValue(itemID: item.id, guide: guide, grade: item.mediaGrade)
        #expect(value.estimate == Money(40, "USD") && value.matches(item))
        item.mediaGrade = .veryGood
        #expect(!value.matches(item))
        // A value from before 1.35, or from 1.35's builds that fell back to eBay, is priced again.
        var eBayFallback = value
        eBayFallback.method = 2
        #expect(!eBayFallback.matches(item))
        let old = CollectionValue(itemID: "v1", at: Date(), found: true, low: Money(100, "USD"), high: Money(120, "USD"))
        item.mediaGrade = nil
        #expect(!old.matches(item))
        // And it round-trips through JSON (the phone's copy of values).
        let data = try! JSONEncoder().encode(value)
        #expect(try! JSONDecoder().decode(CollectionValue.self, from: data) == value)
    }

    @Test func theShopLeadsWithTheMostCommonPressingPlusUSShipping() throws {
        let rates = ExchangeRates(perDollar: ["EUR": 0.5], date: "2026-11-01")
        func offer(_ id: String, from: String, shipping: Decimal?, currency: String = "USD", shop: CDShop = .discogs) -> CDOffer {
            CDOffer(id: id, shop: shop, title: "Kind of Blue", price: Money(20, currency), shipping: shipping.map { Money($0, currency) },
                    shipsFrom: from, url: URL(string: "https://www.discogs.com/sell/item/\(id)")!, match: .album)
        }
        let offers = [offer("1", from: "United States", shipping: 5), offer("2", from: "United States", shipping: 7),
                      offer("3", from: "Germany", shipping: 20), offer("4", from: "US", shipping: 3, currency: "EUR"),
                      offer("5", from: "United States", shipping: 50, shop: .ebay)]
        let shipping = try #require(CDOffer.usShipping(offers, currency: "USD", rates: rates))
        #expect(shipping == Money(6, "USD"))  // 5, 6 (3 EUR) and 7: the median
        #expect(CDOffer.usShipping(Array(offers.prefix(1)), currency: "USD", rates: rates) == nil)

        let estimate = try #require(guide.shopEstimate(shipping: shipping))
        // The most collected pressing's VG to NM, not the identified one's, nor eBay's sales.
        #expect(estimate.low == Money(20, "USD") && estimate.high == Money(36, "USD"))
        #expect(estimate.source.contains("most common pressing") && estimate.source.contains("shipping from a US seller"))
        let unshipped = try #require(guide.shopEstimate(shipping: nil))
        #expect(unshipped.low == Money(14, "USD") && unshipped.source.contains("before shipping"))
        // The Shop's recent finds keep the same estimate.
        #expect(ShopFind(guide: guide)?.fairPrice == unshipped.text)
    }

    // MARK: Search

    @Test func searchFindsRunoutsAndGrades() {
        func item(_ id: String, _ grade: CollectionGrade?, runouts: String? = nil, medium: CollectionMedium = .vinyl) -> CollectionItem {
            var i = CollectionItem(id: id, medium: medium, album: "Album \(id)", artist: "Artist", now: Date(timeIntervalSince1970: 0))
            i.mediaGrade = grade
            i.runouts = runouts
            return i
        }
        let items = [item("nm", .nearMint, runouts: "XSM 47326 1A"), item("vgp", .veryGoodPlus), item("vg", .veryGood),
                     item("none", nil), item("dl", nil, medium: .download)]
        let index = CollectionIndex(collection: MusicCollection(items: items, songPurchases: [:], tracks: []), tracks: [], albumInfos: [:])
        func ids(_ q: String) -> Set<String> { Set(index.search(q).map(\.id)) }
        #expect(ids("runout:xsm47326") == ["nm"])
        #expect(ids("matrix:\"XSM 47326\"") == ["nm"])
        #expect(ids("47326") == ["nm"])  // runouts are text too
        #expect(ids("grade:vg+") == ["vgp"])
        #expect(ids("grade:>=vg+") == ["nm", "vgp"])
        #expect(ids("grade:<vg+") == ["vg"])
        #expect(ids("grade:>vg") == ["nm", "vgp"])
        #expect(ids("grade:none") == ["none"])
        #expect(ids("-grade:none own:physical") == ["nm", "vgp", "vg"])
        #expect(CollectionSearchQuery.parse("grade:excellent").issues.count == 1)
    }

    @Test func olderReadersSeeTheNewKeysAsText() {
        let index = SearchFixtures.index
        for text in ["runout:xsm47326", "grade:vg+", "grade:>=vg"] {
            #expect(index.tracks(matching: SearchQuery.parse(text, now: SearchFixtures.now), now: SearchFixtures.now).isEmpty, "\(text)")
        }
    }

    // MARK: Sync to Discogs

    let fields = [
        DiscogsCollectionField(id: 1, name: "Media Condition", type: "dropdown", options: DiscogsConditionPrice.order),
        DiscogsCollectionField(id: 2, name: "Sleeve Condition", type: "dropdown",
                               options: DiscogsConditionPrice.order + ["Generic", "Not Graded", "No Cover"]),
        DiscogsCollectionField(id: 3, name: "Notes", type: "textarea"),
    ]

    @Test func collectionFieldsAndInstanceGradesParse() throws {
        let parsed = try DiscogsCollectionParser.fields(try TestSupport.fixture("discogs_collection_fields"))
        let grades = DiscogsGradeFields(parsed)
        #expect(grades.media?.id == 1 && grades.sleeve?.id == 2)
        #expect(grades.sleeve?.options.contains("No Cover") == true)
        let page = try DiscogsCollectionParser.page(try TestSupport.fixture("discogs_collection_page1"))
        #expect(page.instances.contains { $0.fields[3] == "Bought at the fair" })
        // A renamed field isn't written to.
        #expect(DiscogsGradeFields([DiscogsCollectionField(id: 1, name: "Disc", type: "dropdown", options: ["Mint (M)"])]).isEmpty)
    }

    @Test func gradesAreSentOnlyWhenSetAndDifferent() {
        let grades = DiscogsGradeFields(fields)
        var item = CollectionItem(id: "a", medium: .vinyl, album: "Kind of Blue", artist: "Miles Davis")
        #expect(grades.changes(for: item).isEmpty)  // nothing set: nothing cleared
        item.mediaGrade = .veryGoodPlus
        item.sleeveGrade = .generic
        #expect(grades.changes(for: item) == [1: "Very Good Plus (VG+)", 2: "Generic"])
        #expect(grades.changes(for: item, current: [1: "Very Good Plus (VG+)", 2: "Good (G)"]) == [2: "Generic"])
        #expect(grades.changes(for: item, current: [1: "Very Good Plus (VG+)", 2: "Generic"]).isEmpty)
    }

    @Test func gradesWithAPlusReachDiscogsAsWritten() async throws {
        // An unencoded "+" reads as a space on the server: "VG+" arrived as "VG " and Discogs answered 422.
        let account = DiscogsAccountStub()
        let instance = DiscogsInstance(instanceID: 10, releaseID: 2772432, folderID: 1)
        try await account.client().setField(1, value: "Very Good Plus (VG+)", instance: instance, username: "example_user")
        let url = try #require(account.all.last?.url)
        #expect(url.path == "/users/example_user/collection/folders/1/releases/2772432/instances/10/fields/1")
        #expect(url.query(percentEncoded: true) == "value=Very%20Good%20Plus%20(VG%2B)")
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        #expect(value == "Very Good Plus (VG+)")
    }

    @Test func planWritesGradesOnLinkedAndAdoptedCopies() {
        var linked = CollectionItem(id: "linked", medium: .vinyl, album: "Kind of Blue", artist: "Miles Davis")
        linked.mediaGrade = .nearMint
        var adopted = CollectionItem(id: "adopted", medium: .vinyl, album: "The Wall", artist: "Pink Floyd")
        adopted.mediaGrade = .veryGood
        var same = CollectionItem(id: "same", medium: .cd, album: "OK Computer", artist: "Radiohead")
        same.mediaGrade = .mint
        let remote = [
            DiscogsInstance(instanceID: 10, releaseID: 2772432).with(fields: [1: "Good (G)"]),
            DiscogsInstance(instanceID: 11, releaseID: 8961614),
            DiscogsInstance(instanceID: 12, releaseID: 1234).with(fields: [1: "Mint (M)"]),
        ]
        let links: [String: DiscogsSyncRow.Link] = ["linked": .init(instanceID: 10, releaseID: 2772432),
                                                     "same": .init(instanceID: 12, releaseID: 1234)]
        let releases = ["linked": 2772432, "adopted": 8961614, "same": 1234]
        let plan = DiscogsSyncPlan.make(items: [linked, adopted, same], releases: releases, links: links, remote: remote,
                                        gradeFields: DiscogsGradeFields(fields))
        #expect(Set(plan.gradeUpdates.map(\.id)) == ["linked", "adopted"])
        #expect(plan.gradeUpdates.first { $0.id == "linked" }?.values == [1: "Near Mint (NM or M-)"])
        #expect(!plan.isEmpty && plan.additions.isEmpty && plan.removals.isEmpty)
        // Without the fields, grades stay here, and the sheet says so.
        let noFields = DiscogsSyncPlan.make(items: [linked], releases: releases, links: links, remote: remote,
                                            gradeFields: DiscogsGradeFields([]))
        #expect(noFields.gradeUpdates.isEmpty && noFields.gradesWithoutField == 1)
        #expect(DiscogsSyncPlan.make(items: [linked], releases: releases, links: links, remote: remote).gradeUpdates.isEmpty)
    }
}

private actor PageReads {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}
