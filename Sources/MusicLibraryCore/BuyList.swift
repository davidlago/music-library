import Foundation

// The Buy List: albums you're looking for, on CD, vinyl or either, each with what it goes for now. Anything priced in
// the Shop can go on it (both apps), as can a Local Library CD on the Mac; Refresh prices each one again with the
// Shop's price guide (`PriceGuides.fullGuide`) and keeps the last checks, so the list shows what changed and what's
// at or under the most you'd pay.
//
// The list lives in the library database (`wanted_albums`, created on open without a schema change), so it's in the
// Wi-Fi sync and iCloud snapshots and both apps show the same list. The phone edits it too: its changes go in its
// own outbox (`WantedOutbox`) and travel in the sync manifest and the iCloud inbox batch (optional fields older Macs
// ignore), and the Mac merges them in (`Database.applyWanted`). Merging is per album and symmetric: the side edited
// last wins the album's fields (removing is an edit), and price checks from both sides are kept (newest first, at
// most `WantedAlbum.maxChecks`). Rows and changes are untrusted when read (`WantedAlbum.sanitized`).

/// What an album went for when it was last priced.
public struct WantedPriceCheck: Codable, Hashable, Sendable {
    public var at: Date
    /// Discogs or eBay had it.
    public var found: Bool
    /// The guide's fair price (`PriceGuide.fairPrice`).
    public var fairLow: Money?
    public var fairHigh: Money?
    public var fairSource: String?
    /// The cheapest copy for sale on Discogs: the edition wanted, else any edition in the format.
    public var discogsLowest: Money?
    public var discogsForSale: Int?
    /// eBay: the lowest typical asking price (used, else new) and recent sales' median.
    public var ebayAsking: Money?
    public var ebaySoldMedian: Money?
    public var ebaySoldCount: Int?

    public init(at: Date, found: Bool, fairLow: Money? = nil, fairHigh: Money? = nil, fairSource: String? = nil,
                discogsLowest: Money? = nil, discogsForSale: Int? = nil, ebayAsking: Money? = nil,
                ebaySoldMedian: Money? = nil, ebaySoldCount: Int? = nil) {
        self.at = at; self.found = found; self.fairLow = fairLow; self.fairHigh = fairHigh; self.fairSource = fairSource
        self.discogsLowest = discogsLowest; self.discogsForSale = discogsForSale; self.ebayAsking = ebayAsking
        self.ebaySoldMedian = ebaySoldMedian; self.ebaySoldCount = ebaySoldCount
    }

    public init(guide: PriceGuide, at: Date = Date()) {
        self.at = at
        found = guide.hasPrices
        if let fair = guide.fairPrice { fairLow = fair.low; fairHigh = fair.high; fairSource = fair.source }
        let identified = guide.editions.first { $0.roles.contains(.identified) }
        if let identified {
            discogsLowest = identified.lowest
            discogsForSale = identified.forSale
        } else {
            let priced = guide.editions.filter { $0.lowest != nil && $0.forSale > 0 }
            discogsLowest = priced.compactMap(\.lowest).min()
            discogsForSale = priced.isEmpty ? nil : priced.map(\.forSale).reduce(0, +)
            if guide.request.format == .any, let master = guide.masterLowest {
                discogsLowest = master
                discogsForSale = guide.masterForSale
            }
        }
        let asking = guide.ebayForSale.flatMap { $0.used ?? $0.new }
        ebayAsking = asking?.typicalLow
        let sold = guide.ebaySold.flatMap { $0.used ?? $0.new }
        ebaySoldMedian = sold?.median
        ebaySoldCount = sold?.count
    }

    /// The middle of the fair price.
    public var fairMid: Money? {
        guard let low = fairLow else { return nil }
        guard let high = fairHigh, high.currency == low.currency else { return low }
        return Money((low.amount + high.amount) / 2, low.currency)
    }

    /// The least anyone is asking now: Discogs' cheapest copy or eBay's typical low.
    public var cheapestNow: Money? {
        [discogsLowest, ebayAsking].compactMap { $0 }.min { a, b in a.currency == b.currency ? a.amount < b.amount : a.currency == "USD" }
    }

