import Foundation

/// Where a widget tap opens the iPhone app: `musiclibrary://…` URLs (the scheme is registered in the app's Info.plist).
public enum GlanceLink: Hashable, Sendable {
    public enum Pane: String, Sendable, CaseIterable { case library, listening, owned }

    case nowPlaying
    /// An album page, by `SearchIndex.albumKey`.
    case album(key: String)
    case insights(Pane)
    case library

    public static let scheme = "musiclibrary"

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .nowPlaying:
            c.host = "now-playing"
        case .album(let key):
            c.host = "album"
            c.queryItems = [URLQueryItem(name: "key", value: key)]
        case .insights(let pane):
            c.host = "insights"
            c.queryItems = [URLQueryItem(name: "pane", value: pane.rawValue)]
        case .library:
            c.host = "library"
        }
        return c.url ?? URL(string: "\(Self.scheme)://library")!
    }

    /// Nil for any other URL.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = { (name: String) in c.queryItems?.first { $0.name == name }?.value }
        switch c.host?.lowercased() {
        case "now-playing":
            self = .nowPlaying
        case "album":
            guard let key = query("key"), !key.isEmpty else { return nil }
            self = .album(key: key)
        case "insights":
            self = .insights(query("pane").flatMap(Pane.init(rawValue:)) ?? .listening)
        case "library":
            self = .library
        default:
            return nil
        }
    }

    /// A collection item's page. Rides on the album link (a new case would break exhaustive switches over this
    /// enum), with the key "item:<id>": older phones look it up as an album, find none and stay where they are.
    public static func item(id: String) -> GlanceLink { .album(key: itemPrefix + id) }

    /// The item an `item(id:)` link opens.
    public var itemID: String? {
        guard case .album(let key) = self, key.hasPrefix(Self.itemPrefix) else { return nil }
        let id = String(key.dropFirst(Self.itemPrefix.count))
        return id.isEmpty ? nil : id
    }

    static let itemPrefix = "item:"
}

/// The widgets' kinds, so the app can reload one of them.
public enum GlanceWidgetKind: String, Sendable, CaseIterable {
    case listening = "Listening", purchases = "Purchases", nowPlaying = "NowPlaying", rediscover = "Rediscover", library = "Library"
}

/// What a widget button or the watch asks the iPhone app's player to do.
public enum GlanceCommand: Codable, Hashable, Sendable {
    case playPause
    case next
    case previous
    case toggleLike
    /// Plays an album's songs that are on the iPhone, by `SearchIndex.albumKey`.
    case playAlbum(key: String)
    case playSong(id: Int64)
    case shuffleLiked
    /// Shuffles every song on the iPhone.
    case shuffleAll
}

/// The iPhone's answer to a command.
public struct GlanceCommandResult: Codable, Hashable, Sendable {
    public var ok: Bool
    public var message: String?

    public init(ok: Bool, message: String? = nil) { self.ok = ok; self.message = message }

    public static let done = GlanceCommandResult(ok: true)
    public static func failed(_ message: String) -> GlanceCommandResult { GlanceCommandResult(ok: false, message: message) }
}

/// The WatchConnectivity messages between the iPhone and the watch. Values are JSON in `Data`, so both sides decode
/// (and check) them with the same types.
public enum GlanceMessage {
    /// iPhone → watch (application context and messages): the encoded `Glance`.
    public static let glance = "glance"
    /// Watch → iPhone: an encoded `GlanceCommand`; the reply's `result` is an encoded `GlanceCommandResult`.
    public static let command = "command"
    public static let result = "result"
    /// Watch → iPhone: cover names (`[String]`, at most `coversPerMessage`) the watch is missing; the reply's
    /// `coverData` has small JPEGs by name (`[String: Data]`). Replies are kept small: messages have a size limit.
    public static let covers = "covers"
    public static let coverData = "coverData"
    public static let coversPerMessage = 4
    /// Watch → iPhone: asks for the current summary (the reply's `glance`). With the shelf index the watch has, it
    /// also carries its `shelfHash`, so the iPhone sends the index again when it differs.
    public static let refresh = "refresh"
    public static let shelfHash = "shelfHash"
    /// iPhone → watch, a file transfer's metadata: `fileKind` is `shelfKind` for the shelf index (`GlanceShelf`),
    /// `shelfVersion` its version and `fileHash` its `contentHash`.
    public static let fileKind = "kind"
    public static let shelfKind = "shelf"
    public static let shelfVersion = "v"
    public static let fileHash = "hash"

    public static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        (value as? Data).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

// MARK: Formatting

public enum GlanceFormat {
    /// "4h 12m", "35m", "50s"; "0m" for nothing.
    public static func listened(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 1 else { return "0m" }
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int((seconds / 60).rounded(.down))
        let (h, m) = (minutes / 60, minutes % 60)
        if h >= 100 { return "\(h)h" }
        return h == 0 ? "\(m)m" : (m == 0 ? "\(h)h" : "\(h)h \(m)m")
    }

    /// "4.2 hours", "35 minutes": for sentences and VoiceOver.
    public static func listenedLong(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "under a minute" }
        let hours = seconds / 3600
        if hours >= 1 { return hours >= 10 ? "\(Int(hours.rounded())) hours" : String(format: "%.1f hours", hours) }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    public static func money(_ amount: Decimal, currencyCode: String, whole: Bool = false) -> String {
        amount.formatted(.currency(code: currencyCode).precision(.fractionLength(whole ? 0 : 2)))
    }

    /// "+12%", "−30%".
    public static func change(_ fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        return percent >= 0 ? "+\(percent)%" : "−\(-percent)%"
    }

    /// "9 AM"
    public static func hour(_ hour: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour)) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    /// "CD #12", "Vinyl #12": a label is never shown without its series. Just the number for a medium this version
    /// doesn't know.
    public static func sticker(medium: String, number: Int) -> String {
        switch medium.trimmingCharacters(in: .whitespaces).lowercased() {
        case "cd": "CD #\(number)"
        case "vinyl": "Vinyl #\(number)"
        default: "\(number)"
        }
    }

    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        n == 1 ? "1 \(singular)" : "\(n.formatted()) \(plural ?? singular + "s")"
    }
}

extension Glance {
    /// An amount in the summary's currency.
    public func money(_ amount: Decimal, whole: Bool = false) -> String {
        GlanceFormat.money(amount, currencyCode: currencyCode, whole: whole)
    }
}

extension Glance.Owned.Purchase {
    /// "Sep 1" this year, "Sep 1, 2024" before.
    public var dateText: String? {
        guard let date = purchaseDate() else { return nil }
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}
