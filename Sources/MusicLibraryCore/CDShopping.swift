import Foundation

// Shopping for a CD: MusicBrainz pins down the exact edition (a release whose media are CDs), then marketplaces
// are searched for copies of it. The pages are read in the app (`CDShopParser`, macOS); this file holds the
// models, the MusicBrainz side, the stores' URLs, currency conversion and matching, and is platform-neutral.

// MARK: Editions

/// One CD edition of an album: a MusicBrainz release with at least one CD medium.
public struct CDEdition: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var date: String
    public var country: String
    public var label: String
    public var catalogNumber: String
    public var barcode: String
    /// "CD", "2×CD", "CD + DVD-Video".
    public var format: String
    public var trackCount: Int
    public var status: String
    public var packaging: String
    public var disambiguation: String
    public var releaseGroupId: String?
    public var releaseGroupTitle: String
    public var releaseType: String

    public init(id: String, title: String, artist: String, date: String = "", country: String = "", label: String = "",
                catalogNumber: String = "", barcode: String = "", format: String = "CD", trackCount: Int = 0,
                status: String = "", packaging: String = "", disambiguation: String = "", releaseGroupId: String? = nil,
                releaseGroupTitle: String = "", releaseType: String = "") {
        self.id = id; self.title = title; self.artist = artist; self.date = date; self.country = country
        self.label = label; self.catalogNumber = catalogNumber; self.barcode = barcode; self.format = format
        self.trackCount = trackCount; self.status = status; self.packaging = packaging
        self.disambiguation = disambiguation; self.releaseGroupId = releaseGroupId
        self.releaseGroupTitle = releaseGroupTitle; self.releaseType = releaseType
    }

    public var year: Int? { date.count >= 4 ? Int(date.prefix(4)) : nil }
}

/// An album (MusicBrainz release group) and the CD editions a search found of it.
public struct CDAlbum: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var releaseType: String
    /// "Compilation", "Live"…
    public var secondaryTypes: [String] = []
    public var firstReleaseDate: String = ""
    public var editions: [CDEdition]
    /// False for an album listed from an artist's discography, until its CD editions are looked up.
    public var editionsLoaded = true

    public var releaseGroupId: String? { MBID.validated(id) }
    /// The album's first release, or the earliest year among the editions.
    public var year: Int? {
        firstReleaseDate.count >= 4 ? Int(firstReleaseDate.prefix(4)) : editions.compactMap(\.year).min()
    }

    /// "Album", "Live Album", "Compilation", "EP".
    public var kind: String {
        if secondaryTypes.contains("Compilation") { return "Compilation" }
        if let other = secondaryTypes.first { return releaseType == "Album" ? "\(other) Album" : "\(other) \(releaseType)" }
        return releaseType
    }
}

/// An artist on MusicBrainz, to list the albums of.
public struct CDArtist: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var disambiguation: String
    public var country: String
    public var score: Int
}

public enum CDDiscographyParser {
    /// Artists from MusicBrainz's artist search, best match first.
    public static func parseArtists(_ data: Data) throws -> [CDArtist] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MusicBrainz search is not a JSON object")
        }
        return (root["artists"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = MBID.validated(a["id"] as? String), let name = a["name"] as? String else { return nil }
            return CDArtist(id: id, name: name, disambiguation: a["disambiguation"] as? String ?? "",
                            country: a["country"] as? String ?? "", score: (a["score"] as? Int) ?? Int(a["score"] as? String ?? "") ?? 0)
        }
    }

    /// The artist's albums from a release group browse (`/release-group?artist=…`), editions not yet loaded, and
    /// the total there is to page through.
    public static func parseAlbums(_ data: Data, artist: String) throws -> (albums: [CDAlbum], total: Int) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MusicBrainz browse is not a JSON object")
        }
        let groups = root["release-groups"] as? [[String: Any]] ?? []
        let albums: [CDAlbum] = groups.compactMap { g in
            guard let id = MBID.validated(g["id"] as? String) else { return nil }
            return CDAlbum(id: id, title: g["title"] as? String ?? "", artist: artist, releaseType: g["primary-type"] as? String ?? "",
                           secondaryTypes: g["secondary-types"] as? [String] ?? [], firstReleaseDate: g["first-release-date"] as? String ?? "",
                           editions: [], editionsLoaded: false)
        }
        return (albums, root["release-group-count"] as? Int ?? albums.count)
    }

    /// Studio albums first, then live albums, other albums, compilations and EPs; oldest first within each.
    public static func sorted(_ albums: [CDAlbum]) -> [CDAlbum] {
        func rank(_ a: CDAlbum) -> Int {
            if a.releaseType == "Album" {
                if a.secondaryTypes.isEmpty { return 0 }
                if a.secondaryTypes == ["Live"] { return 1 }
                if !a.secondaryTypes.contains("Compilation") { return 2 }
                return 3
            }
            return a.releaseType == "EP" ? 4 : 5
        }
        return albums.enumerated().sorted { x, y in
            let a = x.element, b = y.element
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            let da = a.firstReleaseDate, db = b.firstReleaseDate
            if da != db {
                if da.isEmpty { return false }
                if db.isEmpty { return true }
                return da < db
            }
            return x.offset < y.offset
        }.map(\.element)
    }
}

