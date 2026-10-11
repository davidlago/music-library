import Contacts
import CoreLocation
import Foundation

// MARK: Places

/// A point on Earth, in degrees.
public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude; self.longitude = longitude
    }

    /// Great-circle distance in kilometers.
    public func kilometers(to other: GeoPoint) -> Double {
        let r = 6371.0088
        let φ1 = latitude * .pi / 180, φ2 = other.latitude * .pi / 180
        let dφ = φ2 - φ1, dλ = (other.longitude - longitude) * .pi / 180
        let a = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// The geohash Ticketmaster's `geoPoint` parameter takes (9 characters is a few meters).
    public func geohash(precision: Int = 9) -> String {
        let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")
        var lat = (-90.0, 90.0), lon = (-180.0, 180.0)
        var hash = "", bits = 0, value = 0, even = true
        while hash.count < precision {
            if even {
                let mid = (lon.0 + lon.1) / 2
                if longitude >= mid { value = value << 1 | 1; lon.0 = mid } else { value <<= 1; lon.1 = mid }
            } else {
                let mid = (lat.0 + lat.1) / 2
                if latitude >= mid { value = value << 1 | 1; lat.0 = mid } else { value <<= 1; lat.1 = mid }
            }
            even.toggle()
            bits += 1
            if bits == 5 {
                hash.append(alphabet[value])
                bits = 0; value = 0
            }
        }
        return hash
    }
}

public enum DistanceUnit: String, Codable, Sendable, CaseIterable {
    case miles, kilometers

    /// Kilometers where the locale is metric, else miles (the US, the UK).
    public static func preferred(locale: Locale = .current) -> DistanceUnit {
        locale.measurementSystem == .metric ? .kilometers : .miles
    }

    public var abbreviation: String { self == .miles ? "mi" : "km" }
    public func fromKilometers(_ km: Double) -> Double { self == .miles ? km / 1.609344 : km }
    public func toKilometers(_ value: Double) -> Double { self == .miles ? value * 1.609344 : value }
}

/// Where the user lives, from the ZIP or postal code they entered.
public struct HomeLocation: Codable, Hashable, Sendable {
    public var postalCode: String
    public var country: String
    public var point: GeoPoint
    /// "Cambridge, MA", to show what the code was understood as.
    public var place: String

    public init(postalCode: String, country: String, point: GeoPoint, place: String) {
        self.postalCode = postalCode; self.country = country; self.point = point; self.place = place
    }
}

public enum PostalCode {
    /// The code tidied up for looking it up, or nil if it can't be one: US ZIP codes are five digits (ZIP+4 is
    /// cut to five); elsewhere letters, digits, spaces and dashes, 2 to 10 characters.
    public static func normalized(_ input: String, country: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if country.uppercased() == "US" {
            let digits = s.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return digits.count == 5 && digits.allSatisfy { $0.isASCII && $0.isNumber } ? digits : nil
        }
        let collapsed = s.split(separator: " ").joined(separator: " ")
        guard (2...10).contains(collapsed.count),
              collapsed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == "-") }) else { return nil }
        return collapsed
    }

    /// Finds where a postal code is with Apple's geocoder (no account or key).
    public static func locate(_ code: String, country: String) async throws -> HomeLocation? {
        let address = CNMutablePostalAddress()
        address.postalCode = code
        address.isoCountryCode = country
        let marks = try await CLGeocoder().geocodePostalAddress(address)
        guard let mark = marks.first, let c = mark.location?.coordinate,
              let point = GeoPoint(latitude: c.latitude, longitude: c.longitude) else { return nil }
        let place = [mark.locality ?? mark.subAdministrativeArea, mark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        return HomeLocation(postalCode: code, country: country, point: point, place: place.isEmpty ? code : place)
    }
}

// MARK: Models

/// Where concert listings come from. Each needs its own (free) API key.
public enum ConcertSource: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// Arenas, theaters and big clubs: the shows Ticketmaster and Live Nation sell.
    case ticketmaster
    /// Venue calendars, including small clubs and independent venues.
    case jambase

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .ticketmaster: "Ticketmaster"
        case .jambase: "JamBase"
        }
    }

    public var homepage: URL {
        switch self {
        case .ticketmaster: URL(string: "https://www.ticketmaster.com")!
        case .jambase: URL(string: "https://www.jambase.com")!
        }
    }

    public var signupURL: URL {
        switch self {
        case .ticketmaster: URL(string: "https://developer.ticketmaster.com/products-and-docs/apis/getting-started/")!
        case .jambase: URL(string: "https://data.jambase.com")!
        }
    }
}

