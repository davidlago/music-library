import Foundation

// The Shop's Recent Finds: the albums priced in the Shop, on the Mac or the iPhone, newest first. Like the Buy List
// (`BuyList.swift`) they live in the library database (`shop_finds`, created on open without a schema change, in the
// Wi-Fi and iCloud snapshots), the phone's go to the Mac through its outbox (`SyncManifest.shopFinds`,
// `CloudInboxBatch.shopFinds`), and both sides merge by id. A find's id comes from its album, artist and format, so
// the same album looked up on both devices is one find. The photo the phone's DJ was shown stays on the phone.

public struct ShopFind: SyncedRecord, Identifiable {
    /// "find-" and a hash of the album, artist and format (`ShopFind.id(album:artist:format:)`).
    public var id: String
    public var album: String
    public var artist: String
    /// `PriceGuideRequest.Format` raw value; anything else reads as any format.
    public var formatRaw: String
    public var masterID: Int?
    /// The edition priced, when one was identified.
    public var releaseID: Int?
    public var barcode: String
    /// "$18–$32".
    public var fairPrice: String?
    public var thumbnail: URL?
    /// When it was last looked up.
    public var at: Date
    /// The last change: a lookup or removing it (the newer side wins when merging).
    public var updatedAt: Date
    public var removed: Bool

    /// The most kept (newest first); older ones are dropped when saving.
    public static let maxKept = 100

    public init(album: String, artist: String, format: PriceGuideRequest.Format, masterID: Int? = nil, releaseID: Int? = nil,
                barcode: String = "", fairPrice: String? = nil, thumbnail: URL? = nil, at: Date = Date()) {
        id = Self.id(album: album, artist: artist, format: format)
        self.album = album; self.artist = artist; formatRaw = format.rawValue; self.masterID = masterID; self.releaseID = releaseID
        self.barcode = barcode; self.fairPrice = fairPrice; self.thumbnail = thumbnail; self.at = at; updatedAt = at; removed = false
    }

    /// A guide the Shop read (nil when it found nothing), with the Shop's estimate before shipping.
    public init?(guide: PriceGuide, at: Date = Date()) {
        guard guide.hasPrices else { return nil }
        self.init(album: guide.title.isEmpty ? guide.request.album : guide.title,
                  artist: guide.artist.isEmpty ? guide.request.artist : guide.artist, format: guide.request.format,
                  masterID: guide.masterID, releaseID: guide.editions.first { $0.roles.contains(.identified) }?.releaseID,
                  barcode: guide.request.barcodeDigits ?? "", fairPrice: guide.shopEstimate(shipping: nil)?.text, thumbnail: guide.thumbnail, at: at)
    }

    private enum CodingKeys: String, CodingKey {
        case id, album, artist, formatRaw = "format", masterID, releaseID, barcode, fairPrice, thumbnail, at, updatedAt, removed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        album = (try? c.decode(String.self, forKey: .album)) ?? ""
        artist = (try? c.decode(String.self, forKey: .artist)) ?? ""
        formatRaw = (try? c.decode(String.self, forKey: .formatRaw)) ?? PriceGuideRequest.Format.any.rawValue
        masterID = try? c.decode(Int.self, forKey: .masterID)
        releaseID = try? c.decode(Int.self, forKey: .releaseID)
        barcode = (try? c.decode(String.self, forKey: .barcode)) ?? ""
        fairPrice = try? c.decode(String.self, forKey: .fairPrice)
        thumbnail = try? c.decode(URL.self, forKey: .thumbnail)
        at = (try? c.decode(Date.self, forKey: .at)) ?? Date(timeIntervalSince1970: 0)
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? at
        removed = (try? c.decode(Bool.self, forKey: .removed)) ?? false
    }

    public var format: PriceGuideRequest.Format { PriceGuideRequest.Format(rawValue: formatRaw) ?? .any }

    /// What to price when it's opened again.
    public var request: PriceGuideRequest {
        PriceGuideRequest(artist: artist, album: album, format: format, barcode: barcode, releaseID: releaseID, masterID: masterID)
    }

    public static func id(album: String, artist: String, format: PriceGuideRequest.Format) -> String {
        let key = [DiscogsReleaseMatcher.normalized(album), DiscogsReleaseMatcher.normalized(artist), format.rawValue].joined(separator: "|")
        return "find-" + CollectionItem.fnv1a64Hex(key)
    }