/// What the user types to find a CD: album and artist, and optionally a barcode or catalog number from the case.
public struct CDSearchQuery: Hashable, Sendable {
    public var album: String
    public var artist: String
    public var code: String

    public init(album: String = "", artist: String = "", code: String = "") {
        self.album = album; self.artist = artist; self.code = code
    }

    public var isEmpty: Bool { [album, artist, code].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// The code's digits when it reads as a UPC/EAN barcode (8 to 14 digits, spaces and dashes allowed).
    public var barcode: String? {
        let t = code.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return nil }
        let digits = t.filter(\.isNumber)
        return (8...14).contains(digits.count) ? digits : nil
    }

    /// The Lucene query for MusicBrainz's release search. Album and artist match word by word, each word also as
    /// the start of a longer one ("creed revival" finds Creedence Clearwater Revival), so a few words of each
    /// find everything that has them; `loose` (tried when that finds nothing) needs any one word per field.
    public func luceneQuery(loose: Bool = false) -> String {
        func phrase(_ s: String) -> String { "\"\(MusicBrainzClient.luceneEscape(s.trimmingCharacters(in: .whitespaces)))\"" }
        var parts: [String] = []
        if let barcode {
            // MusicBrainz stores UPCs both as 12 digits and as 13 with a leading zero.
            var forms = [barcode]
            if barcode.count == 12 { forms.append("0" + barcode) }
            if barcode.count == 13, barcode.hasPrefix("0") { forms.append(String(barcode.dropFirst())) }
            parts.append("barcode:(" + forms.joined(separator: " OR ") + ")")
        } else if !code.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("catno:" + phrase(code))
        }
        if let album = Self.terms("release", album, loose: loose) { parts.append(album) }
        if let artist = Self.terms("artist", artist, loose: loose) { parts.append(artist) }
        if barcode == nil, !parts.isEmpty { parts.append("format:CD") }
        return parts.joined(separator: " AND ")
    }

    public var luceneQuery: String { luceneQuery() }

    /// "(release:green* AND release:river*)"; words like "the" are left out unless there's nothing else.
    static func terms(_ field: String, _ text: String, loose: Bool) -> String? {
        let all = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || "\"“”„«»()[]:,/&+!?".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'’.")) }
            .filter { !$0.isEmpty }
        let significant = all.filter { !CDOfferMatcher.ignored.contains($0) }
        let words = (significant.isEmpty ? all : significant)
        guard !words.isEmpty else { return nil }
        let clauses = words.map { "\(field):\(MusicBrainzClient.luceneEscape($0))" + ($0.count > 1 ? "*" : "") }
        return clauses.count == 1 ? clauses[0] : "(" + clauses.joined(separator: loose ? " OR " : " AND ") + ")"
    }

    /// The artist search for a search by artist alone, matched the same way.
    public var artistQuery: String? { Self.terms("artist", artist, loose: false) }
}

public enum CDEditionParser {
    /// Media formats that are CDs ("CD", "Enhanced CD", "HDCD", "SHM-CD", "Blu-spec CD", "Hybrid SACD"…).
    public static func isCD(_ format: String) -> Bool {
        let f = format.uppercased()
        return f.contains("CD") && !f.contains("VCD") && !f.contains("CDV") && !f.contains("CD-ROM")
    }