    /// The price to watch: what you'd pay now, else the fair price.
    public var headline: Money? { cheapestNow ?? fairLow }

    /// "$18–$32".
    public var fairText: String? {
        guard let low = fairLow else { return nil }
        guard let high = fairHigh, high != low else { return PriceGuide.text(low) }
        return "\(PriceGuide.text(low))–\(PriceGuide.text(high))"
    }

    func sanitized() -> WantedPriceCheck? {
        guard at.timeIntervalSince1970.isFinite else { return nil }
        func ok(_ m: Money?) -> Money? { m.flatMap(WantedAlbum.validMoney) }
        var c = self
        c.fairLow = ok(fairLow); c.fairHigh = ok(fairHigh); c.discogsLowest = ok(discogsLowest)
        c.ebayAsking = ok(ebayAsking); c.ebaySoldMedian = ok(ebaySoldMedian)
        c.fairSource = fairSource.map { String($0.prefix(200)) }
        c.discogsForSale = discogsForSale.map { max(0, min($0, 10_000_000)) }
        c.ebaySoldCount = ebaySoldCount.map { max(0, min($0, 10_000_000)) }
        return c
    }
}

/// An album on the Buy List.
public struct WantedAlbum: SyncedRecord, Identifiable {
    /// A lowercased UUID.
    public var id: String
    public var artist: String
    public var album: String
    /// `PriceGuideRequest.Format` raw value; anything else reads as any format.
    public var formatRaw: String
    /// What identifies the edition wanted, when one is (empty: any edition in the format).
    public var barcode: String
    public var catalogNumber: String
    public var recordLabel: String
    public var country: String
    public var year: Int?
    public var discogsReleaseID: Int?
    public var discogsMasterID: Int?
    /// Discogs' picture of it (only Discogs image URLs are kept).
    public var thumbnail: URL?
    /// The most you'd pay, in `currency`.
    public var maxPrice: Decimal?
    public var currency: String
    public var notes: String
    public var addedAt: Date
    /// The user's last edit (removing is one); the newer side wins when merging.
    public var updatedAt: Date
    public var removed: Bool
    /// Newest first.
    public var checks: [WantedPriceCheck]

    public static let maxChecks = 24

    public init(id: String = UUID().uuidString.lowercased(), artist: String, album: String, format: PriceGuideRequest.Format,
                barcode: String = "", catalogNumber: String = "", recordLabel: String = "", country: String = "", year: Int? = nil,
                discogsReleaseID: Int? = nil, discogsMasterID: Int? = nil, thumbnail: URL? = nil, maxPrice: Decimal? = nil,
                currency: String = "USD", notes: String = "", addedAt: Date = Date(), checks: [WantedPriceCheck] = []) {
        self.id = id; self.artist = artist; self.album = album; formatRaw = format.rawValue; self.barcode = barcode
        self.catalogNumber = catalogNumber; self.recordLabel = recordLabel; self.country = country; self.year = year
        self.discogsReleaseID = discogsReleaseID; self.discogsMasterID = discogsMasterID; self.thumbnail = thumbnail
        self.maxPrice = maxPrice; self.currency = currency; self.notes = notes; self.addedAt = addedAt; updatedAt = addedAt
        removed = false; self.checks = checks
    }

    /// From a price guide (the Shop's), with the guide as its first check.
    public init(guide: PriceGuide, currency: String, at: Date = Date()) {
        let r = guide.request
        let identified = guide.editions.first { $0.roles.contains(.identified) }
        self.init(artist: guide.artist.isEmpty ? r.artist : guide.artist, album: guide.title.isEmpty ? r.album : guide.title,
                  format: r.format, barcode: r.barcode, catalogNumber: identified?.catalogNumber ?? r.catalogNumber,
                  recordLabel: identified?.label ?? r.label, country: identified?.country ?? r.country, year: identified?.year ?? r.year,
                  discogsReleaseID: identified?.releaseID ?? r.releaseID, discogsMasterID: guide.masterID ?? r.masterID,
                  thumbnail: guide.thumbnail, currency: currency, addedAt: at,
                  checks: guide.hasPrices ? [WantedPriceCheck(guide: guide, at: at)] : [])
    }