/// An upcoming concert.
public struct Concert: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case scheduled, cancelled, postponed, rescheduled
    }

    /// "ticketmaster:<id>" or "jambase:<id>".
    public var id: String
    /// The event's own name: the artist, a tour, a festival, or the headliner the artist opens for.
    public var name: String
    /// The day at the venue (no time zone).
    public var day: PurchaseDay
    /// "19:30" at the venue, when announced.
    public var localTime: String?
    /// The venue's time zone identifier.
    public var timeZone: String?
    public var status: Status
    public var venue: String
    public var city: String
    /// "MA"; the region's name where there's no code.
    public var region: String?
    public var country: String?
    public var venuePoint: GeoPoint?
    /// From home, in kilometers.
    public var distanceKm: Double?
    /// Everyone on the bill, headliners first.
    public var lineup: [String]
    /// The event or ticket page; only ever an http(s) link.
    public var url: URL?
    public var minPrice: Decimal?
    public var currency: String?
    public var isFestival: Bool
    /// The services listing it (the first one's link is `url`).
    public var sources: [ConcertSource]

    public init(id: String, name: String, day: PurchaseDay, localTime: String? = nil, timeZone: String? = nil,
                status: Status = .scheduled, venue: String, city: String, region: String? = nil, country: String? = nil,
                venuePoint: GeoPoint? = nil, distanceKm: Double? = nil, lineup: [String] = [], url: URL? = nil,
                minPrice: Decimal? = nil, currency: String? = nil, isFestival: Bool = false, sources: [ConcertSource]) {
        self.id = id; self.name = name; self.day = day; self.localTime = localTime; self.timeZone = timeZone
        self.status = status; self.venue = venue; self.city = city; self.region = region; self.country = country
        self.venuePoint = venuePoint; self.distanceKm = distanceKm; self.lineup = lineup; self.url = url
        self.minPrice = minPrice; self.currency = currency; self.isFestival = isFestival; self.sources = sources
    }

    /// "Boston, MA"
    public var place: String { [city, region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }

    /// The start time at the venue ("7:30 PM"), when announced.
    public func formattedTime(locale: Locale = .current) -> String? {
        let parts = localTime?.split(separator: ":").compactMap { Int($0) } ?? []
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                            hour: parts[0], minute: parts[1])) else { return nil }
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// The other acts on the bill (not the artist whose page this is).
    public func otherActs(than artist: String) -> [String] {
        let me = ArtistResolver.normalized(artist)
        return lineup.filter { ArtistResolver.normalized($0) != me }
    }

    /// The event's name when it says more than the artist's name (a tour, a festival, someone else's show).
    public func title(for artist: String) -> String? {
        let n = ArtistResolver.normalized(name)
        return n.isEmpty || n == ArtistResolver.normalized(artist) ? nil : name
    }
}

/// What one source has for an artist near home.
public struct SourceConcerts: Codable, Hashable, Sendable {
    public var source: ConcertSource
    /// False when the source doesn't know the artist.
    public var matched: Bool
    /// The artist's page on the source (all tour dates); only ever an http(s) link.
    public var artistURL: URL?
    /// All the artist's upcoming shows on the source, near or not, when it says.
    public var upcomingTotal: Int?
    public var concerts: [Concert]

    public init(source: ConcertSource, matched: Bool, artistURL: URL? = nil, upcomingTotal: Int? = nil, concerts: [Concert] = []) {
        self.source = source; self.matched = matched; self.artistURL = artistURL
        self.upcomingTotal = upcomingTotal; self.concerts = concerts
    }
}

/// An artist's upcoming concerts near home, from every source, with duplicates merged.
public struct NearbyConcerts: Codable, Hashable, Sendable {
    public var concerts: [Concert]
    public var bySource: [SourceConcerts]
    public var fetchedAt: Date

    public init(_ results: [SourceConcerts], fetchedAt: Date = Date()) {
        bySource = results
        concerts = ConcertMerger.merge(results.map(\.concerts))
        self.fetchedAt = fetchedAt
    }

    /// Upcoming shows that aren't near home (by the source that knows of the most).
    public var elsewhereCount: Int {
        bySource.map { max(0, ($0.upcomingTotal ?? 0) - $0.concerts.count) }.max() ?? 0
    }
}

public enum ConcertMerger {
    /// One list, soonest first. The same show from several sources (same day, same venue by name or within
    /// 300 m) is kept once, as listed by the earlier source, with the sources combined.
    public static func merge(_ lists: [[Concert]]) -> [Concert] {
        var merged: [Concert] = []
        for list in lists {
            for c in list {
                if let i = merged.firstIndex(where: { isSameShow($0, c) }) {
                    for s in c.sources where !merged[i].sources.contains(s) { merged[i].sources.append(s) }
                    if merged[i].url == nil { merged[i].url = c.url }
                    if merged[i].localTime == nil { merged[i].localTime = c.localTime }
                    if merged[i].minPrice == nil, c.minPrice != nil { merged[i].minPrice = c.minPrice; merged[i].currency = c.currency }
                } else {
                    merged.append(c)
                }
            }
        }
        return merged.sorted { ($0.day, $0.localTime ?? "", $0.venue) < ($1.day, $1.localTime ?? "", $1.venue) }
    }

    static func isSameShow(_ a: Concert, _ b: Concert) -> Bool {
        guard a.day == b.day else { return false }
        if let p = a.venuePoint, let q = b.venuePoint, p.kilometers(to: q) < 0.3 { return true }
        let va = ArtistResolver.normalized(a.venue), vb = ArtistResolver.normalized(b.venue)
        return !va.isEmpty && va == vb
    }
}

