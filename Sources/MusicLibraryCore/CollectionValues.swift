import Foundation

// What your CDs and records are worth: each copy's edition priced with the Shop's price guide (its Discogs release
// when it's known: the item's own, or the one Sync to Discogs matched; else its barcode, catalog number and the rest),
// kept per item in `collection_values` (created on open without a schema change; in the Wi-Fi and iCloud snapshots,
// so the phone shows them too), and summed up in the Owned pane of Insights (`CollectionValueStats`).

/// One copy's value when it was last priced.
public struct CollectionValue: Codable, Hashable, Sendable {
    public var itemID: String
    public var at: Date
    /// Discogs or eBay had it.
    public var found: Bool
    public var low: Money?
    public var high: Money?
    public var source: String?
    /// The cheapest copy of the edition for sale on Discogs now, and how many there are.
    public var lowest: Money?
    public var forSale: Int?
    public var have: Int?
    public var want: Int?
    /// The Discogs release priced, when one was.
    public var releaseID: Int?
    /// The copy's media grade it was priced for (`CollectionGrade` raw value; nil: ungraded, or priced before 1.35).
    public var grade: String?
    /// How it was worked out (`CollectionValue.method`); nil: before 1.35, when eBay's sales led.
    public var method: Int?

    /// 2: Discogs first, for the copy's grade (`PriceGuide.copyEstimate`).
    public static let method = 2

    public init(itemID: String, at: Date, found: Bool, low: Money? = nil, high: Money? = nil, source: String? = nil,
                lowest: Money? = nil, forSale: Int? = nil, have: Int? = nil, want: Int? = nil, releaseID: Int? = nil) {
        self.itemID = itemID; self.at = at; self.found = found; self.low = low; self.high = high; self.source = source
        self.lowest = lowest; self.forSale = forSale; self.have = have; self.want = want; self.releaseID = releaseID
    }

    /// The copy's value from a guide, for its media grade (`PriceGuide.copyEstimate`).
    public init(itemID: String, guide: PriceGuide, grade: CollectionGrade? = nil, at: Date = Date()) {
        self.itemID = itemID
        self.at = at
        found = guide.hasPrices
        self.grade = grade?.rawValue
        method = Self.method
        if let fair = guide.copyEstimate(grade: grade) { low = fair.low; high = fair.high; source = fair.source }
        let edition = guide.editions.first { $0.roles.contains(.identified) } ?? guide.headline
        lowest = edition?.lowest
        forSale = edition?.forSale
        have = edition?.have
        want = edition?.want
        releaseID = edition?.releaseID
    }

    /// What it's worth: the middle of the fair price.
    public var estimate: Money? {
        guard let low else { return nil }
        guard let high, high.currency == low.currency else { return low }
        return Money((low.amount + high.amount) / 2, low.currency)
    }

    /// "$18–$32".
    public var text: String? {
        guard let low else { return nil }
        guard let high, high != low else { return PriceGuide.text(low) }
        return "\(PriceGuide.text(low))–\(PriceGuide.text(high))"
    }

    func sanitized() -> CollectionValue? {
        guard CollectionItem.isValidID(itemID), at.timeIntervalSince1970.isFinite else { return nil }
        var v = self
        v.low = low.flatMap(WantedAlbum.validMoney)
        v.high = high.flatMap(WantedAlbum.validMoney)
        v.lowest = lowest.flatMap(WantedAlbum.validMoney)
        v.source = source.map { String($0.prefix(200)) }
        v.forSale = forSale.map { max(0, $0) }
        v.have = have.map { max(0, $0) }
        v.want = want.map { max(0, $0) }
        v.releaseID = releaseID.flatMap { DiscogsLink.isValid($0) ? $0 : nil }
        v.grade = grade.flatMap(CollectionGrade.init(rawValue:))?.rawValue
        return v
    }

    /// Only CDs and records are priced.
    public static func canValue(_ item: CollectionItem) -> Bool {
        item.origin == .stored && (item.medium == .cd || item.medium == .vinyl) && !item.album.isEmpty
    }

    /// What to price for a copy: its edition as precisely as it's known. `discogsMatch` is the release Sync to
    /// Discogs matched it to (Mac), used when the item has none of its own.
    public static func request(for item: CollectionItem, discogsMatch: Int? = nil) -> PriceGuideRequest {
        PriceGuideRequest(artist: item.artist, album: item.album, format: item.medium == .vinyl ? .vinyl : .cd,
                          barcode: item.barcode ?? "", catalogNumber: item.catalogNumber ?? "", label: item.recordLabel ?? "",
                          country: item.country ?? "", year: item.year, releaseID: item.discogsReleaseID ?? discogsMatch)
    }

    /// Whether it was priced for the copy as it is now: the same media grade and, when the copy names its Discogs
    /// release, that release. Otherwise it's priced again (changing a grade re-values the copy).
    public func matches(_ item: CollectionItem) -> Bool {
        guard method == Self.method, grade == item.mediaGrade?.rawValue else { return false }
        if let own = item.discogsReleaseID, let releaseID, own != releaseID { return false }
        return true
    }