    /// The CD editions in a MusicBrainz release search, in its order (best match first).
    public static func parseSearch(_ data: Data) throws -> [CDEdition] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MusicBrainz search is not a JSON object")
        }
        return (root["releases"] as? [[String: Any]] ?? []).compactMap(edition)
    }

    static func edition(_ r: [String: Any]) -> CDEdition? {
        guard let id = MBID.validated(r["id"] as? String) else { return nil }
        let media = r["media"] as? [[String: Any]] ?? []
        let formats = media.map { $0["format"] as? String ?? "" }
        guard formats.contains(where: isCD) else { return nil }
        let labels = r["label-info"] as? [[String: Any]] ?? []
        let group = r["release-group"] as? [String: Any]
        let tracks = (r["track-count"] as? Int) ?? media.reduce(0) { $0 + ($1["track-count"] as? Int ?? 0) }
        return CDEdition(
            id: id, title: r["title"] as? String ?? "", artist: MusicBrainzParser.creditString(r["artist-credit"]),
            date: r["date"] as? String ?? "", country: r["country"] as? String ?? "",
            label: MusicBrainzParser.joinedUnique(labels.compactMap { ($0["label"] as? [String: Any])?["name"] as? String }),
            catalogNumber: MusicBrainzParser.joinedUnique(labels.compactMap { $0["catalog-number"] as? String }),
            barcode: r["barcode"] as? String ?? "", format: formatSummary(formats), trackCount: tracks,
            status: r["status"] as? String ?? "", packaging: r["packaging"] as? String ?? "",
            disambiguation: r["disambiguation"] as? String ?? "",
            releaseGroupId: MBID.validated(group?["id"] as? String),
            releaseGroupTitle: group?["title"] as? String ?? "", releaseType: group?["primary-type"] as? String ?? "")
    }

    /// ["CD", "CD"] → "2×CD"; ["CD", "DVD-Video"] → "CD + DVD-Video".
    static func formatSummary(_ formats: [String]) -> String {
        var counts: [(String, Int)] = []
        for f in formats.map({ $0.isEmpty ? "Unknown" : $0 }) {
            if let i = counts.firstIndex(where: { $0.0 == f }) { counts[i].1 += 1 } else { counts.append((f, 1)) }
        }
        return counts.map { $0.1 > 1 ? "\($0.1)×\($0.0)" : $0.0 }.joined(separator: " + ")
    }

    /// Editions grouped by album in the order the albums first appear, albums with an official edition first
    /// (bootlegs reuse barcodes); each album's editions oldest first.
    public static func albums(_ editions: [CDEdition]) -> [CDAlbum] {
        var out: [CDAlbum] = []
        var index: [String: Int] = [:]
        for e in editions {
            let key = e.releaseGroupId ?? e.id
            if let i = index[key] {
                out[i].editions.append(e)
            } else {
                index[key] = out.count
                out.append(CDAlbum(id: key, title: e.releaseGroupTitle.isEmpty ? e.title : e.releaseGroupTitle,
                                   artist: e.artist, releaseType: e.releaseType, editions: [e]))
            }
        }
        for i in out.indices {
            out[i].editions = out[i].editions.enumerated().sorted { a, b in
                let da = a.element.date, db = b.element.date
                if da != db {
                    if da.isEmpty { return false }
                    if db.isEmpty { return true }
                    return da < db
                }
                return a.offset < b.offset
            }.map(\.element)
        }
        let official = out.map { $0.editions.contains { $0.status == "Official" } }
        return out.indices.sorted { a, b in official[a] != official[b] ? official[a] : a < b }.map { out[$0] }
    }
}

// MARK: Links to the stores

/// Where MusicBrainz says an edition (and its album) can be found on other sites.
public struct CDShopLinks: Hashable, Codable, Sendable {
    public var discogsRelease: Int?
    public var discogsMaster: Int?
    public var asin: String?

    public init(discogsRelease: Int? = nil, discogsMaster: Int? = nil, asin: String? = nil) {
        self.discogsRelease = discogsRelease; self.discogsMaster = discogsMaster; self.asin = asin
    }

    /// Reads the url-rels of a release or release group lookup (`inc=url-rels`).
    public static func parse(_ data: Data) throws -> CDShopLinks {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MusicBrainz lookup is not a JSON object")
        }
        var links = CDShopLinks()
        for r in root["relations"] as? [[String: Any]] ?? [] {
            guard r["ended"] as? Bool != true, let res = (r["url"] as? [String: Any])?["resource"] as? String,
                  let url = URL(webLink: res), let host = url.host?.lowercased() else { continue }
            let parts = url.pathComponents.filter { $0 != "/" }
            switch r["type"] as? String {
            case "discogs":
                guard host == "discogs.com" || host.hasSuffix(".discogs.com"), parts.count >= 2,
                      let id = Int(parts[1].prefix { $0.isNumber }), id > 0 else { continue }
                if parts[0] == "release", links.discogsRelease == nil { links.discogsRelease = id }
                if parts[0] == "master", links.discogsMaster == nil { links.discogsMaster = id }
            case "amazon asin":
                guard host.contains("amazon."), let asin = parts.last,
                      asin.count == 10, asin.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { continue }
                if links.asin == nil { links.asin = asin }
            default:
                continue
            }
        }
        return links
    }

    func merged(with other: CDShopLinks) -> CDShopLinks {
        CDShopLinks(discogsRelease: discogsRelease ?? other.discogsRelease, discogsMaster: discogsMaster ?? other.discogsMaster,
                    asin: asin ?? other.asin)
    }
}

