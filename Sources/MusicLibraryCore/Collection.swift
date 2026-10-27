import Foundation

// MARK: Media and labels

/// What a collection item is: a CD, a record, or an album bought as a download. Values written by a newer version
/// read as `.other` (shown with a generic glyph, read-only here, never projected into `album_ownership`).
public enum CollectionMedium: Hashable, Sendable, Comparable {
    case cd, vinyl, download
    /// Written by a newer version: read-only here.
    case other(String)

    /// Trimmed and lowercased; "cd", "vinyl" and "download", else any other `[a-z0-9-]{1,24}` as `.other`. Nil for
    /// anything else (the row comes from a database made elsewhere).
    public init?(rawValue: String) {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "cd": self = .cd
        case "vinyl": self = .vinyl
        case "download": self = .download
        default:
            guard (1...24).contains(raw.count), raw.unicodeScalars.allSatisfy(Self.isRawScalar) else { return nil }
            self = .other(raw)
        }
    }

    /// The medium of a MusicBrainz release from its media formats: any record ("Vinyl", "12\" Vinyl", "7\"") makes it
    /// vinyl, else any audio CD format a CD, else "Digital Media" a download. Nil when none of them is known.
    public init?(musicBrainzFormats formats: [String]) {
        let names = formats.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if names.contains(where: { $0.contains("vinyl") || ["12\"", "10\"", "7\""].contains(where: $0.hasPrefix) }) {
            self = .vinyl
        } else if names.contains(where: Self.cdFormats.contains) {
            self = .cd
        } else if names.contains("digital media") {
            self = .download
        } else {
            return nil
        }
    }

    static let cdFormats: Set<String> = [
        "cd", "sacd", "hybrid sacd", "hdcd", "shm-cd", "blu-spec cd", "blu-spec cd2", "enhanced cd", "cd-r",
        "copy control cd", "8cm cd", "hqcd",
    ]

    static func isRawScalar(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("0"..."9").contains(s) || s == "-"
    }

    public var rawValue: String {
        switch self {
        case .cd: "cd"
        case .vinyl: "vinyl"
        case .download: "download"
        case .other(let raw): raw
        }
    }

    public var isPhysical: Bool { self != .download }

    /// The label series of the medium: CDs and records are numbered apart; downloads aren't numbered.
    public var series: StickerSeries? {
        switch self {
        case .cd: .cd
        case .vinyl: .vinyl
        case .download, .other: nil
        }
    }

    public var name: String {
        switch self {
        case .cd: "CD"
        case .vinyl: "Vinyl"
        case .download: "Download"
        case .other: "Other"
        }
    }

    /// The media this version can add and edit.
    public static let known: [CollectionMedium] = [.cd, .vinyl, .download]

    /// The order copies are listed in: CDs, records, other media, downloads.
    var rank: Int {
        switch self {
        case .cd: 0
        case .vinyl: 1
        case .other: 2
        case .download: 3
        }
    }

    public static func < (a: CollectionMedium, b: CollectionMedium) -> Bool {
        a.rank != b.rank ? a.rank < b.rank : a.rawValue < b.rawValue
    }
}

/// A numbering of label stickers. CDs and records each have their own, both starting at 1: CD #12 and Vinyl #12 are
/// different items.
public enum StickerSeries: String, CaseIterable, Hashable, Comparable, Sendable {
    case cd, vinyl

    public var name: String {
        switch self {
        case .cd: "CD"
        case .vinyl: "Vinyl"
        }
    }

    public var medium: CollectionMedium {
        switch self {
        case .cd: .cd
        case .vinyl: .vinyl
        }
    }

    public static func < (a: StickerSeries, b: StickerSeries) -> Bool {
        (allCases.firstIndex(of: a) ?? 0) < (allCases.firstIndex(of: b) ?? 0)
    }
}

/// A label number on a physical item. Never shown without its series.
public struct Sticker: Hashable, Comparable, Sendable {
    public var series: StickerSeries
    public var number: Int

    public static let maxNumber = AlbumPurchase.maxLabelNumber

    public init?(series: StickerSeries, number: Int) {
        guard (1...Self.maxNumber).contains(number) else { return nil }
        self.series = series; self.number = number
    }

    /// "CD #12", "Vinyl #12".
    public var text: String { "\(series.name) #\(number)" }
    /// For VoiceOver: "CD label 12".
    public var spoken: String { "\(series.name) label \(number)" }
    /// The search token for exactly this label: "sticker:cd12".
    public var token: String { "sticker:\(series.rawValue)\(number)" }

