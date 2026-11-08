import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct ShopFindTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theSameAlbumIsOneFindOnBothDevices() {
        let mac = ShopFind(album: "Kind of Blue", artist: "Miles Davis", format: .vinyl, fairPrice: "$40", at: t0)
        let phone = ShopFind(album: "Kind Of Blue", artist: "miles davis", format: .vinyl, fairPrice: "$45", at: t0 + 60)
        #expect(mac.id == phone.id)
        #expect(ShopFind(album: "Kind of Blue", artist: "Miles Davis", format: .cd).id != mac.id)
        let merged = ShopFind.merge(mac, phone)
        #expect(merged.fairPrice == "$45" && merged.at == t0 + 60)
        #expect(ShopFind.merge(phone, mac) == merged)
    }

    @Test func removingAndLookingUpAgain() {
        let find = ShopFind(album: "A", artist: "B", format: .cd, at: t0)
        let removed = find.removing(at: t0 + 10)
        #expect(ShopFind.merge(find, removed).removed)
        #expect(ShopFind.shown(SyncedRecords.overlay([find], [removed])).isEmpty)
        let again = ShopFind(album: "A", artist: "B", format: .cd, at: t0 + 20)
        #expect(!ShopFind.merge(removed, again).removed)
    }

    @Test func savesPrunesAndApplies() throws {
        let db = try Database(path: ":memory:")
        let finds = (0..<(ShopFind.maxKept + 5)).map { ShopFind(album: "Album \($0)", artist: "X", format: .cd, at: t0 + Double($0)) }
        try db.saveShopFinds(finds)
        let kept = try db.shopFinds()
        #expect(kept.count == ShopFind.maxKept && !kept.contains { $0.album == "Album 0" })
        #expect(ShopFind.shown(kept).first?.album == "Album \(ShopFind.maxKept + 4)")
        let phone = ShopFind(album: "From the phone", artist: "Y", format: .vinyl, at: t0 + 1000)
        #expect(try db.applyShopFinds([phone], libraryID: "another library") == 0)
        #expect(try db.applyShopFinds([phone], libraryID: db.libraryID()) == 1)
        #expect(SyncedRecords.applied([phone], in: try db.shopFinds()) == [phone.id])
        // A bad row is skipped.
        try db.exec("INSERT INTO shop_finds(id,data,updated_at,removed) VALUES('find-x','nope',0,0)")
        let after = try db.shopFinds()
        #expect(after.count == ShopFind.maxKept && after.contains { $0.id == phone.id })
    }

    @Test func travelsInTheManifestAndInbox() throws {
        let find = ShopFind(album: "A", artist: "B", format: .any, at: t0)
        let manifest = try JSONDecoder().decode(SyncManifest.self, from: try JSONEncoder().encode(SyncManifest(files: [], shopFinds: [find])))
        #expect(manifest.shopFinds == [find])
        let batch = CloudInboxBatch(libraryID: "lib", phoneID: "p1", phoneName: "Phone", events: [], requests: [], shopFinds: [find])
        #expect(CloudInboxBatch.decode(try batch.encoded())?.shopFinds == [find])
        // An unknown format from a newer phone is read as any format rather than failing the message.
        let json = #"{"id":"\#(find.id)","album":"A","format":"cassette8","at":1}"#
        #expect(try JSONDecoder().decode(ShopFind.self, from: Data(json.utf8)).format == .any)
    }
}