// MARK: Errors

public enum ConcertError: Error, LocalizedError, Equatable {
    case invalidKey(ConcertSource)
    case limitReached(ConcertSource)
    case http(ConcertSource, Int)

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let s): "\(s.name) didn't accept the API key. Check it in Settings › Concerts."
        case .limitReached(let s): "You've reached \(s.name)'s request limit for now. Try again later."
        // Never the URL: it can carry the API key.
        case .http(let s, let code): "\(s.name) returned an error (HTTP \(code))."
        }
    }
}

/// A concert listing service.
public protocol ConcertProvider: Sendable {
    var source: ConcertSource { get }
    /// The artist's upcoming concerts within `radius` of `home`, soonest first.
    func upcomingConcerts(artist: String, mbid: String?, near home: GeoPoint, radius: Int, unit: DistanceUnit,
                          now: Date) async throws -> SourceConcerts
    /// Upcoming concerts within `radius` of `home` by any of `artists` (a whole library), in as few requests as
    /// the service allows.
    func scan(_ artists: ArtistDirectory, near home: GeoPoint, radius: Int, unit: DistanceUnit, now: Date) async throws -> [ArtistConcert]
}

/// A library artist to look for.
public struct ConcertArtist: Hashable, Sendable {
    public var name: String
    public var mbid: String?
    public init(name: String, mbid: String? = nil) { self.name = name; self.mbid = MBID.validated(mbid) }
}

/// Library artists by MusicBrainz ID and by normalized name, for recognizing them in listings.
public struct ArtistDirectory: Sendable {
    public let artists: [ConcertArtist]
    private let byMBID: [String: String]
    private let byName: [String: String]

