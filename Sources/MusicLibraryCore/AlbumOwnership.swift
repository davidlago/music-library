import Foundation

/// A calendar day with no time or time zone, so a purchase date never shifts when the clock or zone changes.
public struct PurchaseDay: Hashable, Comparable, Codable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1000...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year ?? 2000; month = c.month ?? 1; day = c.day ?? 1
    }

    /// Parses "yyyy-MM-dd"; anything else (the database may come from elsewhere) is nil.
    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var string: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Noon on that day, which stays on the same day whatever the time zone's offset.
    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }

    public static func < (a: PurchaseDay, b: PurchaseDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

/// An album you own a copy of: a CD or a download, when you bought it, what you paid and (for a CD) the number on the
/// sticker you put on the case, all optional. One row per album (`SearchIndex.albumKey`) in the `album_ownership`
/// table, which is now a projection of the collection (`CollectionItem`, `CollectionLegacy`) for older readers, and
/// the Codable form of ownership changes from phones before 1.18.
public struct AlbumPurchase: Hashable, Sendable {
    /// What you bought: the CD, or the album as a download.
    public enum Format: String, CaseIterable, Sendable {
        case cd, digital
    }

    public var album: String
    public var artist: String
    /// Set on the Mac only. A download has no label number.
    public var format: Format {
        didSet { if format == .digital { labelNumber = nil } }
    }
    public var purchasedOn: PurchaseDay?
    /// In the user's currency. Never negative.
    public var price: Decimal?
    /// The number on the label you stuck on your CD to find it on the shelf (`validLabelNumber`). Set on the Mac only;
    /// always nil for a download.
    public var labelNumber: Int? {
        didSet { if let n = labelNumber, format == .digital || Self.validLabelNumber(n) == nil { labelNumber = nil } }
    }

    public init(album: String, artist: String, format: Format = .cd, purchasedOn: PurchaseDay? = nil, price: Decimal? = nil,
                labelNumber: Int? = nil) {
        self.album = album; self.artist = artist; self.format = format; self.purchasedOn = purchasedOn
        self.price = price.flatMap(Self.validPrice)
        self.labelNumber = format == .digital ? nil : labelNumber.flatMap(Self.validLabelNumber)
    }

    /// Label numbers run from 1 to `maxLabelNumber`.
    public static let maxLabelNumber = 9_999_999

    public static func validLabelNumber(_ n: Int) -> Int? { (1...maxLabelNumber).contains(n) ? n : nil }

    /// The price if it's a usable amount (not NaN, not negative), else nil.
    public static func validPrice(_ price: Decimal) -> Decimal? {
        price.isNaN || price < 0 ? nil : price
    }

    /// Prices are stored as plain decimal text ("12.99"), the same in every locale.
    static func priceText(_ price: Decimal?) -> String? {
        price.map { NSDecimalNumber(decimal: $0).description(withLocale: Locale(identifier: "en_US_POSIX")) }
    }

    static func price(text: String?) -> Decimal? {
        text.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }.flatMap(validPrice)
    }
}

/// For ownership edits sent with a sync by phones before 1.18 (now ownership is edited on the Mac only): the date and
/// price as the database stores them, and checked again when read (they come from another device). There's no format
/// or label number: the Mac keeps its own when it applies the change.
extension AlbumPurchase: Codable {
    private enum CodingKeys: String, CodingKey { case album, artist, purchasedOn, price }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(album: try c.decode(String.self, forKey: .album), artist: try c.decode(String.self, forKey: .artist),
                  purchasedOn: try c.decodeIfPresent(String.self, forKey: .purchasedOn).flatMap(PurchaseDay.init(string:)),
                  price: Self.price(text: try c.decodeIfPresent(String.self, forKey: .price)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(album, forKey: .album)
        try c.encode(artist, forKey: .artist)
        try c.encodeIfPresent(purchasedOn?.string, forKey: .purchasedOn)
        try c.encodeIfPresent(Self.priceText(price), forKey: .price)
    }
}

/// A song you bought on its own or in a batch (a download), entered when importing it: when and what you paid, both
/// optional. Saved per track in `track_purchases` (removed with the track). An album you don't own as a CD or download
/// but whose songs you bought counts as a download (`MusicCollection`, `CollectionItem.Origin.songs`).
public struct TrackPurchase: Hashable, Sendable {
    public var purchasedOn: PurchaseDay?
    /// In the user's currency. Never negative.
    public var price: Decimal?

    public init(purchasedOn: PurchaseDay? = nil, price: Decimal? = nil) {
        self.purchasedOn = purchasedOn
        self.price = price.flatMap(AlbumPurchase.validPrice)
    }

    /// `total` (to the cent) split evenly into `count` prices that add up to it, the leftover cents going to the first
    /// ones: $10 for 3 songs is $3.34, $3.33 and $3.33.
    public static func split(_ total: Decimal, into count: Int) -> [Decimal] {
        guard count > 0, let total = AlbumPurchase.validPrice(total) else { return [] }
        var scaled = total * 100, cents = Decimal()
        NSDecimalRound(&cents, &scaled, 0, .plain)
        let all = NSDecimalNumber(decimal: cents).intValue
        let base = all / count, extra = all % count
        return (0..<count).map { Decimal(base + ($0 < extra ? 1 : 0)) / 100 }
    }
}

extension Decimal {
    public var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}
