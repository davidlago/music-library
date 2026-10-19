import Foundation

/// How the collection stays readable by versions before it, and takes in what they change. Pure functions shared by
/// the Mac (which saves the results) and the phone (which applies them in memory).
///
/// `album_ownership` (one row per album key, read by name on phones 1.14–1.20 and older Macs) becomes a projection
/// of the collection: each key's primary CD or download with its own album, artist, date, price and (CDs only) label
/// number. `format` is only ever NULL (a CD) or 'digital'. Records, other media and downloads derived from bought
/// songs are never projected, so an older reader sees a record-only album as not owned rather than as a CD. Only
/// the primary copy of a key is projected, so an older reader doesn't see the labels of other CDs of the same album:
/// after a downgrade, an older Mac can suggest (and accept) a label number a second copy holds. That's documented
/// (help, CHANGELOG), and Label Check lists the duplicate once 1.21 opens the library again.
public enum CollectionLegacy {
    /// An `album_ownership` row.
    public struct Row: Hashable, Sendable {
        public var key: String
        public var purchase: AlbumPurchase
        public var updatedAt: Date

        public init(key: String, purchase: AlbumPurchase, updatedAt: Date) {
            self.key = key; self.purchase = purchase; self.updatedAt = updatedAt
        }
    }

    /// The copy of the key an older reader sees: among stored CDs and downloads of it, the CD with the lowest label
    /// number, then any CD, then a download; ties go to the earliest added, then the lowest id.
    public static func primary(_ items: [CollectionItem], albumKey: String) -> CollectionItem? {
        items.filter { isProjectable($0) && $0.albumKey == albumKey }.min(by: primaryFirst)
    }

    static func isProjectable(_ item: CollectionItem) -> Bool {
        item.origin == .stored && (item.medium == .cd || item.medium == .download)
    }