    /// Prices older than this are offered for updating.
    public static let staleAge: TimeInterval = 30 * 86_400
}

extension Database {
    /// Created on open without a schema change; rows outlive nothing: a removed item's row goes at the next save.
    func createCollectionValuesTable() throws {
        try exec("CREATE TABLE IF NOT EXISTS collection_values(item_id TEXT PRIMARY KEY, data TEXT NOT NULL, checked_at REAL NOT NULL)")
    }

    /// By item id. Rows are untrusted: one that doesn't read is skipped. A copy without the table has none.
    public func collectionValues() throws -> [String: CollectionValue] {
        guard try !columns(of: "collection_values").isEmpty else { return [:] }
        let decoder = JSONDecoder()
        let rows = try query("SELECT item_id, data FROM collection_values") { r -> CollectionValue? in
            guard let id = r.string(0), let text = r.string(1), text.utf8.count <= 64 * 1024,
                  let value = try? decoder.decode(CollectionValue.self, from: Data(text.utf8)), value.itemID == id else { return nil }
            return value.sanitized()
        }
        return Dictionary(rows.compactMap { $0 }.map { ($0.itemID, $0) }, uniquingKeysWith: { a, b in a.at >= b.at ? a : b })
    }

    public func saveCollectionValues(_ values: [CollectionValue]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try transaction {
            for value in values {
                guard let clean = value.sanitized() else { continue }
                try exec("INSERT OR REPLACE INTO collection_values(item_id,data,checked_at) VALUES(?,?,?)",
                         [.text(clean.itemID), .text(String(decoding: try encoder.encode(clean), as: UTF8.self)),
                          .double(clean.at.timeIntervalSince1970)])
            }
            try exec("DELETE FROM collection_values WHERE item_id NOT IN (SELECT id FROM collection_items)")
        }
    }
}

// MARK: Insights

/// The collection's value, for the Owned pane: the total of every priced CD and record (in the currency most of
/// them are priced in), against what you paid for them, by medium, the most valuable copies and the ones that gained
/// the most.
public struct CollectionValueStats: Hashable, Sendable {
    public struct Row: Hashable, Sendable, Identifiable {
        public var item: CollectionItem
        public var value: Money
        public var paid: Decimal?
        public var id: String { item.id }
        public var gain: Decimal? { paid.map { value.amount - $0 } }
    }

    public var currency = "USD"
    public var total: Decimal = 0
    /// Copies that could be priced (stored CDs and records), how many were, and how many found nothing.
    public var eligible = 0
    public var valued = 0
    public var notFound = 0
    /// Priced longer ago than `CollectionValue.staleAge`, or not for the copy as it is now (`CollectionValue.matches`).
    public var stale = 0
    /// What was paid for the priced copies that have a price paid, and what those copies are worth now.
    public var paid: Decimal = 0
    public var paidValue: Decimal = 0
    public var byMedium: [String: Decimal] = [:]
    public var top: [Row] = []
    public var gainers: [Row] = []
    public var lastCheck: Date?

    public init() {}

    public var isEmpty: Bool { valued == 0 }
    public var gain: Decimal { paidValue - paid }
    /// Copies not priced yet (or priced too long ago).
    public var toUpdate: Int { eligible - valued + stale }

    public static func make(collection: MusicCollection, values: [String: CollectionValue], now: Date = Date()) -> CollectionValueStats {
        var s = CollectionValueStats()
        let items = collection.items.filter(CollectionValue.canValue)
        s.eligible = items.count
        var counted: [(CollectionItem, CollectionValue, Money)] = []
        var byCurrency: [String: Int] = [:]
        for item in items {
            guard let v = values[item.id] else { continue }
            if now.timeIntervalSince(v.at) >= CollectionValue.staleAge || !v.matches(item) { s.stale += 1 }
            s.lastCheck = max(s.lastCheck ?? v.at, v.at)
            guard let estimate = v.estimate else { if !v.found { s.notFound += 1 }; continue }
            counted.append((item, v, estimate))
            byCurrency[estimate.currency, default: 0] += 1
        }
        // Values in another currency (rare: a guide made with another setting) are left out of the sums.
        s.currency = byCurrency.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "USD"
        var rows: [Row] = []
        for (item, _, estimate) in counted where estimate.currency == s.currency {
            s.valued += 1
            s.total += estimate.amount
            s.byMedium[item.medium.rawValue, default: 0] += estimate.amount
            let row = Row(item: item, value: estimate, paid: item.price)
            if let paid = item.price {
                s.paid += paid
                s.paidValue += estimate.amount
            }
            rows.append(row)
        }
        s.top = Array(rows.sorted { ($0.value.amount, $0.item.album) > ($1.value.amount, $1.item.album) }.prefix(10))
        s.gainers = Array(rows.filter { ($0.gain ?? 0) > 0 }.sorted { ($0.gain ?? 0) > ($1.gain ?? 0) }.prefix(10))
        return s
    }
}