    /// "12", "#12" → (nil, 12); "cd12", "cd 12", "CD #12", "cd#12" → (.cd, 12);
    /// "vinyl 12", "vinyl#12", "v12", "lp12", "lp #12", "record 12" → (.vinyl, 12). Anything else → nil.
    public static func parse(_ text: String) -> (series: StickerSeries?, number: Int)? {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        var series: StickerSeries?
        // Longest first, so "vinyl" isn't read as "v" + "inyl".
        for (prefix, value) in [("vinyl", StickerSeries.vinyl), ("record", .vinyl), ("lp", .vinyl), ("cd", .cd), ("v", .vinyl)]
        where s.hasPrefix(prefix) {
            series = value
            s = s.dropFirst(prefix.count)
            break
        }
        s = s.drop(while: { $0 == " " })
        if s.hasPrefix("#") { s = s.dropFirst().drop(while: { $0 == " " }) }
        guard (1...7).contains(s.count), s.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(s),
              (1...maxNumber).contains(n) else { return nil }
        return (series, n)
    }

    /// The number in a number field's text, from its decimal digits in any script (a number pad set to Arabic-Indic
    /// numerals types "١٢", which `Int(String)` can't read), the first 7 of them; nil without any. Other characters are
    /// left out.
    public static func typedNumber(_ text: String) -> Int? {
        let digits = text.compactMap(\.wholeNumberValue).filter { (0...9).contains($0) }.prefix(7)
        guard !digits.isEmpty else { return nil }
        return digits.reduce(0) { $0 * 10 + $1 }
    }

    public static func < (a: Sticker, b: Sticker) -> Bool { (a.series, a.number) < (b.series, b.number) }
}

/// Where an item's digital copy in the library came from.
public enum DigitalSource: String, CaseIterable, Sendable {
    /// Made from this copy (a CD rip, a vinyl needle-drop).
    case rip
    /// This purchase is, or came with, the files.
    case download
    /// The same music is in the library, from elsewhere (e.g. the CD of the record you own).
    case same
}

public enum CollectionError: Error, LocalizedError {
    /// A derived download or an item added by a newer version.
    case readOnly
    /// An id or text that wouldn't read back.
    case invalidItem
    /// A cover file name or location that isn't allowed.
    case invalidCover

    public var errorDescription: String? {
        switch self {
        case .readOnly: "This item can't be changed here."
        case .invalidItem: "This item can't be saved."
        case .invalidCover: "The cover couldn't be saved in the library folder."
        }
    }
}

// MARK: Items

/// One thing you own: a CD or record (ripped or not, with or without tracks in the library) or an album download.
/// Saved in `collection_items`, apart from the tracks; `albumKey` (`SearchIndex.albumKey`) links it to its digital
/// copy, which is always derived from the library, never stored.
public struct CollectionItem: Identifiable, Hashable, Sendable {
    /// `songs`: a download derived from songs bought on their own (`TrackPurchase`); never stored.
    public enum Origin: Hashable, Sendable { case stored, songs }

    public var id: String
    /// Changing to a medium of another series (or none) clears `stickerNumber`.
    public var medium: CollectionMedium {
        didSet { if medium.series != oldValue.series { stickerNumber = nil } }
    }
    /// Only for a medium with a series, 1…`Sticker.maxNumber`; anything else reads as nil.
    public var stickerNumber: Int? {
        didSet { if let n = stickerNumber, medium.series == nil || !(1...Sticker.maxNumber).contains(n) { stickerNumber = nil } }
    }
    public var album: String
    public var artist: String
    public var albumKey: String
    public var year: Int?
    public var releaseID: String?
    public var releaseGroupID: String?
    /// The Discogs release, for a copy found there (MusicBrainz didn't list it): its track list is read from it.
    public var discogsReleaseID: Int?
    public var barcode: String?
    public var catalogNumber: String?
    public var recordLabel: String?
    public var country: String?
    /// MusicBrainz media text: "CD", "2×CD", "12\" Vinyl".
    public var formatDetail: String?
    public var discCount: Int?
    /// Tracks on the release, for "partly ripped".
    public var trackCount: Int?
    public var purchasedOn: PurchaseDay?
    /// In the user's currency. Never negative.
    public var price: Decimal? {
        didSet { if let p = price, AlbumPurchase.validPrice(p) == nil { price = nil } }
    }
    public var notes: String?
    /// A file in `CollectionCovers.folder`; nil shows the linked album's cover.jpg.
    public var coverFile: String?
    /// Nil: never linked.
    public var digitalSource: DigitalSource?
    public var createdAt: Date
    public var updatedAt: Date
    public var origin: Origin