extension MusicBrainzClient {
    /// CD editions matching a search, at most 100.
    public func searchCDEditions(_ query: CDSearchQuery) async throws -> [CDEdition] {
        func search(_ lucene: String) async throws -> [CDEdition] {
            guard !lucene.isEmpty, var c = URLComponents(string: "\(Self.baseURL)/release") else { return [] }
            c.queryItems = [.init(name: "query", value: lucene), .init(name: "fmt", value: "json"), .init(name: "limit", value: "100")]
            guard let url = c.url else { return [] }
            return try CDEditionParser.parseSearch(try await fetchData(url))
        }
        let found = try await search(query.luceneQuery())
        if !found.isEmpty || query.barcode != nil { return found }
        // Nothing has every word: any of them, best matches first.
        return try await search(query.luceneQuery(loose: true))
    }

    /// Artists matching a name, best first.
    public func searchArtists(_ name: String) async throws -> [CDArtist] {
        guard let query = CDSearchQuery(artist: name).artistQuery, var c = URLComponents(string: "\(Self.baseURL)/artist") else { return [] }
        c.queryItems = [.init(name: "query", value: query), .init(name: "fmt", value: "json"), .init(name: "limit", value: "10")]
        guard let url = c.url else { return [] }
        return try CDDiscographyParser.parseArtists(try await fetchData(url))
    }

    /// An artist's albums and EPs (all pages, up to 500), in `CDDiscographyParser.sorted` order.
    public func cdAlbums(artist: CDArtist) async throws -> [CDAlbum] {
        guard let id = MBID.validated(artist.id) else { throw NetworkError.badResponse("not a MusicBrainz artist ID") }
        var albums: [CDAlbum] = []
        var offset = 0
        while offset < 500 {
            guard var c = URLComponents(string: "\(Self.baseURL)/release-group") else { break }
            c.percentEncodedQuery = "artist=\(id)&type=album%7Cep&limit=100&offset=\(offset)&fmt=json"
            guard let pageURL = c.url else { break }
            let page = try CDDiscographyParser.parseAlbums(try await fetchData(pageURL), artist: artist.name)
            albums += page.albums
            offset += 100
            if page.albums.isEmpty || offset >= page.total { break }
        }
        return CDDiscographyParser.sorted(albums)
    }

    /// An album's CD editions, oldest first.
    public func cdEditions(releaseGroupId: String) async throws -> [CDEdition] {
        guard let id = MBID.validated(releaseGroupId), var c = URLComponents(string: "\(Self.baseURL)/release") else { return [] }
        c.queryItems = [.init(name: "query", value: "rgid:\(id) AND format:CD"), .init(name: "fmt", value: "json"), .init(name: "limit", value: "100")]
        guard let url = c.url else { return [] }
        let editions = try CDEditionParser.parseSearch(try await fetchData(url)).filter { $0.releaseGroupId == id }
        return CDEditionParser.albums(editions).first?.editions ?? []
    }

    /// One edition, by its MusicBrainz release ID (an album page's "Shop for This CD").
    public func cdEdition(releaseId: String) async throws -> CDEdition? {
        let url = try Self.lookupURL("release", id: releaseId, query: "inc=artist-credits+labels+release-groups+media&fmt=json")
        guard let o = try JSONSerialization.jsonObject(with: try await fetchData(url)) as? [String: Any] else { return nil }
        return CDEditionParser.edition(o)
    }

    /// The edition's Discogs release and Amazon ASIN, and its album's Discogs master.
    public func cdShopLinks(releaseId: String?, releaseGroupId: String?) async throws -> CDShopLinks {
        var links = CDShopLinks()
        if let releaseId, MBID.validated(releaseId) != nil {
            links = try CDShopLinks.parse(try await fetchData(Self.lookupURL("release", id: releaseId, query: "inc=url-rels&fmt=json")))
        }
        if let releaseGroupId, MBID.validated(releaseGroupId) != nil {
            let group = try CDShopLinks.parse(try await fetchData(Self.lookupURL("release-group", id: releaseGroupId, query: "inc=url-rels&fmt=json")))
            links = links.merged(with: group)
        }
        return links
    }
}

// MARK: Stores

