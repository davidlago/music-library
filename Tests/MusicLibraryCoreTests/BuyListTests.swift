import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct BuyListTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func check(_ at: Date, lowest: Decimal? = nil, fair: (Decimal, Decimal)? = nil) -> WantedPriceCheck {
        WantedPriceCheck(at: at, found: true, fairLow: fair.map { Money($0.0, "USD") }, fairHigh: fair.map { Money($0.1, "USD") },
                         discogsLowest: lowest.map { Money($0, "USD") })
    }

    private func album(_ id: String = UUID().uuidString.lowercased(), at: Date) -> WantedAlbum {
        WantedAlbum(id: id, artist: "Miles Davis", album: "Kind of Blue", format: .vinyl, addedAt: at)
    }

    // MARK: Merging

    @Test func mergeTakesTheLatestEditAndEveryCheck() {
        var mac = album("a", at: t0)
        mac.notes = "Mac"
        mac.record(check(t0 + 10, lowest: 30))
        var phone = mac
        phone.notes = "phone"
        phone.maxPrice = 25
        phone.updatedAt = t0 + 100
        phone.checks = [check(t0 + 50, lowest: 28)]
        let merged = WantedAlbum.merge(mac, phone)
        #expect(merged.notes == "phone" && merged.maxPrice == 25)
        #expect(merged.checks.map(\.at) == [t0 + 50, t0 + 10])
        // The same either way round.
        #expect(WantedAlbum.merge(phone, mac) == merged)
        // A tie keeps the first's fields.
        var other = mac
        other.notes = "other"
        #expect(WantedAlbum.merge(mac, other).notes == "Mac")
    }

    @Test func removalWinsOverAnOlderChange() {
        var removed = album("a", at: t0)
        removed.removed = true
        removed.updatedAt = t0 + 200
        var older = album("a", at: t0)
        older.notes = "edited before it was removed"
        older.updatedAt = t0 + 100
        #expect(WantedAlbum.merge(older, removed).removed)
        #expect(BuyList.shown(BuyList.overlay([older], [removed])).isEmpty)
    }

    @Test func checksAreCappedNewestFirst() {
        var w = album(at: t0)
        for i in 0..<40 { w.record(check(t0 + Double(i) * 60, lowest: Decimal(i))) }
        #expect(w.checks.count == WantedAlbum.maxChecks)
        #expect(w.latest?.discogsLowest == Money(39, "USD"))
        #expect(w.change == 1)
    }

    @Test func overlayAndWhatTheCopyAlreadyHas() {
        let a = album("a", at: t0), b = album("b", at: t0 + 1)
        var editedA = a
        editedA.maxPrice = 40
        editedA.updatedAt = t0 + 50
        let c = album("c", at: t0 + 60)
        let overlaid = BuyList.overlay([a, b], [editedA, c])
        #expect(overlaid.map(\.id) == ["a", "b", "c"])
        #expect(overlaid[0].maxPrice == 40)
        // The copy has neither change yet; then the Mac merged them in.
        #expect(BuyList.applied([editedA, c], in: [a, b]).isEmpty)
        #expect(BuyList.applied([editedA, c], in: [editedA, b, c]) == ["a", "c"])
        // A copy with a newer Mac edit has the phone's change too.
        var newer = editedA
        newer.notes = "Mac edit"
        newer.updatedAt = t0 + 90
        #expect(BuyList.applied([editedA], in: [newer]) == ["a"])
    }

    @Test func dealsAndTotals() {
        var w = album(at: t0)
        w.maxPrice = 30
        w.record(check(t0, lowest: 35, fair: (30, 50)))
        #expect(!w.isDeal)
        w.record(check(t0 + 60, lowest: 29, fair: (30, 50)))
        #expect(w.isDeal)
        #expect(w.change == -6)
        var other = album(at: t0 + 1)
        other.record(check(t0, lowest: 12, fair: (10, 20)))
        let shown = BuyList.shown([other, w])
        #expect(shown.first?.id == w.id)
        let totals = BuyList.totals(shown)
        #expect(totals.count == 2 && totals.deals == 1 && totals.priced == 2)
        // The deal at its asking price, the other at the middle of its fair price.
        #expect(totals.cost == Money(29 + 15, "USD"))
    }

    @Test func sameAlbumIsFoundLoosely() {
        let w = album(at: t0)
        #expect(BuyList.entry(in: [w], artist: "Miles Davis", album: "Kind Of Blue", format: .vinyl)?.id == w.id)
        #expect(BuyList.entry(in: [w], artist: "Miles Davis", album: "Kind of Blue", format: .cd) == nil)
        var any = w
        any.format = .any
        #expect(BuyList.entry(in: [any], artist: "Miles Davis", album: "Kind of Blue", format: .cd)?.id == w.id)
    }

    // MARK: From a guide

    @Test func checkFromAGuide() {
        var guide = PriceGuide(request: PriceGuideRequest(artist: "Miles Davis", album: "Kind of Blue", format: .vinyl))
        var a = DiscogsPricedEdition(releaseID: 1, title: "Kind of Blue", country: "US", label: "Columbia", catalogNumber: "CL 1355",
                                     format: "LP", roles: [.mostCollected], forSale: 12)
        a.lowest = Money(40, "USD")
        a.suggestions = [DiscogsConditionPrice(condition: "Near Mint (NM or M-)", price: Money(60, "USD")),
                         DiscogsConditionPrice(condition: "Very Good (VG)", price: Money(30, "USD"))]
        var b = DiscogsPricedEdition(releaseID: 2, title: "Kind of Blue", country: "EU", label: "Sony", catalogNumber: "x",
                                     format: "LP", roles: [.newest], forSale: 3)
        b.lowest = Money(25, "USD")
        guide.editions = [a, b]
        guide.masterID = 5460
        let c = WantedPriceCheck(guide: guide, at: t0)
        #expect(c.found)
        #expect(c.fairLow == Money(30, "USD") && c.fairHigh == Money(60, "USD"))
        // Any edition: the cheapest of them.
        #expect(c.discogsLowest == Money(25, "USD") && c.discogsForSale == 15)
        #expect(c.cheapestNow == Money(25, "USD"))
        let w = WantedAlbum(guide: guide, currency: "USD", at: t0)
        #expect(w.discogsMasterID == 5460 && w.discogsReleaseID == nil && w.checks.count == 1)
        #expect(w.radioDJLine.contains("cheapest now $25.00"))
    }

    // MARK: Decoding

    @Test func decodesLeniently() throws {
        let json = """
        {"id":"ABC-1","artist":"A","album":"B","format":"cassette","addedAt":1,"checks":[{"at":2,"found":true},{"bad":1}],
         "maxPrice":"lots","thumbnail":"https://evil.example/x.jpg","discogsReleaseID":-4,"future":"field"}
        """
        let w = try JSONDecoder().decode(WantedAlbum.self, from: Data(json.utf8))
        #expect(w.format == .any && w.checks.count == 1 && w.maxPrice == nil)
        let clean = try #require(w.sanitized())
        #expect(clean.id == "abc-1" && clean.thumbnail == nil && clean.discogsReleaseID == nil && clean.formatRaw == "any")
        // No album: not kept (unless it's a removal).
        #expect(WantedAlbum(id: "x", artist: "A", album: " ", format: .cd).sanitized() == nil)
    }

    @Test func manifestCarriesChangesOlderMacsIgnore() throws {
        let w = album("a", at: t0)
        let manifest = SyncManifest(files: [], wanted: [w])
        let data = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(SyncManifest.self, from: data).wanted == [w])
        // An older phone sends none.
        let old = try JSONDecoder().decode(SyncManifest.self, from: Data(#"{"files":[],"events":[],"requests":[]}"#.utf8))
        #expect(old.wanted == nil)
        // An empty list isn't sent.
        #expect(SyncManifest(files: [], wanted: []).wanted == nil)
        let batch = CloudInboxBatch(libraryID: "lib", phoneID: "p1", phoneName: "Phone", events: [], requests: [], wanted: [w])
        #expect(CloudInboxBatch.decode(try batch.encoded())?.wanted == [w])
    }

    // MARK: Database

    @Test func savesMergesAndApplies() throws {
        let db = try Database(path: ":memory:")
        var w = album("a", at: t0)
        w.record(check(t0 + 1, lowest: 30))
        #expect(try db.saveWanted([w]) == 1)
        // Saving the same again changes nothing.
        #expect(try db.saveWanted([w]) == 0)
        var phone = w
        phone.maxPrice = 20
        phone.updatedAt = t0 + 30
        phone.checks = [check(t0 + 20, lowest: 28)]
        // Only from this library.
        #expect(try db.applyWanted([phone], libraryID: "another library") == 0)
        #expect(try db.applyWanted([phone], libraryID: db.libraryID()) == 1)
        let stored = try #require(try db.wantedAlbums().first)
        #expect(stored.maxPrice == 20 && stored.checks.count == 2)
        // An older edit from elsewhere doesn't undo the newer one.
        var stale = w
        stale.notes = "stale"
        stale.updatedAt = t0 + 5
        try db.applyWanted([stale], libraryID: nil)
        #expect(try db.wantedAlbums().first?.notes == "")
        // A row that doesn't read is skipped.
        try db.exec("INSERT INTO wanted_albums(id,data,updated_at,removed) VALUES('b','{not json',0,0)")
        #expect(try db.wantedAlbums().map(\.id) == ["a"])
    }

    @Test func snapshotsCarryTheListAndValues() throws {
        let f = try SyncFixture()
        let item = CollectionItem(medium: .vinyl, album: "Kind of Blue", artist: "Miles Davis")
        try f.db.saveCollectionItem(item)
        try f.db.saveWanted([album("a", at: t0)])
        try f.db.saveCollectionValues([CollectionValue(itemID: item.id, at: t0, found: true, low: Money(30, "USD"), high: Money(50, "USD")),
                                       CollectionValue(itemID: "gone", at: t0, found: true, low: Money(1, "USD"))])
        let target = try TestSupport.tempDir().appendingPathComponent("sync.sqlite")
        try f.db.writeSyncSnapshot(to: target, scratch: try TestSupport.tempDir())
        let phone = try Database(snapshotAt: target.path)
        #expect(try phone.wantedAlbums().map(\.id) == ["a"])
        // Values of items no longer here are dropped when saving.
        #expect(try phone.collectionValues().keys.sorted() == [item.id])
        #expect(try phone.collectionValues()[item.id]?.estimate == Money(40, "USD"))
    }

    // MARK: Values

    @Test func valueStats() {
        var a = CollectionItem(medium: .vinyl, album: "A", artist: "X")
        a.price = 20
        var b = CollectionItem(medium: .cd, album: "B", artist: "Y")
        b.price = 15
        let c = CollectionItem(medium: .cd, album: "C", artist: "Z")
        let d = CollectionItem(medium: .download, album: "D", artist: "W")
        let collection = MusicCollection(items: [a, b, c, d], songPurchases: [:], tracks: [])
        let now = t0 + 40 * 86_400
        // Priced the way this version prices (`CollectionValue.method`).
        func current(_ v: CollectionValue) -> CollectionValue { var v = v; v.method = CollectionValue.method; return v }
        let values = [
            a.id: current(CollectionValue(itemID: a.id, at: now, found: true, low: Money(40, "USD"), high: Money(60, "USD"))),
            b.id: current(CollectionValue(itemID: b.id, at: t0, found: true, low: Money(10, "USD"))),
            c.id: current(CollectionValue(itemID: c.id, at: now, found: false)),
        ]
        // A value priced before 1.35 (eBay first) is due again, however recent.
        var old = values[a.id]!
        old.method = nil
        #expect(CollectionValueStats.make(collection: collection, values: values.merging([a.id: old]) { $1 }, now: now).stale == 2)
        let s = CollectionValueStats.make(collection: collection, values: values, now: now)
        #expect(s.eligible == 3 && s.valued == 2 && s.notFound == 1 && s.stale == 1)
        #expect(s.total == 60 && s.paid == 35 && s.paidValue == 60 && s.gain == 25)
        #expect(s.byMedium == ["vinyl": 50, "cd": 10])
        #expect(s.top.map(\.item.id) == [a.id, b.id])
        #expect(s.gainers.map(\.item.id) == [a.id])
        #expect(s.toUpdate == 2)
    }

    @Test func requestForACopy() {
        var item = CollectionItem(medium: .vinyl, album: "Kind of Blue", artist: "Miles Davis")
        item.barcode = "074646193518"
        item.catalogNumber = "CL 1355"
        item.year = 1959
        let r = CollectionValue.request(for: item, discogsMatch: 1234)
        #expect(r.format == .vinyl && r.releaseID == 1234 && r.catalogNumber == "CL 1355" && r.year == 1959)
        item.discogsReleaseID = 99
        #expect(CollectionValue.request(for: item, discogsMatch: 1234).releaseID == 99)
        #expect(!CollectionValue.canValue(CollectionItem(medium: .download, album: "A", artist: "B")))
    }
}