    public init(_ artists: [ConcertArtist]) {
        let usable = artists.filter { a in
            let n = ArtistResolver.normalized(a.name)
            return !n.isEmpty && !Self.notArtists.contains(n)
        }
        self.artists = usable
        byMBID = Dictionary(usable.compactMap { a in a.mbid.map { ($0, a.name) } }, uniquingKeysWith: { a, _ in a })
        byName = Dictionary(usable.map { (ArtistResolver.normalized($0.name), $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// Placeholder credits that would match unrelated listings.
    static let notArtists: Set<String> = ["various artists", "various", "unknown artist", "unknown", "soundtrack", "cast"]

    public var isEmpty: Bool { artists.isEmpty }

    /// The library's name for a performer in a listing. A performer linked to a MusicBrainz artist only
    /// matches that artist; otherwise the names must match.
    public func match(name: String, mbids: [String] = []) -> String? {
        if let hit = mbids.lazy.compactMap({ self.byMBID[$0] }).first { return hit }
        guard let hit = byName[ArtistResolver.normalized(name)] else { return nil }
        if !mbids.isEmpty, let mine = artists.first(where: { $0.name == hit })?.mbid, !mbids.contains(mine) { return nil }
        return hit
    }
}

/// A concert by one of the library's artists.
public struct ArtistConcert: Codable, Hashable, Sendable, Identifiable {
    /// The library's name for the artist.
    public var artist: String
    public var concert: Concert
    public var id: String { "\(artist.lowercased())|\(concert.id)" }

    public init(artist: String, concert: Concert) { self.artist = artist; self.concert = concert }
}

/// Every library artist's upcoming concerts near home.
public struct ConcertScan: Codable, Hashable, Sendable {
    public var items: [ArtistConcert]
    public var sources: [ConcertSource]
    public var scannedAt: Date

    public init(items: [ArtistConcert], sources: [ConcertSource], scannedAt: Date = Date()) {
        self.items = items; self.sources = sources; self.scannedAt = scannedAt
    }

    /// The same show found by several sources is listed once per artist; soonest first.
    public static func merge(_ lists: [[ArtistConcert]]) -> [ArtistConcert] {
        var byArtist: [String: (name: String, lists: [[Concert]])] = [:]
        for (i, list) in lists.enumerated() {
            for item in list {
                let key = item.artist.lowercased()
                var entry = byArtist[key] ?? (item.artist, Array(repeating: [], count: lists.count))
                entry.lists[i].append(item.concert)
                byArtist[key] = entry
            }
        }
        return byArtist.values.flatMap { entry in ConcertMerger.merge(entry.lists).map { ArtistConcert(artist: entry.name, concert: $0) } }
            .sorted { ($0.concert.day, $0.concert.localTime ?? "", $0.artist) < ($1.concert.day, $1.concert.localTime ?? "", $1.artist) }
    }
}

public typealias ConcertGet = @Sendable (URLRequest) async throws -> Data

/// Sends a request; any status but 200 is a `ConcertError` for `source`.
func concertGet(_ source: ConcertSource) -> ConcertGet {
    { request in
        var request = request
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 401, 403: throw ConcertError.invalidKey(source)
        case 402, 429: throw ConcertError.limitReached(source)
        case let code: throw ConcertError.http(source, code)
        }
    }
}

/// Keeps what's actually upcoming and near: sources measure from slightly different points, so allow a
/// little past the edge.
func nearAndUpcoming(_ concerts: [Concert], radius: Int, unit: DistanceUnit, now: Date) -> [Concert] {
    let limit = unit.toKilometers(Double(radius)) * 1.05
    let today = PurchaseDay(now)
    return concerts.filter { $0.day >= today && ($0.distanceKm ?? 0) <= limit }
}

private func str(_ v: Any?) -> String? {
    (v as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
}

private func number(_ v: Any?) -> Double? {
    let d = (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    return d.flatMap { $0.isFinite ? $0 : nil }
}

private func point(_ o: [String: Any]?) -> GeoPoint? {
    guard let o, let lat = number(o["latitude"]), let lon = number(o["longitude"]) else { return nil }
    return GeoPoint(latitude: lat, longitude: lon)
}

private func price(_ v: Double?) -> Decimal? {
    guard let v, v >= 0, v < 1_000_000 else { return nil }
    return Decimal(string: String(format: "%.2f", v))
}

/// "19:30" from "19:30:00" (or the time part of "2026-11-02T19:30:00").
private func hoursMinutes(_ s: String?) -> String? {
    guard let s else { return nil }
    let time = s.split(separator: "T").last.map(String.init) ?? s
    let parts = time.split(separator: ":")
    guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
    return String(format: "%02d:%02d", h, m)
}

// MARK: Ticketmaster

/// A performer on Ticketmaster.
public struct TicketmasterAttraction: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var musicBrainzIds: [String]
    public var isMusic: Bool
    public var upcomingEvents: Int?
    public var url: URL?

    public init(id: String, name: String, musicBrainzIds: [String] = [], isMusic: Bool = true, upcomingEvents: Int? = nil, url: URL? = nil) {
        self.id = id; self.name = name; self.musicBrainzIds = musicBrainzIds; self.isMusic = isMusic
        self.upcomingEvents = upcomingEvents; self.url = url
    }
}

/// Reads Ticketmaster Discovery API (v2) responses. Everything in them is untrusted: links must be web links,
/// MusicBrainz IDs must be UUIDs, and malformed events are skipped.
public enum TicketmasterParser {
    public static func parseAttractions(_ data: Data) throws -> [TicketmasterAttraction] {
        try embedded(data, "attractions").compactMap(attraction)
    }

    /// The events in a search, soonest first, with distances from `home`.
    public static func parseEvents(_ data: Data, home: GeoPoint?) throws -> [Concert] {
        ConcertMerger.merge([try embedded(data, "events").compactMap { event($0, home: home) }])
    }

    public struct Page: Sendable {
        /// Each event with the performers on its bill.
        public var events: [(concert: Concert, performers: [TicketmasterAttraction])]
        public var totalElements: Int
        public var totalPages: Int
    }

    /// One page of an event search, in the order given.
    public static func parsePage(_ data: Data, home: GeoPoint?) throws -> Page {
        let o = try object(data)
        let events = ((o["_embedded"] as? [String: Any])?["events"] as? [[String: Any]] ?? []).compactMap { e in
            event(e, home: home).map { c in
                (c, ((e["_embedded"] as? [String: Any])?["attractions"] as? [[String: Any]] ?? []).compactMap(attraction))
            }
        }
        let page = o["page"] as? [String: Any]
        return Page(events: events, totalElements: number(page?["totalElements"]).map { Int($0) } ?? events.count,
                    totalPages: number(page?["totalPages"]).map { Int($0) } ?? 1)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("Ticketmaster response is not a JSON object")
        }
        return o
    }

    private static func embedded(_ data: Data, _ key: String) throws -> [[String: Any]] {
        // A search without results has no `_embedded` at all.
        (try object(data)["_embedded"] as? [String: Any])?[key] as? [[String: Any]] ?? []
    }

    static func attraction(_ a: [String: Any]) -> TicketmasterAttraction? {
        guard let id = str(a["id"]), let name = str(a["name"]) else { return nil }
        let links = a["externalLinks"] as? [String: Any]
        let mbids = (links?["musicbrainz"] as? [[String: Any]] ?? []).compactMap { MBID.validated(str($0["id"])) }
        let segments = (a["classifications"] as? [[String: Any]] ?? []).compactMap { str(($0["segment"] as? [String: Any])?["name"]) }
        let upcoming = (a["upcomingEvents"] as? [String: Any]).flatMap { number($0["_total"]) }.map { Int($0) }
        return TicketmasterAttraction(id: id, name: name, musicBrainzIds: mbids,
                                      isMusic: segments.isEmpty || segments.contains { $0.lowercased() == "music" },
                                      upcomingEvents: upcoming, url: str(a["url"]).flatMap(URL.init(webLink:)))
    }

    static func event(_ e: [String: Any], home: GeoPoint?) -> Concert? {
        guard e["test"] as? Bool != true, let id = str(e["id"]), let name = str(e["name"]) else { return nil }
        let dates = e["dates"] as? [String: Any] ?? [:]
        let start = dates["start"] as? [String: Any] ?? [:]
        guard let day = str(start["localDate"]).flatMap(PurchaseDay.init(string:)) else { return nil }
        let timeKnown = start["timeTBA"] as? Bool != true && start["noSpecificTime"] as? Bool != true

        let inner = e["_embedded"] as? [String: Any] ?? [:]
        let v = (inner["venues"] as? [[String: Any]])?.first ?? [:]
        let venuePoint = point(v["location"] as? [String: Any])
        let state = v["state"] as? [String: Any]
        var distance: Double?
        if let home, let venuePoint {
            distance = home.kilometers(to: venuePoint)
        } else if let d = number(e["distance"]), d >= 0 {
            distance = str(e["units"])?.uppercased() == "KM" ? d : d * 1.609344
        }
        let cheapest = (e["priceRanges"] as? [[String: Any]] ?? [])
            .compactMap { r in price(number(r["min"])).map { ($0, str(r["currency"])) } }
            .min { $0.0 < $1.0 }
        let status: Concert.Status = switch str((dates["status"] as? [String: Any])?["code"])?.lowercased() {
        case "cancelled", "canceled": .cancelled
        case "postponed": .postponed
        case "rescheduled": .rescheduled
        default: .scheduled
        }
        return Concert(
            id: "ticketmaster:\(id)", name: name, day: day,
            localTime: timeKnown ? hoursMinutes(str(start["localTime"])) : nil,
            timeZone: str(dates["timezone"]) ?? str(v["timezone"]), status: status,
            venue: str(v["name"]) ?? "Venue to be announced",
            city: str((v["city"] as? [String: Any])?["name"]) ?? "",
            region: str(state?["stateCode"]) ?? str(state?["name"]),
            country: str((v["country"] as? [String: Any])?["countryCode"]),
            venuePoint: venuePoint, distanceKm: distance,
            lineup: (inner["attractions"] as? [[String: Any]] ?? []).compactMap { str($0["name"]) },
            url: str(e["url"]).flatMap(URL.init(webLink:)),
            minPrice: cheapest?.0, currency: cheapest?.1, sources: [.ticketmaster])
    }

    /// The Ticketmaster performer for a library artist: one sharing its MusicBrainz ID, else a music performer
    /// with the same (normalized) name. Keyword searches also return tribute acts and anything mentioning the
    /// name, so nothing looser is accepted.
    public static func match(_ name: String, mbid: String?, in results: [TicketmasterAttraction]) -> TicketmasterAttraction? {
        let mbid = MBID.validated(mbid)
        if let mbid, let hit = results.first(where: { $0.musicBrainzIds.contains(mbid) }) { return hit }
        let wanted = ArtistResolver.normalized(name)
        guard !wanted.isEmpty else { return nil }
        // With an MBID, a namesake that is linked to a different artist is someone else.
        let candidates = results.filter {
            $0.isMusic && ArtistResolver.normalized($0.name) == wanted && (mbid == nil || $0.musicBrainzIds.isEmpty)
        }
        return candidates.max { ($0.upcomingEvents ?? 0) < ($1.upcomingEvents ?? 0) }
    }
}

/// Ticketmaster's Discovery API: a free key from developer.ticketmaster.com (5 requests a second, 5,000 a day).
public actor TicketmasterClient: ConcertProvider {
    public static let baseURL = "https://app.ticketmaster.com/discovery/v2"
    public nonisolated let source = ConcertSource.ticketmaster
    private let apiKey: String
    private let get: ConcertGet
    private let minInterval: TimeInterval
    private var nextSlot = Date.distantPast

    public init(apiKey: String, minInterval: TimeInterval = 0.25, get: ConcertGet? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minInterval = minInterval
        self.get = get ?? concertGet(.ticketmaster)
    }

    public func upcomingConcerts(artist: String, mbid: String?, near home: GeoPoint, radius: Int, unit: DistanceUnit,
                                 now: Date = Date()) async throws -> SourceConcerts {
        let found = try TicketmasterParser.parseAttractions(try await fetch("attractions.json", [
            "keyword": artist, "classificationName": "music", "size": "20",
        ]))
        guard let a = TicketmasterParser.match(artist, mbid: mbid, in: found) else {
            return SourceConcerts(source: source, matched: false)
        }
        var result = SourceConcerts(source: source, matched: true, artistURL: a.url, upcomingTotal: a.upcomingEvents)
        if a.upcomingEvents == 0 { return result }
        let events = try await fetch("events.json", [
            "attractionId": a.id, "geoPoint": home.geohash(), "radius": String(radius),
            "unit": unit == .miles ? "miles" : "km", "sort": "date,asc", "size": "50",
        ])
        result.concerts = nearAndUpcoming(try TicketmasterParser.parseEvents(events, home: home), radius: radius, unit: unit, now: now)
        return result
    }

    /// Every music event near home over the next year, matched against the library. Ticketmaster returns at
    /// most 1,000 results per search, so the year is searched month by month, and a month with more events
    /// than that is split in half until each part fits.
    public func scan(_ artists: ArtistDirectory, near home: GeoPoint, radius: Int, unit: DistanceUnit,
                     now: Date = Date()) async throws -> [ArtistConcert] {
        guard !artists.isEmpty else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.startOfDay(for: now)
        var windows: [(Date, Date)] = (0..<12).compactMap { m in
            guard let a = calendar.date(byAdding: .month, value: m, to: start),
                  let b = calendar.date(byAdding: .month, value: m + 1, to: start) else { return nil }
            return (a, b)
        }
        let pageSize = 200, maxResults = 1000
        var found: [ArtistConcert] = []
        var requests = 0
        while let (from, to) = windows.first, requests < Self.maxScanRequests {
            windows.removeFirst()
            var page = 0, pages = 1
            while page < pages, requests < Self.maxScanRequests {
                let data = try await fetch("events.json", [
                    "classificationName": "music", "geoPoint": home.geohash(), "radius": String(radius),
                    "unit": unit == .miles ? "miles" : "km", "sort": "date,asc", "size": String(pageSize), "page": String(page),
                    "startDateTime": Self.timestamp(from), "endDateTime": Self.timestamp(to),
                ])
                requests += 1
                let result = try TicketmasterParser.parsePage(data, home: home)
                if page == 0, result.totalElements > maxResults, to.timeIntervalSince(from) > 86_400 {
                    let mid = from.addingTimeInterval((to.timeIntervalSince(from) / 2).rounded())
                    windows.insert(contentsOf: [(from, mid), (mid, to)], at: 0)
                    break
                }
                for (concert, performers) in result.events {
                    for p in performers {
                        if let name = artists.match(name: p.name, mbids: p.musicBrainzIds) {
                            found.append(ArtistConcert(artist: name, concert: concert))
                        }
                    }
                }
                pages = min(result.totalPages, maxResults / pageSize)
                page += 1
            }
        }
        let near = Set(nearAndUpcoming(found.map(\.concert), radius: radius, unit: unit, now: now).map(\.id))
        return ConcertScan.merge([found.filter { near.contains($0.concert.id) }])
    }

    /// Plenty for a year in a big city, while keeping well under the 5,000 a day.
    static let maxScanRequests = 120

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
            .timeSeparator(.colon).timeZone(separator: .omitted)).replacingOccurrences(of: "+0000", with: "Z")
    }

    private func fetch(_ path: String, _ query: [String: String]) async throws -> Data {
        let wait = nextSlot.timeIntervalSinceNow
        nextSlot = max(nextSlot, Date()).addingTimeInterval(minInterval)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        return try await get(URLRequest(url: try Self.url(path, query, apiKey: apiKey)))
    }

    static func url(_ path: String, _ query: [String: String], apiKey: String) throws -> URL {
        try queryURL("\(baseURL)/\(path)", query.merging(["apikey": apiKey]) { $1 })
    }
}

/// `base` with the query (sorted, so URLs are stable) and `+` encoded, since many servers read it as a space.
func queryURL(_ base: String, _ query: [String: String]) throws -> URL {
    guard var c = URLComponents(string: base) else { throw NetworkError.badResponse("Bad URL") }
    c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let url = c.url else { throw NetworkError.badResponse("Bad query") }
    return url
}

// MARK: JamBase

/// Reads JamBase Concert Data API (v3) event searches: schema.org-style `Concert`s and `Festival`s.
public enum JamBaseParser {
    public struct Result: Sendable {
        public var concerts: [Concert]
        /// The artist as JamBase lists them in the results, if they appear.
        public var artistURL: URL?
        public var upcomingTotal: Int?
    }