    private enum CodingKeys: String, CodingKey {
        case id, artist, album, formatRaw = "format", barcode, catalogNumber, recordLabel, country, year, discogsReleaseID,
             discogsMasterID, thumbnail, maxPrice, currency, notes, addedAt, updatedAt, removed, checks
    }

    /// Lenient: a field this version can't read is left empty rather than failing the whole message.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        artist = (try? c.decode(String.self, forKey: .artist)) ?? ""
        album = (try? c.decode(String.self, forKey: .album)) ?? ""
        formatRaw = (try? c.decode(String.self, forKey: .formatRaw)) ?? PriceGuideRequest.Format.any.rawValue
        barcode = (try? c.decode(String.self, forKey: .barcode)) ?? ""
        catalogNumber = (try? c.decode(String.self, forKey: .catalogNumber)) ?? ""
        recordLabel = (try? c.decode(String.self, forKey: .recordLabel)) ?? ""
        country = (try? c.decode(String.self, forKey: .country)) ?? ""
        year = try? c.decode(Int.self, forKey: .year)
        discogsReleaseID = try? c.decode(Int.self, forKey: .discogsReleaseID)
        discogsMasterID = try? c.decode(Int.self, forKey: .discogsMasterID)
        thumbnail = try? c.decode(URL.self, forKey: .thumbnail)
        maxPrice = try? c.decode(Decimal.self, forKey: .maxPrice)
        currency = (try? c.decode(String.self, forKey: .currency)) ?? "USD"
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        addedAt = (try? c.decode(Date.self, forKey: .addedAt)) ?? Date(timeIntervalSince1970: 0)
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? addedAt
        removed = (try? c.decode(Bool.self, forKey: .removed)) ?? false
        checks = ((try? c.decode([Lenient<WantedPriceCheck>].self, forKey: .checks)) ?? []).compactMap(\.value)
    }

    public var format: PriceGuideRequest.Format {
        get { PriceGuideRequest.Format(rawValue: formatRaw) ?? .any }
        set { formatRaw = newValue.rawValue }
    }

    public var latest: WantedPriceCheck? { checks.first }
    /// The check before the latest, for what changed.
    public var previous: WantedPriceCheck? { checks.dropFirst().first }

    /// A specific edition is wanted.
    public var isEdition: Bool { discogsReleaseID != nil || !barcode.isEmpty || !catalogNumber.isEmpty }

    /// "US 1959 · Columbia CL 1355".
    public var editionDetails: String {
        let place = [country, year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let label = [recordLabel, catalogNumber].filter { !$0.isEmpty }.joined(separator: " ")
        return [place, label].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What to price.
    public var request: PriceGuideRequest {
        PriceGuideRequest(artist: artist, album: album, format: format, barcode: barcode, catalogNumber: catalogNumber,
                          label: recordLabel, country: country, year: year, releaseID: discogsReleaseID, masterID: discogsMasterID)
    }

    /// The most you'd pay, as money.
    public var maxMoney: Money? { maxPrice.map { Money($0, currency) } }

    /// Something is asking no more than the most you'd pay.
    public var isDeal: Bool {
        guard let max = maxMoney, let now = latest?.cheapestNow, now.currency == max.currency else { return false }
        return now.amount <= max.amount
    }

    /// How the price to watch moved since the check before (negative: cheaper).
    public var change: Decimal? {
        guard let now = latest?.headline, let before = previous?.headline, now.currency == before.currency else { return nil }
        return now.amount - before.amount
    }

    /// Not priced, or priced longer ago than `age`.
    public func needsCheck(now: Date = Date(), age: TimeInterval) -> Bool {
        guard let at = latest?.at else { return true }
        return now.timeIntervalSince(at) >= age
    }

    /// Same album in the same format (adding it twice moves it rather than adding a second).
    public func isSame(artist: String, album: String, format: PriceGuideRequest.Format) -> Bool {
        self.format == format && DiscogsReleaseMatcher.isSameAlbum(self.album, album) && ShopOwnership.sameArtist(self.artist, artist)
    }

    /// Adds a check, newest first, keeping at most `maxChecks` (one per moment).
    public mutating func record(_ check: WantedPriceCheck) {
        checks = Self.mergeChecks(checks, [check])
    }

    /// One line for the Radio DJ: "*Kind of Blue* by Miles Davis (Vinyl; US 1959 · Columbia CL 1355): fair $40–$60,
    /// cheapest now $35, most they'd pay $45 (a deal now); priced Nov 8".
    public var radioDJLine: String {
        var line = "*\(album)* by \(artist.isEmpty ? "unknown artist" : artist) (\([format.name, editionDetails].filter { !$0.isEmpty }.joined(separator: "; ")))"
        var parts: [String] = []
        if let check = latest {
            if let fair = check.fairText { parts.append("fair \(fair)") }
            if let now = check.cheapestNow { parts.append("cheapest now \(PriceGuide.text(now))") }
            if !check.found { parts.append("nothing found for sale") }
        } else {
            parts.append("not priced yet")
        }
        if let max = maxMoney { parts.append("most they'd pay \(PriceGuide.text(max))\(isDeal ? " (a deal now)" : "")") }
        if let at = latest?.at { parts.append("priced \(at.formatted(date: .abbreviated, time: .omitted))") }
        if !notes.isEmpty { parts.append("note: \(notes.prefix(200))") }
        line += ": " + parts.joined(separator: ", ")
        return line
    }

    /// Takes in a price guide read for it: its figures as the latest check (when it found anything) and, the first
    /// time, Discogs' picture and master for it (an edit, so merging keeps them).
    public mutating func take(_ guide: PriceGuide, at date: Date = Date()) {
        if guide.hasPrices { record(WantedPriceCheck(guide: guide, at: date)) }
        if thumbnail == nil, let t = guide.thumbnail, DiscogsLink.isImageURL(t) { thumbnail = t; updatedAt = max(updatedAt, date) }
        if discogsMasterID == nil, let m = guide.masterID, DiscogsLink.isValid(m) { discogsMasterID = m; updatedAt = max(updatedAt, date) }
    }

    // MARK: Merging

    /// The two versions of an album taken together: fields from the one edited last (ties go to `a`), checks from both.
    public static func merge(_ a: WantedAlbum, _ b: WantedAlbum) -> WantedAlbum {
        var merged = b.updatedAt > a.updatedAt ? b : a
        merged.checks = mergeChecks(a.checks, b.checks)
        merged.addedAt = min(a.addedAt, b.addedAt)
        return merged
    }

    static func mergeChecks(_ a: [WantedPriceCheck], _ b: [WantedPriceCheck]) -> [WantedPriceCheck] {
        var seen = Set<Double>()
        return (a + b).sorted { $0.at > $1.at }.filter { seen.insert($0.at.timeIntervalSince1970.rounded()).inserted }
            .prefix(maxChecks).map { $0 }
    }

    // MARK: Validation

    static func validMoney(_ m: Money) -> Money? {
        guard m.currency.count == 3, m.currency.allSatisfy({ $0.isASCII && $0.isUppercase }), m.amount >= 0, m.amount < 100_000_000 else { return nil }
        return m
    }

    public static func isValidID(_ id: String) -> Bool { CollectionItem.isValidID(id) }

    /// Nil for one that can't be used (bad id, no album); fields too long are cut, bad values dropped.
    public func sanitized() -> WantedAlbum? {
        let id = id.lowercased()
        guard Self.isValidID(id) else { return nil }
        var w = self
        w.id = id
        func clean(_ s: String, _ max: Int) -> String {
            String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(max).map(Character.init))
                .trimmingCharacters(in: .whitespaces)
        }
        w.artist = clean(artist, 500)
        w.album = clean(album, 500)
        guard !w.album.isEmpty || removed else { return nil }
        w.formatRaw = format.rawValue
        w.barcode = String(barcode.filter { ("0"..."9").contains($0) }.prefix(20))
        w.catalogNumber = clean(catalogNumber, 100)
        w.recordLabel = clean(recordLabel, 200)
        w.country = clean(country, 100)
        w.year = year.flatMap { (1000...9999).contains($0) ? $0 : nil }
        w.discogsReleaseID = discogsReleaseID.flatMap { DiscogsLink.isValid($0) ? $0 : nil }
        w.discogsMasterID = discogsMasterID.flatMap { DiscogsLink.isValid($0) ? $0 : nil }
        w.thumbnail = thumbnail.flatMap { DiscogsLink.isImageURL($0) ? $0 : nil }
        w.currency = currency.count == 3 && currency.allSatisfy({ $0.isASCII && $0.isLetter }) ? currency.uppercased() : "USD"
        w.maxPrice = maxPrice.flatMap { $0 > 0 && $0 < 100_000_000 ? $0 : nil }
        w.notes = String(notes.prefix(5000))
        for date in [addedAt, updatedAt] where !date.timeIntervalSince1970.isFinite { return nil }
        w.checks = Self.mergeChecks(checks.compactMap { $0.sanitized() }, [])
        return w
    }
}