public enum CDShop: String, Codable, CaseIterable, Sendable, Identifiable {
    case discogs, ebay, cdandlp, alibris
    case amazon, walmart, halfPriceBooks, barnesAndNoble

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .discogs: "Discogs"
        case .ebay: "eBay"
        case .cdandlp: "CDandLP"
        case .alibris: "Alibris"
        case .amazon: "Amazon"
        case .walmart: "Walmart"
        case .halfPriceBooks: "Half Price Books"
        case .barnesAndNoble: "Barnes & Noble"
        }
    }

    /// Stores whose listings the app reads; the others are links to a search on their site.
    public static let searched: [CDShop] = [.discogs, .ebay, .cdandlp, .alibris]
    public static let linked: [CDShop] = [.amazon, .walmart, .halfPriceBooks, .barnesAndNoble]

    public var home: URL {
        switch self {
        case .discogs: URL(string: "https://www.discogs.com/")!
        case .ebay: URL(string: "https://www.ebay.com/")!
        case .cdandlp: URL(string: "https://www.cdandlp.com/en/")!
        case .alibris: URL(string: "https://www.alibris.com/")!
        case .amazon: URL(string: "https://www.amazon.com/")!
        case .walmart: URL(string: "https://www.walmart.com/")!
        case .halfPriceBooks: URL(string: "https://www.hpb.com/")!
        case .barnesAndNoble: URL(string: "https://www.barnesandnoble.com/")!
        }
    }

    /// The site's domain; listing and image links from a page must be https on it (or a subdomain), see `owns`.
    var domains: [String] {
        switch self {
        case .discogs: ["discogs.com"]
        case .ebay: ["ebay.com", "ebayimg.com", "ebaystatic.com"]
        case .cdandlp: ["cdandlp.com"]
        case .alibris: ["alibris.com", "alibris-static.com"]
        case .amazon: ["amazon.com"]
        case .walmart: ["walmart.com"]
        case .halfPriceBooks: ["hpb.com"]
        case .barnesAndNoble: ["barnesandnoble.com"]
        }
    }

    /// Whether `url` is an https link on this store's site.
    public func owns(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// What's being shopped for: one edition, any CD edition of an album, or (for a CD MusicBrainz doesn't list,
/// `isByName`) whatever the user typed.
public struct CDShoppingTarget: Hashable, Sendable {
    public var album: String
    public var artist: String
    public var releaseGroupId: String?
    /// nil: any CD edition of the album.
    public var edition: CDEdition?
    public var links: CDShopLinks
    /// A barcode the user typed, for a CD found by name.
    public var typedBarcode: String?

    public init(album: String, artist: String, releaseGroupId: String?, edition: CDEdition?, links: CDShopLinks = CDShopLinks()) {
        self.album = album; self.artist = artist; self.releaseGroupId = releaseGroupId; self.edition = edition; self.links = links
    }

    /// The CD as typed, for one that isn't on MusicBrainz: only the stores' own searches find it.
    public init(byName query: CDSearchQuery) {
        func clean(_ s: String) -> String {
            s.filter { !"\"“”„«»".contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        self.init(album: clean(query.album), artist: clean(query.artist), releaseGroupId: nil, edition: nil)
        typedBarcode = query.barcode
    }

    public var isByName: Bool { releaseGroupId == nil && edition == nil }

    /// Digits of the edition's barcode, when it has a usable one.
    public var barcode: String? { edition.flatMap { CDSearchQuery(code: $0.barcode).barcode } ?? typedBarcode }

    /// "Radiohead OK Computer": what to type into a store's search box.
    public var keywords: String {
        let artist = artist.lowercased() == "various artists" ? "" : artist
        return [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// A store page to read (or open) for a target.
public struct CDShopRequest: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Listings of exactly the edition (a Discogs release, an eBay barcode search).
        case edition
        /// Listings of the album on CD, any edition (a Discogs master).
        case album
        /// A keyword search: results need checking against the title.
        case keywords
    }

    public var shop: CDShop
    public var url: URL
    public var kind: Kind
}

public enum CDShopURLs {
    static func make(_ base: String, _ items: [(String, String)]) -> URL? {
        guard var c = URLComponents(string: base) else { return nil }
        c.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url
    }

    /// The pages the app reads for a target, in the order they're read per store.
    public static func requests(for target: CDShoppingTarget) -> [CDShopRequest] {
        var out: [CDShopRequest] = []
        // A typed title is rarely the store's ("Perspective – Best Of The Live Sessions From Osl…"), and the stores
        // want every word: search by the artist and let the matcher pick the listings that name the album.
        let words = target.isByName && !target.artist.isEmpty ? target.artist : target.keywords
        // Discogs: the edition's listings, else every CD edition of the album.
        if target.edition != nil, let id = target.links.discogsRelease,
           let url = make("https://www.discogs.com/shop/list", [("release", String(id)), ("ships_to", "US"), ("sort", "price"), ("sortOrder", "ascending")]) {
            out.append(CDShopRequest(shop: .discogs, url: url, kind: .edition))
        } else if let id = target.links.discogsMaster,
                  let url = make("https://www.discogs.com/shop/list", [("master", String(id)), ("formatName", "CD"), ("ships_to", "US"), ("sort", "price"), ("sortOrder", "ascending")]) {
            out.append(CDShopRequest(shop: .discogs, url: url, kind: .album))
        }
        // eBay's Music CDs category; by barcode (cheapest first, with shipping), and by name.
        if let barcode = target.barcode,
           let url = make("https://www.ebay.com/sch/i.html", [("_nkw", barcode), ("_sacat", "176984"), ("_sop", "15")]) {
            out.append(CDShopRequest(shop: .ebay, url: url, kind: .edition))
        }
        if !words.isEmpty, let url = make("https://www.ebay.com/sch/i.html", [("_nkw", words), ("_sacat", "176984")]) {
            out.append(CDShopRequest(shop: .ebay, url: url, kind: .keywords))
        }
        if !words.isEmpty, let url = make("https://www.cdandlp.com/en/search/", [("q", words)]) {
            out.append(CDShopRequest(shop: .cdandlp, url: url, kind: .keywords))
        }
        if !words.isEmpty, let url = make("https://www.alibris.com/search/music", [("keyword", words)]) {
            out.append(CDShopRequest(shop: .alibris, url: url, kind: .keywords))
        }
        return out
    }

    /// The store's own search for the target, to open in a browser.
    public static func browse(_ shop: CDShop, for target: CDShoppingTarget) -> URL? {
        let words = target.keywords
        let code = target.barcode ?? words
        switch shop {
        case .discogs:
            if target.edition != nil, let id = target.links.discogsRelease {
                return make("https://www.discogs.com/sell/release/\(id)", [("ships_to", "US")])
            }
            if let id = target.links.discogsMaster {
                return make("https://www.discogs.com/sell/list", [("master_id", String(id)), ("format", "CD"), ("ships_to", "US")])
            }
            return make("https://www.discogs.com/search/", [("q", words), ("type", "release"), ("format_exact", "CD")])
        case .ebay:
            return make("https://www.ebay.com/sch/i.html", [("_nkw", code), ("_sacat", "176984")])
        case .cdandlp:
            return make("https://www.cdandlp.com/en/search/", [("q", words)])
        case .alibris:
            return make("https://www.alibris.com/search/music", [("keyword", words)])
        case .amazon:
            if let asin = target.edition != nil ? target.links.asin : nil { return URL(string: "https://www.amazon.com/dp/\(asin)") }
            return make("https://www.amazon.com/s", [("k", code), ("i", "popular")])
        case .walmart:
            return make("https://www.walmart.com/search", [("q", code)])
        case .halfPriceBooks:
            return make("https://www.hpb.com/search", [("q", words)])
        case .barnesAndNoble:
            return make("https://www.barnesandnoble.com/s/" + (code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""), [])
        }
    }
}

// MARK: Offers

public struct Money: Hashable, Codable, Sendable, Comparable {
    public var amount: Decimal
    /// ISO 4217 code.
    public var currency: String

    public init(_ amount: Decimal, _ currency: String) { self.amount = amount; self.currency = currency }

    public static func < (a: Money, b: Money) -> Bool { a.amount < b.amount }

    /// "$22.59", "US $5.00", "€3.00", "17.21 €", "£12", "about $27.32", "+ $7.49", "$10.98 to $15.00" (the
    /// lower end), "1,234.50"; nil without a recognizable currency or amount.
    public static func parse(_ text: String, defaultCurrency: String? = nil) -> Money? {
        let t = text.replacingOccurrences(of: "\u{a0}", with: " ")
        let symbols: [(String, String)] = [("US $", "USD"), ("US$", "USD"), ("C $", "CAD"), ("C$", "CAD"), ("CA$", "CAD"),
                                           ("AU $", "AUD"), ("A$", "AUD"), ("AU$", "AUD"), ("£", "GBP"), ("€", "EUR"),
                                           ("¥", "JPY"), ("$", "USD")]
        var currency = defaultCurrency
        var firstSymbol = t.endIndex
        // An ISO code next to the amount: "SEK 80.00", "80.00 CHF".
        if let r = t.range(of: #"[A-Z]{3}(?=\s*\d)|(?<=\d\s?)[A-Z]{3}\b"#, options: .regularExpression),
           Locale.commonISOCurrencyCodes.contains(String(t[r])) {
            firstSymbol = r.lowerBound
            currency = String(t[r])
        }
        for (sym, code) in symbols {
            if let r = t.range(of: sym), r.lowerBound < firstSymbol {
                firstSymbol = r.lowerBound
                currency = code
            }
        }
        guard let currency else { return nil }
        guard let r = t.range(of: #"\d[\d,]*(\.\d{1,2})?"#, options: .regularExpression) else { return nil }
        let digits = t[r].replacingOccurrences(of: ",", with: "")
        guard let amount = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return Money(amount, currency)
    }

    public func formatted() -> String {
        amount.formatted(.currency(code: currency).locale(Locale(identifier: "en_US")))
    }
}

/// Reads the European Central Bank's reference rates from Frankfurter (https://frankfurter.dev, no key).
public struct ExchangeRates: Hashable, Codable, Sendable {
    /// Units of each currency per US dollar.
    public var perDollar: [String: Decimal]
    public var date: String

    public init(perDollar: [String: Decimal] = [:], date: String = "") { self.perDollar = perDollar; self.date = date }

    public static let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=USD")!

    public static func parse(_ data: Data) throws -> ExchangeRates {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["base"] as? String) == "USD", let rates = o["rates"] as? [String: Any] else {
            throw NetworkError.badResponse("exchange rates are malformed")
        }
        var out: [String: Decimal] = [:]
        for (code, value) in rates {
            if let n = value as? NSNumber, n.doubleValue > 0 { out[code] = Decimal(string: n.stringValue) ?? Decimal(n.doubleValue) }
        }
        return ExchangeRates(perDollar: out, date: o["date"] as? String ?? "")
    }

    /// The amount in US dollars, or nil for a currency without a rate.
    public func dollars(_ money: Money) -> Decimal? {
        if money.currency == "USD" { return money.amount }
        guard let rate = perDollar[money.currency], rate > 0 else { return nil }
        var value = money.amount / rate, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded
    }
}

public struct CDOffer: Identifiable, Hashable, Sendable {
    public enum Condition: String, Hashable, Sendable { case new, used, unknown }

    /// How sure it is that this is the edition being shopped for.
    public enum Match: Int, Hashable, Comparable, Sendable {
        /// Found by keywords: probably the album, edition unknown.
        case possible
        /// The album on CD, another or unknown edition.
        case album
        /// Listed as this edition (Discogs release, barcode, catalog number).
        case edition

        public static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String
    public var shop: CDShop
    public var title: String
    /// The edition as the listing describes it: "1997 · US · Capitol · CDP 7243 8 55229 2 5".
    public var edition: String
    public var condition: Condition
    /// "Pre-Owned", "Very Good Plus (VG+) / sleeve Near Mint (NM or M-)".
    public var conditionText: String
    public var notes: String
    public var price: Money
    /// nil: not shown on the page (see `shippingNote`).
    public var shipping: Money?
    public var shippingNote: String
    /// Price plus shipping in dollars, when the store worked it out (Discogs' "about $27.32").
    public var quotedTotal: Money?
    public var seller: String
    public var sellerRating: String
    public var shipsFrom: String
    /// "Buy It Now", "Auction · 3 bids", "or Best Offer"; "from" for a store's lowest price over several copies.
    public var saleFormat: String
    public var url: URL
    public var imageURL: URL?
    public var match: Match

    public init(id: String, shop: CDShop, title: String, edition: String = "", condition: Condition = .unknown,
                conditionText: String = "", notes: String = "", price: Money, shipping: Money? = nil, shippingNote: String = "",
                quotedTotal: Money? = nil, seller: String = "", sellerRating: String = "", shipsFrom: String = "",
                saleFormat: String = "", url: URL, imageURL: URL? = nil, match: Match) {
        self.id = id; self.shop = shop; self.title = title; self.edition = edition; self.condition = condition
        self.conditionText = conditionText; self.notes = notes; self.price = price; self.shipping = shipping
        self.shippingNote = shippingNote; self.quotedTotal = quotedTotal; self.seller = seller
        self.sellerRating = sellerRating; self.shipsFrom = shipsFrom; self.saleFormat = saleFormat; self.url = url
        self.imageURL = imageURL; self.match = match
    }

    /// Price plus shipping in US dollars when known (shipping unknown counts as nothing).
    public func totalDollars(_ rates: ExchangeRates) -> Decimal? {
        if let quotedTotal, let d = rates.dollars(quotedTotal) { return d }
        guard let price = rates.dollars(price) else { return nil }
        guard let shipping else { return price }
        guard let s = rates.dollars(shipping) else { return nil }
        return price + s
    }
}

// MARK: Matching

public enum CDOfferMatcher {
    static let ignored: Set<String> = ["the", "a", "an", "and", "of", "from", "at", "in", "on", "with", "cd", "album", "edition", "deluxe", "remastered", "remaster"]

    static func words(_ s: String) -> [String] {
        TextNormalizer.normalize(s).lowercased().split(separator: " ").map(String.init).filter { !ignored.contains($0) }
    }

    /// Whether a listing's text names the album: every significant word of its title is in it (or, with a
    /// `fraction` below 1, at least that share of them: for a title the user typed, which may not be the store's).
    public static func names(_ text: String, album: String, fraction: Double = 1) -> Bool {
        let wanted = words(album)
        guard !wanted.isEmpty else { return true }
        let have = Set(words(text))
        // Sellers cut titles off mid-word to fit eBay's 80 characters ("…Live Sessions From Osl (UK IMPORT)"):
        // a word that starts one wanted, missing at most two letters, counts.
        let stubs = have.filter { $0.count >= 3 }
        func found(_ w: String) -> Bool {
            have.contains(w) || stubs.contains { w.count - $0.count <= 2 && w.hasPrefix($0) }
        }
        let found = wanted.filter(found).count
        return fraction >= 1 ? found == wanted.count : Double(found) >= (Double(wanted.count) * fraction).rounded(.up)
    }

    /// Letters and digits only, for comparing catalog numbers and barcodes: "CDP 7243 8 55229 2 5" → "cdp7243855229 25".
    static func compact(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Whether a listing's edition details carry the edition's catalog number or barcode.
    public static func mentions(_ text: String, edition: CDEdition) -> Bool {
        let hay = compact(text)
        guard !hay.isEmpty else { return false }
        let codes = edition.catalogNumber.components(separatedBy: "; ").map(compact) + [compact(edition.barcode)]
        return codes.contains { $0.count >= 5 && hay.contains($0) }
    }

    static let otherFormats = ["vinyl", " lp", "lp ", "[lp]", "cassette", "8-track", "8 track", "dvd", "blu-ray", "bluray", "minidisc", "reel to reel"]

    /// Keeps the offers that are for the target and sets how well each matches; best matches first, then cheapest.
    public static func filter(_ offers: [CDOffer], for target: CDShoppingTarget, rates: ExchangeRates) -> [CDOffer] {
        var seen = Set<String>()
        var out: [CDOffer] = []
        for var offer in offers where seen.insert(offer.id).inserted {
            let text = " " + offer.title.lowercased() + " "
            if offer.match != .edition, otherFormats.contains(where: text.contains), !text.contains(" cd") { continue }
            // Several albums in one listing.
            if text.range(of: #"\blots?\b|\bbundle\b"#, options: .regularExpression) != nil { continue }
            switch offer.match {
            case .edition:
                // A barcode search also finds listings that only mention it.
                guard offer.shop == .discogs || names(offer.title, album: target.album, fraction: target.isByName ? 0.5 : 1) else { continue }
            case .album:
                break
            case .possible:
                guard names(offer.title + " " + offer.edition, album: target.album, fraction: target.isByName ? 0.5 : 1) else { continue }
                // eBay titles often leave the artist out; the other stores' titles start with it ("Artist – Title"),
                // which keeps out tributes that name the artist in their title.
                if offer.shop != .ebay, target.artist.lowercased() != "various artists",
                   !names(offer.title.components(separatedBy: " – ").first ?? offer.title, album: target.artist) { continue }
                if let edition = target.edition, mentions(offer.title + " " + offer.edition, edition: edition) {
                    offer.match = .edition
                }
            }
            if offer.match == .edition, target.edition == nil { offer.match = .album }
            out.append(offer)
        }
        return out.sorted { a, b in
            if a.match != b.match { return a.match > b.match }
            let ta = a.totalDollars(rates), tb = b.totalDollars(rates)
            switch (ta, tb) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id < b.id
            }
        }
    }
}

/// Discogs' public marketplace summary for a release (`/marketplace/stats/<id>`, no sign-in).
public struct DiscogsMarketStats: Hashable, Sendable {
    public var forSale: Int
    public var lowest: Money?

    public static func parse(_ data: Data) throws -> DiscogsMarketStats {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("Discogs stats are not a JSON object")
        }
        var lowest: Money?
        if let p = o["lowest_price"] as? [String: Any], let v = p["value"] as? NSNumber, let c = p["currency"] as? String {
            lowest = Money(Decimal(string: v.stringValue) ?? Decimal(v.doubleValue), c)
        }
        return DiscogsMarketStats(forSale: o["num_for_sale"] as? Int ?? 0, lowest: lowest)
    }

    public static func url(release: Int) -> URL? {
        URL(string: "https://api.discogs.com/marketplace/stats/\(release)?curr_abbr=USD")
    }
}