    /// The events with `artist` on the bill (matched by name unless `trustArtist`, for searches by artist ID),
    /// soonest first, with distances from `home`.
    public static func parseEvents(_ data: Data, artist: String, trustArtist: Bool, home: GeoPoint?) throws -> Result {
        let wanted = ArtistResolver.normalized(artist)
        var result = Result(concerts: [])
        for e in try raw(data).events {
            let performers = e["performer"] as? [[String: Any]] ?? []
            let me = performers.first { str($0["name"]).map(ArtistResolver.normalized) == wanted }
            guard me != nil || trustArtist, let concert = event(e, performer: me, home: home) else { continue }
            result.concerts.append(concert)
            if result.artistURL == nil, let me {
                result.artistURL = str(me["url"]).flatMap(URL.init(webLink:))
                result.upcomingTotal = number(me["x-numUpcomingEvents"]).map { Int($0) }
            }
        }
        result.concerts = ConcertMerger.merge([result.concerts])
        return result
    }

    /// Library artists' concerts on one page of results (a search for many artists at once).
    public static func parseScanPage(_ data: Data, artists: ArtistDirectory, home: GeoPoint?) throws -> (items: [ArtistConcert], totalPages: Int) {
        let (events, totalPages) = try raw(data)
        var items: [ArtistConcert] = []
        for e in events {
            for p in e["performer"] as? [[String: Any]] ?? [] {
                guard let name = str(p["name"]).flatMap({ artists.match(name: $0) }),
                      let concert = event(e, performer: p, home: home) else { continue }
                items.append(ArtistConcert(artist: name, concert: concert))
            }
        }
        return (items, totalPages)
    }