    public var sticker: Sticker? {
        guard let series = medium.series, let n = stickerNumber else { return nil }
        return Sticker(series: series, number: n)
    }

    /// Stored items of a medium this version knows can be edited (on the Mac).
    public var isEditable: Bool { origin == .stored && CollectionMedium.known.contains(medium) }

    public init(id: String = CollectionItem.newID(), medium: CollectionMedium, album: String, artist: String,
                albumKey: String? = nil, now: Date = Date()) {
        self.id = id
        self.medium = medium
        self.album = album
        self.artist = artist
        self.albumKey = albumKey ?? SearchIndex.albumKey(album: album, artist: artist)
        createdAt = now
        updatedAt = now
        origin = .stored
    }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// The id of an item migrated from `album_ownership`, the same on the Mac and on a phone reading an older copy.
    public static func legacyID(albumKey: String) -> String { "own-" + fnv1a64Hex(albumKey) }

    /// Every item has an album or an artist, except one made from an older app's row for an album with neither tag
    /// (a legacy id): it keeps the row's empty title rather than one made up for it.
    static func isNamed(album: String, artist: String, id: String) -> Bool {
        !album.isEmpty || !artist.isEmpty || id.hasPrefix("own-")
    }

    /// The id of a download derived from bought songs.
    public static func songsID(albumKey: String) -> String { "songs-" + fnv1a64Hex(albumKey) }

    static func fnv1a64Hex(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// 1–64 characters from `[a-z0-9-]`.
    public static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.unicodeScalars.allSatisfy(CollectionMedium.isRawScalar)
    }

    /// The longest album or artist, record label (and the other release fields) and notes `collection_items` reads.
    static let maxTitle = 1000, maxField = 200, maxNotes = 10_000

    /// The item as `collection_items` reads it back: text trimmed and clipped to the lengths read (empty fields nil),
    /// and values out of range dropped. Saving goes through it, so nothing written reads back blank or unreadable.
    func normalized() -> CollectionItem {
        func field(_ s: String?, _ limit: Int) -> String? { s.map { Self.clip($0, limit) }.flatMap { $0.isEmpty ? nil : $0 } }
        var item = self
        item.album = Self.clip(album, Self.maxTitle)
        item.artist = Self.clip(artist, Self.maxTitle)
        if item.albumKey.isEmpty { item.albumKey = SearchIndex.albumKey(album: item.album, artist: item.artist) }
        item.year = year.flatMap { (1000...9999).contains($0) ? $0 : nil }
        item.releaseID = MBID.validated(releaseID)
        item.releaseGroupID = MBID.validated(releaseGroupID)
        item.discogsReleaseID = DiscogsLink.isValid(discogsReleaseID) ? discogsReleaseID : nil
        item.barcode = barcode.flatMap { (6...20).contains($0.count) && $0.allSatisfy { ("0"..."9").contains($0) } ? $0 : nil }
        item.catalogNumber = field(catalogNumber, Self.maxField)
        item.recordLabel = field(recordLabel, Self.maxField)
        item.country = field(country, Self.maxField)
        item.formatDetail = field(formatDetail, Self.maxField)
        item.discCount = discCount.flatMap { (1...99).contains($0) ? $0 : nil }
        item.trackCount = trackCount.flatMap { (1...999).contains($0) ? $0 : nil }
        item.notes = field(notes, Self.maxNotes)
        item.coverFile = coverFile.flatMap { CollectionCovers.isFileName($0) ? $0 : nil }
        return item
    }