    static func primaryFirst(_ a: CollectionItem, _ b: CollectionItem) -> Bool {
        func rank(_ i: CollectionItem) -> (Int, Int, Int) {
            (i.medium == .cd ? 0 : 1, i.stickerNumber == nil ? 1 : 0, i.stickerNumber ?? 0)
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }

    /// The `album_ownership` row an item projects to.
    static func purchase(of item: CollectionItem) -> AlbumPurchase {
        AlbumPurchase(album: item.album, artist: item.artist, format: item.medium == .download ? .digital : .cd,
                      purchasedOn: item.purchasedOn, price: item.price, labelNumber: item.medium == .cd ? item.stickerNumber : nil)
    }

    /// Takes in rows an older version wrote. A key with no CD or download gets one (the migration: with the id
    /// `legacyID`, so the Mac and a phone reading an older copy agree). A row newer than its key's primary copy was
    /// edited by an older app: its date, price and medium are copied into that copy, and its label number when it has
    /// one. Never deletes: a row gone missing is written again by the next projection. `changed` lists the items
    /// created or changed.
    ///
    /// Two things an older app's row can't say are kept: a label number (versions before 1.18 write none) and a
    /// download (versions before 1.19 write no format; a row turns a download into a CD only with a label number).
    public static func reconcile(items: [CollectionItem], legacy: [Row]) -> (items: [CollectionItem], changed: [CollectionItem]) {
        var items = items
        var changed: [CollectionItem] = []
        var ids = Set(items.map(\.id))
        var index: [String: [Int]] = [:]
        for (i, item) in items.enumerated() where isProjectable(item) { index[item.albumKey, default: []].append(i) }
        for row in legacy.sorted(by: { $0.key < $1.key }) where !row.key.isEmpty {
            if let i = index[row.key]?.min(by: { primaryFirst(items[$0], items[$1]) }) {
                let p = items[i]
                guard row.updatedAt.timeIntervalSince1970 > p.updatedAt.timeIntervalSince1970 + 0.001 else { continue }
                var q = p
                q.purchasedOn = row.purchase.purchasedOn
                q.price = row.purchase.price
                if row.purchase.format == .digital { q.medium = .download }
                else if q.medium == .download, row.purchase.labelNumber != nil { q.medium = .cd }
                if q.medium == .cd, let n = row.purchase.labelNumber { q.stickerNumber = n }
                q.updatedAt = row.updatedAt
                items[i] = q
                changed.append(q)
            } else {
                let p = row.purchase
                var item = newItem(key: row.key, album: p.album, artist: p.artist, medium: p.format == .digital ? .download : .cd,
                                   at: row.updatedAt, ids: &ids)
                item.stickerNumber = p.labelNumber
                item.purchasedOn = p.purchasedOn
                item.price = p.price
                index[row.key, default: []].append(items.count)
                items.append(item)
                changed.append(item)
            }
        }
        return (items, changed)
    }

    /// An item for an album key known only from an older app: `legacyID`, or when that's taken (by a copy of
    /// another medium now), the first free of `legacyID` of "<key>#2", "#3"… The id must not be random: a phone
    /// reconciles in memory on every load, and links to the item (widgets, the watch) need it to stay the same.
    static func newItem(key: String, album: String, artist: String, medium: CollectionMedium, at date: Date,
                        ids: inout Set<String>) -> CollectionItem {
        var id = CollectionItem.legacyID(albumKey: key)
        var n = 1
        while ids.contains(id) {
            n += 1
            id = CollectionItem.legacyID(albumKey: key + "#\(n)")
        }
        ids.insert(id)
        // Clipped as `collection_items` reads it back, so the projection doesn't then blank an older reader's title.
        let album = CollectionItem.clip(album, CollectionItem.maxTitle), artist = CollectionItem.clip(artist, CollectionItem.maxTitle)
        // A row with neither wouldn't read back (and would then stop being projected).
        return CollectionItem(id: id, medium: medium, album: album.isEmpty && artist.isEmpty ? "Unknown Album" : album,
                              artist: artist, albumKey: key, now: date)
    }

    /// What `album_ownership` should hold, by key.
    public static func projection(items: [CollectionItem]) -> [String: Row] {
        var primaries: [String: CollectionItem] = [:]
        for item in items where isProjectable(item) {
            if let p = primaries[item.albumKey], !primaryFirst(item, p) { continue }
            primaries[item.albumKey] = item
        }
        return primaries.mapValues { Row(key: $0.albumKey, purchase: purchase(of: $0), updatedAt: $0.updatedAt) }
    }

    /// The items after ownership changes still waiting in a phone's outbox (made by versions before 1.18), with the
    /// rules the Mac applies them by (`applyLegacyPurchase`). `albumKey` gives an event's album from its track.
    public static func overlay(events: [SyncEvent], on items: [CollectionItem], albumKey: (Int64) -> String?) -> [CollectionItem] {
        var items = items
        for e in events.sorted(by: { $0.at < $1.at }) {
            guard case .purchase(let p) = e.kind, let key = albumKey(e.trackID) else { continue }
            _ = applyLegacyPurchase(p, key: key, album: p?.album ?? "", artist: p?.artist ?? "", at: e.at, to: &items)
        }
        return items
    }

    /// Applies an ownership change from a phone before 1.18 to the key's primary CD or download: skipped when that
    /// copy changed later; a purchase sets its date and price (or adds an unlabeled CD when the key has neither); nil
    /// removes it only when it has no label number (a label is a fact only the Mac records). Medium, label numbers and
    /// records are never touched. True when something changed.
    public static func applyLegacyPurchase(_ purchase: AlbumPurchase?, key: String, album: String, artist: String,
                                           at date: Date, to items: inout [CollectionItem]) -> Bool {
        let index = items.indices.filter { isProjectable(items[$0]) && items[$0].albumKey == key }
            .min { primaryFirst(items[$0], items[$1]) }
        if let i = index, items[i].updatedAt > date { return false }
        switch (purchase, index) {
        case let (p?, i?):
            items[i].purchasedOn = p.purchasedOn
            items[i].price = p.price
            items[i].updatedAt = date
            return true
        case let (p?, nil):
            var ids = Set(items.map(\.id))
            var item = newItem(key: key, album: album, artist: artist, medium: .cd, at: date, ids: &ids)
            item.purchasedOn = p.purchasedOn
            item.price = p.price
            items.append(item)
            return true
        case let (nil, i?):
            guard items[i].stickerNumber == nil else { return false }
            items.remove(at: i)
            return true
        case (nil, nil):
            return false
        }
    }
}