/// Decodes what it can of an array element, so one bad entry doesn't lose the rest.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: The list

public enum BuyList {
    /// Albums still wanted, in the order shown: deals first, then the most recently added.
    public static func shown(_ all: [WantedAlbum]) -> [WantedAlbum] {
        all.filter { !$0.removed }.sorted { a, b in
            if a.isDeal != b.isDeal { return a.isDeal }
            return a.addedAt > b.addedAt
        }
    }

    public static func overlay(_ base: [WantedAlbum], _ changes: [WantedAlbum]) -> [WantedAlbum] { SyncedRecords.overlay(base, changes) }
    public static func applied(_ changes: [WantedAlbum], in base: [WantedAlbum]) -> Set<String> { SyncedRecords.applied(changes, in: base) }

    /// The list's entry for an album, if it's on it.
    public static func entry(in list: [WantedAlbum], artist: String, album: String, format: PriceGuideRequest.Format) -> WantedAlbum? {
        list.first { !$0.removed && $0.isSame(artist: artist, album: album, format: format) }
            ?? list.first { !$0.removed && $0.format == .any && $0.isSame(artist: artist, album: album, format: .any) }
    }

    /// What finding everything at about its fair price would cost, per currency of the fair prices (deals at their
    /// asking price), and how many have no price yet.
    public struct Totals: Hashable, Sendable {
        public var count = 0
        public var priced = 0
        public var deals = 0
        public var cost: Money?
        public init() {}
    }