    public static func merge(_ a: ShopFind, _ b: ShopFind) -> ShopFind {
        var merged = b.updatedAt > a.updatedAt ? b : a
        // A lookup on either side keeps the newest date seen.
        if !merged.removed { merged.at = max(a.at, b.at) }
        return merged
    }

    public func sanitized() -> ShopFind? {
        guard id.hasPrefix("find-"), CollectionItem.isValidID(id) else { return nil }
        var f = self
        f.album = String(album.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
        f.artist = String(artist.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.album.isEmpty || removed else { return nil }
        f.formatRaw = format.rawValue
        f.masterID = masterID.flatMap { DiscogsLink.isValid($0) ? $0 : nil }
        f.releaseID = releaseID.flatMap { DiscogsLink.isValid($0) ? $0 : nil }
        f.barcode = String(barcode.filter { ("0"..."9").contains($0) }.prefix(20))
        f.fairPrice = fairPrice.map { String($0.prefix(40)) }
        f.thumbnail = thumbnail.flatMap { DiscogsLink.isImageURL($0) ? $0 : nil }
        for date in [at, updatedAt] where !date.timeIntervalSince1970.isFinite { return nil }
        return f
    }

    /// The finds to show: not removed, newest first.
    public static func shown(_ all: [ShopFind]) -> [ShopFind] {
        Array(all.filter { !$0.removed }.sorted { $0.at > $1.at }.prefix(maxKept))
    }

    /// Removed (a tombstone, so an older lookup elsewhere can't bring it back until it's looked up again).
    public func removing(at date: Date = Date()) -> ShopFind {
        var f = self
        f.removed = true
        f.updatedAt = max(date, updatedAt)
        return f
    }
}

public typealias ShopFindOutbox = RecordOutbox<ShopFind>

extension Database {
    /// Created on open without a schema change; synced to phones and backed up.
    func createShopFindsTable() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS shop_finds(
            id TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at REAL NOT NULL, removed INTEGER NOT NULL DEFAULT 0)
        """)
    }

    /// Every find, removed ones too. Rows are untrusted; a copy without the table has none.
    public func shopFinds() throws -> [ShopFind] {
        guard try !columns(of: "shop_finds").isEmpty else { return [] }
        let decoder = JSONDecoder()
        return try query("SELECT id, data FROM shop_finds ORDER BY rowid") { r -> ShopFind? in
            guard let id = r.string(0), let text = r.string(1), text.utf8.count <= 64 * 1024,
                  let find = try? decoder.decode(ShopFind.self, from: Data(text.utf8)), find.id == id else { return nil }
            return find.sanitized()
        }.compactMap { $0 }
    }

    /// Saves finds, each merged with what's stored; keeps the newest `ShopFind.maxKept` and a year of removals.
    @discardableResult
    public func saveShopFinds(_ finds: [ShopFind]) throws -> Int {
        let stored = Dictionary(try shopFinds().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var changed = 0
        try transaction {
            for find in finds.prefix(5000) {
                guard let clean = find.sanitized() else { continue }
                let merged = stored[clean.id].map { ShopFind.merge($0, clean) } ?? clean
                if stored[clean.id] == merged { continue }
                try exec("""
                INSERT INTO shop_finds(id,data,updated_at,removed) VALUES(?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET data=excluded.data, updated_at=excluded.updated_at, removed=excluded.removed
                """, [.text(merged.id), .text(String(decoding: try encoder.encode(merged), as: UTF8.self)),
                      .double(merged.updatedAt.timeIntervalSince1970), .int(merged.removed ? 1 : 0)])
                changed += 1
            }
            try exec("""
            DELETE FROM shop_finds WHERE removed=0 AND id NOT IN
                (SELECT id FROM shop_finds WHERE removed=0 ORDER BY updated_at DESC LIMIT \(ShopFind.maxKept))
            """)
            try exec("DELETE FROM shop_finds WHERE removed=1 AND updated_at < ?",
                     [.double(Date().addingTimeInterval(-365 * 86_400).timeIntervalSince1970)])
        }
        return changed
    }

    /// A phone's finds (Wi-Fi sync or iCloud inbox), only from this library.
    @discardableResult
    public func applyShopFinds(_ finds: [ShopFind], libraryID phoneLibrary: String?) throws -> Int {
        guard !finds.isEmpty, phoneLibrary == nil || phoneLibrary == libraryID() else { return 0 }
        return try saveShopFinds(finds)
    }
}