    private static func raw(_ data: Data) throws -> (events: [[String: Any]], totalPages: Int) {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("JamBase response is not a JSON object")
        }
        let pages = number((o["pagination"] as? [String: Any])?["totalPages"]).map { Int($0) } ?? 1
        return (o["events"] as? [[String: Any]] ?? [], pages)
    }

    static func event(_ e: [String: Any], performer: [String: Any]?, home: GeoPoint?) -> Concert? {
        guard let id = str(e["identifier"]), let name = str(e["name"]) else { return nil }
        let isFestival = str(e["@type"]) == "Festival"
        // At a festival, the artist's own day.
        let start = (isFestival ? str(performer?["x-performanceDate"]) : nil) ?? str(e["startDate"])
        guard let day = start.map({ String($0.prefix(10)) }).flatMap(PurchaseDay.init(string:)) else { return nil }
        let venue = e["location"] as? [String: Any] ?? [:]
        let address = venue["address"] as? [String: Any] ?? [:]
        let region = address["addressRegion"] as? [String: Any]
        let venuePoint = point(venue["geo"] as? [String: Any])
        let performers = (e["performer"] as? [[String: Any]] ?? []).sorted {
            ($0["x-isHeadliner"] as? Bool == true ? 0 : 1, number($0["x-performanceRank"]) ?? 999)
                < ($1["x-isHeadliner"] as? Bool == true ? 0 : 1, number($1["x-performanceRank"]) ?? 999)
        }
        let lineup = performers.compactMap { str($0["name"]) }
        let headliners = performers.filter { $0["x-isHeadliner"] as? Bool == true }.compactMap { str($0["name"]) }
        // A concert's own name is "Artist at Venue"; the headliners say more (and whether the artist opens).
        let title = str(e["x-customTitle"]) ?? (isFestival ? name : headliners.isEmpty ? name : ListFormatter.localizedString(byJoining: headliners))
        let offers = e["offers"] as? [[String: Any]] ?? []
        let cheapest = offers.compactMap { o -> (Decimal, String?)? in
            let spec = o["priceSpecification"] as? [String: Any]
            return price(number(spec?["minPrice"]) ?? number(spec?["price"])).map { ($0, str(spec?["priceCurrency"])) }
        }.min { $0.0 < $1.0 }
        let status: Concert.Status = switch str(e["eventStatus"])?.lowercased() {
        case "cancelled", "canceled": .cancelled
        case "postponed": .postponed
        case "rescheduled": .rescheduled
        default: .scheduled
        }
        // "US-MA" → "MA"
        let regionCode = str(region?["identifier"]).map { $0.split(separator: "-").last.map(String.init) ?? $0 }
        return Concert(
            // Identifiers already name their source ("jambase:13800001").
            id: id.contains(":") ? id : "jambase:\(id)", name: title, day: day,
            localTime: start.flatMap { $0.count > 10 ? hoursMinutes($0) : nil },
            timeZone: str(address["x-timezone"]), status: status,
            venue: str(venue["name"]) ?? "Venue to be announced",
            city: str(address["addressLocality"]) ?? "",
            region: regionCode ?? str(region?["name"]),
            country: str((address["addressCountry"] as? [String: Any])?["identifier"]),
            venuePoint: venuePoint, distanceKm: home.flatMap { h in venuePoint.map { h.kilometers(to: $0) } },
            lineup: lineup,
            url: str(e["url"]).flatMap(URL.init(webLink:)) ?? offers.lazy.compactMap { str($0["url"]).flatMap(URL.init(webLink:)) }.first,
            minPrice: cheapest?.0, currency: cheapest?.1, isFestival: isFestival, sources: [.jambase])
    }
}