    public static func totals(_ shown: [WantedAlbum]) -> Totals {
        var t = Totals()
        t.count = shown.count
        var sums: [String: Decimal] = [:]
        for w in shown {
            if w.isDeal { t.deals += 1 }
            guard let price = w.isDeal ? w.latest?.cheapestNow : (w.latest?.fairMid ?? w.latest?.headline) else { continue }
            t.priced += 1
            sums[price.currency, default: 0] += price.amount
        }
        if let main = sums.max(by: { $0.value < $1.value }) { t.cost = Money(main.value, main.key) }
        return t
    }
}

// MARK: Synced records

/// A record both apps edit (Buy List albums, Shop finds): kept in the library database, changed on the phone through
/// an outbox, merged by id on either side.
public protocol SyncedRecord: Codable, Hashable, Sendable {
    var id: String { get }
    /// The two versions taken together; the same either way round apart from ties.
    static func merge(_ a: Self, _ b: Self) -> Self
    /// Nil for one that can't be used; fields cut and bad values dropped.
    func sanitized() -> Self?
}

public enum SyncedRecords {
    /// `base` (the snapshot's) with `changes` (the phone's, not yet applied by the Mac) merged in, by id.
    public static func overlay<R: SyncedRecord>(_ base: [R], _ changes: [R]) -> [R] {
        var byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: R.merge)
        var order = base.map(\.id)
        for c in changes {
            if let old = byID[c.id] { byID[c.id] = R.merge(old, c) } else { byID[c.id] = c; order.append(c.id) }
        }
        var seen = Set<String>()
        return order.filter { seen.insert($0).inserted }.compactMap { byID[$0] }
    }

    /// The changes `base` already has (merging them changes nothing): they can leave the phone's outbox.
    public static func applied<R: SyncedRecord>(_ changes: [R], in base: [R]) -> Set<String> {
        let byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Set(changes.filter { c in byID[c.id].map { R.merge($0, c) == $0 } ?? false }.map(\.id))
    }
}

