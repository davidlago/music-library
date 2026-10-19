import Foundation

/// What `Database.collectionItems()` read.
public struct CollectionRead: Sendable {
    public var items: [CollectionItem]
    /// Rows that didn't validate (written by a newer version, or damaged): "update the app".
    public var unreadable: Int
    /// False for a copy from a version before the collection: the items were made from `album_ownership`.
    public var hadTable: Bool

    public init(items: [CollectionItem], unreadable: Int, hadTable: Bool) {
        self.items = items; self.unreadable = unreadable; self.hadTable = hadTable
    }
}

extension Database {
    static let collectionColumns = [
        "id", "medium", "sticker", "album", "artist", "album_key", "year", "mb_release_id", "mb_release_group_id",
        "barcode", "catalog_number", "record_label", "country", "format_detail", "disc_count", "track_count",
        "purchased_on", "price", "notes", "cover_file", "digital_source", "created_at", "updated_at",
    ]

    /// The collection, created on open without a schema change (like `rip_checks`): phones on older versions read
    /// synced copies without it, and see `album_ownership`, which the Mac keeps as a projection of it. No UNIQUE index
    /// on labels: existing data may already repeat a number.
    func createCollectionTable() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS collection_items(
            id TEXT PRIMARY KEY, medium TEXT NOT NULL, sticker INTEGER, album TEXT NOT NULL, artist TEXT NOT NULL,
            album_key TEXT NOT NULL, year INTEGER, mb_release_id TEXT, mb_release_group_id TEXT, barcode TEXT,
            catalog_number TEXT, record_label TEXT, country TEXT, format_detail TEXT, disc_count INTEGER,
            track_count INTEGER, purchased_on TEXT, price TEXT, notes TEXT, cover_file TEXT, digital_source TEXT,
            created_at REAL NOT NULL, updated_at REAL NOT NULL)
        """)
        try exec("CREATE INDEX IF NOT EXISTS collection_items_album ON collection_items(album_key)")
        try exec("CREATE INDEX IF NOT EXISTS collection_items_sticker ON collection_items(medium, sticker)")
        try exec("CREATE INDEX IF NOT EXISTS collection_items_release ON collection_items(mb_release_id)")
    }

    /// Takes in what older versions wrote to `album_ownership` (the first time, the migration), then makes it match
    /// the collection again. Running it twice changes nothing.
    func reconcileLegacyOwnership() throws {
        try transaction {
            let current = try collectionItems().items
            let (_, changed) = CollectionLegacy.reconcile(items: current, legacy: try legacyOwnershipRows())
            for item in changed { try writeCollectionItem(item) }
            try projectLegacyOwnership(keys: nil)
        }
    }

    /// Every item. Rows are untrusted (the file may come from elsewhere): values that don't validate read as unknown,
    /// and rows without a usable id, medium or title are left out and counted. Columns added later read as unknown
    /// when missing. A copy from a version before the collection has its items made from `album_ownership`, with the
    /// same ids the Mac's migration gives them.
    public func collectionItems() throws -> CollectionRead {
        let present = try columns(of: "collection_items")
        guard !present.isEmpty else {
            return CollectionRead(items: CollectionLegacy.reconcile(items: [], legacy: try legacyOwnershipRows()).items,
                                  unreadable: 0, hadTable: false)
        }
        let select = Self.collectionColumns.map { present.contains($0) ? $0 : "NULL" }.joined(separator: ",")
        let rows = try query("SELECT \(select) FROM collection_items ORDER BY created_at, id", map: Self.collectionItem)
        return CollectionRead(items: rows.compactMap { $0 }, unreadable: rows.filter { $0 == nil }.count, hadTable: true)
    }

    private static func collectionItem(_ r: Row) -> CollectionItem? {
        func text(_ i: Int32, max: Int) -> String? {
            guard let s = r.string(i)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= max else { return nil }
            return s
        }
        func int(_ i: Int32, _ range: ClosedRange<Int>) -> Int? { r.int(i).flatMap { range.contains($0) ? $0 : nil } }
        func date(_ i: Int32) -> Date {
            let t = r.double(i)
            return Date(timeIntervalSince1970: t.isFinite ? t : 0)
        }

        guard let id = r.string(0)?.lowercased(), CollectionItem.isValidID(id),
              let medium = r.string(1).flatMap(CollectionMedium.init(rawValue:)) else { return nil }
        let album = text(3, max: CollectionItem.maxTitle) ?? "", artist = text(4, max: CollectionItem.maxTitle) ?? ""
        guard !album.isEmpty || !artist.isEmpty else { return nil }
        let key = r.string(5).flatMap { $0.isEmpty ? nil : $0 } ?? SearchIndex.albumKey(album: album, artist: artist)
        var item = CollectionItem(id: id, medium: medium, album: album, artist: artist, albumKey: key, now: date(21))
        item.stickerNumber = r.int(2)
        item.year = int(6, 1000...9999)
        item.releaseID = MBID.validated(r.string(7))
        item.releaseGroupID = MBID.validated(r.string(8))
        item.barcode = r.string(9).flatMap { (6...20).contains($0.count) && $0.allSatisfy { ("0"..."9").contains($0) } ? $0 : nil }
        item.catalogNumber = text(10, max: CollectionItem.maxField)
        item.recordLabel = text(11, max: CollectionItem.maxField)
        item.country = text(12, max: CollectionItem.maxField)
        item.formatDetail = text(13, max: CollectionItem.maxField)
        item.discCount = int(14, 1...99)
        item.trackCount = int(15, 1...999)
        item.purchasedOn = r.string(16).flatMap(PurchaseDay.init(string:))
        item.price = AlbumPurchase.price(text: r.string(17))
        item.notes = text(18, max: CollectionItem.maxNotes)
        item.coverFile = r.string(19).flatMap { CollectionCovers.isFileName($0) ? $0 : nil }
        item.digitalSource = r.string(20).flatMap(DigitalSource.init(rawValue:))
        item.updatedAt = date(22)
        return item
    }

    /// Every `album_ownership` row (none in a copy from before it). Dates, prices and label numbers that don't parse
    /// read as unknown and a format that doesn't as a CD, as older readers do.
    public func legacyOwnershipRows() throws -> [CollectionLegacy.Row] {
        let present = try columns(of: "album_ownership")
        guard !present.isEmpty else { return [] }
        let label = present.contains("label_number") ? "label_number" : "NULL"
        let format = present.contains("format") ? "format" : "NULL"
        return try query("SELECT key, album, artist, purchased_on, price, \(label), \(format), updated_at FROM album_ownership ORDER BY key") { r in
            let updated = r.double(7)
            return CollectionLegacy.Row(
                key: r.string(0) ?? "",
                purchase: AlbumPurchase(album: r.string(1) ?? "", artist: r.string(2) ?? "",
                                        format: r.string(6).flatMap(AlbumPurchase.Format.init(rawValue:)) ?? .cd,
                                        purchasedOn: r.string(3).flatMap(PurchaseDay.init(string:)),
                                        price: AlbumPurchase.price(text: r.string(4)), labelNumber: r.int(5)),
                updatedAt: Date(timeIntervalSince1970: updated.isFinite ? updated : 0))
        }.filter { !$0.key.isEmpty }
    }

    /// Saves an item (added or changed), then brings `album_ownership` up to date for its old and new album keys.
    /// Derived downloads and items of media added by a newer version can't be saved (`CollectionError.readOnly`).
    /// Duplicate labels are refused by the editor, not here, so items already sharing a number stay saveable.
    public func saveCollectionItem(_ item: CollectionItem, at date: Date = Date()) throws {
        try saveCollectionItems([item], at: date)
    }

    /// Saves several items in one transaction. Text is saved as it reads back (`CollectionItem.normalized`), and an
    /// item left with neither an album nor an artist is refused (`CollectionError.invalidItem`).
    public func saveCollectionItems(_ items: [CollectionItem], at date: Date = Date()) throws {
        let items = items.map { $0.normalized() }
        for item in items {
            guard item.isEditable else { throw CollectionError.readOnly }
            guard CollectionItem.isValidID(item.id), !item.album.isEmpty || !item.artist.isEmpty else { throw CollectionError.invalidItem }
        }
        try transaction {
            var keys = Set<String>()
            for var item in items {
                keys.formUnion(try collectionKeys(id: item.id))
                keys.insert(item.albumKey)
                item.updatedAt = date
                try writeCollectionItem(item)
            }
            try projectLegacyOwnership(keys: keys)
        }
    }

    /// Removes an item (never its tracks), then updates `album_ownership` for its album key.
    public func deleteCollectionItem(id: String) throws {
        try transaction {
            let keys = try collectionKeys(id: id)
            try exec("DELETE FROM collection_items WHERE id=?", [.text(id)])
            try projectLegacyOwnership(keys: keys)
        }
    }

    /// Applies `CollectionLinker` changes to the stored items they name. They aren't edits: `updatedAt` stays the
    /// time of the last one, which changes made by older apps are compared with (`CollectionLegacy`), so `date` is
    /// unused.
    public func applyCollectionChanges(_ changes: [CollectionLinker.Change], at date: Date = Date()) throws {
        guard !changes.isEmpty else { return }
        try transaction {
            let items = Dictionary(try collectionItems().items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var keys = Set<String>()
            for change in changes {
                guard let item = items[change.id], item.isEditable else { continue }
                let changed = change.applied(to: item)
                guard changed != item else { continue }
                keys.formUnion([item.albumKey, changed.albumKey])
                try writeCollectionItem(changed)
            }
            try projectLegacyOwnership(keys: keys)
        }
    }

    /// Moves the items linked to an album whose album or album artist tags changed to its new key. Like the linker's
    /// changes, not an edit: `updatedAt` is kept, so `date` is unused.
    public func rekeyCollection(from oldKey: String, to newKey: String, at date: Date = Date()) throws {
        guard oldKey != newKey else { return }
        try transaction {
            let media = CollectionMedium.known.map { "'\($0.rawValue)'" }.joined(separator: ",")
            try exec("UPDATE collection_items SET album_key=? WHERE album_key=? AND medium IN (\(media))",
                     [.text(newKey), .text(oldKey)])
            try projectLegacyOwnership(keys: [oldKey, newKey])
        }
    }

    /// Makes `album_ownership` match the projection (`CollectionLegacy.projection`) for `keys`, or every key with nil:
    /// writes rows that are missing or differ, and deletes the rows of keys with no CD or download left.
    public func projectLegacyOwnership(keys: Set<String>?) throws {
        try transaction {
            let projection = CollectionLegacy.projection(items: try collectionItems().items)
            struct Stored: Equatable {
                var album: String?
                var artist: String?
                var format: String?
                var purchasedOn: String?
                var price: String?
                var label: Int?
                var updatedAt: Double
            }
            var stored: [String: Stored] = [:]
            try query("SELECT key, album, artist, format, purchased_on, price, label_number, updated_at FROM album_ownership") { r in
                (r.string(0) ?? "", Stored(album: r.string(1), artist: r.string(2), format: r.string(3), purchasedOn: r.string(4),
                                           price: r.string(5), label: r.int(6), updatedAt: r.double(7)))
            }.forEach { stored[$0.0] = $0.1 }
            for key in (keys ?? Set(stored.keys).union(projection.keys)).sorted() {
                guard let row = projection[key] else {
                    if stored[key] != nil { try exec("DELETE FROM album_ownership WHERE key=?", [.text(key)]) }
                    continue
                }
                let p = row.purchase
                let wanted = Stored(album: p.album, artist: p.artist, format: p.format == .cd ? nil : p.format.rawValue,
                                    purchasedOn: p.purchasedOn?.string, price: AlbumPurchase.priceText(p.price),
                                    label: p.labelNumber, updatedAt: row.updatedAt.timeIntervalSince1970)
                guard stored[key] != wanted else { continue }
                try exec("INSERT OR REPLACE INTO album_ownership(key,album,artist,format,purchased_on,price,label_number,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                         [.text(key), .text(p.album), .text(p.artist), .text(wanted.format), .text(wanted.purchasedOn),
                          .text(wanted.price), .int(p.labelNumber), .double(wanted.updatedAt)])
            }
        }
    }

    /// The paths of the items' own covers ("Music/Collection Covers/…"), valid names only.
    public func collectionCoverPaths() throws -> [String] {
        guard try !columns(of: "collection_items").isEmpty else { return [] }
        let files = try query("SELECT DISTINCT cover_file FROM collection_items WHERE cover_file IS NOT NULL") { $0.string(0) }
        return Set(files.compactMap { $0.flatMap(CollectionCovers.path) }).sorted()
    }

    /// Saves (or with nil, forgets) that you own the album with this key (`SearchIndex.albumKey`): sets the album's
    /// primary CD or download (adding one when it has neither), or removes its CDs and downloads; records are kept.
    /// Deprecated: for the app's ownership views until they move to `saveCollectionItem`; removed in the cleanup.
    public func saveAlbumPurchase(key: String, _ purchase: AlbumPurchase?, at date: Date = Date()) throws {
        try transaction {
            var items = try collectionItems().items.filter { CollectionLegacy.isProjectable($0) && $0.albumKey == key }
            if let p = purchase {
                var ids = Set(try query("SELECT id FROM collection_items") { $0.string(0) ?? "" })
                let medium: CollectionMedium = p.format == .digital ? .download : .cd
                var item = items.min(by: CollectionLegacy.primaryFirst)
                    ?? CollectionLegacy.newItem(key: key, album: p.album, artist: p.artist, medium: medium, at: date, ids: &ids)
                let album = CollectionItem.clip(p.album, CollectionItem.maxTitle), artist = CollectionItem.clip(p.artist, CollectionItem.maxTitle)
                if !album.isEmpty || !artist.isEmpty { item.album = album; item.artist = artist }
                item.medium = medium
                item.stickerNumber = p.labelNumber
                item.purchasedOn = p.purchasedOn
                item.price = p.price
                item.updatedAt = date
                try writeCollectionItem(item)
                items = []
            }
            for item in items { try exec("DELETE FROM collection_items WHERE id=?", [.text(item.id)]) }
            try projectLegacyOwnership(keys: [key])
        }
    }

    /// The album keys the stored item with this id has now (none when it isn't stored).
    private func collectionKeys(id: String) throws -> Set<String> {
        Set(try query("SELECT album_key FROM collection_items WHERE id=?", [.text(id)]) { $0.string(0) ?? "" })
    }

    /// Writes an item as it reads back (`normalized`; an upsert that keeps columns a newer version added), without
    /// the projection. Callers make sure it has an album or an artist.
    func writeCollectionItem(_ item: CollectionItem) throws {
        let item = item.normalized()
        let columns = Self.collectionColumns
        let updates = columns.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        try exec("""
        INSERT INTO collection_items(\(columns.joined(separator: ","))) VALUES(\(columns.map { _ in "?" }.joined(separator: ",")))
        ON CONFLICT(id) DO UPDATE SET \(updates)
        """, [
            .text(item.id), .text(item.medium.rawValue), .int(item.sticker?.number), .text(item.album), .text(item.artist),
            .text(item.albumKey), .int(item.year), .text(item.releaseID), .text(item.releaseGroupID), .text(item.barcode),
            .text(item.catalogNumber), .text(item.recordLabel), .text(item.country), .text(item.formatDetail),
            .int(item.discCount), .int(item.trackCount), .text(item.purchasedOn?.string), .text(AlbumPurchase.priceText(item.price)),
            .text(item.notes), .text(item.coverFile), .text(item.digitalSource?.rawValue),
            .double(item.createdAt.timeIntervalSince1970), .double(item.updatedAt.timeIntervalSince1970),
        ])
    }

    /// Applies an ownership change from a phone before 1.18 (`CollectionLegacy.applyLegacyPurchase`) and projects
    /// the key. True when something changed.
    func applyLegacyPurchase(_ purchase: AlbumPurchase?, track: Track, at date: Date) throws -> Bool {
        let key = SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist)
        let before = try collectionItems().items
        var after = before
        guard CollectionLegacy.applyLegacyPurchase(purchase, key: key, album: track.album, artist: track.effectiveAlbumArtist,
                                                   at: date, to: &after) else { return false }
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = Set(after.map(\.id))
        for item in before where !kept.contains(item.id) { try exec("DELETE FROM collection_items WHERE id=?", [.text(item.id)]) }
        for item in after where old[item.id] != item { try writeCollectionItem(item) }
        try projectLegacyOwnership(keys: [key])
        return true
    }
}