/// JamBase's Concert Data API: venue-sourced listings, strong on small and independent venues. A free
/// (non-commercial) key allows 1,000 requests a month and requires crediting JamBase, so results are cached.
public actor JamBaseClient: ConcertProvider {
    public static let baseURL = "https://api.data.jambase.com/v3"
    public nonisolated let source = ConcertSource.jambase
    private let apiKey: String
    private let get: ConcertGet

    public init(apiKey: String, get: ConcertGet? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.get = get ?? concertGet(.jambase)
    }

    /// By MusicBrainz ID when there is one (exact), falling back to the name when JamBase doesn't know the ID.
    public func upcomingConcerts(artist: String, mbid: String?, near home: GeoPoint, radius: Int, unit: DistanceUnit,
                                 now: Date = Date()) async throws -> SourceConcerts {
        var query = [
            "geoLatitude": String(format: "%.4f", home.latitude), "geoLongitude": String(format: "%.4f", home.longitude),
            "geoRadiusAmount": String(min(5000, max(1, radius))), "geoRadiusUnits": unit == .miles ? "mi" : "km",
            "perPage": "50",
        ]
        var parsed: JamBaseParser.Result?
        if let mbid = MBID.validated(mbid) {
            query["artistId"] = "musicbrainz:\(mbid)"
            do {
                let byId = try JamBaseParser.parseEvents(try await fetch(query), artist: artist, trustArtist: true, home: home)
                if !byId.concerts.isEmpty { parsed = byId }
            } catch ConcertError.http(_, let code) where code == 400 || code == 404 {
                // An ID JamBase hasn't linked to anyone.
            }
            query["artistId"] = nil
        }
        if parsed == nil {
            query["artistName"] = artist
            parsed = try JamBaseParser.parseEvents(try await fetch(query), artist: artist, trustArtist: false, home: home)
        }
        let result = parsed ?? JamBaseParser.Result(concerts: [])
        return SourceConcerts(source: source, matched: !result.concerts.isEmpty || result.artistURL != nil,
                              artistURL: result.artistURL, upcomingTotal: result.upcomingTotal,
                              concerts: nearAndUpcoming(result.concerts, radius: radius, unit: unit, now: now))
    }

    /// Searches for many artists per request (names joined with `|`), to stay within the monthly quota.
    public func scan(_ artists: ArtistDirectory, near home: GeoPoint, radius: Int, unit: DistanceUnit,
                     now: Date = Date()) async throws -> [ArtistConcert] {
        var found: [ArtistConcert] = []
        for batch in Self.batches(artists.artists.map(\.name)) {
            var page = 1, pages = 1
            while page <= min(pages, 5) {
                let data = try await fetch([
                    "artistName": batch.joined(separator: "|"),
                    "geoLatitude": String(format: "%.4f", home.latitude), "geoLongitude": String(format: "%.4f", home.longitude),
                    "geoRadiusAmount": String(min(5000, max(1, radius))), "geoRadiusUnits": unit == .miles ? "mi" : "km",
                    "perPage": "100", "page": String(page),
                ])
                let result = try JamBaseParser.parseScanPage(data, artists: artists, home: home)
                found += result.items
                pages = result.totalPages
                page += 1
            }
        }
        let near = Set(nearAndUpcoming(found.map(\.concert), radius: radius, unit: unit, now: now).map(\.id))
        return ConcertScan.merge([found.filter { near.contains($0.concert.id) }])
    }

    /// Artist names in groups that keep each request's query a reasonable length (`|` separates names, so
    /// names containing it are left out).
    static func batches(_ names: [String], maxLength: Int = 1500) -> [[String]] {
        var batches: [[String]] = [], current: [String] = [], length = 0
        for name in names where !name.contains("|") {
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)?.count ?? name.count * 3
            if !current.isEmpty, length + encoded + 3 > maxLength {
                batches.append(current)
                current = []; length = 0
            }
            current.append(name)
            length += encoded + 3
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func fetch(_ query: [String: String]) async throws -> Data {
        var request = URLRequest(url: try queryURL("\(Self.baseURL)/events", query))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try await get(request)
    }
}

// MARK: Finding

public enum ConcertFinder {
    /// Asks every provider at once. One failing doesn't hide what the others found; if all fail, the first
    /// error is thrown.
    public static func find(artist: String, mbid: String?, near home: GeoPoint, radius: Int, unit: DistanceUnit,
                            providers: [any ConcertProvider], now: Date = Date()) async throws -> (NearbyConcerts, [ConcertError]) {
        let outcomes = await withTaskGroup(of: (Int, Result<SourceConcerts, Error>).self) { group in
            for (i, p) in providers.enumerated() {
                group.addTask {
                    do { return (i, .success(try await p.upcomingConcerts(artist: artist, mbid: mbid, near: home, radius: radius, unit: unit, now: now))) }
                    catch { return (i, .failure(error)) }
                }
            }
            var all: [(Int, Result<SourceConcerts, Error>)] = []
            for await o in group { all.append(o) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var results: [SourceConcerts] = [], errors: [Error] = []
        for o in outcomes {
            switch o {
            case .success(let r): results.append(r)
            case .failure(let e): errors.append(e)
            }
        }
        if results.isEmpty, let first = errors.first { throw first }
        return (NearbyConcerts(results, fetchedAt: now), errors.compactMap { $0 as? ConcertError })
    }

    /// Scans with every provider at once, like `find`.
    public static func scan(_ artists: [ConcertArtist], near home: GeoPoint, radius: Int, unit: DistanceUnit,
                            providers: [any ConcertProvider], now: Date = Date()) async throws -> (ConcertScan, [ConcertError]) {
        let directory = ArtistDirectory(artists)
        let outcomes = await withTaskGroup(of: (Int, Result<[ArtistConcert], Error>).self) { group in
            for (i, p) in providers.enumerated() {
                group.addTask {
                    do { return (i, .success(try await p.scan(directory, near: home, radius: radius, unit: unit, now: now))) }
                    catch { return (i, .failure(error)) }
                }
            }
            var all: [(Int, Result<[ArtistConcert], Error>)] = []
            for await o in group { all.append(o) }
            return all.sorted { $0.0 < $1.0 }
        }
        var lists: [[ArtistConcert]] = [], sources: [ConcertSource] = [], errors: [Error] = []
        for (i, o) in outcomes {
            switch o {
            case .success(let items): lists.append(items); sources.append(providers[i].source)
            case .failure(let e): errors.append(e)
            }
        }
        if lists.isEmpty, let first = errors.first { throw first }
        return (ConcertScan(items: ConcertScan.merge(lists), sources: sources, scannedAt: now), errors.compactMap { $0 as? ConcertError })
    }
}