/// The phone's changes to synced records the Mac hasn't applied yet, by record (the latest version of each),
/// persisted as JSON.
public final class RecordOutbox<Record: SyncedRecord>: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var items: [Record]

    public init(url: URL) {
        self.url = url
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Lenient<Record>].self, from: $0) } ?? []
        items = read.compactMap { $0.value?.sanitized() }
    }

    public var changes: [Record] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    /// Keeps the record's latest version (merged with one already waiting).
    public func put(_ record: Record) {
        lock.lock(); defer { lock.unlock() }
        if let i = items.firstIndex(where: { $0.id == record.id }) { items[i] = Record.merge(items[i], record) } else { items.append(record) }
        save()
    }

    public func remove(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    public func removeAll() { remove(Set(changes.map(\.id))) }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
        } catch {}
    }
}

/// The phone's Buy List changes the Mac hasn't applied yet.
public typealias WantedOutbox = RecordOutbox<WantedAlbum>

// MARK: Database

extension Database {
    /// Created on open without a schema change (like `collection_items`); synced to phones and backed up.
    func createWantedTable() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS wanted_albums(
            id TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at REAL NOT NULL, removed INTEGER NOT NULL DEFAULT 0)
        """)
    }

    /// Every album on the list, removed ones too (they keep a removal from being undone by an older change). Rows
    /// are untrusted: one that doesn't read is skipped. A copy without the table has none.
    public func wantedAlbums() throws -> [WantedAlbum] {
        guard try !columns(of: "wanted_albums").isEmpty else { return [] }
        let decoder = JSONDecoder()
        return try query("SELECT id, data FROM wanted_albums ORDER BY rowid") { r -> WantedAlbum? in
            guard let id = r.string(0), let text = r.string(1), text.utf8.count <= 256 * 1024,
                  let album = try? decoder.decode(WantedAlbum.self, from: Data(text.utf8)), album.id.lowercased() == id.lowercased() else { return nil }
            return album.sanitized()
        }.compactMap { $0 }
    }

    /// Saves albums as given, each merged with what's stored (`WantedAlbum.merge`). Returns how many changed.
    @discardableResult
    public func saveWanted(_ albums: [WantedAlbum]) throws -> Int {
        let stored = Dictionary(try wantedAlbums().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var changed = 0
        try transaction {
            for album in albums {
                guard let clean = album.sanitized() else { continue }
                let merged = stored[clean.id].map { WantedAlbum.merge($0, clean) } ?? clean
                if stored[clean.id] == merged { continue }
                let data = String(decoding: try encoder.encode(merged), as: UTF8.self)
                try exec("""
                INSERT INTO wanted_albums(id,data,updated_at,removed) VALUES(?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET data=excluded.data, updated_at=excluded.updated_at, removed=excluded.removed
                """, [.text(merged.id), .text(data), .double(merged.updatedAt.timeIntervalSince1970), .int(merged.removed ? 1 : 0)])
                changed += 1
            }
            // Removals are kept a year, long enough for any phone's older change to arrive and lose to them.
            try exec("DELETE FROM wanted_albums WHERE removed=1 AND updated_at < ?",
                     [.double(Date().addingTimeInterval(-365 * 86_400).timeIntervalSince1970)])
        }
        return changed
    }

    /// A phone's Buy List changes (Wi-Fi sync or iCloud inbox), only from this library. Returns how many changed.
    @discardableResult
    public func applyWanted(_ changes: [WantedAlbum], libraryID phoneLibrary: String?) throws -> Int {
        guard !changes.isEmpty, phoneLibrary == nil || phoneLibrary == libraryID() else { return 0 }
        return try saveWanted(Array(changes.prefix(5000)))
    }
}