    /// Trimmed and at most `limit` characters (trimmed again, so it reads back the same).
    static func clip(_ s: String, _ limit: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= limit ? t : String(t.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The source to go by: the stored one, or for a CD or download never linked, the files being its own.
    var effectiveSource: DigitalSource? {
        digitalSource ?? (medium == .cd ? .rip : medium == .download ? .download : nil)
    }
}

/// What an item's digital copy is, derived from the library each time.
public enum DigitalState: Hashable, Sendable {
    /// Never linked, no tracks under its album key.
    case none
    /// Tracks present, from this copy (or a CD or download never linked).
    case digitized(tracks: Int)
    /// Digitized, but fewer tracks than the release has.
    case partial(have: Int, of: Int)
    /// The music is in the library from elsewhere; `from` is the id of a copy of the album it came from.
    case otherCopy(tracks: Int, from: String?)
    /// Was linked, but the album key has no tracks now.
    case missing

    public var hasMusic: Bool {
        switch self {
        case .digitized, .partial, .otherCopy: true
        case .none, .missing: false
        }
    }

    /// Callers check `isPhysical`: a download with no tracks isn't waiting for anything.
    public var needsDigitizing: Bool {
        switch self {
        case .none, .missing: true
        case .digitized, .partial, .otherCopy: false
        }
    }
}

/// How a cover shows what you own.
public enum CopyMark: Hashable, Sendable {
    /// The "Borrowed" badge.
    case notInCollection
    case cd(number: Int?, digitized: Bool, more: Int)
    case vinyl(number: Int?, digitized: Bool, more: Int)
    case download(partial: Bool, more: Int)
    case other(more: Int)

    public var sticker: Sticker? {
        switch self {
        case .cd(let n?, _, _): Sticker(series: .cd, number: n)
        case .vinyl(let n?, _, _): Sticker(series: .vinyl, number: n)
        default: nil
        }
    }
}

/// The views of the collection: the Shelf (the whole physical collection: CDs, records and media a newer version
/// added), one medium, or the physical items without a digital copy. Downloads are their own view, shown with the
/// digital collection. The raw values are stored (sidebar selections), so `.all` keeps its name.
public enum CollectionScope: String, CaseIterable, Hashable, Sendable {
    case all, cds, vinyl, downloads, toDigitize

    public var title: String {
        switch self {
        case .all: "Shelf"
        case .cds: "CDs"
        case .vinyl: "Vinyl"
        case .downloads: "Downloads"
        case .toDigitize: "To Digitize"
        }
    }

    /// The same items in the collection query language.
    public var query: String {
        switch self {
        case .all: "own:physical"
        case .cds: "own:cd"
        case .vinyl: "own:vinyl"
        case .downloads: "own:download"
        case .toDigitize: "own:physical ripped:no"
        }
    }

    func contains(_ item: CollectionItem, state: DigitalState) -> Bool {
        switch self {
        case .all: item.medium.isPhysical
        case .cds: item.medium == .cd
        case .vinyl: item.medium == .vinyl
        case .downloads: item.medium == .download
        case .toDigitize: item.medium.isPhysical && state.needsDigitizing
        }
    }
}

public struct CollectionItemRoute: Hashable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

/// Which digitized items of the collection go to a phone on top of its selection. A Mac setting per phone, never sent.
public enum CollectionSyncScope: String, CaseIterable, Codable, Sendable {
    case off, cds, vinyl, all

    public var title: String {
        switch self {
        case .off: "Off"
        case .cds: "Digitized CDs"
        case .vinyl: "Digitized vinyl"
        case .all: "Everything I own that's digitized"
        }
    }
}

// MARK: Collection

/// Every item plus the lookups the UI needs. Immutable; built off the main thread on each library reload (Mac) and in
/// `LibrarySnapshot` (phone).
public struct MusicCollection: Sendable {
    public static let empty = MusicCollection(items: [], songPurchases: [:], tracks: [])

    /// Stored items plus downloads derived from bought songs, in `CollectionSort.sticker` order.
    public let items: [CollectionItem]
    /// Rows dropped on read ("update the app").
    public let unreadable: Int

    private let byID: [String: CollectionItem]
    private let byKey: [String: [CollectionItem]]
    private let bySticker: [Sticker: [CollectionItem]]
    private let tracksByKey: [String: [Track]]
    /// For a derived download, how many of the album's songs were bought.
    private let songsBought: [String: Int]

    public init(items stored: [CollectionItem], songPurchases: [Int64: TrackPurchase], tracks: [Track], unreadable: Int = 0) {
        var tracksByKey: [String: [Track]] = [:]
        for t in tracks { tracksByKey[SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist), default: []].append(t) }
        for (k, list) in tracksByKey { tracksByKey[k] = list.sorted(by: LibrarySnapshot.albumOrder) }

        // Songs bought on their own make a download of their album, unless an album download is already stored.
        var derived: [String: CollectionItem] = [:]
        var bought: [String: Int] = [:]
        let storedDownloads = Set(stored.filter { $0.medium == .download }.map(\.albumKey))
        if !songPurchases.isEmpty {
            for t in tracks {
                guard let song = songPurchases[t.id] else { continue }
                let key = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
                guard !storedDownloads.contains(key) else { continue }
                var item = derived[key] ?? {
                    let albumTracks = tracksByKey[key] ?? []
                    var d = CollectionItem(id: CollectionItem.songsID(albumKey: key), medium: .download, album: t.album,
                                           artist: t.effectiveAlbumArtist, albumKey: key, now: t.addedAt)
                    d.origin = .songs
                    d.digitalSource = .download
                    d.year = albumTracks.compactMap(\.year).filter { $0 > 0 }.max()
                    d.releaseID = albumTracks.lazy.compactMap(\.metadata.mbReleaseId).first
                    // The release's length when the tags say (one disc), so a few songs of it read as partial.
                    let total = albumTracks.allSatisfy { ($0.metadata.discTotal ?? 1) <= 1 && ($0.metadata.discNo ?? 1) <= 1 }
                        ? albumTracks.compactMap(\.metadata.trackTotal).filter { (1...999).contains($0) }.max() ?? 0 : 0
                    d.trackCount = max(albumTracks.count, total)
                    return d
                }()
                if let price = song.price { item.price = (item.price ?? 0) + price }
                if let day = song.purchasedOn { item.purchasedOn = min(item.purchasedOn ?? day, day) }
                item.createdAt = min(item.createdAt, t.addedAt)
                item.updatedAt = item.createdAt
                derived[key] = item
                bought[key, default: 0] += 1
            }
        }

        let all = CollectionSort.sticker.sorted(stored + derived.values.sorted { $0.albumKey < $1.albumKey })
        items = all
        self.unreadable = unreadable
        self.tracksByKey = tracksByKey
        songsBought = bought
        byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        byKey = Dictionary(grouping: all, by: \.albumKey).mapValues { $0.sorted(by: Self.precedes) }
        var stickers: [Sticker: [CollectionItem]] = [:]
        for item in all { if let s = item.sticker { stickers[s, default: []].append(item) } }
        bySticker = stickers
    }

    /// The order copies of one album are listed in, which is also which one marks the album: the labeled CD with the
    /// lowest number, any CD, a labeled record, any record, other media, a stored download, a derived download.
    static func precedes(_ a: CollectionItem, _ b: CollectionItem) -> Bool {
        func rank(_ i: CollectionItem) -> (Int, Int, Int) {
            let origin = i.origin == .songs ? 1 : 0
            return (i.medium.rank * 2 + origin, i.stickerNumber == nil ? 1 : 0, i.stickerNumber ?? 0)
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }

    public func item(id: String) -> CollectionItem? { byID[id] }

    /// CDs (by number), records, other media, downloads, then a derived download.
    public func copies(albumKey: String) -> [CollectionItem] { byKey[albumKey] ?? [] }

    public func items(artist: String) -> [CollectionItem] {
        items.filter { $0.artist.caseInsensitiveCompare(artist) == .orderedSame }
    }

    /// More than one is a duplicate label.
    public func items(at sticker: Sticker) -> [CollectionItem] { bySticker[sticker] ?? [] }

    /// The items with this number in either series, CDs first.
    public func items(number: Int) -> [CollectionItem] {
        StickerSeries.allCases.flatMap { s in Sticker(series: s, number: number).map(items(at:)) ?? [] }
    }

    /// The labeled items just before and after the number on the shelf, whether or not the number is used.
    public func neighbors(of sticker: Sticker) -> (previous: CollectionItem?, next: CollectionItem?) {
        var previous: CollectionItem?, next: CollectionItem?
        for item in items {
            guard let s = item.sticker, s.series == sticker.series else { continue }
            if sticker.number > s.number, s.number > (previous?.stickerNumber ?? 0) { previous = item }
            if s.number > sticker.number, (next?.stickerNumber ?? Int.max) > s.number { next = item }
        }
        return (previous, next)
    }

    public func digitalState(_ item: CollectionItem) -> DigitalState {
        let n = item.origin == .songs ? songsBought[item.albumKey] ?? 0 : tracksByKey[item.albumKey]?.count ?? 0
        guard n > 0 else { return item.digitalSource == nil ? .none : .missing }
        switch item.effectiveSource {
        case .rip, .download:
            if let total = item.trackCount, total > n { return .partial(have: n, of: total) }
            return .digitized(tracks: n)
        case .same, nil:
            let from = copies(albumKey: item.albumKey).first {
                $0.id != item.id && ($0.effectiveSource == .rip || $0.effectiveSource == .download)
            }
            return .otherCopy(tracks: n, from: from?.id)
        }
    }

    /// The library tracks under the item's album key, in album order.
    public func libraryTracks(_ item: CollectionItem) -> [Track] { tracksByKey[item.albumKey] ?? [] }

    /// One past the highest number in the series (counting `pending` ones not saved yet), or 1 for the first. Once
    /// the highest is `Sticker.maxNumber`, the lowest free number instead; with none free (never in practice), the
    /// maximum, which is taken: check `taken` before using it.
    public func nextNumber(in series: StickerSeries, pending: [Int] = []) -> Int {
        let used = Set(numbers(in: series) + pending.filter { (1...Sticker.maxNumber).contains($0) })
        let highest = used.max() ?? 0
        guard highest >= Sticker.maxNumber else { return highest + 1 }
        var n = 1
        while used.contains(n), n < Sticker.maxNumber { n += 1 }
        return n
    }

    /// The lowest unused number below the highest one.
    public func firstGap(in series: StickerSeries) -> Int? { gaps(in: series).first?.lowerBound }

    /// The numbers missing from 1 to the highest one, as ranges.
    public func gaps(in series: StickerSeries) -> [ClosedRange<Int>] {
        var gaps: [ClosedRange<Int>] = []
        var last = 0
        for n in Set(numbers(in: series)).sorted() {
            if n > last + 1 { gaps.append((last + 1)...(n - 1)) }
            last = n
        }
        return gaps
    }

    /// Numbers used by more than one item.
    public func duplicates(in series: StickerSeries) -> [Int: [CollectionItem]] {
        var out: [Int: [CollectionItem]] = [:]
        for (sticker, list) in bySticker where sticker.series == series && list.count > 1 { out[sticker.number] = list }
        return out
    }

    /// Another item with this label (the one with id `excluding` doesn't count).
    public func taken(_ sticker: Sticker, excluding id: String?) -> CollectionItem? {
        items(at: sticker).first { $0.id != id }
    }

    private func numbers(in series: StickerSeries) -> [Int] {
        items.compactMap { $0.sticker?.series == series ? $0.stickerNumber : nil }
    }

    /// How a library album's cover shows the copies you own: the preferred copy, and how many more there are.
    public func mark(albumKey: String) -> CopyMark {
        guard let primary = copies(albumKey: albumKey).first else { return .notInCollection }
        return mark(item: primary)
    }

    public func mark(item: CollectionItem) -> CopyMark {
        let more = max(copies(albumKey: item.albumKey).count, 1) - 1
        let state = digitalState(item)
        switch item.medium {
        case .cd: return .cd(number: item.stickerNumber, digitized: state.hasMusic, more: more)
        case .vinyl: return .vinyl(number: item.stickerNumber, digitized: state.hasMusic, more: more)
        case .download:
            if case .partial = state { return .download(partial: true, more: more) }
            return .download(partial: false, more: more)
        case .other: return .other(more: more)
        }
    }

    /// Stored items that may be this release (by release, barcode, album key or release group), of `medium` when
    /// given: the ones without a digital copy first, then the closest matches.
    public func matches(releaseID: String?, releaseGroupID: String?, albumKey: String?, barcode: String?,
                        medium: CollectionMedium?) -> [CollectionItem] {
        let release = MBID.validated(releaseID), group = MBID.validated(releaseGroupID)
        let code = barcode.flatMap(Self.barcodeKey)
        var found: [(item: CollectionItem, strength: Int, offset: Int)] = []
        for (offset, item) in items.enumerated() where item.origin == .stored && (medium == nil || item.medium == medium) {
            let strength: Int
            if let release, item.releaseID == release { strength = 0 }
            else if let code, item.barcode.flatMap(Self.barcodeKey) == code { strength = 1 }
            else if let albumKey, item.albumKey == albumKey { strength = 2 }
            else if let group, item.releaseGroupID == group { strength = 3 }
            else { continue }
            found.append((item, strength, offset))
        }
        return found.sorted { a, b in
            let da = digitalState(a.item).needsDigitizing, db = digitalState(b.item).needsDigitizing
            if da != db { return da }
            return a.strength != b.strength ? a.strength < b.strength : a.offset < b.offset
        }.map(\.item)
    }

    /// A barcode's digits without leading zeros, so a UPC and the same code as an EAN match.
    static func barcodeKey(_ s: String) -> String? {
        let digits = s.filter { ("0"..."9").contains($0) }.drop { $0 == "0" }
        return digits.isEmpty ? nil : String(digits)
    }

    /// The library albums of the digitized items in scope, to add to a phone's selection.
    public func syncItems(_ scope: CollectionSyncScope) -> [ExportItem] {
        guard scope != .off else { return [] }
        var keys = Set<String>()
        var out: [(key: String, item: ExportItem)] = []
        for item in items {
            switch scope {
            case .off: continue
            case .cds: guard item.medium == .cd else { continue }
            case .vinyl: guard item.medium == .vinyl else { continue }
            case .all: break
            }
            guard digitalState(item).hasMusic, let first = tracksByKey[item.albumKey]?.first,
                  keys.insert(item.albumKey).inserted else { continue }
            out.append((item.albumKey, .album(album: first.album, artist: first.effectiveAlbumArtist)))
        }
        return out.sorted { $0.key < $1.key }.map(\.item)
    }

    public func count(_ scope: CollectionScope) -> Int {
        items.reduce(0) { $0 + (scope.contains($1, state: digitalState($1)) ? 1 : 0) }
    }

    public func items(in scope: CollectionScope) -> [CollectionItem] {
        items.filter { scope.contains($0, state: digitalState($0)) }
    }

    /// The digital collection's artists plus the ones you only own on CD or vinyl (their albums counted once per album
    /// key, no songs), case-insensitively by name: the Artists list of both collections.
    public func artists(adding digital: [ArtistSummary]) -> [ArtistSummary] {
        let known = Set(digital.map { $0.name.lowercased() })
        var physical: [String: (name: String, albums: Set<String>)] = [:]
        for item in items where item.medium.isPhysical && !item.artist.isEmpty {
            let key = item.artist.lowercased()
            guard !known.contains(key) else { continue }
            physical[key, default: (item.artist, [])].albums.insert(item.albumKey)
        }
        return digital + physical.values.map { ArtistSummary(name: $0.name, albumCount: $0.albums.count, trackCount: 0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every item's artist, trackless items included, once each (case-insensitively), A to Z.
    public var artists: [String] {
        var seen: [String: String] = [:]
        for item in items where !item.artist.isEmpty { seen[item.artist.lowercased()] = seen[item.artist.lowercased()] ?? item.artist }
        return seen.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The item's own cover ("Music/Collection Covers/<file>"), else the linked album's cover.jpg when the album has
    /// tracks. Relative to the library root; resolve it with `LibraryPath.resolve`.
    public func coverPath(_ item: CollectionItem) -> String? {
        if let file = item.coverFile, let path = CollectionCovers.path(file) { return path }
        guard let first = tracksByKey[item.albumKey]?.map(\.path).min(), LibraryPath.isPlainRelative(first) else { return nil }
        return ((first as NSString).deletingLastPathComponent as NSString).appendingPathComponent("cover.jpg")
    }
}

// MARK: Linking

/// Keeps items linked to their digital copies as the library changes.
public enum CollectionLinker {
    /// What to change on a stored item; nil fields stay as they are.
    public struct Change: Hashable, Sendable {
        public var id: String
        public var albumKey: String?
        public var releaseID: String?
        public var releaseGroupID: String?
        public var year: Int?
        public var digitalSource: DigitalSource?

        public init(id: String, albumKey: String? = nil, releaseID: String? = nil, releaseGroupID: String? = nil,
                    year: Int? = nil, digitalSource: DigitalSource? = nil) {
            self.id = id; self.albumKey = albumKey; self.releaseID = releaseID; self.releaseGroupID = releaseGroupID
            self.year = year; self.digitalSource = digitalSource
        }

        var isEmpty: Bool { albumKey == nil && releaseID == nil && releaseGroupID == nil && year == nil && digitalSource == nil }

        func applied(to item: CollectionItem) -> CollectionItem {
            var item = item
            if let albumKey { item.albumKey = albumKey }
            if let releaseID { item.releaseID = releaseID }
            if let releaseGroupID { item.releaseGroupID = releaseGroupID }
            if let year { item.year = year }
            if let digitalSource { item.digitalSource = digitalSource }
            return item
        }
    }

    /// After a reload: backfills release IDs (not from another copy's songs) and year from the most common tags of
    /// linked tracks, persists the inferred source (nil + tracks → .rip for CDs, .download for downloads, .same
    /// otherwise), and relinks an item whose key lost its tracks only when its releaseID is on exactly one live album
    /// key. Never by name.
    public static func changes(items: [CollectionItem], tracks: [Track]) -> [Change] {
        var byKey: [String: [Track]] = [:]
        var keysByRelease: [String: Set<String>] = [:]
        for t in tracks {
            let key = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
            byKey[key, default: []].append(t)
            if let r = MBID.validated(t.metadata.mbReleaseId) { keysByRelease[r, default: []].insert(key) }
        }
        var out: [Change] = []
        for item in items where item.isEditable {
            var change = Change(id: item.id)
            var key = item.albumKey
            if byKey[key] == nil, item.digitalSource != nil, let r = item.releaseID,
               let live = keysByRelease[r], live.count == 1, let only = live.first, only != key {
                change.albumKey = only
                key = only
            }
            if let linked = byKey[key] {
                let source = item.digitalSource ?? (item.medium == .cd ? .rip : item.medium == .download ? .download : .same)
                // Songs from another copy carry that copy's release (a record's music ripped from the CD): only the
                // release group, shared by every edition, is taken from them.
                if item.releaseID == nil, source != .same {
                    change.releaseID = mostCommon(linked.compactMap { MBID.validated($0.metadata.mbReleaseId) })
                }
                if item.releaseGroupID == nil {
                    change.releaseGroupID = mostCommon(linked.compactMap { MBID.validated($0.metadata.extended.mbReleaseGroupId) })
                }
                if item.year == nil {
                    change.year = mostCommon(linked.compactMap(\.year).filter { (1000...9999).contains($0) })
                }
                if item.digitalSource == nil { change.digitalSource = source }
            }
            if !change.isEmpty { out.append(change) }
        }
        return out
    }

    /// The most frequent value, the smallest among equals.
    static func mostCommon<T: Hashable & Comparable>(_ values: [T]) -> T? {
        var counts: [T: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.min { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }?.key
    }

    /// Name-based proposals for "Link to Library Album…": the same release first, then the release group, then
    /// albums of the same title by a compatible artist (`CatalogOwnership`). Only ever suggestions: a release group
    /// match may be another edition.
    public static func suggestions(for item: CollectionItem, albums: [AlbumSummary], tracks: [Track]) -> [AlbumSummary] {
        var releases: [String: Set<String>] = [:], groups: [String: Set<String>] = [:]
        for t in tracks {
            let key = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
            if let r = MBID.validated(t.metadata.mbReleaseId) { releases[key, default: []].insert(r) }
            if let g = MBID.validated(t.metadata.extended.mbReleaseGroupId) { groups[key, default: []].insert(g) }
        }
        let forms = Set(CatalogOwnership.albumForms(item.album))
        let artist = CatalogOwnership.tokens(item.artist)
        var ranked: [(album: AlbumSummary, rank: Int, offset: Int)] = []
        for (offset, album) in albums.enumerated() {
            let key = SearchIndex.albumKey(album: album.album, artist: album.artist)
            if let r = item.releaseID, releases[key]?.contains(r) == true {
                ranked.append((album, 0, offset))
            } else if let g = item.releaseGroupID, groups[key]?.contains(g) == true {
                ranked.append((album, 1, offset))
            } else if !forms.isDisjoint(with: CatalogOwnership.albumForms(album.album)),
                      CatalogOwnership.compatible(artist, CatalogOwnership.tokens(album.artist)) {
                ranked.append((album, 2, offset))
            }
        }
        return ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.offset < $1.offset }.map(\.album)
    }
}

extension CollectionItem {
    /// Puts what songs imported as this item's digital copy cost on it: the price and the date each only where the
    /// item has none, so nothing it had is replaced. True when the songs' purchase is on the item now (their price went
    /// there, or with no price, their date did or is the item's already); false, the songs keep their own purchases,
    /// or what was typed would be lost.
    public mutating func takeSongsPurchase(price: Decimal?, day: PurchaseDay?) -> Bool {
        let taken = price != nil ? self.price == nil : (day == nil || purchasedOn == nil || purchasedOn == day)
        if self.price == nil, let price { self.price = price }
        if purchasedOn == nil, let day { purchasedOn = day }
        return taken
    }
}
